#!/usr/bin/env python3
"""Require real OS tel dispatch, native ingress and the public example event."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import plistlib
import struct

import sdk_m0_conformance as m0
from summarize import EvidenceError, one, require

ROOT = Path(__file__).resolve().parent.parent
BUNDLE = 'dev.iosvoipsdk.example'
URL = 'tel:+15555550142'
HANDLE = '+15555550142'
NAME = 'sdk-m3-tel'
FILES = ('binaries/example', 'binaries/main.jsbundle', 'Info.plist',
         'simulated-entitlements.plist', 'host-entitlements.plist')
SETTINGS_TEST = 'DefaultCallingTests/testSelectCallingApp()'
SETTINGS_ROLES = ('before-selection-screen', 'after-selection-screen',
                  'before-selection-accessibility', 'after-selection-accessibility')


def simulated_entitlements(path):
    """Read Xcode's simulator claim, not restricted host-signature entitlements."""
    data = path.read_bytes()
    require(len(data) >= 32 and struct.unpack_from('<I', data)[0] == 0xFEEDFACF,
            'M3 requires a thin little-endian 64-bit simulator executable')
    count, command_bytes = struct.unpack_from('<II', data, 16)
    end = 32 + command_bytes
    require(end <= len(data), 'truncated Mach-O commands')
    position, claims = 32, []
    for _ in range(count):
        require(position + 8 <= end, 'truncated Mach-O command')
        command, size = struct.unpack_from('<II', data, position)
        require(size >= 8 and position + size <= end, 'invalid Mach-O command bounds')
        if command == 0x19:  # LC_SEGMENT_64
            require(size >= 72, 'truncated Mach-O segment')
            sections = struct.unpack_from('<I', data, position + 64)[0]
            require(72 + sections * 80 <= size, 'truncated Mach-O sections')
            for index in range(sections):
                section = position + 72 + index * 80
                name = data[section:section + 16].rstrip(b'\0')
                segment = data[section + 16:section + 32].rstrip(b'\0')
                if (segment, name) != (b'__TEXT', b'__entitlements'): continue
                length = struct.unpack_from('<Q', data, section + 40)[0]
                offset = struct.unpack_from('<I', data, section + 48)[0]
                require(0 < length <= 1_048_576 and end <= offset <= len(data) - length,
                        'invalid simulator entitlement section bounds')
                claims.append(data[offset:offset + length].rstrip(b'\0'))
        position += size
    require(position == end and len(claims) == 1, 'missing or duplicate simulator entitlement section')
    value = plistlib.loads(claims[0])
    require(isinstance(value, dict), 'simulator entitlements must be a dictionary')
    return claims[0]


def product_files(root, run_file=False):
    require(root.is_dir(), 'missing Settings test products')
    files = {}
    for path in sorted(root.rglob('*')):
        require(not path.is_symlink(), 'Settings products may not contain symlinks')
        if path.is_file(): files[path.relative_to(root).as_posix()] = m0.digest(path)
    require(files and len([name for name in files if name.endswith('.xctestrun')]) == (2 if run_file else 1) and
            (not run_file or 'M3Run.xctestrun' in files),
            'require one source-bound Settings test run configuration')
    return files


def settings_configuration(original, run_id, simulator, pid, inherited):
    configured = copy.deepcopy(original)
    targets = [target for target in configured.values() if isinstance(target, dict) and target.get('IsUITestBundle')]
    require(len(targets) == 1, 'require one Settings UI test target')
    environment = targets[0].setdefault('EnvironmentVariables', {})
    environment.update(SDK_M3_SETTINGS_RUN_ID=run_id, SDK_M3_SETTINGS_SIMULATOR_ID=simulator,
                       SDK_M3_SETTINGS_APP_PID=str(pid))
    if inherited:
        base = environment.get('DYLD_INSERT_LIBRARIES', '')
        environment['DYLD_INSERT_LIBRARIES'] = base + (':' if base else '') + inherited
    return configured


def settings_attachments(root, simulator):
    rows = json.loads((root / 'manifest.json').read_text())
    require(isinstance(rows, list) and len(rows) == 1 and rows[0].get('testIdentifier') == SETTINGS_TEST,
            'Settings attachments have an unexpected test identity')
    result = {}
    for role in SETTINGS_ROLES:
        matches = [row for row in rows[0]['attachments']
                   if row.get('suggestedHumanReadableName', '').startswith(role + '_')]
        require(len(matches) == 1 and matches[0].get('deviceId') == simulator,
                'missing or mixed-device Settings attachment: ' + role)
        name = matches[0].get('exportedFileName')
        require(isinstance(name, str) and Path(name).name == name, 'invalid attachment filename')
        path = root / name
        require(path.is_file() and path.stat().st_size > 0, 'empty Settings attachment')
        if role.endswith('-screen'):
            require(path.read_bytes().startswith(b'\x89PNG\r\n\x1a\n') and path.stat().st_size > 64,
                    'Settings screenshot is not a PNG')
        else:
            candidates = [line for line in path.read_text().splitlines()
                          if 'Button,' in line and "label: 'VoIP SDK Example'" in line]
            require(len(candidates) == 1 and (role.startswith('before-') or ', Selected' in candidates[0]),
                    'actual Settings candidate/selection is missing')
        result[role] = path
    return result


def qualify(rows, dispatch, run_id, simulator_id, pid):
    require(type(pid) is int and pid > 0 and rows and all(type(row.get('pid')) is int and row.get('runID') == run_id and row.get('simulatorID') == simulator_id and
                        row.get('pid') == pid and row.get('main') is True and row.get('bundleID') == BUNDLE
                        for row in rows), 'mixed M3 process/queue identity')
    require(all(type(row.get('sequence')) is int for row in rows) and
            [row.get('sequence') for row in rows] == list(range(1, len(rows) + 1)) and
            all(type(row.get('t_ms')) is int and type(row.get('wallTimeMS')) is int for row in rows) and
            all(a['t_ms'] <= b['t_ms'] and a['wallTimeMS'] <= b['wallTimeMS'] for a, b in zip(rows, rows[1:])),
            'invalid M3 sequence/clock')
    require([row['event'] for row in rows[:2]] == ['app.entry', 'launch'] and
            one(rows, 'launch').get('mode') == 'sdk-m3' and type(one(rows, 'launch').get('traceVersion')) is int and
            one(rows, 'launch').get('traceVersion') == 2,
            'missing M3 app entry/mode')
    ready, ingress, event = (one(rows, name) for name in ('m3.listenerReady', 'm3.nativeIngress', 'm3.dialRequest'))
    require(type(dispatch.get('schemaVersion')) is int and dispatch.get('schemaVersion') == 1 and dispatch.get('runID') == run_id and
            dispatch.get('simulatorID') == simulator_id and type(dispatch.get('appPID')) is int and dispatch.get('appPID') == pid and
            dispatch.get('argv') == ['xcrun', 'simctl', 'openurl', simulator_id, URL] and
            type(dispatch.get('exitCode')) is int and dispatch.get('exitCode') == 0, 'missing or substituted OS URL dispatch')
    start, end = dispatch.get('startedWallTimeMS'), dispatch.get('finishedWallTimeMS')
    require(type(start) is int and type(end) is int and ready['wallTimeMS'] <= start <= end and
            start - 2 <= ingress['wallTimeMS'] <= end + 15_000,
            'native ingress does not follow the recorded OS dispatch')
    require((ingress.get('kind') == 'url' and ingress.get('urlSHA256') == hashlib.sha256(URL.encode()).hexdigest()) or
            (ingress.get('kind') == 'activity' and ingress.get('isStartCallIntent') is True),
            'native ingress is not a tel URL or public start-call activity')
    require(rows.index(ready) < rows.index(ingress) < rows.index(event) < rows.index(one(rows, 'sdk.result')) <
            rows.index(one(rows, 'done')) == len(rows) - 1, 'M3 readiness/ingress/public event order differs')
    require(type(ready.get('conversationCount')) is type(event.get('conversationCount')) is int and
            ready.get('conversationCount') == event.get('conversationCount') == 0 and
            event.get('handleSHA256') == hashlib.sha256(HANDLE.encode()).hexdigest() and event.get('video') is False,
            'public dialRequest destination/video changed or routing created a call')
    require(one(rows, 'sdk.result').get('success') is True and
            not any(row.get('error') or row.get('errorType') for row in rows) and
            not any(key in row for row in rows for key in ('handle', 'url', 'token', 'value', 'payload', 'caller')),
            'M3 failed or disclosed private input')
    return dict(success=True, scenario='sdk-m3', nativeIngress=ingress['kind'], publicDialRequest=True)


def check_input_build(app, receipt, identity=None, settings_products=None):
    identity = m0.source_identity() if identity is None else identity
    require(type(receipt.get('schemaVersion')) is int and receipt.get('schemaVersion') == 1 and receipt.get('product') == 'sdk-m3' and
            receipt.get('configuration') == 'Release' and receipt.get('mediaAdapter') == 'none' and
            receipt.get('sourceStart') == receipt.get('sourceEnd') == identity and
            all(receipt.get(key) == value for key, value in identity.items()) and
            receipt.get('files', {}).get('binaries/example') == m0.digest(m0.executable(app)) and
            receipt.get('files', {}).get('binaries/main.jsbundle') == m0.digest(app / 'main.jsbundle') and
            receipt.get('files', {}).get('Info.plist') == m0.digest(app / 'Info.plist'),
            'M3 example does not match committed build-time source and bytes')
    claims = plistlib.loads(simulated_entitlements(m0.executable(app)))
    require(claims.get('com.apple.developer.calling-app') is True and
            'com.apple.developer.dialing-app' not in claims, 'missing normal Xcode simulator calling entitlement')
    require(settings_products is not None and receipt.get('settingsProducts') == product_files(settings_products),
            'Settings UI test products do not match their build receipt')


def validate_settings(root, manifest, build, ready, dispatch):
    products = root / 'settings/products'
    actual = product_files(products, run_file=True)
    run_hash = actual.pop('M3Run.xctestrun')
    require(actual == build.get('settingsProducts') and run_hash == manifest.get('settingsRunSHA256'),
            'Settings executable/run configuration is not build-bound')
    original_name = next(name for name in actual if name.endswith('.xctestrun'))
    original = plistlib.loads((products / original_name).read_bytes())
    configured = plistlib.loads((products / 'M3Run.xctestrun').read_bytes())
    targets = [value for value in configured.values() if isinstance(value, dict) and value.get('IsUITestBundle')]
    original_targets = [value for value in original.values() if isinstance(value, dict) and value.get('IsUITestBundle')]
    require(len(targets) == len(original_targets) == 1, 'unexpected Settings UI target')
    base = original_targets[0].get('EnvironmentVariables', {}).get('DYLD_INSERT_LIBRARIES', '')
    injected = targets[0].get('EnvironmentVariables', {}).get('DYLD_INSERT_LIBRARIES', '')
    if injected == base: inherited = ''
    else:
        require(injected.startswith(base + (':' if base else '')), 'Settings replaced its original injector')
        inherited = injected[len(base) + (1 if base else 0):]
    require(hashlib.sha256(inherited.encode()).hexdigest() == manifest.get('inheritedDYLDSHA256') and
            configured == settings_configuration(original, manifest['runID'], manifest['simulatorID'], ready['pid'], inherited),
            'Settings launch identity or environment was substituted')
    files = manifest.get('settingsFiles', {})
    require(files and all(isinstance(name, str) and not Path(name).is_absolute() and Path(name).parts[0] == 'settings' and
                          '..' not in Path(name).parts and not (root / name).is_symlink() and m0.digest(root / name) == digest for name, digest in files.items()), 'unbound Settings evidence')
    require({'settings/test.log', 'settings/attachments/manifest.json'} <= files.keys(), 'missing Settings log/attachments')
    attachments = settings_attachments(root / 'settings/attachments', manifest['simulatorID'])
    require(all(path.relative_to(root).as_posix() in files for path in attachments.values()), 'unbound Settings selection images/AX')
    rows = []
    for line in (root / 'settings/test.log').read_text(errors='replace').splitlines():
        if line.startswith('M3SETTINGS '): rows.append(json.loads(line.removeprefix('M3SETTINGS ')))
    require(len(rows) == 1, 'require one actual Settings selection result')
    result = rows[0]
    require(type(result.get('schemaVersion')) is int and result.get('schemaVersion') == 1 and result.get('runID') == manifest['runID'] and
            result.get('simulatorID') == manifest['simulatorID'] and type(result.get('appPID')) is int and
            result['appPID'] == ready['pid'] and result.get('method') == 'public-xctest-ui' and
            result.get('selected') is True and result.get('tapped') is True and type(result.get('beforeSelected')) is bool and
            type(result.get('wallTimeMS')) is int and ready['wallTimeMS'] <= result['wallTimeMS'] <= dispatch['startedWallTimeMS'],
            'Settings selection is not bound to this ready application and dispatch')


def validate(root, source_root=ROOT):
    manifest = json.loads((root / 'manifest.json').read_text())
    identity = m0.source_identity(source_root)
    require(type(manifest.get('schemaVersion')) is int and manifest.get('schemaVersion') == 1 and manifest.get('scenario') == 'sdk-m3' and
            manifest.get('ownsSimulator') is True and manifest.get('runtimeInjectionRequested') is False and
            manifest.get('directIngressInjectionRequested') is False and
            all(manifest.get(key) == value for key, value in identity.items()), 'invalid M3 source/ownership manifest')
    build = json.loads((root / 'input-build-receipt.json').read_text())
    require(m0.digest(root / 'input-build-receipt.json') == manifest.get('inputBuildReceiptSHA256') and type(build.get('schemaVersion')) is int and build.get('schemaVersion') == 1 and
            build.get('product') == 'sdk-m3' and build.get('configuration') == 'Release' and build.get('mediaAdapter') == 'none' and
            build.get('sourceStart') == build.get('sourceEnd') == identity and all(build.get(key) == value for key, value in identity.items()),
            'input build is not source-bound')
    require(manifest.get('files') == {name: m0.digest(root / name) for name in FILES} and
            build.get('files', {}).get('binaries/example') == m0.digest(root / 'binaries/example') and
            build.get('files', {}).get('binaries/main.jsbundle') == m0.digest(root / 'binaries/main.jsbundle') and
            build.get('files', {}).get('Info.plist') == m0.digest(root / 'Info.plist'),
            'M3 built bytes are unbound or were re-signed after the build')
    require(manifest.get('installed') == {key: m0.digest(root / name) for key, name in
            [('executableSHA256', 'binaries/example'), ('javascriptSHA256', 'binaries/main.jsbundle'), ('infoPlistSHA256', 'Info.plist')]},
            'installed M3 example bytes differ')
    plist = plistlib.loads((root / 'Info.plist').read_bytes())
    entitlements = plistlib.loads((root / 'simulated-entitlements.plist').read_bytes())
    host = plistlib.loads((root / 'host-entitlements.plist').read_bytes())
    require((root / 'simulated-entitlements.plist').read_bytes() == simulated_entitlements(root / 'binaries/example') and
            isinstance(host, dict) and 'com.apple.developer.calling-app' not in host and
            'com.apple.developer.dialing-app' not in host, 'simulator claim was substituted or placed in the host signature')
    require(plist.get('CFBundleIdentifier') == BUNDLE and 'voip' in plist.get('UIBackgroundModes', []) and
            'INStartCallIntent' in plist.get('NSUserActivityTypes', []) and
            not any(scheme.lower() == 'tel' for row in plist.get('CFBundleURLTypes', []) for scheme in row.get('CFBundleURLSchemes', [])) and
            entitlements.get('com.apple.developer.calling-app') is True and
            'com.apple.developer.dialing-app' not in entitlements, 'M3 default-calling eligibility differs')
    cleanup = json.loads((root / 'cleanup.json').read_text())
    require(m0.digest(root / 'cleanup.json') == manifest.get('cleanupSHA256') and
            cleanup.get('simulatorID') == manifest.get('simulatorID') and cleanup.get('deleted') is True and
            cleanup.get('absentFromInventory') is True and
            cleanup.get('globalEnvironmentUnchanged') is True,
            'M3 owned simulator cleanup did not complete')
    require(m0.digest(root / 'dispatch.json') == manifest.get('dispatchSHA256') and
            m0.digest(root / 'environment.json') == manifest.get('environmentSHA256'), 'unbound M3 dispatch/environment')
    environment = json.loads((root / 'environment.json').read_text())
    require(environment.get('simulatorID') == manifest.get('simulatorID') and
            all(isinstance(environment.get(key), str) and environment[key] for key in
                ('simulatorRuntimeID', 'simulatorOS', 'simulatorBuild', 'xcodeVersion')) and
            tuple(int(part) for part in environment['simulatorOS'].split('.')[:2]) >= (18, 2), 'invalid M3 execution environment')
    require(m0.digest(root / 'commands.json') == manifest.get('commandsSHA256'), 'unbound M3 control commands')
    commands = json.loads((root / 'commands.json').read_text())['steps']
    for phase in ('verify-built-signature', 'read-host-entitlements', 'install', 'select-calling-app',
                  'export-settings-attachments', 'os-tel-dispatch'):
        matches = [row for row in commands if row.get('phase') == phase]
        require(len(matches) == 1 and type(matches[0].get('exitCode')) is int and matches[0].get('exitCode') == 0, 'M3 control failed: ' + phase)
    ui_command = next(row['argv'] for row in commands if row.get('phase') == 'select-calling-app')
    require(isinstance(ui_command, list) and ui_command[:2] == ['xcodebuild', 'test-without-building'],
            'Settings was not driven by the public built UI test')
    for option, value in (('-destination', 'platform=iOS Simulator,id=' + manifest['simulatorID']),
                          ('-parallel-testing-enabled', 'NO'), ('-maximum-concurrent-test-simulator-destinations', '1'),
                          ('-only-testing:SettingsProbe/DefaultCallingTests/testSelectCallingApp', None)):
        require(ui_command.count(option) == 1 and (value is None or
                ui_command.index(option) + 1 < len(ui_command) and ui_command[ui_command.index(option) + 1] == value),
                'Settings test destination or selection differs')
    require(ui_command.count('-xctestrun') == 1 and ui_command.index('-xctestrun') + 1 < len(ui_command) and
            Path(ui_command[ui_command.index('-xctestrun') + 1]).parts[-3:] == ('settings', 'products', 'M3Run.xctestrun'),
            'Settings did not run the bound configuration')
    require(build.get('buildLogs') and all(Path(name).name == name and (root / 'build-logs' / name).stat().st_size > 0 and
            m0.digest(root / 'build-logs' / name) == digest for name, digest in build['buildLogs'].items()),
            'missing, empty or unbound M3 build log')
    rows, receipt = m0.bound_rows(root, NAME, manifest, BUNDLE)
    dispatch = json.loads((root / 'dispatch.json').read_text())
    validate_settings(root, manifest, build, one(rows, 'm3.listenerReady'), dispatch)
    result = qualify(rows, dispatch, manifest['runID'], manifest['simulatorID'], receipt['appPID'])
    return dict(**result, source=identity, installed=manifest['installed'], defaultSelection='measured public XCTest Settings tap and selected state')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    args = parser.parse_args()
    try:
        result = validate(args.root)
    except (EvidenceError, OSError, ValueError, KeyError, TypeError, StopIteration) as error:
        result = dict(success=False, error=str(error))
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['success'] else 1)
