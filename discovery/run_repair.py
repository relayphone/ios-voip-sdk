#!/usr/bin/env python3
"""Measure deleted-package loader repair on one disposable simulator."""
import argparse
from collections import Counter
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

REPO = Path(__file__).resolve().parent.parent
CLI = REPO / "Tools/cksim"
KEYS = ("DYLD_INSERT_LIBRARIES", "CKSIM_RUNTIME", "CKSIM_BUNDLE_IDS", "CKSIM_ENABLED", "CKSIM_PROFILE")


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def hashes(values):
    return {key: None if value is None else hashlib.sha256(value.encode()).hexdigest()
            for key, value in values.items()}


def environment_diagnostic(actual, expected, fixture_paths):
    """Describe exact values and entry order without retaining inherited paths."""
    actual_entries = actual['DYLD_INSERT_LIBRARIES'].split(':') if actual['DYLD_INSERT_LIBRARIES'] is not None else []
    expected_entries = expected['DYLD_INSERT_LIBRARIES'].split(':') if expected['DYLD_INSERT_LIBRARIES'] is not None else []

    def entries(values):
        return [dict(role=next((role for role, path in fixture_paths.items() if value == path), 'inherited'),
                     sha256=hashlib.sha256(value.encode()).hexdigest(), utf8Bytes=len(value.encode()),
                     expectedIndices=[index for index, entry in enumerate(expected_entries) if value == entry])
                for value in values]

    return dict(actualSHA256=hashes(actual), expectedSHA256=hashes(expected),
                matchingKeys={key: actual[key] == expected[key] for key in KEYS},
                dyld=dict(actualEntries=entries(actual_entries), expectedEntries=entries(expected_entries),
                          sameEntryInventory=Counter(actual_entries) == Counter(expected_entries),
                          sameEntryOrder=actual_entries == expected_entries))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir()  # Refuse stale evidence, even an existing empty directory.
    work = Path(tempfile.mkdtemp(prefix="callkit-repair-build-")).resolve()
    simulator = None
    original = None
    ownership = None
    phase = "start"
    failure = None
    receipt = dict(schemaVersion=1, acceptance="R4 deleted-package repair preserves unrelated injectors",
                   runID=str(uuid.uuid4()).upper(), startedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                   cliSHA256=sha(CLI), testSHA256=sha(__file__), checks=[], steps=[])
    compiler_env = dict(os.environ)
    if os.environ.get("COMPILER_DEVELOPER_DIR"):
        compiler_env["DEVELOPER_DIR"] = os.environ["COMPILER_DEVELOPER_DIR"]

    def command(label, argv, timeout=60, *, env=None, check=True, sensitive=False):
        nonlocal phase
        phase = label
        started = time.monotonic()
        # Regular files avoid an unbounded pipe drain if a descendant stalls.
        with tempfile.TemporaryFile(mode="w+") as stdout, tempfile.TemporaryFile(mode="w+") as stderr:
            process = subprocess.Popen(argv, cwd=REPO, stdout=stdout, stderr=stderr, text=True,
                                       env=env, start_new_session=True)
            try:
                process.wait(timeout=timeout)
            except BaseException as error:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired as reap_error:
                    raise RuntimeError(label + " process group did not reap within five seconds") from reap_error
                if isinstance(error, subprocess.TimeoutExpired):
                    receipt["steps"].append(dict(phase=label, timeoutSeconds=timeout, timedOut=True))
                    raise RuntimeError(label + " exceeded its bounded deadline") from error
                raise
            stdout.seek(0)
            stderr.seek(0)
            result = subprocess.CompletedProcess(argv, process.returncode, stdout.read(), stderr.read())
        receipt["steps"].append(dict(phase=label, timeoutSeconds=timeout,
                                    elapsedSeconds=round(time.monotonic()-started, 3), exitCode=result.returncode,
                                    stdoutSHA256=hashlib.sha256(result.stdout.encode()).hexdigest(),
                                    stderrSHA256=hashlib.sha256(result.stderr.encode()).hexdigest()))
        if not sensitive:
            (out / (label+".stdout")).write_text(result.stdout)
            (out / (label+".stderr")).write_text(result.stderr)
        if check and result.returncode:
            raise RuntimeError(label + " failed; see scoped diagnostic")
        return result

    def sim(label, *argv, **kwargs):
        return command(label, ["xcrun", "simctl", *argv], **kwargs)

    def expect(name, condition):
        nonlocal phase
        phase = name
        if not condition:
            raise RuntimeError(name + " failed")
        receipt["checks"].append(name)

    def snapshot(label):
        values = {}
        for key in KEYS:
            result = sim(label+"-"+key.lower(), "getenv", simulator, key, sensitive=True)
            if result.stderr.strip() == "'%s' not found" % key:
                values[key] = None
            elif result.stderr:
                raise RuntimeError("Environment read diagnostic for " + key)
            else:
                values[key] = result.stdout.removesuffix("\n")
        receipt.setdefault('environmentSHA256', {})[label] = hashes(values)
        return values

    def write_key(label, key, value):
        operation = ["unsetenv", key] if value is None else ["setenv", key, value]
        sim(label, "spawn", simulator, "launchctl", *operation, sensitive=True)

    def cli(label, operation):
        argv = [sys.executable, str(CLI), "--simulator", simulator, "--runtime-dir", str(work/"runtime")]
        if operation == "install":
            argv += ["--bundle", "dev.callkitsim.repair"]
        return json.loads(command(label, [*argv, operation], timeout=180).stdout)

    def interrupted(signum, frame):
        raise RuntimeError("Interrupted by signal " + str(signum))

    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, interrupted)
    try:
        receipt["sourceCommit"] = command("source-commit", ["git", "rev-parse", "HEAD"]).stdout.strip()
        command("build-runtime", ["bash", "scripts/build-runtime.sh", str(work/"runtime")], timeout=300,
                env=dict(compiler_env, CKSIM_BUILD_ARCHS=platform.machine()))
        info = json.loads((work/"runtime/build-info.json").read_text())
        receipt["package"] = {key: info[key] for key in ("version", "sourceCommit", "sourceDirty", "sourceInputsSHA256", "architectures", "files", "toolchain", "sdk")}
        receipt["package"]["buildInfoSHA256"] = sha(work/"runtime/build-info.json")
        expect("clean-source-package-bound", info["sourceCommit"] == receipt["sourceCommit"] and not info["sourceDirty"])
        sdk = command("sdk-path", ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], env=compiler_env).stdout.strip()
        (work/"unrelated.c").write_text("void CKSIMRepairUnrelatedInjector(void) {}\n")
        (work/"ready.c").write_text("int main(void) { return 0; }\n")
        before, after, ready = work/"unrelated-before.dylib", work/"unrelated-after.dylib", work/"ready"
        receipt["helpers"] = {}
        for label, target, source, flags in (("before", before, "unrelated.c", ["-dynamiclib"]),
                                             ("after", after, "unrelated.c", ["-dynamiclib"]),
                                             ("ready", ready, "ready.c", [])):
            command("build-"+label, ["xcrun", "--sdk", "iphonesimulator", "clang", "-target", platform.machine()+"-apple-ios18.0-simulator",
                                    "-isysroot", sdk, *flags, str(work/source), "-o", str(target)], env=compiler_env)
            command("sign-"+label, ["codesign", "-s", "-", "--force", str(target)])
            command("verify-"+label, ["codesign", "--verify", "--strict", str(target)])
            receipt["helpers"][label] = sha(target)
        runtimes = json.loads(sim("runtime-inventory", "list", "runtimes", "-j", timeout=30).stdout)["runtimes"]
        available = [item for item in runtimes if item.get("platform") == "iOS" and item["isAvailable"]]
        runtime = max(available, key=lambda item: tuple(int(part) for part in item["version"].split(".")))
        simulator = sim("simulator-create", "create", "callkit-repair-"+receipt["runID"][:8],
                        "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", runtime["identifier"], timeout=30).stdout.strip()
        uuid.UUID(simulator)
        ownership = Path.home()/".local/state/callkit-simulator"/(simulator+".json")
        receipt["simulator"] = dict(udid=simulator, runtimeID=runtime["identifier"], version=runtime["version"], buildVersion=runtime["buildversion"])
        sim("simulator-boot", "boot", simulator, timeout=60)
        sim("simulator-bootstatus", "bootstatus", simulator, "-b", timeout=180)
        sim("helper-spawn-readiness", "spawn", simulator, str(ready))
        original = snapshot("original")
        receipt["originalEnvironmentSHA256"] = hashes(original)
        libraries_before = ":".join(filter(None, [original["DYLD_INSERT_LIBRARIES"], str(before)]))
        loader = str(work/"runtime/CKSimLoader.dylib")
        fixture_paths = dict(before=str(before), loader=loader, after=str(after))
        expected_before = dict(original, DYLD_INSERT_LIBRARIES=libraries_before)
        write_key("append-before-injector", "DYLD_INSERT_LIBRARIES", libraries_before)
        before_install = snapshot('before-install')
        receipt['environmentDiagnostics'] = dict(beforeInstall=environment_diagnostic(before_install, expected_before, fixture_paths))
        expect('before-injector-read-back', before_install == expected_before)
        expect("no-prior-ownership-for-owned-simulator", not ownership.exists())
        expect("install-success", cli("cli-install", "install")["installed"] is True)
        applied = snapshot("installed")
        expected_applied = dict(expected_before, DYLD_INSERT_LIBRARIES=libraries_before+":"+loader,
                                CKSIM_RUNTIME=str(work/'runtime/CKSimRuntime.dylib'),
                                CKSIM_BUNDLE_IDS='dev.callkitsim.repair', CKSIM_ENABLED='1', CKSIM_PROFILE='ios-27.0')
        receipt['environmentDiagnostics']['installed'] = environment_diagnostic(applied, expected_applied, fixture_paths)
        if ownership.exists():
            saved = json.loads(ownership.read_text())
            receipt['ownershipDiagnostic'] = dict(fileSHA256=sha(ownership),
                original=environment_diagnostic(saved['original'], before_install, fixture_paths),
                applied=environment_diagnostic(saved['applied'], expected_applied, fixture_paths))
        expect("install-preserves-inherited-plus-unrelated-before", applied["DYLD_INSERT_LIBRARIES"] == libraries_before+":"+loader)
        expect("owned-install-state-saved", ownership.exists())
        receipt["ownershipSHA256"] = sha(ownership)
        write_key("append-after-injector", "DYLD_INSERT_LIBRARIES", applied["DYLD_INSERT_LIBRARIES"]+":"+str(after))
        shutil.rmtree(work/"runtime")
        expect("package-deleted-before-repair", not (work/"runtime").exists())
        expect("source-cli-repairs-deleted-package", cli("cli-repair", "repair")["repaired"] is True)
        repaired = snapshot("repaired")
        expected_repaired = dict(original, DYLD_INSERT_LIBRARIES=libraries_before+":"+str(after))
        receipt['environmentDiagnostics']['repaired'] = environment_diagnostic(repaired, expected_repaired, fixture_paths)
        expect("repair-removes-only-owned-loader", repaired["DYLD_INSERT_LIBRARIES"] == libraries_before+":"+str(after)
               and loader not in repaired["DYLD_INSERT_LIBRARIES"].split(":"))
        expect("repair-preserves-original-owned-keys", all(repaired[key] == original[key] for key in KEYS[1:]))
        expect("repair-deletes-ownership-state", not ownership.exists())
        expect("repeated-repair-no-op", cli("cli-repair-repeat", "repair")["repaired"] is False)
        expect("repeated-repair-preserves-environment", snapshot("repeated") == repaired)
        receipt["repairedEnvironmentSHA256"] = hashes(repaired)
    except Exception as error:
        failure = dict(phase=phase, reason=str(error), type=type(error).__name__)
    finally:
        cleanup_errors = []
        if simulator and original is not None:
            try:
                current = snapshot("before-restoring")
                for key in KEYS:
                    if current[key] != original[key]:
                        write_key("restore-"+key.lower(), key, original[key])
                expect("original-global-environment-restored", snapshot("restored") == original)
            except Exception as error:
                cleanup_errors.append(dict(phase=phase, reason=str(error)))
        deleted = simulator is None
        if simulator:
            try:
                sim("simulator-shutdown", "shutdown", simulator, timeout=30, check=False)
            except Exception as error:
                cleanup_errors.append(dict(phase=phase, reason=str(error)))
            try:
                sim("simulator-delete", "delete", simulator, timeout=60)
                expect("owned-simulator-deleted", True)
                deleted = True
                # State for a deleted run-owned simulator cannot serve recovery.
                if ownership is not None:
                    ownership.unlink(missing_ok=True)
            except Exception as error:
                cleanup_errors.append(dict(phase=phase, reason=str(error)))
        if deleted:
            try:
                shutil.rmtree(work)
                expect("owned-build-directory-deleted", not work.exists())
            except Exception as error:
                cleanup_errors.append(dict(phase="build-cleanup", reason=str(error)))
        else:
            receipt["retainedBuildDirectory"] = str(work)
            cleanup_errors.append(dict(phase="build-cleanup", reason="Build retained while owned simulator deletion is unresolved"))
        if cleanup_errors:
            failure = dict(cleanupErrors=cleanup_errors, priorFailure=failure)
        receipt.update(success=failure is None, finishedAt=datetime.datetime.now(datetime.timezone.utc).isoformat())
        if failure:
            receipt["failure"] = failure
        (out/"native-receipt.json").write_text(json.dumps(receipt, indent=2)+"\n")
        print(json.dumps(dict(success=receipt["success"], checks=len(receipt["checks"]), receipt=str(out/"native-receipt.json"))))
    return 0 if receipt["success"] else 1


if __name__ == "__main__":
    sys.exit(main())
