#!/usr/bin/env python3
"""Exercise shipping push-launch CLI with synthetic files and fake xcrun only."""
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import time
import uuid


ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "Tools/cksim"
DEVICE = "00000000-0000-0000-0000-000000000001"
BUNDLE = "dev.callkitsim.synthetic"
RUN = "synthetic-push-launch"
INHERITED_LOADER = "/synthetic/argent.dylib:/synthetic/another.dylib"
SERVICES = "PID\tStatus\tLabel\n-\t0\tUIKitApplication:" + BUNDLE + "[synthetic-stopped]\n"
PAYLOAD = {"type": "incomingCall", "eventId": "synthetic-event", "callerName": "Synthetic"}
FAKE_XCRUN = '''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

fixture = Path(os.environ["CKSIM_SYNTHETIC_PUSH_FIXTURE"])
args = sys.argv[1:]
with (fixture / "xcrun.jsonl").open("a") as output:
    output.write(json.dumps(dict(args=args, pid=os.getpid(),
        env={key: value for key, value in os.environ.items()
             if key.startswith("SIMCTL_CHILD_") or key == "CKSIM_RUN_ID"})) + "\\n")
config = json.loads((fixture / "config.json").read_text())
if args == ["simctl", "get_app_container", config["device"], config["bundle"], "data"]:
    print(fixture / "container")
elif args == ["simctl", "spawn", config["device"], "launchctl", "list"]:
    sys.stdout.write(config["services"])
    sys.stderr.write(config.get("queryStderr", ""))
elif args == ["simctl", "launch", "--console", config["device"], config["bundle"]]:
    print(json.dumps(dict(fixtureKind="synthetic", launched=True)))
else:
    raise SystemExit("Unexpected fake xcrun invocation: " + repr(args))
'''


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def fixture(directory):
    package = directory / "package"
    (package / "profiles").mkdir(parents=True)
    version = (ROOT / "VERSION").read_text().strip()
    files = {}
    for name in ("CKSimRuntime.dylib", "CKSimLoader.dylib", "cksim-notify", "cksim",
                 "profiles/ios-27.0.json", "VERSION"):
        data = ((version + "\n") if name == "VERSION" else "synthetic fixture: " + name).encode()
        (package / name).write_bytes(data)
        files[name] = hashlib.sha256(data).hexdigest()
    (package / "build-info.json").write_text(json.dumps(dict(schemaVersion=1, version=version, files=files)))
    root = directory / "container/Documents/.callkit-simulator"
    root.mkdir(parents=True, mode=0o700)
    (directory / "payload.json").write_text(json.dumps(PAYLOAD))
    (directory / "config.json").write_text(json.dumps(dict(device=DEVICE, bundle=BUNDLE, services=SERVICES, queryStderr="")))
    binary = directory / "bin/xcrun"
    binary.parent.mkdir()
    binary.write_text(FAKE_XCRUN)
    binary.chmod(0o755)
    return package, root


def controls():
    checks = []
    with tempfile.TemporaryDirectory(prefix="cksim-push-launch-controls-") as temporary:
        work = Path(temporary).resolve()

        def check(label, expected=None, *, mutate=None, run=RUN, must_report="true", invocations=2, exit_code=1):
            directory = work / label
            package, root = fixture(directory)
            receipt_path = directory / "receipt.json"
            if mutate:
                mutate(directory, root)
            preserved = {path: path.read_bytes() for path in (root / "push-launch.json", root / "push-launch.consuming", receipt_path)
                         if path.is_file() and not path.is_symlink()}
            links = {path: os.readlink(path) for path in (root, root / "push-launch.json", root / "push-launch.consuming", receipt_path)
                     if path.is_symlink()}
            env = dict(os.environ, PATH=str(directory / "bin") + os.pathsep + os.environ.get("PATH", ""),
                       CKSIM_SYNTHETIC_PUSH_FIXTURE=str(directory), CKSIM_RUN_ID="inherited-parent-run",
                       SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=INHERITED_LOADER,
                       SIMCTL_CHILD_CKSIM_RUN_ID="inherited-child-run", SIMCTL_CHILD_SYNTHETIC_MARKER="preserve-me")
            for key in ("SIMCTL_CHILD_CKSIM_ENABLED", "SIMCTL_CHILD_CKSIM_PROFILE", "SIMCTL_CHILD_CKSIM_RUNTIME"):
                env.pop(key, None)
            before = int(time.time() * 1000)
            process = subprocess.Popen([str(CLI), "--simulator", DEVICE, "--bundle", BUNDLE,
                "--runtime-dir", str(package), "push", "--payload-file", str(directory / "payload.json"),
                "--must-report", must_report, "--launch", "--run-id", run, "--launch-receipt", str(receipt_path)],
                env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                stdout, stderr = process.communicate(timeout=20)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate()
                raise RuntimeError(label + ": CLI subprocess timed out")
            after = int(time.time() * 1000)
            diagnostic = f"{label}: exit={process.returncode}, stdout={stdout!r}, stderr={stderr!r}"
            log = directory / "xcrun.jsonl"
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            if expected:
                require(process.returncode == exit_code and expected in stderr and not stdout, diagnostic)
                require(not any(call["args"][1:2] == ["launch"] for call in calls), label + ": rejection launched app")
                require(not (root / "push-launch.json").exists() or root / "push-launch.json" in preserved,
                        label + ": rejection published a new envelope")
                require(not receipt_path.exists() or receipt_path in preserved, label + ": rejection wrote a receipt")
            else:
                require(process.returncode == 0 and not stderr and json.loads(stdout) == dict(fixtureKind="synthetic", launched=True), diagnostic)
                raw = (root / "push-launch.json").read_bytes()
                envelope = json.loads(raw)
                nonce = str(uuid.UUID(envelope["id"])).upper()
                require(set(envelope) == {"schemaVersion", "id", "runID", "bundleID", "createdAtMS", "expiresAtMS", "mustReport", "payload"}
                        and envelope["schemaVersion"] == 1 and envelope["id"] == nonce and envelope["runID"] == RUN
                        and envelope["bundleID"] == BUNDLE and envelope["payload"] == PAYLOAD
                        and envelope["mustReport"] is (must_report == "true"), label + ": envelope identity/payload mismatch")
                require(before <= envelope["createdAtMS"] <= after and envelope["expiresAtMS"] - envelope["createdAtMS"] == 30000,
                        label + ": envelope must have a current 30-second TTL")
                require(raw == (json.dumps(envelope, sort_keys=True) + "\n").encode(), label + ": unexpected envelope serialization")
                for path, mode in ((root, 0o700), (root / "push-launch.json", 0o600), (receipt_path, 0o600)):
                    info = path.lstat()
                    require(not path.is_symlink() and stat.S_IMODE(info.st_mode) == mode and info.st_uid == os.getuid(),
                            label + ": unsafe staged ownership/mode")
                receipt = json.loads(receipt_path.read_text())
                require(receipt == dict(schemaVersion=1, simulatorID=DEVICE, bundleID=BUNDLE, runID=RUN, pushID=nonce,
                    envelope=envelope, envelopeSHA256=hashlib.sha256(raw).hexdigest(), mode=0o600, appServiceAbsent=True,
                    serviceQuery=SERVICES, serviceQuerySHA256=hashlib.sha256(SERVICES.encode()).hexdigest(), runtimeInjectionRequested=False),
                    label + ": launch receipt does not bind the staged bytes/service query")
                require(calls[-1]["pid"] == process.pid, label + ": CLI did not become the console launcher with exec")
                child = calls[-1]["env"]
                require(child["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] == INHERITED_LOADER
                        and child["SIMCTL_CHILD_CKSIM_RUN_ID"] == RUN and child["CKSIM_RUN_ID"] == "inherited-parent-run"
                        and child["SIMCTL_CHILD_SYNTHETIC_MARKER"] == "preserve-me", label + ": inherited launch environment changed")
                require(not any(key in child for key in ("SIMCTL_CHILD_CKSIM_ENABLED", "SIMCTL_CHILD_CKSIM_PROFILE", "SIMCTL_CHILD_CKSIM_RUNTIME")),
                        label + ": launch requested external runtime injection")
                require(not list(root.glob(".push-launch-*")), label + ": temporary staging file leaked")
            require(len(calls) == invocations, f"{label}: unexpected xcrun invocations: {calls}")
            if calls:
                require(calls[0]["args"] == ["simctl", "get_app_container", DEVICE, BUNDLE, "data"], label + ": wrong container query")
                require(calls[1]["args"] == ["simctl", "spawn", DEVICE, "launchctl", "list"]
                        and calls[1]["env"]["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] == "", label + ": unsafe service query")
            if not expected:
                require(calls[-1]["args"] == ["simctl", "launch", "--console", DEVICE, BUNDLE], label + ": wrong console launcher")
            for path, original in preserved.items():
                require(path.read_bytes() == original, label + ": rejection overwrote existing state")
            for path, original in links.items():
                require(path.is_symlink() and os.readlink(path) == original, label + ": rejection replaced a symlink")
            checks.append(dict(name=label, expected=expected or "secure synthetic push launch", passed=True))

        def active(directory, root):
            config = json.loads((directory / "config.json").read_text())
            config["services"] += "123\t0\tUIKitApplication:" + BUNDLE + "[synthetic]\n"
            (directory / "config.json").write_text(json.dumps(config))

        def query(services=SERVICES, diagnostic=""):
            def mutate(directory, root):
                path = directory / "config.json"
                config = json.loads(path.read_text())
                config.update(services=services, queryStderr=diagnostic)
                path.write_text(json.dumps(config))
            return mutate

        def symlink_directory(directory, root):
            root.rmdir()
            target = directory / "outside"
            target.mkdir(mode=0o700)
            root.symlink_to(target, target_is_directory=True)

        def write(name, content):
            return lambda directory, root: ((directory if name in ("receipt.json", "payload.json") else root) / name).write_text(content)

        check("secure-launch", invocations=3)
        check("optional-report-launch", must_report="false", invocations=3)
        check("active-app", "Push launch requires a stopped app", mutate=active)
        check("empty-service-query", "Invalid launchctl service table", mutate=query(""))
        check("header-only-service-query", "Invalid launchctl service table", mutate=query("PID\tStatus\tLabel\n"))
        check("malformed-service-query", "Invalid launchctl service table", mutate=query("PID\tStatus\tLabel\ninvalid\t0\tlabel\n"))
        check("diagnostic-service-query", "Stopped-app query failed or returned diagnostics", mutate=query(diagnostic="synthetic query diagnostic\n"))
        check("unsafe-directory-mode", "Unsafe push launch directory", mutate=lambda directory, root: root.chmod(0o755))
        check("unsafe-directory-symlink", "Unsafe push launch directory", mutate=symlink_directory)
        check("existing-pending", "File exists", mutate=write("push-launch.json", "existing-pending\n"))
        check("dangling-pending", "File exists",
              mutate=lambda directory, root: (root / "push-launch.json").symlink_to(directory / "absent"))
        check("existing-claim", "A push launch claim already exists", mutate=write("push-launch.consuming", "existing-claim\n"))
        check("invalid-payload-array", "Push payload must be an object", mutate=write("payload.json", "[]"))
        check("invalid-payload-json", "Expecting property name", mutate=write("payload.json", "{"))
        check("oversized-payload", "Push payload must be an object", mutate=write("payload.json", json.dumps({"synthetic": "x" * 5120})))
        for label, value in (("run-traversal", "../outside"), ("run-empty", ""), ("run-too-long", "r" * 65)):
            check(label, "push --launch requires --run-id and a fresh --launch-receipt", run=value, invocations=0, exit_code=2)
        check("reused-receipt", "Launch receipt already exists; inspect before staging.", mutate=write("receipt.json", "existing-receipt\n"), invocations=0)
        check("dangling-receipt", "Launch receipt already exists; inspect before staging.", invocations=0,
              mutate=lambda directory, root: (directory / "receipt.json").symlink_to(directory / "absent"))
        check("dangling-claim", "A push launch claim already exists",
              mutate=lambda directory, root: (root / "push-launch.consuming").symlink_to(directory / "absent"))
    return checks


if __name__ == "__main__":
    print(json.dumps(dict(success=True, measurement="measured synthetic CLI subprocess controls only",
        fixtureKind="synthetic", cliSHA256=hashlib.sha256(CLI.read_bytes()).hexdigest(), checks=controls()), indent=2))
