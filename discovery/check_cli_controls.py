#!/usr/bin/env python3
"""Run the shipping CLI against synthetic packages and a fake simulator mailbox.

These controls execute Tools/cksim, but never invoke Apple tools, alter launchd,
or write installation state. Fixtures are synthetic, not device evidence.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "Tools/cksim"
DEVICE = "00000000-0000-0000-0000-000000000001"
BUNDLE = "dev.callkitsim.synthetic"
RUN = "synthetic-cli-control"
PID = 12345

# A notification drives the synthetic runtime responder synchronously. Every
# xcrun invocation is recorded; any unsupported operation fails closed.
FAKE_XCRUN = '''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

fixture = Path(os.environ["CKSIM_SYNTHETIC_CLI_FIXTURE"])
args = sys.argv[1:]
with (fixture / "xcrun.jsonl").open("a") as output:
    output.write(json.dumps(args) + "\\n")
config = json.loads((fixture / "config.json").read_text())
if args == ["simctl", "get_app_container", config["device"], config["bundle"], "data"]:
    print(fixture / "container")
elif args == ["simctl", "spawn", config["device"],
              str(fixture / "package/cksim-notify"), "synthetic.notification"]:
    mailbox = fixture / "container/Documents/.callkit-simulator" / config["run"]
    requests = list((mailbox / "requests").glob("*.json"))
    if len(requests) != 1:
        raise SystemExit("Expected exactly one synthetic request")
    command = json.loads(requests[0].read_text())
    if config["response"] != "timeout":
        response = dict(command, success=True, fixture="synthetic")
        field = config["response"]
        if field != "positive":
            response[field] = command[field] + 1 if field == "pid" else "mismatched"
        (mailbox / "responses" / requests[0].name).write_text(json.dumps(response))
else:
    raise SystemExit("Unexpected fake xcrun invocation: " + repr(args))
'''


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def fixture(directory, response):
    package = directory / "package"
    (package / "profiles").mkdir(parents=True)
    version = (ROOT / "VERSION").read_text().strip()
    files = {}
    for name in ("CKSimRuntime.dylib", "CKSimLoader.dylib", "cksim-notify", "cksim", "profiles/ios-27.0.json", "VERSION"):
        path = package / name
        path.write_bytes((version + "\n").encode() if name == "VERSION" else ("synthetic fixture: " + name).encode())
        files[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    (package / "build-info.json").write_text(json.dumps(dict(schemaVersion=1, version=version, files=files)))
    root = directory / "container/Documents/.callkit-simulator"
    for name in ("requests", "responses"):
        (root / RUN / name).mkdir(parents=True)
    session = dict(schemaVersion=1, bundleID=BUNDLE, pid=PID, runID=RUN, notification="synthetic.notification")
    (root / "session.json").write_text(json.dumps(session))
    (directory / "config.json").write_text(json.dumps(dict(device=DEVICE, bundle=BUNDLE, run=RUN, response=response)))
    binary = directory / "bin/xcrun"
    binary.parent.mkdir()
    binary.write_text(FAKE_XCRUN)
    binary.chmod(0o755)
    return package, root, session


def controls():
    checks = []
    with tempfile.TemporaryDirectory(prefix="cksim-cli-controls-") as temporary:
        work = Path(temporary).resolve()

        def check(label, expected=None, *, mutate=None, response="positive", invocations=2):
            directory = work / label
            package, root, session = fixture(directory, response)
            if mutate:
                mutate(package, root, session)
            env = dict(os.environ, PATH=str(directory / "bin") + os.pathsep + os.environ.get("PATH", ""),
                       CKSIM_SYNTHETIC_CLI_FIXTURE=str(directory))
            result = subprocess.run([str(CLI), "--simulator", DEVICE, "--bundle", BUNDLE,
                                     "--runtime-dir", str(package), "--timeout", "0.1", "status"],
                                    env=env, capture_output=True, text=True, timeout=20)
            diagnostic = f"{label}: exit={result.returncode}, stdout={result.stdout!r}, stderr={result.stderr!r}"
            if expected:
                require(result.returncode == 1 and expected in result.stderr and not result.stdout, diagnostic)
            else:
                require(result.returncode == 0 and not result.stderr, diagnostic)
                actual = json.loads(result.stdout)
                require(actual.get("success") is True and actual.get("fixture") == "synthetic", diagnostic)
                request = json.loads(next((root / RUN / "requests").glob("*.json")).read_text())
                require(all(actual.get(key) == request[key] for key in ("id", "runID", "pid", "bundleID")), diagnostic)
                require(request["operation"] == "status", diagnostic)
            log = directory / "xcrun.jsonl"
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            require(len(calls) == invocations, f"{label}: unexpected fake xcrun calls: {calls}")
            if invocations < 2:
                require(not list((root / RUN / "requests").iterdir()), f"{label}: rejected input created a command")
            checks.append(dict(name=label, expected=expected or "synthetic status success", passed=True))

        def corrupt_package(package, root, session):
            (package / "CKSimRuntime.dylib").write_bytes(b"synthetic corrupted runtime")

        def traversal_package(package, root, session):
            outside = package.parent / "outside.dylib"
            outside.write_bytes(b"synthetic outside package")
            manifest = json.loads((package / "build-info.json").read_text())
            manifest["files"]["../outside.dylib"] = hashlib.sha256(outside.read_bytes()).hexdigest()
            (package / "build-info.json").write_text(json.dumps(manifest))

        def session_value(key, value):
            def mutate(package, root, session):
                session[key] = value
                (root / "session.json").write_text(json.dumps(session))
            return mutate

        check("synthetic-positive-status")
        check("package-checksum-corruption", "Runtime package checksum mismatch: CKSimRuntime.dylib",
              mutate=corrupt_package, invocations=0)
        check("package-path-traversal", "Runtime package checksum mismatch: ../outside.dylib",
              mutate=traversal_package, invocations=0)
        for label, key, value in (("bundle", "bundleID", "dev.callkitsim.other"),
                                  ("pid-zero", "pid", 0), ("pid-string", "pid", "12345"),
                                  ("runID-traversal", "runID", "../outside"), ("runID-empty", "runID", "")):
            check("session-" + label, "Invalid runtime session; launch the app with this runtime first.",
                  mutate=session_value(key, value), invocations=1)
        for field in ("id", "runID", "pid", "bundleID"):
            check("response-mismatched-" + field, "Runtime response identity mismatch.", response=field)
        check("response-timeout", "timed out; outcome is unknown. Query status/events before retrying.", response="timeout")
    return checks


if __name__ == "__main__":
    print(json.dumps(dict(success=True, fixtureKind="synthetic", cliSHA256=hashlib.sha256(CLI.read_bytes()).hexdigest(),
                          checks=controls()), indent=2))
