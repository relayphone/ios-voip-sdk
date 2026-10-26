"""CI policy shared by the SDK, runtime and infrastructure workflows."""
from pathlib import PurePosixPath
from pathlib import Path
import re
import subprocess
import json
import os
import sys

SDK_JOBS = ('offline-controls', 'apple-host-controls', 'sdk-example', 'sdk-core',
            'sdk-fixtures', 'device-release', 'journeys', 'legacy-audio-lifecycle',
            'swift-livekit-native', 'expo-livekit-native')
GROUPS = {'m1': dict(group='m1', m1='1', part='journeys', system='0'),
          'contracts': dict(group='contracts', m1='1', part='contracts', system='0'),
          'push-entry': dict(group='push-entry', m1='1', part='push-entry', system='0'),
          'system': dict(group='system', m1='0', part='all', system='1')}
CRITICAL = {'offline-controls', 'apple-host-controls', 'sdk-example', 'sdk-core',
            'sdk-fixtures', 'journeys'}


def select(paths, full=False):
    if full:
        return dict(sdk=True, runtime=True, helper=True, matrix=dict(include=list(GROUPS.values())),
                    sdk_plan=dict.fromkeys(SDK_JOBS, True))
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
        elif path.startswith(('Tests/RuntimeEvents/', 'Tests/Inspector/')):
            runtime = helper = True
        elif path.startswith('Inspector/') or path == 'scripts/build-inspector.sh':
            runtime = True
        elif path.startswith(('Sources/Engine/', 'Sources/Interposition/', 'Tools/')) or path == 'scripts/build-runtime.sh':
            sdk = runtime = True
        elif path.startswith('discovery/'):
            sdk = True
            runtime |= PurePosixPath(path).name in ('check_cli_controls.py', 'check_lck_provider_policy.py')
            helper |= PurePosixPath(path).name.startswith(('run_', 'sdk_m0_conformance', 'sdk_m1_contracts_conformance'))
        elif path.startswith(('Sources/', 'Integrations/', 'Expo/', 'ExpoMedia/', 'example/', 'Tests/')) or path in SDK_INPUTS:
            sdk = True
        elif path.startswith('docs/research/'):
            sdk = True
        else:
            # New executable/configuration inputs get conservative critical checks.
            sdk = runtime = helper = True
    groups = {'m1'}
    shared = any(p.startswith(COMPILED_SDK) for p in paths)
    if shared or any('m1_contract' in p or audio_contract(p) for p in paths):
        groups.add('contracts')
    if shared or any('push_report_entry' in p or 'push_entry_' in p or p.startswith('Tests/PushLaunch/') for p in paths):
        groups.add('push-entry')
    if any('sdk_system' in p or p.startswith(('Sources/Engine/', 'Sources/Interposition/', 'Tools/')) or p == 'scripts/build-runtime.sh' for p in paths):
        groups.add('system')
    jobs = {job: sdk and job in CRITICAL for job in SDK_JOBS}
    jobs['device-release'] = sdk and any(p in NATIVE_INPUTS or p in DEVICE_BUILDERS or p.startswith(('ExpoMedia/', 'Sources/VoIPPlatform/', 'Tests/ExpoMedia/')) for p in paths)
    jobs['expo-livekit-native'] = sdk and any(p in ('package.json', 'package-lock.json', 'app.plugin.js') or p in DEVICE_BUILDERS or p.startswith(('ExpoMedia/', 'Tests/ExpoMedia/')) for p in paths)
    jobs['swift-livekit-native'] = sdk and any('swift_livekit' in p or p.startswith(('Sources/VoIPSDK/', 'Sources/VoIPPlatform/', 'Integrations/LiveKit/', 'Tests/SwiftLiveKit/')) or p in ('Package.swift', 'Tools/cksim-notify.c') for p in paths)
    jobs['legacy-audio-lifecycle'] = sdk and (shared or any('m1_contract' in p or 'run_audio_lifecycle_legacy' in p or audio_contract(p) for p in paths))
    return dict(sdk=sdk, runtime=runtime, helper=helper,
                matrix=dict(include=[v for k, v in GROUPS.items() if k in groups]), sdk_plan=jobs)


SDK_INPUTS = {'Package.swift', 'VERSION', 'IosVoipSDK.podspec', 'expo-module.config.json',
              'package.json', 'package-lock.json', 'tsconfig.json', 'app.plugin.js'}
COMPILED_SDK = ('Sources/VoIPSDK/', 'Sources/VoIPPlatform/', 'Sources/Engine/', 'Sources/Interposition/')
NATIVE_INPUTS = {'Package.swift', 'IosVoipSDK.podspec', 'expo-module.config.json',
                 'package.json', 'package-lock.json', 'app.plugin.js'}
DEVICE_BUILDERS = {'discovery/build_sdk_device_release.py', 'discovery/device_oracles.py',
                   'discovery/device_release_exclusion.py', 'discovery/check_device_release.py'}


def audio_contract(path):
    return (path.startswith('Tests/AudioLifecycle/') or 'sdk_m2_audio_lifecycle' in path
            or 'audio-session-lifecycle/' in path)


def documentation(path):
    return (PurePosixPath(path).suffix.lower() == '.md'
            or path.startswith('docs/') and PurePosixPath(path).suffix.lower() in ('.txt', '.png', '.jpg', '.jpeg', '.svg', '.pdf')
            or path in ('LICENSE', '.gitignore', '.DS_Store')
            or path.startswith('.github/ISSUE_TEMPLATE/'))


def gate(results, expected):
    if results.get('changes', {}).get('result') != 'success':
        raise ValueError('Change selection did not succeed')
    if set(results) != {'changes', *expected} or any(type(v) is not bool for v in expected.values()):
        raise ValueError('Selected jobs and aggregate dependencies differ')
    failed = {name: row.get('result') for name, row in results.items() if name != 'changes'
              and row.get('result') != ('success' if expected[name] else 'skipped')}
    if failed:
        raise ValueError('Required check results differ: ' + str(failed))


def changed_paths(base, head, root):
    if any(not isinstance(v, str) or not re.fullmatch('[0-9a-fA-F]{40}', v) for v in (base, head)):
        raise ValueError('Expected immutable base/head commit SHAs')
    diff = subprocess.run(['git', 'diff', '--no-renames', '--name-only', '-z',
        base + '...' + head, '--'], cwd=root, check=True, capture_output=True, timeout=20)
    return diff.stdout.decode('utf-8', errors='surrogateescape').rstrip('\0').split('\0') if diff.stdout else []


def event_selection(name, event, root):
    if name in ('push', 'schedule', 'workflow_dispatch'):
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
            for key, job in (('device', 'device-release'), ('swift', 'swift-livekit-native'),
                             ('expo', 'expo-livekit-native'), ('legacy', 'legacy-audio-lifecycle')):
                values[key] = json.dumps(plan['sdk_plan'][job])
            with Path(os.environ['GITHUB_OUTPUT']).open('a') as output:
                for key, value in values.items(): output.write(key + '=' + value + '\n')
            print('Selected SDK groups: ' + ', '.join(row['group'] for row in plan['matrix']['include'])
                  if plan['sdk'] else 'SDK native checks unselected.')
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
