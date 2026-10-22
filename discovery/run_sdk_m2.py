#!/usr/bin/env python3
"""Measure selected LiveKit and watchdog journeys on one fresh owned simulator."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
import uuid

from sdk_m0_conformance import executable
from sdk_m2_conformance import PRODUCT_FILES, digest, source_identity, validate, validate_build

ROOT = Path(__file__).resolve().parent.parent
EXAMPLE = 'dev.iosvoipsdk.example'
CONTRACTS = 'dev.iosvoipsdk.m1contracts'


def write(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def command(args, timeout=30, log=None, check=True, env=None):
    try:
        result = subprocess.run(list(map(str, args)), capture_output=True, timeout=timeout, env=env)
    except subprocess.TimeoutExpired as error:
        if log is not None:
            with log.open('ab') as stream:
                stream.write((error.stdout or b'') + (error.stderr or b'') + b'\nCommand timed out.\n')
        raise
    if log is not None:
        with log.open('ab') as stream:
            stream.write(result.stdout + result.stderr)
    if check and result.returncode:
        raise RuntimeError(f'{args[0]} failed (exit {result.returncode}); see retained command log')
    return result


def sim(args, **kwargs):
    return command(['xcrun', 'simctl', *args], **kwargs)


def wait_for(read, seconds, process=None, phase='fault handshake'):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = read()
        if value is not None:
            return value
        if process is not None and process.poll() is not None:
            raise RuntimeError(phase + ': supervisor exited before readiness')
        time.sleep(0.05)
    raise RuntimeError(phase + ': deadline before readiness')


def validated_session(raw, run_id):
    try:
        value = json.loads(raw)
    except (ValueError, UnicodeDecodeError) as error:
        raise RuntimeError('runtime session: malformed JSON') from error
    if not isinstance(value, dict):
        raise RuntimeError('runtime session: invalid object')
    pid = value.get('pid')
    expected = dict(schemaVersion=1, runID=run_id, pid=pid, bundleID=EXAMPLE,
                    profile='ios-27.0', notification=f'dev.callkitsim.control.{pid}')
    if (type(pid) is not int or pid <= 0 or value.keys() != expected.keys() or
            any(type(value[k]) is not type(v) or value[k] != v for k, v in expected.items())):
        raise RuntimeError('runtime session: unexpected schema or ownership')
    return value


def retire_session(out, data, name, run_id, udid):
    """Retire only our preceding session before launching the next owned app."""
    path = data / 'Documents/.callkit-simulator/session.json'
    record = dict(runID=run_id, simulatorID=udid, bundleID=EXAMPLE,
                  wallTimeMS=int(time.time() * 1000), retired=False)
    if path.is_symlink():
        raise RuntimeError('session retirement: symbolic link refused')
    if path.exists() and not path.is_file():
        raise RuntimeError('session retirement: non-file refused')
    try:
        raw = path.read_bytes()
    except FileNotFoundError:
        raw = None
    if raw is not None:
        session = validated_session(raw, run_id)
        with (out / (name + '.retired-session.json')).open('xb') as retained:
            retained.write(raw)
        if path.read_bytes() != raw:
            raise RuntimeError('session retirement: session changed before removal')
        path.unlink()
        record.update(retired=True, pid=session['pid'], sessionSHA256=hashlib.sha256(raw).hexdigest())
    write(out / (name + '.retirement.json'), record)


def configure_faults(out, data, name, case, run_id, udid, process, notifier):
    session_path = data / 'Documents/.callkit-simulator/session.json'
    started = time.monotonic()
    progress = dict(runID=run_id, simulatorID=udid, case=case, diagnosticOnly=True, steps=[])

    def phase(label, **fields):
        progress['steps'].append(dict(phase=label, wallTimeMS=int(time.time() * 1000),
                                     elapsedSeconds=round(time.monotonic() - started, 3), **fields))
        write(out / (name + '.handshake.json'), progress)

    def current_session():
        if session_path.is_symlink():
            raise RuntimeError('runtime session: symbolic link refused')
        if session_path.exists() and not session_path.is_file():
            raise RuntimeError('runtime session: non-file refused')
        try:
            raw = session_path.read_bytes()
        except FileNotFoundError:
            return None
        return raw, validated_session(raw, run_id)

    phase('waiting-runtime-session')
    try:
        raw, session = wait_for(current_session, 30, process, phase='runtime session')
    except (OSError, ValueError, RuntimeError) as error:
        phase('runtime-session-failed', error=str(error))
        raise
    pid = session['pid']
    (out / (name + '.session.json')).write_bytes(raw)
    phase('runtime-session-ready', pid=pid)
    nonce = str(uuid.uuid4()).upper()
    request = dict(id=nonce, runID=run_id, pid=pid, bundleID=EXAMPLE, operation='faults',
                   faults=dict(staleAudio=case == 'stale-audio', reportCallbackDelayMS=0, invalidateDuringHandoff=False))
    request_path = out / (name + '.control.request.json')
    write(request_path, request)
    control = data / 'Documents/.callkit-simulator' / run_id
    temporary = control / 'requests' / (nonce + '.tmp')
    shutil.copyfile(request_path, temporary)
    temporary.rename(temporary.with_suffix('.json'))
    phase('notifying-runtime', pid=pid)
    sim(['spawn', udid, notifier, session['notification']], timeout=5, log=out / 'control-notify.log')
    response_path = control / 'responses' / (nonce + '.json')
    try:
        wait_for(lambda: response_path if response_path.is_file() else None, 2, process, phase='fault acknowledgement')
    except RuntimeError as error:
        phase('fault-acknowledgement-failed', error=str(error))
        raise
    response = json.loads(response_path.read_text())
    if not (all(response.get(k) == request[k] for k in ('id', 'runID', 'pid', 'bundleID')) and
            response.get('success') is True and response.get('result') == {'configured': True}):
        raise RuntimeError('runtime refused fault configuration')
    phase('fault-acknowledged', pid=pid)
    retained_response = out / (name + '.control.response.json')
    shutil.copyfile(response_path, retained_response)
    ready = dict(runID=run_id, case=case, pid=pid, staleAudio=case == 'stale-audio')
    ready_path = out / (name + '.control-ready.json')
    write(ready_path, ready)
    write(out / (name + '.control-binding.json'), dict(runID=run_id, case=case, pid=pid, nonce=nonce,
          requestSHA256=digest(request_path), responseSHA256=digest(retained_response), readySHA256=digest(ready_path)))
    temporary = data / 'tmp' / ('sdk-m2-control-' + run_id + '.tmp')
    shutil.copyfile(ready_path, temporary)
    temporary.rename(temporary.with_suffix('.json'))
    phase('ready-published', pid=pid)


def scenario(out, build, run_id, udid, inherited, case, budget, audio_path=None):
    name = 'sdk-m2-' + case
    bundle = EXAMPLE if case in ('livekit', 'stale-audio') else CONTRACTS
    env = os.environ.copy()
    env.update(SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=inherited, SIMCTL_CHILD_CKSIM_RUN_ID=run_id)
    if bundle == EXAMPLE:
        env.update(SIMCTL_CHILD_SDK_M2_CASE=case, SIMCTL_CHILD_SDK_M2_RUN_ID=run_id)
    else:
        env['SIMCTL_CHILD_SDK_M1_CONTRACT_CASE'] = case
        if audio_path is not None:
            env['SIMCTL_CHILD_SDK_M2_AUDIO_PATH'] = audio_path
    data = Path(sim(['get_app_container', udid, bundle, 'data'], timeout=20).stdout.decode().strip())
    if bundle == EXAMPLE:
        retire_session(out, data, name, run_id, udid)
    console_mode = '--console' if bundle == EXAMPLE else '--console-pty'
    args = [sys.executable, ROOT / 'discovery/run_scenario.py', '--console-launcher-stop', '--timeout', str(budget),
            '--output', out / (name + '.log'), '--receipt', out / (name + '.receipt.json'),
            '--run-id', run_id, '--simulator-id', udid, '--scenario', name, '--bundle-id', bundle,
            '--terminate-command', 'xcrun', 'simctl', 'terminate', udid, bundle,
            '--launch-command', 'xcrun', 'simctl', 'launch', console_mode, '--terminate-running-process', udid, bundle]
    with (out / (name + '.supervisor.log')).open('xb') as log:
        process = subprocess.Popen(list(map(str, args)), env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            if bundle == EXAMPLE:
                configure_faults(out, data, name, case, run_id, udid, process, build / 'binaries/cksim-notify')
            if process.wait(timeout=budget + 40):
                raise RuntimeError(name + ' supervisor failed')
        finally:
            if process.poll() is None:
                # Let the strict supervisor retain its failure and run app cleanup.
                try:
                    sim(['terminate', udid, bundle], timeout=10, check=False, log=out / 'failed-app-stop.log')
                except (OSError, subprocess.SubprocessError) as error:
                    with (out / 'failed-app-stop.log').open('a') as stop_log:
                        stop_log.write(str(error) + '\n')
                try:
                    process.wait(timeout=25)
                except subprocess.TimeoutExpired:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill(); process.wait(timeout=5)
            journal = data / 'Documents/.callkit-simulator' / run_id / 'events.jsonl'
            if journal.is_file():
                target = out / (name + '.runtime.jsonl')
                shutil.copyfile(journal, target)
                receipt = out / (name + '.receipt.json')
                if receipt.is_file():
                    value = json.loads(receipt.read_text()); value['journalSHA256'] = digest(target)
                    write(receipt, value)


def redact(out, inherited):
    for path in out.rglob('*.log'):
        before = path.read_bytes(); after = before
        for entry in inherited.split(':'):
            if entry:
                after = after.replace(entry.encode(), b'<inherited-external-library>')
        if after != before:
            path.write_bytes(after)
            receipt = path.with_suffix('.receipt.json')
            if receipt.is_file():
                row = json.loads(receipt.read_text()); row['unredactedTraceSHA256'] = row['traceSHA256']
                row.update(traceSHA256=digest(path), externalLibraryPathsRedacted=True)
                write(receipt, row)


def cleanup(out, udid):
    result = dict(simulatorID=udid, deleted=False, absentFromInventory=False)
    # Each cleanup operation gets its own attempt, including after a hang.
    for operation, field in (('shutdown', 'shutdownExitCode'), ('delete', 'deleteExitCode')):
        try:
            result[field] = sim([operation, udid], timeout=30, check=False, log=out / 'cleanup.log').returncode
        except (OSError, subprocess.SubprocessError) as error:
            result[field] = None
            result[operation + 'Error'] = str(error)
    try:
        remaining = json.loads(sim(['list', 'devices', '-j'], timeout=60).stdout)['devices']
        result['absentFromInventory'] = all(row.get('udid') != udid for rows in remaining.values() for row in rows)
        result['deleted'] = result['deleteExitCode'] == 0 and result['absentFromInventory']
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        result['verificationError'] = str(error)
    write(out / 'cleanup.json', result)


def inherited_dyld(udid, out):
    log = out / 'launch-environment-query.log'
    if 'SIMCTL_CHILD_DYLD_INSERT_LIBRARIES' in os.environ:
        log.write_text('Using explicit per-launch inherited library value (value omitted).\n')
        return os.environ['SIMCTL_CHILD_DYLD_INSERT_LIBRARIES']
    log.write_text('Read inherited DYLD_INSERT_LIBRARIES with a 60-second infrastructure budget.\n')
    try:
        query = sim(['spawn', udid, 'launchctl', 'getenv', 'DYLD_INSERT_LIBRARIES'], timeout=60, check=False)
    except subprocess.TimeoutExpired as error:
        with log.open('ab') as stream:
            stream.write(b'Query timed out.\n' + (error.stderr or b''))
        raise
    with log.open('ab') as stream:
        stream.write(f'Query exit code: {query.returncode}\n'.encode() + query.stderr)
    if query.returncode != 0 or query.stderr:
        raise RuntimeError('cannot read inherited launch environment; see launch-environment-query.log')
    return query.stdout.removesuffix(b'\n').decode()


def create_simulator(out, name, runtime):
    try:
        value = sim(['create', name,
                     os.environ.get('SDK_M2_DEVICE_TYPE', 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro'),
                     runtime], timeout=30).stdout.decode().strip()
        uuid.UUID(value)
        return value
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, KeyboardInterrupt, SystemExit):
        # Creation can succeed in CoreSimulator before its CLI hangs. Recover
        # only our unpredictable exact name, never an existing QA simulator.
        try:
            inventory = json.loads(sim(['list', 'devices', '-j'], timeout=60).stdout)['devices']
            for rows in inventory.values():
                for row in rows:
                    if row.get('name') == name:
                        cleanup(out, row['udid'])
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            (out / 'creation-recovery-error.log').write_text(str(error) + '\n')
        raise


def run(build, out, runtime_id=None, audio_path=None):
    identity = source_identity(ROOT)
    validate_build(build, identity)  # Refuse stale/malformed products before any simctl call.
    if any(k.startswith('SIMCTL_CHILD_CKSIM_') and v for k, v in os.environ.items()):
        raise RuntimeError('plain M2 acceptance refuses inherited CKSIM child overrides')
    out.mkdir()
    for name in (*PRODUCT_FILES, 'build-info.json', 'source-before.json', 'source-after.json'):
        target = out / name; target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(build / name, target)
    write(out / 'source-before.json', identity)
    host = command(['bash', ROOT / 'Tests/AudioCore/run.sh'], timeout=180)
    write(out / 'host-audio-controls.json', dict(source=identity, result=json.loads(host.stdout)))
    runtimes = json.loads(sim(['list', 'runtimes', '-j'], timeout=60).stdout)['runtimes']
    available = [r for r in runtimes if r.get('platform') == 'iOS' and r.get('isAvailable') and
                 (runtime_id is None or runtime_id in (r['identifier'], r.get('name')))]
    if not available:
        raise RuntimeError('requested iOS runtime unavailable')
    runtime = max(available, key=lambda r: tuple(map(int, r['version'].split('.'))))
    major = int(runtime['version'].split('.')[0])
    expected_path = 'modern' if major >= 27 else 'legacy'
    if audio_path is None: audio_path = expected_path
    if audio_path != expected_path:
        raise RuntimeError('requested audio path does not match selected iOS runtime')
    shutil.copyfile(build / 'environment-preflight.json', out / 'environment-preflight.json')
    preflight = json.loads((out / 'environment-preflight.json').read_text())
    selected = preflight.get('selectedRuntime', {})
    if (preflight.get('success') is not True or preflight.get('requested', {}).get('audioPath') != audio_path or
            any(selected.get(k) != runtime[k] for k in ('identifier', 'version', 'buildversion'))):
        raise RuntimeError('M2 preflight differs from selected runtime/audio path')
    write(out / 'runtime.json', {k: runtime[k] for k in ('identifier', 'version', 'buildversion')})
    run_id = str(uuid.uuid4()).upper(); udid = None; inherited = ''
    try:
        udid = create_simulator(out, 'sdk-m2-' + run_id, runtime['identifier'])
        sim(['boot', udid], timeout=60, log=out / 'boot.log')
        sim(['bootstatus', udid, '-b'], timeout=300, log=out / 'boot.log')
        inherited = inherited_dyld(udid, out)
        if any(Path(p).name in ('CKSimRuntime.dylib', 'CKSimLoader.dylib') for p in inherited.split(':') if p):
            raise RuntimeError('plain M2 acceptance refuses external runtime injection')
        write(out / 'environment.json', dict(simulatorID=udid, simulatorRuntimeID=runtime['identifier'],
              simulatorOS=runtime['version'], xcodeVersion=command(['xcodebuild', '-version']).stdout.decode().strip(),
              sdkVersion=command(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version']).stdout.decode().strip(),
              hostArchitecture=os.uname().machine))
        installed = {}
        for bundle, app, prefix in ((EXAMPLE, build / 'apps/example.app', 'example'),
                                    (CONTRACTS, build / 'apps/contracts.app', 'contracts')):
            sim(['install', udid, app], timeout=180, log=out / (prefix + '-install.log'))
            actual = Path(sim(['get_app_container', udid, bundle, 'app'], timeout=20).stdout.decode().strip())
            installed[prefix + 'SHA256'] = digest(executable(actual))
            profiles = list(actual.rglob('IosVoipSDKRuntime.bundle/ios-27.0.json'))
            if len(profiles) != 1:
                raise RuntimeError('installed runtime profile inventory differs')
            installed[prefix + 'ProfileSHA256'] = digest(profiles[0])
            if bundle == EXAMPLE:
                installed['javascriptSHA256'] = digest(actual / 'main.jsbundle')
                framework = actual / 'Frameworks/LiveKitWebRTC.framework'
                installed['livekitWebRTCSHA256'] = digest(framework / 'LiveKitWebRTC')
                installed['livekitWebRTCInfoSHA256'] = digest(framework / 'Info.plist')
        write(out / 'installed.json', installed)
        sim(['privacy', udid, 'grant', 'microphone', EXAMPLE], timeout=30, log=out / 'microphone-permission.log')
        for case, budget in (('livekit', 120), ('stale-audio', 90), ('media-reentrancy', 30), ('audio-lifecycle', 90)):
            scenario(out, build, run_id, udid, inherited, case, budget, audio_path)
    finally:
        if udid:
            cleanup(out, udid)
        redact(out, inherited)
    after = source_identity(ROOT); write(out / 'source-after.json', after)
    if identity != after:
        raise RuntimeError('source changed during M2 capture')
    manifest = dict(schemaVersion=1, product='sdk-m2', scenario='sdk-m2', configuration='Release',
                    mediaAdapter='livekit', ownsSimulator=True, runtimeInjectionRequested=False, audioPath=audio_path,
                    runID=run_id, simulatorID=udid, **identity,
                    files={name: digest(out / name) for name in PRODUCT_FILES},
                    controlFiles={p.name: digest(p) for p in out.iterdir() if p.name.endswith(
                        ('.session.json', '.control.request.json', '.control.response.json', '.control-ready.json', '.control-binding.json'))},
                    externalDYLDInsertLibrariesPresent=bool(inherited),
                    externalDYLDInsertLibrariesSHA256=hashlib.sha256(inherited.encode()).hexdigest())
    for field, filename in dict(sourceBeginSHA256='source-before.json', sourceEndSHA256='source-after.json',
           cleanupSHA256='cleanup.json', environmentSHA256='environment.json', runtimeSHA256='runtime.json',
           installedSHA256='installed.json', buildReceiptSHA256='build-info.json',
           hostAudioControlsSHA256='host-audio-controls.json',
           environmentPreflightSHA256='environment-preflight.json').items():
        manifest[field] = digest(out / filename)
    write(out / 'manifest.json', manifest)
    result = validate(out, source_root=ROOT); write(out / 'summary.json', result)
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(128 + signum))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--runtime')
    parser.add_argument('--audio-path', choices=('legacy', 'modern'))
    options = parser.parse_args()
    try:
        run(options.build_root.resolve(), options.output.resolve(), options.runtime, options.audio_path)
    except (OSError, ValueError, RuntimeError, KeyError, subprocess.SubprocessError) as error:
        print(json.dumps(dict(success=False, error=str(error)), indent=2), file=sys.stderr)
        raise SystemExit(1)
