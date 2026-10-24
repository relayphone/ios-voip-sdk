#!/usr/bin/env python3
"""Tap the separate inspector, then consume its runtime journal and UI screenshots."""
import argparse
import json
from pathlib import Path
import signal
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Tests/RuntimeEvents'))
from run import capture_diagnostics, fixture_session, latest_runtime, launch_fixture, record_environment, remove_simulators, run

BUNDLE = 'dev.callkitsim.eventfixture'


# Provided display: four 60s simctl calls, a 180s cold launch, and the status reply.
def wait_for_inspector(process, log, timeout=480):
    deadline = time.monotonic() + timeout
    while True:
        if process.poll() is not None:
            raise RuntimeError('Inspector exited during startup: ' + log.read_text())
        output = log.read_text()
        if 'Inspector on ' in output:
            return
        if time.monotonic() >= deadline:
            raise RuntimeError('Inspector launch timed out: ' + output)
        time.sleep(0.1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--package', type=Path, required=True)
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--inspector', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--target-simulator')
    parser.add_argument('--display-simulator')
    parser.add_argument('--runtime', help='Require this exact available simulator runtime identifier')
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True)
    project = ROOT / 'Tests/Inspector/UITests.xcodeproj'
    build = out / 'ui-build'
    with (out / 'ui-build.log').open('w') as log:
        subprocess.run(['xcodebuild','build-for-testing','-project',str(project),'-scheme','InspectorUITests',
                        '-destination','generic/platform=iOS Simulator','-derivedDataPath',str(build),
                        'CODE_SIGNING_ALLOWED=NO'], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=300)
    runtimes = json.loads(run('xcrun','simctl','list','runtimes','-j'))['runtimes']
    runtime = latest_runtime(runtimes, args.runtime)
    record_environment(out, runtime)
    print('Selected simulator runtime: ' + runtime, flush=True)
    owned = []
    bridge = tests = None
    target = display = None
    channel = None
    def device(supplied, name):
        if supplied:
            return supplied
        value = run('xcrun','simctl','create',name + str(uuid.uuid4())[:8],
                    'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro',runtime)
        owned.append(value)
        run('xcrun','simctl','boot',value)
        run('xcrun','simctl','bootstatus',value,'-b',timeout=300)
        return value
    try:
        target = device(args.target_simulator, 'M4 Target ')
        print('Installing target fixture before booting the inspector display.', flush=True)
        channel, run_id = launch_fixture(target, args.fixture)
        session = fixture_session(channel, run_id)
        assert session.get('controlTransport') == 'directory-watch-v1', 'fixture must support spawn-free mailbox controls'
        common = [str(ROOT/'Tools/cksim'),'--simulator',target,'--bundle',BUNDLE,
                  '--runtime-dir',str(args.package.resolve()), '--app-container', str(channel.parent.parent)]
        display = device(args.display_simulator, 'M4 Inspector ')
        with (out / 'bridge.log').open('w') as log:
            bridge = subprocess.Popen(common + ['inspect','--app',str(args.inspector.resolve()),
                                      '--inspector-simulator',display], stdout=log, stderr=subprocess.STDOUT)
        wait_for_inspector(bridge, out/'bridge.log')
        with (out / 'ui-test.log').open('w') as log:
            tests = subprocess.Popen(['xcodebuild','test-without-building','-project',str(project),'-scheme','InspectorUITests',
                                      '-destination','platform=iOS Simulator,id='+display,'-derivedDataPath',str(build),
                                      '-resultBundlePath',str(out/'inspector.xcresult'),'CODE_SIGNING_ALLOWED=NO',
                                      '-parallel-testing-enabled','NO','-collect-test-diagnostics','never'], stdout=log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline and tests.poll() is None:
            started = next((line for line in (out/'ui-test.log').read_text().splitlines()
                            if 'Test Case ' in line and 'testAnswerFromInspector' in line and 'started.' in line), None)
            if started:
                break
            time.sleep(0.1)
        else:
            raise RuntimeError('UI test did not start: ' + (out/'ui-test.log').read_text()[-2000:])
        payload = out / 'incoming.json'
        payload.write_text(json.dumps(dict(operation='incoming')))
        timing = dict(testCaseStartLine=started, pushCommandStartedAtMS=int(time.time() * 1000))
        (out/'stimulus-timing.json').write_text(json.dumps(timing))
        run(*common,'push','--payload-file',payload,'--must-report','true')
        timing['pushCommandFinishedAtMS'] = int(time.time() * 1000)
        (out/'stimulus-timing.json').write_text(json.dumps(timing))
        code = tests.wait(timeout=300)
        captured = run(*common, 'watch','--json','--duration','0.3')
        (out/'events.jsonl').write_text(captured+'\n')
        rows = [json.loads(line) for line in captured.splitlines()]
        assert code == 0, (out/'ui-test.log').read_text()[-4000:]
        assert all(all(row[k] == session[k] for k in ('runID', 'pid', 'bundleID')) for row in rows)
        answers = [r for r in rows if r['event']=='action.settled' and r['kind']=='answer']
        assert len(answers)==1 and answers[0]['origin']=='system' and answers[0]['fulfilled']
        assert any(r['event']=='audio.activated' for r in rows)
        run('xcrun','xcresulttool','export','attachments','--path',out/'inspector.xcresult','--output-path',out/'screenshots')
        (out/'environment.txt').write_text(run('xcodebuild','-version')+'\n'+runtime+'\n')
        print(json.dumps(dict(success=True, answerLatencyMS=answers[0]['latencyMS'], screenshots='screenshots/')))
    finally:
        failed = sys.exc_info()[0] is not None
        if target:
            capture_diagnostics(out, target, channel=channel, failed=failed)
        if failed and display:
            capture_diagnostics(out / 'display', display, bundle='dev.callkitsim.inspector', failed=True)
        for process in (tests, bridge):
            if process is not None and process.poll() is None:
                process.send_signal(signal.SIGINT)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        remove_simulators(owned)


if __name__ == '__main__':
    main()
