"""CI policy shared by the SDK, runtime and infrastructure workflows."""
from pathlib import PurePosixPath
from pathlib import Path
import re
import subprocess
import json
import os
import sys

SDK_JOBS = ('sdk-native',)
SDK_NATIVE_JOBS = ('offline-controls', 'apple-host-controls', 'sdk-example', 'sdk-core',
                   'simulator-journeys')


def select(paths, full=False):
    if full:
        return dict(sdk=True, runtime=True, helper=True, sdk_plan=dict.fromkeys(SDK_JOBS, True))
    paths = [p for p in paths if not documentation(p)]
    sdk = runtime = helper = False
    for path in paths:
        if path.startswith('scripts/sim/'):
            sdk = runtime = helper = True
        elif path.startswith('scripts/ci/'):
            sdk = helper = True
            runtime |= not PurePosixPath(path).name.startswith('sdk_')
        elif path.startswith('.github/workflows/'):
            name = PurePosixPath(path).name
            sdk |= name in ('sdk-m0.yml', 'ci-changes.yml')
            runtime |= name in ('runtime-m4.yml', 'ci-changes.yml')
            helper |= name in ('sim-infrastructure.yml', 'ci-changes.yml')
        elif path.startswith(('Tests/CKSimProtocolTests/', 'Tests/RuntimeEngineTests/', 'Tests/InspectorTests/',
                              'Tests/RuntimeTests/', 'Tests/CKSimToolTests/', 'Tests/Fixtures/')):
            runtime = True
        elif path.startswith('Inspector/'):
            runtime = True
        elif path.startswith(('Sources/Engine/', 'Sources/Interposition/', 'Sources/CKSimProtocol/', 'Sources/CKSimTool/',
                              'Sources/cksim/', 'tools/')):
            sdk = runtime = True
        elif path.startswith('discovery/'):
            sdk = True
            runtime |= PurePosixPath(path).name == 'check_cli_controls.py'
            helper |= PurePosixPath(path).name.startswith('run_')
        elif path.startswith(('Sources/', 'Examples/', 'Tests/')) or path in SDK_INPUTS:
            sdk = True
        elif path.startswith('docs/research/'):
            sdk = True
            runtime |= path.startswith('docs/research/callkit-simulator-probe/livecommunicationkit/multicall/')
        else:
            # New executable/configuration inputs get conservative critical checks.
            sdk = runtime = helper = True
    return dict(sdk=sdk, runtime=runtime, helper=helper, sdk_plan={'sdk-native': sdk})


SDK_INPUTS = {'Package.swift', 'VERSION', 'IosVoipSDK.podspec'}


def documentation(path):
    return (PurePosixPath(path).suffix.lower() == '.md'
            or path.startswith('docs/') and PurePosixPath(path).suffix.lower() in ('.txt', '.png', '.jpg', '.jpeg', '.svg', '.pdf')
            or path in ('LICENSE', '.gitignore', '.DS_Store')
            or path.startswith('.github/ISSUE_TEMPLATE/'))


def gate(results, expected):
    results = dict(results)
    coverage = results.pop('nightly-coverage', None)
    if coverage is not None and coverage.get('result') != 'success':
        raise ValueError('Nightly coverage check did not succeed')
    if results.get('changes', {}).get('result') != 'success':
        raise ValueError('Change selection did not succeed')
    if 'sdk-native' in expected and 'sdk-native' not in results:
        # Preserve the serial selector contract when its native job is sharded.
        # Every shard must match the same selected/skip state, and no missing or
        # unexpected dependency may be hidden by collapsing the results.
        if set(expected) != set(SDK_JOBS) or set(results) != {
                'changes', *SDK_NATIVE_JOBS, *(set(SDK_JOBS) - {'sdk-native'})}:
            raise ValueError('Selected native shards and aggregate dependencies differ')
        wanted = 'success' if expected['sdk-native'] is True else 'skipped'
        shard_result = wanted if all(results[name].get('result') == wanted
                                     for name in SDK_NATIVE_JOBS) else 'failure'
        results = {name: row for name, row in results.items() if name not in SDK_NATIVE_JOBS}
        results['sdk-native'] = {'result': shard_result}
    if set(results) != {'changes', *expected} or any(type(v) is not bool for v in expected.values()):
        raise ValueError('Selected jobs and aggregate dependencies differ')
    failed = {name: row.get('result') for name, row in results.items() if name != 'changes'
              and row.get('result') != ('success' if expected[name] else 'skipped')}
    if failed:
        raise ValueError('Required check results differ: ' + str(failed))


def changed_paths(base, head, root, *, push=False):
    if any(not isinstance(v, str) or not re.fullmatch('[0-9a-fA-F]{40}', v) for v in (base, head)):
        raise ValueError('Expected immutable base/head commit SHAs')
    diff = subprocess.run(['git', 'diff', '--no-renames', '--name-only', '-z',
        *([base, head] if push else [base + '...' + head]), '--'],
        cwd=root, check=True, capture_output=True, timeout=20)
    return diff.stdout.decode('utf-8', errors='surrogateescape').rstrip('\0').split('\0') if diff.stdout else []


def event_selection(name, event, root):
    if name == 'push':
        # A push may contain several commits or be forced. Compare the exact
        # endpoints and only skip native work when every changed path is known.
        try:
            before, after = event['before'], event['after']
            if before == '0' * 40 or after == '0' * 40:
                raise ValueError('Push endpoint is unavailable')
            paths = changed_paths(before, after, root, push=True)
            non_native = paths and all(documentation(p) or p.startswith(('docs/', 'spikes/')) for p in paths)
            if non_native:
                plan = select([])
                plan['helper'] = True  # Preserve the inexpensive host controls.
                return plan
        except (KeyError, TypeError, ValueError, OSError, subprocess.SubprocessError):
            pass  # An unavailable or malformed diff must never suppress native work.
        return select([], full=True)
    if name in ('schedule', 'workflow_dispatch'):
        return select([], full=True)
    if name == 'pull_request':
        base, head = event['pull_request']['base']['sha'], event['pull_request']['head']['sha']
    elif name == 'merge_group':
        base, head = event['merge_group']['base_sha'], event['merge_group']['head_sha']
    else:
        raise ValueError('Unsupported CI event: ' + name)
    return select(changed_paths(base, head, root))


def main():
    try:
        action = sys.argv[1] if len(sys.argv) > 1 else 'select'
        if action == 'gate':
            gate(json.loads(os.environ['CI_NEEDS_JSON']), json.loads(os.environ['CI_EXPECTED_JSON']))
            print('All selected checks passed; all unselected checks were skipped.')
        elif action == 'select':
            event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
            plan = event_selection(os.environ['GITHUB_EVENT_NAME'], event, os.environ['GITHUB_WORKSPACE'])
            values = {k: json.dumps(v, separators=(',', ':')) for k, v in plan.items()}
            values['runtime_plan'] = json.dumps({'runtime-native': plan['runtime']})
            with Path(os.environ['GITHUB_OUTPUT']).open('a') as output:
                for key, value in values.items(): output.write(key + '=' + value + '\n')
            print('SDK native: ' + str(plan['sdk']))
            print('Runtime native: ' + str(plan['runtime']) + '; helper controls: ' + str(plan['helper']))
        else:
            raise ValueError('Expected select or gate')
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        message = 'infra:changes: ' + json.dumps(str(error))
        print('::error::' + message, file=sys.stderr)
        if os.environ.get('GITHUB_STEP_SUMMARY'):
            with Path(os.environ['GITHUB_STEP_SUMMARY']).open('a') as summary:
                summary.write('- ' + message + '\n')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
