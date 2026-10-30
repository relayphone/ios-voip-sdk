"""CI policy shared by the SDK, runtime and infrastructure workflows."""
from pathlib import PurePosixPath
from pathlib import Path
import re
import subprocess
import json
import os
import sys

SDK_JOBS = ('sdk-native', 'legacy-audio-lifecycle', 'swift-livekit-native',
            'expo-livekit-native', 'routes-duo')
SDK_NATIVE_JOBS = ('offline-controls', 'apple-host-controls', 'sdk-example', 'sdk-core',
                   'sdk-fixtures', 'device-release', 'journeys')
GROUPS = {'m1': dict(group='m1', m1='1', part='journeys', system='0'),
          'contracts': dict(group='contracts', m1='1', part='contracts', system='0'),
          'push-entry': dict(group='push-entry', m1='1', part='push-entry', system='0'),
          'system': dict(group='system', m1='0', part='all', system='1')}


def select(paths, full=False):
    if full:
        return dict(sdk=True, runtime=True, helper=True, sdk_plan=dict.fromkeys(SDK_JOBS, True),
                    matrix=dict(include=list(GROUPS.values())))
    paths = [p for p in paths if not documentation(p)]
    sdk = runtime = helper = False
    unknown = False
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
        elif path.startswith('Tests/CKSimProtocolTests/'):
            runtime = True
        elif path.startswith(('Tests/RuntimeEvents/', 'Tests/Inspector/')):
            runtime = helper = True
        elif path.startswith('Inspector/') or path == 'scripts/build-inspector.sh':
            runtime = True
        elif path.startswith(('Sources/Engine/', 'Sources/Interposition/', 'Sources/CKSimProtocol/', 'Tools/')) or path == 'scripts/build-runtime.sh':
            sdk = runtime = True
        elif path.startswith('discovery/'):
            sdk = True
            runtime |= PurePosixPath(path).name in ('check_cli_controls.py', 'check_lck_provider_policy.py')
            helper |= PurePosixPath(path).name.startswith(('run_', 'sdk_m0_conformance', 'sdk_m1_contracts_conformance'))
        elif path.startswith(('Sources/', 'Integrations/', 'Expo/', 'ExpoMedia/', 'example/', 'Tests/')) or path in SDK_INPUTS:
            sdk = True
        elif path.startswith('docs/research/'):
            sdk = True
            runtime |= path.startswith('docs/research/callkit-simulator-probe/livecommunicationkit/multicall/')
        else:
            # New executable/configuration inputs get conservative critical checks.
            sdk = runtime = helper = True
            unknown = True
    shared = any(p.startswith(COMPILED_SDK) for p in paths)
    jobs = dict.fromkeys(SDK_JOBS, False)
    jobs['sdk-native'] = sdk
    jobs['expo-livekit-native'] = sdk and (shared or any('expo_livekit' in p or p in EXPO_JOURNEY_INPUTS or p in NATIVE_INPUTS or p in DEVICE_BUILDERS
        or p.startswith(('Expo/', 'ExpoMedia/', 'example/', 'Tests/ExpoMedia/', 'scripts/sim/')) for p in paths))
    jobs['swift-livekit-native'] = sdk and any('swift_livekit' in p or p.startswith(
        ('Sources/VoIPSDK/', 'Sources/VoIPPlatform/', 'Sources/CKSimProtocol/', 'Integrations/LiveKit/',
         'Tests/SwiftLiveKit/', 'scripts/sim/')) or p in ('Package.swift',
         'discovery/run_scenario.py') for p in paths)
    jobs['legacy-audio-lifecycle'] = sdk and (shared or any('m1_contract' in p
        or 'run_audio_lifecycle_legacy' in p or audio_contract(p)
        or p.startswith('scripts/sim/') or p == 'discovery/run_scenario.py' for p in paths))
    jobs['routes-duo'] = sdk and (shared or unknown or any(p.startswith(('Sources/', 'Integrations/', 'discovery/', 'scripts/sim/',
        'scripts/ci/', 'Tests/AudioRoutes/', 'Tools/',
        'docs/research/callkit-simulator-probe/livecommunicationkit/'))
        or p in ('Package.swift', 'VERSION', 'IosVoipSDK.podspec') for p in paths))
    groups = {'m1'}
    # Only known, narrow inputs may reduce the matrix. An unrecognized file,
    # including a new script or shared action, keeps every native journey.
    def narrow(p):
        return (p.startswith(('Expo/', 'example/', 'Tests/AudioLifecycle/', 'Tests/PushLaunch/',
                              'Tests/SwiftLiveKit/', 'Tests/RuntimeEvents/', 'Tests/Inspector/'))
                or p in ('package.json', 'package-lock.json', 'tsconfig.json',
                         'expo-module.config.json', 'app.plugin.js')
                or audio_contract(p)
                or p.startswith('discovery/') and any(token in p for token in
                    ('sdk_m1_contract', 'sdk_system', 'push_report_entry', 'push_entry_')))
    shared_harness = any(not narrow(p) for p in paths)
    if shared_harness:
        groups.update(GROUPS)
    else:
        if any('m1_contract' in p or audio_contract(p) for p in paths): groups.add('contracts')
        if any('push_report_entry' in p or 'push_entry_' in p or p.startswith('Tests/PushLaunch/')
               for p in paths): groups.add('push-entry')
        if any('sdk_system' in p or p == 'scripts/build-runtime.sh' for p in paths): groups.add('system')
    return dict(sdk=sdk, runtime=runtime, helper=helper, sdk_plan=jobs,
                matrix=dict(include=[value for key, value in GROUPS.items() if key in groups]))


SDK_INPUTS = {'Package.swift', 'VERSION', 'IosVoipSDK.podspec', 'expo-module.config.json',
              'package.json', 'package-lock.json', 'tsconfig.json', 'app.plugin.js'}
COMPILED_SDK = ('Sources/VoIPSDK/', 'Sources/VoIPPlatform/', 'Sources/Engine/', 'Sources/Interposition/', 'Sources/CKSimProtocol/')
NATIVE_INPUTS = {'Package.swift', 'IosVoipSDK.podspec', 'expo-module.config.json',
                 'package.json', 'package-lock.json', 'app.plugin.js'}
DEVICE_BUILDERS = {'discovery/build_sdk_device_release.py', 'discovery/device_oracles.py',
                   'discovery/device_release_exclusion.py', 'discovery/check_device_release.py'}

EXPO_JOURNEY_INPUTS = {'VERSION', 'discovery/run_swift_livekit.py',
                       'discovery/build_swift_livekit_contract.py', 'discovery/swift_livekit_conformance.py',
                       'discovery/run_scenario.py', 'discovery/sdk_m0_conformance.py',
                       'discovery/sdk_m1_conformance.py', 'discovery/summarize.py'}


def audio_contract(path):
    return (path.startswith('Tests/AudioLifecycle/') or 'sdk_m2_audio_lifecycle' in path
            or 'audio-session-lifecycle/' in path)


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


OPTIONAL = {'swift-livekit-native': 'swift', 'expo-livekit-native': 'expo',
            'legacy-audio-lifecycle': 'legacy'}


def workflow_parts(text):
    if text.count('\njobs:\n') != 1:
        raise ValueError('Expected block-style workflow jobs')
    header, jobs = text.split('\njobs:\n')
    blocks = {}
    current = None
    for line in jobs.splitlines(keepends=True):
        if line.strip() and not line[0].isspace() and not line.startswith('#'):
            raise ValueError('Unsupported top-level field after workflow jobs')
        match = re.fullmatch(r'  ([A-Za-z_][\w-]*):\s*(?:#[^\n]*)?\n?', line)
        if match:
            current = match[1]
            if current in blocks: raise ValueError('Duplicate workflow job')
            blocks[current] = line
        elif current is None and line.strip():
            raise ValueError('Cannot parse workflow job boundaries')
        elif current:
            blocks[current] += line
    if not set(OPTIONAL) <= blocks.keys():
        raise ValueError('Expected optional SDK jobs are missing')
    inherited = []
    field = None
    for line in header.splitlines(keepends=True):
        if line and not line[0].isspace() and not line.startswith('#'):
            field = line.split(':', 1)[0]
        if field in ('env', 'defaults'): inherited.append(line)
    return blocks, ''.join(inherited)


def workflow_optional_changes(before, after):
    old, old_env = workflow_parts(before)
    new, new_env = workflow_parts(after)
    if 'routes-duo' in old and 'routes-duo' not in new:
        raise ValueError('Expected Duo job is missing')
    changed = {'routes-duo'} if 'routes-duo' in new and old.get('routes-duo') != new['routes-duo'] else set()
    if old.get('sdk-fixtures') != new.get('sdk-fixtures'):
        changed.add('legacy-audio-lifecycle')
        if 'routes-duo' in new: changed.add('routes-duo')
    if old_env != new_env:
        return changed | set(OPTIONAL) | ({'routes-duo'} if 'routes-duo' in new else set())
    if 'changes' not in old and 'changes' in new:
        # One-time migration of the exact guards introduced by this policy.
        # Every other command/env/condition/dependency edit remains observable.
        for job, flag in OPTIONAL.items():
            condition = "    if: needs.changes.outputs." + flag + " == 'true'\n"
            if job == 'legacy-audio-lifecycle':
                line = '    needs: plain-simulator\n'
                if old[job].count(line) != 1: raise ValueError('Unknown legacy dependency')
                old[job] = old[job].replace(line, '    needs: [changes, sdk-native]\n' + condition)
            else:
                if re.search(r'^    (needs|if):', old[job], re.M):
                    raise ValueError('Unknown pre-selection job guard')
                first, rest = old[job].split('\n', 1)
                old[job] = first + '\n    needs: changes\n' + condition + rest
    return changed | {job for job in OPTIONAL if old[job].strip() != new[job].strip()}


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
    paths = changed_paths(base, head, root)
    plan = select(paths)
    workflow = '.github/workflows/sdk-m0.yml'
    if workflow in paths:
        def content(sha):
            found = subprocess.run(['git', 'ls-tree', '--name-only', sha, '--', workflow],
                cwd=root, check=True, capture_output=True, timeout=20)
            if not found.stdout: raise ValueError('Cannot compare missing SDK workflow')
            return subprocess.run(['git', 'show', sha + ':' + workflow], cwd=root,
                check=True, capture_output=True, text=True, timeout=20).stdout
        for job in workflow_optional_changes(content(base), content(head)):
            plan['sdk_plan'][job] = True
    return plan


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
            for key, job in (('swift', 'swift-livekit-native'),
                             ('expo', 'expo-livekit-native'), ('legacy', 'legacy-audio-lifecycle'),
                             ('routes', 'routes-duo')):
                values[key] = json.dumps(plan['sdk_plan'][job])
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
