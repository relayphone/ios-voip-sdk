#!/usr/bin/env python3
"""Seven external cksim journeys on the simulator already owned by M0.

No simulator creation, installation, DYLD mutation or device access lives here.
Native acceptance is decided by sdk_system_conformance, never by this driver.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
import uuid

import sdk_m0_conformance as m0
from summarize import require

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts/sim'))
from sim import (Session, clear_failure_marker, console_preapp_rejection, failure_is_classified,
                 report_failure, summary)

BUNDLE = 'dev.iosvoipsdk.example'
CASES = ('answer-end', 'decline', 'hold-accept', 'end-accept', 'mute-echo', 'provider-reset', 'push-launch')
SCENARIO_TIMEOUT_SECONDS = 120
PREAPP_ERROR = (f'An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=3):\n'
    f'Simulator device failed to launch {BUNDLE}.\nNo such process\n'
    f'Underlying error (domain=NSPOSIXErrorDomain, code=3):\n'
    f"\tApplication launch for '{BUNDLE}' did not return a process handle nor launch error.\n\tNo such process\n").encode()
# Measured on an owned iOS 27.0 simulator, terminating installed Settings without launching it.
NOT_RUNNING = ('An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=3):\n'
    f'Simulator device failed to terminate {BUNDLE}.\nfound nothing to terminate\n'
    'Underlying error (domain=NSPOSIXErrorDomain, code=3):\n'
    f'\tThe request to terminate "{BUNDLE}" failed. found nothing to terminate\n\tfound nothing to terminate\n')


def _report(label, retry, terminal=True):
    # Host refusal controls inherit GITHUB_STEP_SUMMARY too; only a native
    # owner context may classify them as this job's measured failures.
    if os.environ.get('SIM_FAILURE_MARKER'):
        (report_failure if terminal else summary)(label, retry)


def write(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')


def live(path, probe=False):
    if not path.exists():
        return []
    # Observations may race a live file append. Only the unterminated final
    # line is deferred; every complete PROBE line is parsed strictly. The final
    # gate rereads and hashes the entire original capture without this view.
    rows = []
    for line in path.read_bytes().splitlines(keepends=True):
        if not line.endswith(b'\n'):
            continue
        if probe:
            if b'PROBE ' not in line:
                continue
            line = line.split(b'PROBE ', 1)[1]
        rows.append(json.loads(line))
    return rows


def app_data_container(simulator, supplied=None):
    if supplied is not None:
        container = Path(supplied)
    else:
        result = subprocess.run(['xcrun', 'simctl', 'get_app_container', simulator, BUNDLE, 'data'],
                                capture_output=True, text=True, timeout=60)
        require(result.returncode == 0, 'simctl get_app_container failed: ' + result.stderr)
        raw = result.stdout.removesuffix('\n')
        require(bool(raw), 'Example data container is missing or invalid')
        container = Path(raw)
    require(container.is_absolute() and container.is_dir(), 'Example data container is missing or invalid')
    return container


class Journey:
    def __init__(self, args, directory, case, container):
        self.args, self.root, self.case = args, directory, case
        directory.mkdir()
        self.name = 'sdk-system-' + case
        self.trace = directory / (self.name + '.log')
        self.process = None
        self.bindings, self.controls, self.commands = [], [], []
        self.container = container
        self.runtime = self.container / 'Documents/.callkit-simulator' / args.run_id
        self.journal = self.runtime / 'events.jsonl'
        self.pid = None
        self.checkpoint_observed = False

    def sim(self, *command, timeout=60):
        result = subprocess.run(['xcrun', 'simctl', *command], capture_output=True, text=True, timeout=timeout)
        require(result.returncode == 0, 'simctl ' + command[0] + ' failed: ' + result.stderr)
        return result.stdout.removesuffix('\n')

    def wait(self, condition, seconds=12):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if self.process and self.process.poll() is not None:
                raise RuntimeError('system supervisor exited before checkpoint')
            value = condition()
            if value:
                return value
            time.sleep(.025)
        raise RuntimeError(self.case + ': checkpoint deadline')

    def rows(self):
        rows = live(self.trace, True)
        if rows:
            self.checkpoint()
        return rows

    def checkpoint(self):
        session = getattr(self.args, 'sim_session', None)
        if session is not None and not self.checkpoint_observed:
            try:
                session.checkpoint()
            except (OSError, ValueError, KeyError, TypeError):
                _report('infra:helper', 'checkpoint state unavailable; never retried')
                raise
            self.checkpoint_observed = True

    def engine(self):
        return live(self.journal)

    def snapshot(self, predicate):
        rows = [row for row in self.rows() if row['event'] == 'sdk.snapshot']
        return rows and predicate(rows[-1]['conversations']) and rows[-1]

    def command(self, operation, conversation=None):
        value = dict(id=str(uuid.uuid4()).upper(), runID=self.args.run_id, case=self.case, pid=self.pid, operation=operation)
        if conversation:
            value['conversationID'] = conversation
        name = f'fixture-{len(self.commands):02}.json'
        write(self.root / name, value)
        target = self.container / ('tmp/sdk-system-control-' + self.args.run_id + '.json')
        require(not target.exists(), 'unconsumed fixture command')
        temporary = target.with_suffix('.tmp')
        write(temporary, value)
        temporary.replace(target)
        self.commands.append(name)
        if operation != 'finish':
            self.wait(lambda: any(row['event'] == 'system.commandCompleted' and row.get('id') == value['id'] for row in self.rows()))

    def cli(self, operation, *arguments, expected_error=None):
        name = f'control-{len(self.controls):02}.json'
        command = [str(self.args.package / 'cksim'), '--simulator', self.args.simulator, '--bundle', BUNDLE,
                   '--runtime-dir', str(self.args.package), '--app-container', str(self.container),
                   '--timeout', '10', '--command-receipt', str(self.root / name),
                   operation, *arguments]
        result = subprocess.run(command, capture_output=True, timeout=75)
        (self.root / (name + '.stdout')).write_bytes(result.stdout)
        (self.root / (name + '.stderr')).write_bytes(result.stderr)
        self.controls.append(name)
        response = json.loads(result.stdout)
        require((result.returncode == 1 and response.get('success') is False and expected_error in response.get('error', '')) if expected_error else
                result.returncode == 0, 'cksim ' + operation + ' refused: ' + result.stderr.decode(errors='replace'))
        return response

    def push(self, role, duplicate=False):
        path = self.root / (role + ('-duplicate' if duplicate else '') + '.payload.json')
        payload = dict(incomingCall=dict(eventId='system-event-' + self.args.run_id + '-' + role,
            serverCallId='system-server-' + self.args.run_id + '-' + role,
            caller=dict(id='system-fixture', displayName='System acceptance', phoneNumber='+15555550142'), hasVideo=False))
        write(path, payload)
        response = self.cli('push', '--payload-file', str(path), '--must-report', 'false' if duplicate else 'true')
        if duplicate:
            self.wait(lambda: any(row['event'] == 'push.completed' and row.get('pushID') == response['id'] for row in self.engine()))
            return
        return self.bind(role, response['id'])

    def bind(self, role, push_id):
        report = self.wait(lambda: next((row for row in self.engine() if row['event'] == 'report.incoming' and row.get('pushID') == push_id), None))
        known = {value['conversationID'] for value in self.bindings}
        snapshot = self.wait(lambda: self.snapshot(lambda calls: len([call for call in calls if call['id'] not in known and call['status'] == 'ringing']) == 1))
        call = next(call for call in snapshot['conversations'] if call['id'] not in known and call['status'] == 'ringing')
        binding = dict(role=role, conversationID=call['id'], callUUID=report['callUUID'], pushID=push_id,
                       reportSequence=report['sequence'], snapshotSequence=snapshot['sequence'])
        self.bindings.append(binding)
        return binding

    def settle(self, response):
        ids = response['result']['actionIDs']
        self.wait(lambda: all(any(row['event'] == 'action.settled' and row.get('actionID') == identity and row.get('fulfilled') is True
                                  for row in self.engine()) for identity in ids))

    def answer(self, call):
        self.settle(self.cli('answer', call['callUUID']))
        self.connected(call)

    def connected(self, call):
        # Signaling fulfillment is not backend connection (A8). Wait for the
        # real connecting projection, then issue an explicit public report.
        self.wait(lambda: self.snapshot(lambda calls: any(value['id'] == call['conversationID'] and value['status'] == 'connecting' and 'pending' not in value for value in calls)))
        self.command('backend-connected', call['conversationID'])
        self.wait(lambda: self.snapshot(lambda calls: any(value['id'] == call['conversationID'] and value['status'] == 'connected' and value['hasConnectedAt'] for value in calls)))
        self.wait(lambda: any(row['event'] == 'system.hook' and row.get('conversationID') == call['conversationID'] and row.get('status') == 'connected' and row.get('hasConnectedAt') is True for row in self.rows()))

    def end(self, call, decline=False):
        self.settle(self.cli('decline' if decline else 'end', call['callUUID']))
        self.wait(lambda: self.snapshot(lambda calls: all(value['id'] != call['conversationID'] for value in calls)))

    def start(self, command, env):
        deadline = time.monotonic() + SCENARIO_TIMEOUT_SECONDS
        paths = (self.runtime.parent / 'session.json', self.journal)
        baseline = tuple(path.read_bytes() if path.exists() else None for path in paths)
        receipt_path = self.root / (self.name + '.receipt.json')
        for attempt in range(2):
            remaining = deadline - time.monotonic()
            if attempt and remaining <= 0:
                _report('infra:launch', 'exhausted (aggregate deadline before retry)', terminal=False)
            require(remaining > 0, self.case + ': checkpoint deadline')
            if attempt:
                fresh = (self.pid is None and not (self.bindings or self.controls or self.commands) and
                    tuple(path.read_bytes() if path.exists() else None for path in paths) == baseline and
                    (archived / self.trace.name).read_bytes() == PREAPP_ERROR and
                    (archived / receipt_path.name).read_bytes() == receipt_bytes)
                if not fresh:
                    _report('product:' + self.name, 'startup evidence changed; never retried')
                require(fresh, 'fresh evidence before startup recovery')
            launch = list(command)
            session = getattr(self.args, 'sim_session', None)
            if attempt and session is not None:
                require(not session.is_checkpointed(), 'app checkpoint before startup recovery')
            with (self.root / 'supervisor.log').open('xb') as log:
                remaining = deadline - time.monotonic()
                if attempt and remaining <= 0:
                    _report('infra:launch', 'exhausted (aggregate deadline before retry)', terminal=False)
                require(remaining > 0, self.case + ': checkpoint deadline')
                launch[launch.index('--timeout') + 1] = str(remaining)
                if attempt:
                    clear_failure_marker()
                try:
                    self.process = subprocess.Popen(launch, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                except OSError:
                    _report('infra:launch', 'supervisor transport failed; never retried')
                    raise
            try:
                ready = self.wait(lambda: next((row for row in self.rows() if row['event'] == 'system.ready'), None),
                                  max(0, deadline - time.monotonic()))
                self.checkpoint()
                if attempt:
                    _report('infra:launch', 'recovered (one pre-app retry)', terminal=False)
                return ready
            except RuntimeError as error:
                # Only a completed, exact pre-app rejection is replayable. Any
                # assertion, partial stream, or fresh app/runtime evidence fails.
                if (str(error) != 'system supervisor exited before checkpoint' or attempt or
                        self.case == 'push-launch' or time.monotonic() >= deadline or
                        self.pid is not None or self.bindings or self.controls or self.commands):
                    if attempt:
                        _report('infra:launch', 'exhausted (no further pre-app retry)', terminal=False)
                    raise
                try:
                    receipt_bytes = receipt_path.read_bytes()
                    value = json.loads(receipt_bytes)
                    owner = self.process.pid
                    eligible = (self.process.poll() == 1 and
                        console_preapp_rejection(value, self.trace.read_bytes(),
                            dict(runID=self.args.run_id, simulatorID=self.args.simulator,
                                 scenario=self.name, bundleID=BUNDLE), owner, SCENARIO_TIMEOUT_SECONDS))
                    if eligible:
                        unchanged = tuple(path.read_bytes() if path.exists() else None for path in paths) == baseline
                        if not unchanged:
                            _report('product:' + self.name, 'runtime evidence changed; never retried')
                        eligible = unchanged
                    if eligible:
                        try: os.killpg(owner, 0)
                        except ProcessLookupError: pass
                        else: eligible = False
                except (OSError, ValueError, TypeError):
                    eligible = False
                if not eligible:
                    raise
                # The native entry point installs one shared lifecycle budget.
                # Direct startup controls retain their existing unowned seam.
                if hasattr(self.args, 'sim_session') and (
                        self.args.sim_session is None or not self.args.sim_session.reserve_retry()):
                    _report('infra:launch', 'exhausted (shared pre-app budget unavailable)', terminal=False)
                    raise
                # Keep the complete first attempt; the winning attempt retains
                # the existing filenames and unchanged conformance contract.
                archived = self.root / 'preapp-attempt-1'
                archived.mkdir()
                for path in (self.trace, receipt_path, self.root / 'supervisor.log'):
                    path.rename(archived / path.name)
                _report('infra:launch', 'scheduled (one pre-app retry)', terminal=False)

    def run(self):
        env = dict(os.environ, SIMCTL_CHILD_CKSIM_RUN_ID=self.args.run_id,
            SIMCTL_CHILD_SDK_SYSTEM_RUN_ID=self.args.run_id, SIMCTL_CHILD_SDK_SYSTEM_CASE=self.case,
            SIMCTL_CHILD_SDK_M0_ACCEPTANCE='0', SIMCTL_CHILD_SDK_M1_CASE='')
        session = getattr(self.args, 'sim_session', None)
        if session is not None:
            env['SIM_STATE'] = str(session.path)
        launch = ['xcrun', 'simctl', 'launch', '--console', self.args.simulator, BUNDLE]
        if self.case == 'push-launch':
            path = self.root / 'first.payload.json'
            write(path, dict(incomingCall=dict(eventId='system-event-' + self.args.run_id + '-first',
                serverCallId='system-server-' + self.args.run_id + '-first', caller=dict(id='cold-fixture'), hasVideo=False)))
            launch = [str(self.args.package / 'cksim'), '--simulator', self.args.simulator, '--bundle', BUNDLE,
                '--runtime-dir', str(self.args.package), 'push', '--payload-file', str(path), '--must-report', 'true',
                '--launch', '--run-id', self.args.run_id, '--launch-receipt', str(self.root / 'launch-push.json')]
        command = [sys.executable, str(ROOT / 'discovery/run_scenario.py'), '--console-launcher-stop', '--inherit-launcher-group', '--timeout', str(SCENARIO_TIMEOUT_SECONDS),
            '--output', str(self.trace), '--receipt', str(self.root / (self.name + '.receipt.json')),
            '--run-id', self.args.run_id, '--simulator-id', self.args.simulator, '--scenario', self.name, '--bundle-id', BUNDLE,
            '--terminate-command', 'xcrun', 'simctl', 'terminate', self.args.simulator, BUNDLE, '--launch-command', *launch]
        cleanup_required = False
        phase = 'startup'
        try:
            ready = self.start(command, env)
            phase = 'journey'
            self.pid = ready['pid']
            session = json.loads((self.runtime.parent / 'session.json').read_text())
            require(session['runID'] == self.args.run_id and session['pid'] == self.pid and session['bundleID'] == BUNDLE, 'fresh runtime session differs')
            write(self.root / 'session.json', session)
            if self.case == 'push-launch':
                first = self.bind('first', json.loads((self.root / 'launch-push.json').read_text())['pushID'])
                response = self.cli('answer', first['callUUID'])
                self.wait(lambda: self.snapshot(lambda calls: any(value['id'] == first['conversationID'] and value.get('pending', {}).get('kind') == 'join' and value['pending']['origin'] == 'system' for value in calls)))
                self.command('attach-handler')
                self.settle(response)
                self.connected(first)
                self.end(first)
            else:
                first = self.push('first')
                if self.case == 'decline':
                    self.end(first, True)
                else:
                    self.answer(first)
                    if self.case in ('hold-accept', 'end-accept'):
                        waiting = self.push('waiting')
                        self.settle(self.cli('hold-and-accept' if self.case == 'hold-accept' else 'end-and-accept', waiting['callUUID'], '--active-call', first['callUUID']))
                        self.wait(lambda: self.snapshot(lambda calls: any(value['id'] == first['conversationID'] and value['status'] == 'held' for value in calls) if self.case == 'hold-accept' else all(value['id'] != first['conversationID'] for value in calls)))
                        self.connected(waiting)
                        self.end(waiting)
                        if self.case == 'hold-accept': self.end(first)
                    elif self.case == 'mute-echo':
                        self.settle(self.cli('mute', first['callUUID'], '--muted', 'true'))
                        self.push('first', True)
                        self.command('app-mute', first['conversationID'])
                        self.wait(lambda: any(row['event'] == 'system.handler' and row.get('origin') == 'app' and row.get('kind') == 'mute' for row in self.rows()))
                        self.cli('reset', expected_error='selected-provider reset requires no pending runtime actions')
                        self.settle(self.cli('mute', first['callUUID'], '--muted', 'false'))
                        self.command('release-mute')
                        self.wait(lambda: any(row['event'] == 'action.settled' and row.get('origin') == 'muteEcho' for row in self.engine()))
                        self.settle(self.cli('tones', first['callUUID'], '--digits', '12#A'))
                        self.end(first)
                    elif self.case == 'provider-reset':
                        self.cli('reset')
                        self.wait(lambda: any(row['event'] == 'system.event' and row.get('name') == 'providerReset' for row in self.rows()))
                    else: self.end(first)
            empty = self.wait(lambda: self.snapshot(lambda calls: calls == []))
            self.wait(lambda: any(row['event'] == 'system.hook' and row.get('count') == 0 and row['sequence'] > empty['sequence'] for row in self.rows()))
            self.command('finish')
            phase = 'capture'
            require(self.process.wait(timeout=30) == 0, 'system supervisor refused capture')
        except Exception:
            # Preserve the primary journey failure before cleanup can classify
            # its own error. A finished journey's capture failure keeps the
            # child's classification or defers to the entry-point fallback.
            if phase == 'journey' or (phase == 'startup' and not failure_is_classified()):
                _report('product:' + self.name, 'never retried')
            raise
        finally:
            if self.process is not None:
                handlers = {sig: signal.signal(sig, signal.SIG_IGN) for sig in (signal.SIGTERM, signal.SIGINT)}
                try:
                    if self.process.poll() is None:
                        cleanup_required = True
                        diagnostic = dict(supervisorPID=self.process.pid, forcedGroupKill=False)
                        try: self.sim('terminate', self.args.simulator, BUNDLE, timeout=10)
                        except Exception as error:
                            diagnostic['appStopError'] = str(error)
                            _report('infra:terminate', 'never retried')
                        try: self.process.wait(timeout=25)
                        except subprocess.TimeoutExpired:
                            # Never signal a group after its owner has been reaped.
                            try:
                                if self.process.poll() is None:
                                    require(os.getpgid(self.process.pid) == self.process.pid == os.getsid(self.process.pid),
                                            'supervisor private process-group ownership is unknown')
                                    try:
                                        os.killpg(self.process.pid, signal.SIGKILL)
                                        diagnostic['forcedGroupKill'] = True
                                    except ProcessLookupError: pass
                            finally: self.process.wait(timeout=5)
                        write(self.root / 'failed-cleanup.json', diagnostic)
                    try: os.killpg(self.process.pid, 0)
                    except ProcessLookupError: group_absent = True
                    else: group_absent = False
                    if not group_absent:
                        _report('infra:terminate', 'owned group absence was not proven; never retried')
                    require(group_absent, 'supervisor/console group remains or cleanup is unknown')
                    destination = self.root / (self.name + '.runtime.jsonl')
                    if self.journal.exists(): shutil.copyfile(self.journal, destination)
                    receipt_path = self.root / (self.name + '.receipt.json')
                    if receipt_path.exists():
                        receipt = json.loads(receipt_path.read_text())
                        receipt['supervisorGroupAbsentAfterStop'] = True
                        if destination.exists(): receipt['journalSHA256'] = m0.digest(destination)
                        receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')
                    write(self.root / 'index.json', dict(bindings=self.bindings, controls=self.controls,
                          fixtureCommands=self.commands, supervisorPID=self.process.pid))
                finally:
                    for sig, handler in handlers.items(): signal.signal(sig, handler)
        require(not cleanup_required, 'failure cleanup cannot qualify a native journey')


def run(args):
    state = getattr(args, 'sim_state', None) or os.environ.get('SIM_STATE')
    try:
        args.sim_session = Session.attach(state, args.simulator) if state else None
    except (OSError, ValueError, KeyError, TypeError):
        _report('infra:helper', 'cannot attach to the owned simulator session; never retried')
        raise
    args.package = args.package.resolve()
    from sdk_system_conformance import package_check
    identity = m0.source_identity()
    package_check(args.package, identity)
    # The shipping CLI still validates every package file before each operation.
    args.output.mkdir()
    shutil.copytree(args.package, args.output / 'control-package')
    container = app_data_container(args.simulator, args.data_container)
    for case in CASES:
        try:
            Journey(args, args.output / case, case, container).run()
        except Exception:
            if not failure_is_classified():
                _report('product:sdk-system-' + case, 'never retried')
            raise


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator', required=True)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--package', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--data-container', type=Path, help='Reuse the installed example container already validated by M0')
    parser.add_argument('--sim-state', type=Path, help='Use the parent runner\'s existing simulator session')
    args = parser.parse_args()
    require(str(uuid.UUID(args.simulator)).upper() == args.simulator and
            __import__('re').fullmatch(r'[A-Za-z0-9_-]{1,64}', args.run_id), 'invalid owned simulator/run identity')
    def interrupted(_signum, _frame):
        raise KeyboardInterrupt('system runner interrupted')
    signal.signal(signal.SIGTERM, interrupted)
    if not os.environ.get('SIM_FAILURE_MARKER'):
        os.environ['SIM_FAILURE_MARKER'] = str(args.output / '.failure-classified')
    run(args)
