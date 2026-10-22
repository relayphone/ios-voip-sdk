#!/usr/bin/env python3
"""Exercise the real loader CLI against an isolated fake simctl environment."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


CLI = Path(__file__).resolve().parent.parent / "Tools/cksim"
DEVICE = "00000000-0000-4000-8000-000000000001"
LIBRARY_KEY = "DYLD_INSERT_LIBRARIES"


def check(condition, message):
    if not condition:
        raise RuntimeError(message)


def main():
    checks = []
    with tempfile.TemporaryDirectory(prefix="cksim-repair-") as temporary:
        root = Path(temporary).resolve()
        binary = root / "bin"
        binary.mkdir()
        fake = binary / "xcrun"
        fake.write_text("#!" + sys.executable + "\n" + """
import json, os, pathlib, sys
path = pathlib.Path(os.environ['FAKE_SIMCTL_STATE'])
state = json.loads(path.read_text())
args = sys.argv[1:]
state.setdefault('commands', []).append(args)
path.write_text(json.dumps(state))
assert args[0] == 'simctl', args
if args[1] == 'getenv':
    key = args[3]
    observed = state.get('simctlEnvironment', state['environment'])
    if key in observed:
        print(observed[key])
    else:
        print("'%s' not found" % key, file=sys.stderr)
elif args[1:4] == ['spawn', '@DEVICE@', 'launchctl']:
    operation, key = args[4:6]
    if state.get('requireSafeControlEnvironment') and os.environ.get('SIMCTL_CHILD_DYLD_INSERT_LIBRARIES') != '':
        print('deleted loader would be injected into launchctl', file=sys.stderr)
        sys.exit(78)
    if operation == 'getenv':
        if key in state['environment']:
            print(state['environment'][key])
        sys.exit(0)
    if state.get('failKey') == key:
        print('injected launchctl failure', file=sys.stderr)
        sys.exit(7)
    if operation == 'setenv':
        state['environment'][key] = args[6]
    elif operation == 'unsetenv':
        state['environment'].pop(key, None)
    else:
        raise AssertionError(args)
    path.write_text(json.dumps(state))
else:
    raise AssertionError(args)
""".replace("@DEVICE@", DEVICE))
        fake.chmod(0o755)
        driver = root / "run_cli.py"
        driver.write_text("import pathlib, runpy, sys\n"
                          "home, cli, *args = sys.argv[1:]\n"
                          "pathlib.Path.home = classmethod(lambda cls: pathlib.Path(home))\n"
                          "sys.argv = [cli, *args]\n"
                          "runpy.run_path(cli, run_name='__main__')\n")

        def case(name, original):
            directory = root / name
            directory.mkdir()
            package = directory / "runtime"
            package.mkdir()
            version = (CLI.parent.parent / "VERSION").read_text().strip()
            files = {}
            for name in ("CKSimRuntime.dylib", "CKSimLoader.dylib", "cksim-notify", "cksim", "profiles/ios-27.0.json", "VERSION"):
                path = package / name
                path.parent.mkdir(exist_ok=True)
                path.write_bytes((version + "\n").encode() if name == "VERSION" else b"offline fixture\n")
                files[name] = hashlib.sha256(path.read_bytes()).hexdigest()
            (package / "build-info.json").write_text(json.dumps(dict(schemaVersion=1, version=version, files=files)))
            fake_state = directory / "simctl.json"
            fake_state.write_text(json.dumps(dict(environment=original)))
            env = {**os.environ, "PATH": f"{binary}:{os.environ['PATH']}",
                   "FAKE_SIMCTL_STATE": str(fake_state)}
            ownership = directory / ".local/state/callkit-simulator" / f"{DEVICE}.json"

            def run(operation, success=True, bundle=True):
                command = [sys.executable, str(driver), str(directory), str(CLI),
                           "--simulator", DEVICE, "--runtime-dir", str(package)]
                if bundle:
                    command += ["--bundle", bundle if isinstance(bundle, str) else "dev.cksim.fixture"]
                result = subprocess.run([*command, operation], capture_output=True, text=True, env=env, timeout=30)
                check((result.returncode == 0) == success, f"{operation}: {result.stdout} {result.stderr}")
                return result

            def state():
                return json.loads(fake_state.read_text())

            def update(**values):
                current = state()
                current.update(values)
                fake_state.write_text(json.dumps(current))

            return package, ownership, run, state, update

        original = {LIBRARY_KEY: '/opt/Argent.dylib'}
        package, ownership, run, state, update = case('stale-simctl-getenv', original)
        update(simctlEnvironment={LIBRARY_KEY: '/opt/stale.dylib'})
        run('install')
        check(state()['environment'][LIBRARY_KEY] == original[LIBRARY_KEY]+':'+str(package/'CKSimLoader.dylib'),
              'install read stale simctl environment instead of current launchd')
        shutil.rmtree(package)
        run('repair', bundle=False)
        check(state()['environment'] == original, 'repair restored stale simctl environment')
        checks.append('current-launchd-read-not-stale-simctl')

        original = {LIBRARY_KEY: '/opt/Argent.dylib'}
        package, ownership, run, state, update = case('deleted-loader-control-process', original)
        run('install')
        shutil.rmtree(package)
        update(requireSafeControlEnvironment=True)
        run('repair', bundle=False)
        check(state()['environment'] == original, 'safe launchctl repair changed inherited environment')
        checks.append('deleted-loader-never-injected-into-control-process')

        original = {LIBRARY_KEY: '/opt/Argent.dylib\n', 'CKSIM_PROFILE': ' \n', 'CKSIM_ENABLED': ''}
        package, ownership, run, state, update = case('launchctl-empty-and-newline', original)
        run('install')
        run('repair', bundle=False)
        check(state()['environment'] == original, 'launchctl transport changed empty/unset/trailing newline values')
        checks.append('launchctl-preserves-empty-unset-and-trailing-newlines')

        original = {LIBRARY_KEY: "/opt/Argent.dylib", "CKSIM_PROFILE": "previous-profile", "CKSIM_ENABLED": ""}
        package, ownership, run, state, update = case("deleted-package", original)
        run("install")
        shutil.rmtree(package)
        result = run("repair", bundle=False)
        check(json.loads(result.stdout)["repaired"], "deleted package was not repaired")
        check(state()["environment"] == original, "repair did not restore the original environment")
        check(not ownership.exists(), "repair left ownership behind")
        commands = len(state()["commands"])
        result = run("repair", bundle=False)
        check(not json.loads(result.stdout)["repaired"], "repeated repair was not a no-op")
        check(len(state()["commands"]) == commands, "repeated repair changed the simulator")
        checks += ["deleted-package", "repeated-repair"]

        package, ownership, run, state, update = case("unrelated-libraries", {LIBRARY_KEY: "/opt/Argent.dylib"})
        run("install")
        loader = str(package / "CKSimLoader.dylib")
        current = state()["environment"]
        current[LIBRARY_KEY] += f":/opt/XCTest.dylib:/other/CKSimLoader.dylib:{loader}.backup"
        update(environment=current)
        run("repair")
        check(state()["environment"] == {LIBRARY_KEY: f"/opt/Argent.dylib:/opt/XCTest.dylib:/other/CKSimLoader.dylib:{loader}.backup"},
              "repair removed unrelated appended libraries")
        checks.append("unrelated-appended-libraries")

        package, ownership, run, state, update = case("removed-original-library", {LIBRARY_KEY: "/opt/Argent.dylib"})
        run("install")
        current = state()["environment"]
        current[LIBRARY_KEY] = str(package / "CKSimLoader.dylib")
        update(environment=current)
        run("repair")
        check(LIBRARY_KEY not in state()["environment"], "repair resurrected a library removed externally")
        checks.append("externally-removed-library-stays-removed")

        for fail_key in (LIBRARY_KEY, "CKSIM_PROFILE"):
            original = {LIBRARY_KEY: "", "CKSIM_PROFILE": "original"}
            package, ownership, run, state, update = case(f"partial-{fail_key}", original)
            update(failKey=fail_key)
            run("install", success=False)
            check(ownership.exists(), "partial install has no recovery state")
            update(failKey=None)
            run("repair")
            check(state()["environment"] == original, "partial installation was not restored")
            run("repair")
        checks += ["partial-before-first-write", "partial-after-owned-writes"]

        original = {"CKSIM_BUNDLE_IDS": "prior-owner"}
        package, ownership, run, state, update = case("partial-add-bundle", original)
        run("install")
        update(failKey="CKSIM_BUNDLE_IDS")
        run("install", success=False, bundle="dev.cksim.second")
        saved = json.loads(ownership.read_text())
        check("dev.cksim.fixture" in saved["recoverable"]["CKSIM_BUNDLE_IDS"], "prior installation was not recoverable")
        update(failKey=None)
        run("repair")
        check(state()["environment"] == original, "partial second install did not restore the original owner")
        checks.append("partial-add-bundle-recovers-prior-value")

        package, ownership, run, state, update = case("partial-repair", {LIBRARY_KEY: "/opt/Argent.dylib"})
        run("install")
        update(failKey="CKSIM_PROFILE")
        run("repair", success=False)
        check(ownership.exists(), "failed repair discarded recovery state")
        update(failKey=None)
        run("repair")
        check(state()["environment"] == {LIBRARY_KEY: "/opt/Argent.dylib"}, "retry after partial repair failed")
        checks.append("retry-after-partial-repair")

        package, ownership, run, state, update = case("ambiguous-key", {LIBRARY_KEY: "/opt/Argent.dylib"})
        run("install")
        current = state()["environment"]
        current["CKSIM_PROFILE"] = "external-profile"
        update(environment=current)
        result = run("repair", success=False)
        check("CKSIM_PROFILE" in result.stderr and str(ownership) in result.stderr and "retry" in result.stderr,
              "ambiguous edit has no actionable ownership diagnostic")
        check(state()["environment"] == current, "ambiguous repair changed the environment")
        check(ownership.exists(), "ambiguous repair discarded its recovery state")
        checks.append("ambiguous-key-refuses-before-writes")

        package, ownership, run, state, update = case("duplicate-loader", {})
        run("install")
        current = state()["environment"]
        current[LIBRARY_KEY] += ":" + current[LIBRARY_KEY]
        update(environment=current)
        result = run("repair", success=False)
        check(LIBRARY_KEY in result.stderr, "duplicate loader lacks an ownership diagnostic")
        check(state()["environment"] == current and ownership.exists(), "duplicate loader repair changed state")
        checks.append("ambiguous-duplicate-loader-refuses")

    print(json.dumps(dict(success=True, checks=checks), indent=2))


if __name__ == "__main__":
    main()
