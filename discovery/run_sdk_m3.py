#!/usr/bin/env python3
"""Dispatch a real tel URL on one fresh simulator; no native ingress injection."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import time
import uuid

import sdk_m0_conformance as m0
import sdk_m3_conformance as gate


def write(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def probe_rows(path):
    rows = []
    if path.exists():
        for line in path.read_text(errors='replace').splitlines():
            if 'PROBE ' in line:
                try:
                    row = json.loads(line.split('PROBE ', 1)[1])
                    if isinstance(row, dict): rows.append(row)
                except ValueError:
                    pass
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--build-receipt', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True, help='fresh private capture directory')
    parser.add_argument('--runtime', help='installed iOS runtime identifier; otherwise latest available')
    parser.add_argument('--device-type', default='com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro')
    parser.add_argument('--preboot-wait-seconds', type=int, default=0,
                        help='bounded owned-UUID announcement checkpoint before boot')
    parser.add_argument('--settings-wait-seconds', type=int, default=0,
                        help='bounded public Settings UI checkpoint; does not select an app automatically')
    args = parser.parse_args()
    if not 0 <= args.preboot_wait_seconds <= 240: parser.error('Preboot checkpoint must be 0...240 seconds')
    if not 0 <= args.settings_wait_seconds <= 240: parser.error('Settings checkpoint must be 0...240 seconds')
    root = Path(__file__).resolve().parent.parent
    os.chdir(root)
    args.out.mkdir(mode=0o700)
    out = args.out.resolve()
    simulator = None
    supervisor = None
    control = None
    original_dyld = None
    dyld_sampled = False
    run_id = str(uuid.uuid4()).upper()
    steps = []
    manifest = dict(schemaVersion=1, scenario='sdk-m3', runID=run_id, ownsSimulator=True,
                    runtimeInjectionRequested=False, directIngressInjectionRequested=False)
    failure = None
    def interrupted(signum, _frame):
        raise InterruptedError('M3 interrupted by signal ' + str(signum))
    saved_handlers = {sig: signal.signal(sig, interrupted) for sig in (signal.SIGTERM, signal.SIGINT)}

    def command(label, argv, timeout=60, env=None, check=True):
        started = time.monotonic()
        result = subprocess.run(argv, capture_output=True, timeout=timeout, env=env)
        steps.append(dict(phase=label, exitCode=result.returncode,
                          elapsedSeconds=round(time.monotonic() - started, 3),
                          stdoutSHA256=hashlib.sha256(result.stdout).hexdigest(),
                          stderrSHA256=hashlib.sha256(result.stderr).hexdigest()))
        # Control diagnostics are kept inside the private capture; environment
        # values and arbitrary system URL/intent payloads are never printed.
        if result.stderr: (out / (label + '.log')).write_bytes(result.stderr)
        if check and result.returncode: raise RuntimeError(label + ' failed; inspect the private capture')
        return result

    def sim(label, *argv, **kwargs):
        return command(label, ['xcrun', 'simctl', *argv], **kwargs)

    def read_dyld(label):
        result = sim(label, 'spawn', simulator, 'launchctl', 'getenv', 'DYLD_INSERT_LIBRARIES',
                     env={**os.environ, 'SIMCTL_CHILD_DYLD_INSERT_LIBRARIES': ''})
        if result.stderr: raise RuntimeError('Cannot read simulator launch environment')
        return None if not result.stdout else result.stdout.removesuffix(b'\n')

    def wait_for(predicate, seconds, message):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            value = predicate()
            if value: return value
            if supervisor.poll() is not None: raise RuntimeError('M3 supervisor exited before ' + message)
            time.sleep(0.05)
        raise RuntimeError('Deadline waiting for ' + message)

    try:
        identity = m0.source_identity()
        app = args.app.resolve()
        build = json.loads(args.build_receipt.read_text())
        gate.check_input_build(app, build, identity)
        manifest.update(identity)
        shutil.copyfile(args.build_receipt, out / 'input-build-receipt.json')
        manifest['inputBuildReceiptSHA256'] = m0.digest(out / 'input-build-receipt.json')
        (out / 'binaries').mkdir()
        shutil.copyfile(m0.executable(app), out / 'binaries/unsigned-example')
        signed = out / 'signed-example.app'
        shutil.copytree(app, signed, symlinks=True)
        request = out / 'requested-entitlements.plist'
        request.write_bytes(plistlib.dumps({'com.apple.developer.calling-app': True}))
        command('sign-owned-copy', ['codesign', '--force', '--sign', '-', '--entitlements', str(request), str(signed)])
        command('verify-owned-signature', ['codesign', '--verify', '--strict', str(signed)])
        entitlements = command('read-signed-entitlements', ['codesign', '--display', '--entitlements', ':-', str(signed)])
        plistlib.loads(entitlements.stdout)
        (out / 'signed-entitlements.plist').write_bytes(entitlements.stdout)
        shutil.copyfile(m0.executable(signed), out / 'binaries/example')
        shutil.copyfile(signed / 'main.jsbundle', out / 'binaries/main.jsbundle')
        shutil.copyfile(signed / 'Info.plist', out / 'Info.plist')
        manifest['files'] = {name: m0.digest(out / name) for name in gate.FILES}
        # Signing is confined to the copy; retain the original build receipt chain.
        gate.check_input_build(app, build, identity)
        runtimes = json.loads(command('runtimes', ['xcrun', 'simctl', 'list', 'runtimes', '-j']).stdout)['runtimes']
        available = [r for r in runtimes if r.get('platform') == 'iOS' and r.get('isAvailable') and
                     (not args.runtime or r.get('identifier') == args.runtime)]
        if not available: raise RuntimeError('Requested iOS simulator runtime is unavailable')
        runtime = max(available, key=lambda r: tuple(int(p) for p in r['version'].split('.')))
        simulator = sim('create', 'create', 'sdk-m3-' + run_id, args.device_type, runtime['identifier']).stdout.decode().strip()
        uuid.UUID(simulator)
        manifest['simulatorID'] = simulator
        print('Created owned M3 simulator ' + simulator + '; boot has not started.', flush=True)
        if args.preboot_wait_seconds:
            checkpoint = dict(runID=run_id, simulatorID=simulator, ownsSimulator=True)
            write(out / 'preboot-checkpoint.json', checkpoint)
            deadline = time.monotonic() + args.preboot_wait_seconds
            observation = out / 'boot-observation.json'
            while not observation.exists():
                if time.monotonic() >= deadline: raise RuntimeError('Deadline waiting for owned UUID announcement')
                time.sleep(0.05)
            if json.loads(observation.read_text()) != checkpoint:
                raise RuntimeError('Preboot observation does not match this owned simulator')
        sim('boot', 'boot', simulator)
        sim('bootstatus', 'bootstatus', simulator, '-b', timeout=300)
        original_dyld = read_dyld('read-original-dyld')
        dyld_sampled = True
        inherited = os.environ.get('SIMCTL_CHILD_DYLD_INSERT_LIBRARIES', (original_dyld or b'').decode())
        if any(Path(p).name in ('CKSimRuntime.dylib', 'CKSimLoader.dylib') for p in inherited.split(':') if p):
            raise RuntimeError('M3 refuses external SDK runtime injection')
        environment = dict(simulatorID=simulator, simulatorRuntimeID=runtime['identifier'],
                           simulatorOS=runtime['version'], simulatorBuild=runtime['buildversion'],
                           xcodeVersion=command('xcode-version', ['xcodebuild', '-version']).stdout.decode().strip())
        write(out / 'environment.json', environment)
        manifest['environmentSHA256'] = m0.digest(out / 'environment.json')
        sim('install', 'install', simulator, str(signed), timeout=180)
        installed = Path(sim('installed-app', 'get_app_container', simulator, gate.BUNDLE, 'app').stdout.decode().strip())
        manifest['installed'] = dict(executableSHA256=m0.digest(m0.executable(installed)),
                                     javascriptSHA256=m0.digest(installed / 'main.jsbundle'),
                                     infoPlistSHA256=m0.digest(installed / 'Info.plist'))
        launch_env = {key: value for key, value in os.environ.items()
                      if not key.startswith(('SIMCTL_CHILD_CKSIM_', 'SIMCTL_CHILD_SDK_M0_', 'SIMCTL_CHILD_SDK_M1_', 'SIMCTL_CHILD_SDK_M2_', 'SIMCTL_CHILD_SDK_M3_'))}
        launch_env.update(SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=inherited, SIMCTL_CHILD_CKSIM_RUN_ID=run_id,
                          SIMCTL_CHILD_SDK_M3_RUN_ID=run_id, SIMCTL_CHILD_SDK_M3_ACCEPTANCE='1')
        control = (out / 'supervisor-control.log').open('wb')
        supervisor = subprocess.Popen([sys.executable, 'discovery/run_scenario.py', '--console-launcher-stop',
            '--timeout', str(args.settings_wait_seconds + 150), '--output', str(out / (gate.NAME + '.log')),
            '--receipt', str(out / (gate.NAME + '.receipt.json')), '--run-id', run_id, '--simulator-id', simulator,
            '--scenario', gate.NAME, '--bundle-id', gate.BUNDLE,
            '--terminate-command', 'xcrun', 'simctl', 'terminate', simulator, gate.BUNDLE,
            '--launch-command', 'xcrun', 'simctl', 'launch', '--console-pty', '--terminate-running-process', simulator, gate.BUNDLE],
            env=launch_env, stdout=control, stderr=subprocess.STDOUT)
        trace = out / (gate.NAME + '.log')
        ready = wait_for(lambda: next((r for r in probe_rows(trace) if r.get('event') == 'm3.listenerReady'), None),
                         60, 'the actual public listener')
        launch = next(r for r in probe_rows(trace) if r.get('event') == 'launch')
        if ready.get('runID') != run_id or ready.get('simulatorID') != simulator or ready.get('pid') != launch.get('pid'):
            raise RuntimeError('M3 listener readiness has mixed launch identity')
        pid = launch['pid']
        data = Path(sim('app-data', 'get_app_container', simulator, gate.BUNDLE, 'data').stdout.decode().strip())
        session = json.loads((data / 'Documents/.callkit-simulator/session.json').read_text())
        if any(session.get(k) != v for k, v in [('runID', run_id), ('pid', pid), ('bundleID', gate.BUNDLE)]):
            raise RuntimeError('Runtime session does not match the launched example')
        if args.settings_wait_seconds:
            checkpoint = dict(runID=run_id, simulatorID=simulator, appPID=pid,
                              requiredMethod='public-settings-ui', selected=False)
            write(out / 'settings-checkpoint.json', checkpoint)
            print('Public Settings checkpoint: ' + str(out / 'settings-checkpoint.json'), flush=True)
            print('Select the example in Calling defaults on owned simulator ' + simulator +
                  ', then write matching selection-observation.json. This step is not automated.', flush=True)
            selection = out / 'selection-observation.json'
            wait_for(lambda: selection.exists(), args.settings_wait_seconds, 'public Settings selection observation')
            observed = json.loads(selection.read_text())
            if any(observed.get(k) != checkpoint[k] for k in ('runID', 'simulatorID', 'appPID')) or \
                    observed.get('method') != 'public-settings-ui' or observed.get('selected') is not True:
                raise RuntimeError('Invalid Settings selection observation')
            manifest['selectionObservationSHA256'] = m0.digest(selection)
        argv = ['xcrun', 'simctl', 'openurl', simulator, gate.URL]
        dispatch = dict(schemaVersion=1, runID=run_id, simulatorID=simulator, appPID=pid,
                        argv=argv, startedWallTimeMS=time.time_ns() // 1_000_000)
        result = command('os-tel-dispatch', argv, timeout=60, check=False)
        dispatch.update(exitCode=result.returncode, finishedWallTimeMS=time.time_ns() // 1_000_000)
        write(out / 'dispatch.json', dispatch)
        manifest['dispatchSHA256'] = m0.digest(out / 'dispatch.json')
        if result.returncode: raise RuntimeError('OS tel dispatch failed; simulator eligibility is unqualified')
        if supervisor.wait(timeout=90): raise RuntimeError('No successful supervised public dialRequest; inspect eligibility and native ingress')
        if m0.source_identity() != identity: raise RuntimeError('M3 source changed during acceptance')
    except (Exception, KeyboardInterrupt) as error:
        failure = dict(type=type(error).__name__, reason=str(error))
    finally:
        # A second cancellation must not skip bounded deletion of this run's
        # simulator. Restore the caller's handlers after owned cleanup completes.
        for sig in saved_handlers: signal.signal(sig, signal.SIG_IGN)
        cleanup = dict(simulatorID=simulator, deleted=False)
        if supervisor is not None and supervisor.poll() is None and simulator:
            try: sim('stop-owned-example', 'terminate', simulator, gate.BUNDLE, timeout=20, check=False)
            except Exception: pass
            try: supervisor.wait(timeout=10)
            except subprocess.TimeoutExpired:
                supervisor.terminate()
                try: supervisor.wait(timeout=5)
                except subprocess.TimeoutExpired: supervisor.kill(); supervisor.wait(timeout=5)
        if control is not None: control.close()
        if simulator:
            cleanup['globalEnvironmentUnchanged'] = False
            if dyld_sampled:
                try:
                    restored = read_dyld('read-final-dyld')
                    cleanup['globalEnvironmentUnchanged'] = restored == original_dyld
                    if restored != original_dyld: failure = dict(reason='Simulator launch environment changed during M3', priorFailure=failure)
                except Exception as error:
                    failure = dict(reason='Could not verify simulator launch environment', type=type(error).__name__, priorFailure=failure)
            try: sim('shutdown', 'shutdown', simulator, timeout=30, check=False)
            except Exception: pass
            try:
                deleted = sim('delete', 'delete', simulator, timeout=60, check=False)
                cleanup.update(deleteExitCode=deleted.returncode, deleted=deleted.returncode == 0)
            except Exception as error:
                cleanup['errorType'] = type(error).__name__
            if not cleanup['deleted']: failure = dict(reason='Owned simulator deletion did not complete', priorFailure=failure)
        write(out / 'cleanup.json', cleanup)
        write(out / 'commands.json', dict(steps=steps))
        manifest['cleanupSHA256'] = m0.digest(out / 'cleanup.json')
        manifest['commandsSHA256'] = m0.digest(out / 'commands.json')
        write(out / 'manifest.json', manifest)
        for sig, handler in saved_handlers.items(): signal.signal(sig, handler)
    if failure is None:
        try: result = gate.validate(out)
        except Exception as error: result = dict(success=False, error=str(error))
    else:
        result = dict(success=False, failure=failure, nativeM3Acceptance='pending')
    write(out / 'summary.json', result)
    print(json.dumps(dict(success=result['success'], capture=str(out), nativeM3Acceptance='measured' if result['success'] else 'pending')))
    return 0 if result['success'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
