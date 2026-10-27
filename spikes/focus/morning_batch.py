"""Ordered, resumable focus measurements. Dry runs never touch a device or secrets."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import uuid

HERE = Path(__file__).resolve().parent
RUNNER = HERE / "run.sh"
DEFAULT_UNKNOWN = "+15555550200"
TEAM = "85A9MS6428"


def make_plan(unknown):
    """Give every sample a stable identity, so an interrupted attempt is never replayed."""
    if not re.fullmatch(r"\+[1-9][0-9]{7,14}", unknown) or unknown == "+15555550199":
        raise ValueError("unknown caller must be a different E.164 test handle")
    out = []

    def add(label, row, args=(), samples=1):
        for sample in range(1, samples + 1):
            out.append({"id": f"{label}-{sample:02}", "row": row,
                        "args": [*args, "--keep-setup"], "sample": sample})

    add("filter", "C06")
    add("calls-baseline", "C01")
    add("focus-status", "C05")
    add("callkit-positive", "C00", ["--provider", "callkit"])
    for index in range(1, 17):
        if index in [5, 9, 13]:
            add(f"callkit-refresh-f{index:02}", "C00", ["--provider", "callkit"])
        add(f"ck-matrix-f{index:02}", f"F{index:02}", ["--provider", "callkit"], samples=3)
    add("ck-dnd-unknown-positive-before", "C00", ["--provider", "callkit", "--unknown-caller", "--caller-value", unknown])
    add("ck-dnd-unknown", "F09", ["--provider", "callkit", "--focus-mode", "dnd",
                                    "--unknown-caller", "--caller-value", unknown], samples=3)
    add("ck-dnd-unknown-positive-after", "C00", ["--provider", "callkit", "--unknown-caller", "--caller-value", unknown])
    for row, provider in [("CK-C02", "callkit"), ("LCK-C02b", "lck")]:
        add(f"{provider}-repeat-positive", "C00", ["--provider", provider])
        for setting in ["off", "on"]:
            add(f"{provider}-repeat-{setting}", row, ["--repeated-calls", setting], samples=3)
    for provider in ["callkit", "lck"]:
        add(f"{provider}-calls-positive", "C00", ["--provider", provider])
        for setting in ["Contacts Only", "Everyone"]:
            for identity in ["contact", "unknown"]:
                args = ["--provider", provider, "--calls", setting]
                if identity == "unknown":
                    args += ["--unknown-caller", "--caller-value", unknown]
                add(f"{provider}-{setting.replace(' ', '-').lower()}-{identity}", "C01", args, 3)
        for favorite in ["yes", "no"]:
            add(f"{provider}-favorite-{favorite}", "C01",
                ["--provider", provider, "--calls", "Favorites", "--favorite", favorite], 3)
    for provider, row in [("callkit", "CK-F13"), ("lck", "F13")]:
        for shape in ["e164", "national", "generic"]:
            add(f"{provider}-{shape}-positive", "C00", ["--provider", provider, "--caller-format", shape])
            add(f"{provider}-handle-{shape}", row, ["--caller-format", shape], 3)
    for provider in ["callkit", "lck"]:
        add(f"{provider}-answer-positive", "C00", ["--provider", provider])
        add(f"{provider}-answer", "F01", ["--provider", provider, "--server-answer"], 3)
    add("callkit-dnd-answer-positive-before", "C00", ["--provider", "callkit", "--unknown-caller", "--caller-value", unknown])
    add("callkit-dnd-answer", "F09", ["--provider", "callkit", "--focus-mode", "dnd",
                                       "--unknown-caller", "--caller-value", unknown, "--server-answer"], 3)
    add("callkit-dnd-answer-positive-after", "C00", ["--provider", "callkit", "--unknown-caller", "--caller-value", unknown])
    for index in range(1, 17):
        add(f"activity-{index:02}", f"L{index:02}")
    # Mac permission is requested only here; C00 --listen is the last measurement.
    add("microphone-positive", "C00", ["--listen"])
    return out


def safe_env():
    return {key: value for key, value in os.environ.items() if not key.startswith("PHONE_APNS_")}


def atomic_json(path, value):
    temp = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    with temp.open("x", encoding="utf-8") as f:
        os.chmod(temp, 0o600)
        json.dump(value, f, sort_keys=True, indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(temp, path)


def run_json(argv, env=None, timeout=25):
    result = subprocess.run(argv, capture_output=True, text=True, env=env, timeout=timeout)
    if result.returncode:
        raise RuntimeError("row dry-run failed; inspect the runner independently")
    return json.loads(result.stdout)


def dry_run(plan, unknown):
    # Explicitly run the underlying dry-runs, rather than merely inventing a plan.
    clean = {k: v for k, v in safe_env().items() if not k.startswith("FOCUS_")}
    def redact(value):
        if isinstance(value, dict):
            return {key: redact(child) for key, child in value.items()}
        if isinstance(value, list):
            return [redact(child) for child in value]
        return value.replace(unknown, "<unknown-test-handle>") if isinstance(value, str) else value
    preflight = redact(run_json([str(RUNNER), "preflight", "--dry-run"], env=clean))
    print(json.dumps({"deviceGate": "require unique iPhone 13 from devicectl device inventory before build/UI",
                      "preflight": preflight, "signing": "xcodegen; xcodebuild build-for-testing -allowProvisioningUpdates with signed-in Xcode account and team " + TEAM,
                      "microphonePreflight": "compile listener and request authorization once (bounded 30 seconds, no recording)",
                      "deviceLock": "~/.device-locks/<FOCUS_DEVICE>.lock; no stealing; Phone priority"}))
    for item in plan:
        value = run_json([str(RUNNER), item["row"], *item["args"], "--dry-run"], env=clean)
        # Unknown number may be a real test handle; never display it.
        value = redact(value)
        print(json.dumps({"id": item["id"], "sample": item["sample"], "plan": value}, separators=(",", ":")))
    print(json.dumps({"cleanup": redact(run_json([str(RUNNER), "restore-all", "--dry-run"], env=clean)),
                      "pause": "Create FOCUS_WORK/PAUSE; finish current row, restore, release lock, resume after removing marker"}))


def checkpoint_id(plan):
    # Binding includes the caller without writing it into the checkpoint.
    return hashlib.sha256(json.dumps(plan, sort_keys=True).encode()).hexdigest()


def phone_wants_device(work, lock_dir, device):
    return (work / "PAUSE").exists() or (lock_dir / "PAUSE").exists() or (lock_dir / (device + ".priority")).exists()


DEVICE_ID_PATTERN = re.compile(r"[A-F0-9]{8}-[A-F0-9]{16}")


def iphone13_identity(inventory, selected):
    """Accept a canonical uppercase hardware UDID only, never an alias or name."""
    if not DEVICE_ID_PATTERN.fullmatch(selected):
        raise ValueError("FOCUS_DEVICE must be the canonical uppercase iPhone hardware UDID")
    devices = inventory.get("result", {}).get("devices", [])
    if not isinstance(devices, list):
        raise ValueError("device inventory is unavailable")
    matches = []
    for item in devices:
        if not isinstance(item, dict):
            continue
        hardware = item.get("hardwareProperties") or {}
        if not isinstance(hardware, dict):
            continue
        udid = hardware.get("udid")
        if isinstance(udid, str) and udid.upper() == selected:
            matches.append((item, hardware))
    if len(matches) != 1:
        raise ValueError("device identity is missing or ambiguous")
    item, hardware = matches[0]
    model, kind = hardware.get("marketingName"), hardware.get("productType")
    if model not in [None, "iPhone 13"] or kind not in [None, "iPhone14,5"] or (model is None and kind is None):
        raise ValueError("only iPhone 13 is authorized; model missing, conflicting or different")
    return selected


def identify_iphone13(selected, work):
    if not DEVICE_ID_PATTERN.fullmatch(selected):
        raise ValueError("FOCUS_DEVICE must be the canonical uppercase iPhone hardware UDID")
    inventory = work / ("device-inventory-" + uuid.uuid4().hex + ".json")
    try:
        command(["xcrun", "devicectl", "list", "devices", "--json-output", str(inventory), "--quiet"],
                safe_env(), work / "device-inventory.log", 30)
        return iphone13_identity(json.loads(inventory.read_text()), selected)
    finally:
        inventory.unlink(missing_ok=True)


def private_row_result(work, item, payload):
    result_name = payload.get("result")
    if not isinstance(result_name, str):
        raise RuntimeError("row has no verifiable private result")
    result_path = Path(result_name).resolve()
    if not result_path.is_relative_to(work):
        raise RuntimeError("row result is outside the private work directory")
    result = json.loads(result_path.read_text())
    if (result.get("row") != item["row"] or result.get("status") != payload.get("status")
            or result.get("restored") not in [True, "focus-off"]):
        raise RuntimeError("row result or restoration is not verified")
    return result_name, result


def result_summary(item, result):
    """Only non-sensitive qualification flags, never caller, token or transcript."""
    summary = {}
    if isinstance(result.get("visualNegativeQualified"), bool):
        summary["visualNegativeQualified"] = result["visualNegativeQualified"]
    if "--server-answer" in item["args"]:
        evidence = result.get("answeredElsewhere") or {}
        status = evidence.get("status")
        summary["answerEvidence"] = status if status in ["observed", "unqualified"] else "unqualified"
    if "--listen" in item["args"]:
        audio = result.get("audio") or {}
        if audio.get("reason") == "mic permission pending":
            summary["microphone"] = "mic permission pending; visual evidence only"
        elif audio.get("calibrationValid") is True:
            summary["microphone"] = "positive calibration recorded"
        else:
            summary["microphone"] = "visual evidence only"
    if re.fullmatch(r"L[0-9]{2}", item["row"]):
        summary["activityCoverage"] = "single transport/presentation subcase" if result.get("coverage") else "unqualified"
    return summary


class DeviceLock:
    def __init__(self, base, device):
        if not re.fullmatch(r"[A-Za-z0-9-]+", device):
            raise ValueError("FOCUS_DEVICE must be a device identifier")
        self.base, self.path, self.nonce = base, base / (device + ".lock"), uuid.uuid4().hex

    def acquire(self):
        self.base.mkdir(mode=0o700, parents=True, exist_ok=True)
        try:
            self.path.mkdir(mode=0o700)
        except FileExistsError:
            raise RuntimeError("device lock occupied; Phone has priority; no device action taken")
        atomic_json(self.path / "owner.json", {"owner": "focus-morning-batch", "pid": os.getpid(), "nonce": self.nonce})

    def release(self):
        owner = json.loads((self.path / "owner.json").read_text())
        if owner.get("nonce") != self.nonce:
            raise RuntimeError("device lock ownership changed; not releasing")
        (self.path / "owner.json").unlink()
        self.path.rmdir()


class BatchPaused(RuntimeError):
    pass


class ProcessGroupCleanupError(RuntimeError):
    """A timed-out command still owns processes; keep the device locked."""


def stop_process_group(process):
    """Stop the entire inherited group, including the runner's UI observer."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        process.wait(timeout=5)
        return
    except OSError as error:
        raise ProcessGroupCleanupError("cannot stop the process group") from error
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        pass
    # The parent may have exited while an observer remains, so always kill the group.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except OSError as error:
        raise ProcessGroupCleanupError("cannot kill the process group") from error
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired as error:
        raise ProcessGroupCleanupError("runner did not exit after termination") from error
    deadline = time.monotonic() + 5
    while True:
        try:
            os.killpg(process.pid, 0)
        except ProcessLookupError:
            return
        except OSError as error:
            raise ProcessGroupCleanupError("cannot verify process group exit") from error
        if time.monotonic() >= deadline:
            raise ProcessGroupCleanupError("process group remains after termination")
        time.sleep(0.05)


def command(argv, env, log, timeout, should_pause=None):
    with log.open("ab") as stream:
        process = subprocess.Popen(argv, stdout=stream, stderr=subprocess.STDOUT, env=env, start_new_session=True)
        deadline = time.monotonic() + timeout
        try:
            while process.poll() is None:
                if should_pause is not None and should_pause():
                    raise BatchPaused("Phone priority or PAUSE requested")
                if time.monotonic() >= deadline:
                    raise subprocess.TimeoutExpired(argv, timeout)
                time.sleep(0.1)
        except BaseException:
            stop_process_group(process)
            raise
        result = process
        if result.returncode:
            # A failed parent can leave its observer alive even after it has exited.
            stop_process_group(process)
    if result.returncode:
        raise RuntimeError("command failed; inspect the private batch log; uncertain attempts are not retried")


def signed_build(work, device, env, should_pause):
    # A unique derived directory prevents a stale xctestrun from a previous build being selected.
    build = work / ("signed-build-" + uuid.uuid4().hex)
    build.mkdir(mode=0o700)
    log = work / "sign-build.log"
    command(["xcodegen", "generate", "--spec", str(HERE / "project.yml"), "--quiet"], env, log, 90, should_pause)
    command(["xcodebuild", "build-for-testing", "-project", str(HERE / "FocusProbe.xcodeproj"),
             "-scheme", "FocusProbe", "-destination", "id=" + device, "-derivedDataPath", str(build),
             "-allowProvisioningUpdates", "DEVELOPMENT_TEAM=" + TEAM], env, log, 1200, should_pause)
    choices = list((build / "Build" / "Products").glob("*.xctestrun"))
    if len(choices) != 1:
        raise RuntimeError("signed build must yield exactly one xctestrun")
    return choices[0]


def authorize_microphone(work, should_pause):
    """Ask once early; a missing answer never blocks the rest of the batch."""
    binary = work / "listen"
    log = work / "microphone-authorization.log"
    log.write_text("")
    try:
        command(["swiftc", str(HERE / "listen.swift"), "-o", str(binary)], safe_env(), log, 90, should_pause)
        command([str(binary), "--authorize"], safe_env(), log, 30, should_pause)
        return "authorized" if "Microphone authorized" in log.read_text() else "pending-or-denied"
    except BatchPaused:
        raise
    except ProcessGroupCleanupError:
        raise
    except (RuntimeError, subprocess.TimeoutExpired, OSError):
        return "pending-or-denied"


def run_batch(plan, args):
    device = os.environ.get("FOCUS_DEVICE")
    if not device:
        raise ValueError("FOCUS_DEVICE is required; no device selected automatically")
    os.umask(0o077)
    work = Path(os.environ.get("FOCUS_WORK", str(HERE / "out"))).resolve()
    repo = HERE.parents[1]
    if work.is_relative_to(repo) and work != HERE / "out":
        raise ValueError("Use ignored spikes/focus/out or a private path outside the repository")
    work.mkdir(mode=0o700, parents=True, exist_ok=True)
    work.chmod(0o700)
    # Inventory is read-only and happens before signing, UI tests, or any Focus change.
    device = identify_iphone13(device, work)
    lock_dir = Path.home() / ".device-locks"
    if phone_wants_device(work, lock_dir, device):
        raise BatchPaused("PAUSE or Phone priority marker exists; no device action taken")
    lock = DeviceLock(lock_dir, device)
    lock.acquire()
    checkpoint = work / "morning-checkpoint.json"
    # Row execution needs APNs credentials. The runner only forwards them to the sender.
    env = os.environ.copy()
    env.pop("FOCUS_REQUIRE_DEVICE_JOURNAL", None)
    env["FOCUS_DEVICE"], env["FOCUS_WORK"] = device, str(work)
    state = None
    dirty = checkpoint.exists()  # Unknown state is unsafe until a valid checkpoint proves it clean.
    verified = False
    stopped = False
    unsafe_processes = False
    old_handlers = {}

    def pause_handler(_signum, _frame):
        nonlocal stopped
        stopped = True

    def pause_requested():
        return stopped or phone_wants_device(work, lock_dir, device)

    def mark_restored():
        nonlocal dirty
        state["dirty"] = False
        interrupted = state.get("inFlight")
        if interrupted:
            # Its outcome may include a delivered push: never replay it on resume.
            state["completed"][interrupted] = {"status": "unqualified-interrupted", "result": None}
            state["inFlight"] = None
        atomic_json(checkpoint, state)
        dirty = False

    try:
        for signum in [signal.SIGINT, signal.SIGTERM]:
            old_handlers[signum] = signal.signal(signum, pause_handler)
        if checkpoint.exists():
            state = json.loads(checkpoint.read_text())
            if state.get("device") != device:
                dirty = False  # A different device's checkpoint must not be touched.
                raise RuntimeError("checkpoint belongs to another device; use a separate work directory")
            dirty = state.get("dirty", bool(state.get("inFlight") or state.get("completed")))
            if state.get("planHash") != checkpoint_id(plan):
                raise RuntimeError("checkpoint plan changed; recover the original run before resuming")
        else:
            state = {"version": 1, "device": device, "planHash": checkpoint_id(plan),
                     "completed": {}, "inFlight": None, "dirty": False}
            atomic_json(checkpoint, state)
            dirty = False
        if pause_requested():
            raise BatchPaused("Phone priority or PAUSE requested")
        if state.get("build"):
            build = Path(state["build"])
            if not build.is_file() or hashlib.sha256(build.read_bytes()).hexdigest() != state.get("buildHash"):
                raise RuntimeError("checkpoint signed build is missing or changed")
        else:
            build = signed_build(work, device, safe_env(), pause_requested)
            state["build"] = str(build)
            state["buildHash"] = hashlib.sha256(build.read_bytes()).hexdigest()
            atomic_json(checkpoint, state)
        env["FOCUS_XCTESTRUN"] = str(build)
        if pause_requested():
            raise BatchPaused("Phone priority or PAUSE requested")
        # No Focus action, including restoration, occurs before this assertion succeeds.
        if dirty:
            env["FOCUS_REQUIRE_DEVICE_JOURNAL"] = "1"
        command([str(RUNNER), "preflight"], env, work / "preflight.log", 660, pause_requested)
        verified = True
        if dirty:
            # Previous crash: restore first, then account for the ambiguous attempt without retry.
            command([str(RUNNER), "restore-all"], env, work / "batch-restore.log", 660)
            mark_restored()
            env.pop("FOCUS_REQUIRE_DEVICE_JOURNAL", None)
        if pause_requested():
            raise BatchPaused("Phone priority or PAUSE requested")
        state["microphoneAuthorization"] = authorize_microphone(work, pause_requested)
        atomic_json(checkpoint, state)
        if state["microphoneAuthorization"] != "authorized":
            print("mic permission pending or unavailable; continuing with visual evidence only", flush=True)
        for item in plan:
            if item["id"] in state["completed"]:
                continue
            if pause_requested():
                stopped = True
                break
            # Persist the attempt before a push can occur. Never replay an interrupted attempt.
            state["dirty"] = True
            state["inFlight"] = item["id"]
            atomic_json(checkpoint, state)
            dirty = True
            print("Running", item["id"], flush=True)
            log = work / ("batch-" + item["id"] + ".log")
            row_failed = False
            try:
                command([str(RUNNER), item["row"], *item["args"]], env, log, 900)
            except ProcessGroupCleanupError:
                raise
            except RuntimeError:
                # A measured-but-unqualified row may exit nonzero after successful cleanup.
                # Only continue if its private result independently proves restoration.
                row_failed = True
            # Distinguish unsupported rows from measurements; never call a skipped row a pass.
            lines = log.read_text().splitlines()
            payload = None
            for line in reversed(lines):
                try:
                    value = json.loads(line)
                    if isinstance(value, dict) and "status" in value:
                        payload = value
                        break
                except json.JSONDecodeError:
                    continue
            if payload is None:
                try:
                    payload = json.loads(log.read_text())
                except json.JSONDecodeError:
                    raise RuntimeError("row produced no machine-readable result")
            status = payload.get("status")
            if row_failed:
                result_name, row_result = private_row_result(work, item, payload)
                if status in ["recorded", "restored", "restore-failed-use-restore-all"]:
                    raise RuntimeError("failed row restoration is not verified")
                state["completed"][item["id"]] = {"status": "unqualified", "reason": status, "result": result_name,
                                                    **result_summary(item, row_result)}
            elif status == "recorded":
                result_name, row_result = private_row_result(work, item, payload)
                state["completed"][item["id"]] = {"status": status, "result": result_name, **result_summary(item, row_result)}
            elif status == "skipped-dependency-or-unsupported":
                state["completed"][item["id"]] = {"status": status, "result": None}
            else:
                raise RuntimeError("row did not finish with a recorded result or explicit skip")
            state["inFlight"] = None
            atomic_json(checkpoint, state)
        return 75 if pause_requested() else 0
    except BatchPaused:
        return 75
    except ProcessGroupCleanupError:
        unsafe_processes = True
        raise
    finally:
        failure = None
        if unsafe_processes:
            failure = RuntimeError("a subprocess group may still be running")
        elif dirty:
            if verified and state is not None and env.get("FOCUS_XCTESTRUN"):
                try:
                    env["FOCUS_REQUIRE_DEVICE_JOURNAL"] = "1"
                    command([str(RUNNER), "restore-all"], env, work / "batch-restore.log", 660)
                    mark_restored()
                except (RuntimeError, subprocess.TimeoutExpired, OSError) as error:
                    failure = error
            else:
                failure = RuntimeError("restore required but Share Across Devices OFF could not be verified")
        if not dirty and failure is None:
            lock.release()
        for signum, handler in old_handlers.items():
            signal.signal(signum, handler)
        if failure:
            print("Restoration incomplete; device lock retained for recovery", file=sys.stderr)
            if unsafe_processes:
                raise RuntimeError("subprocess group may still be running; retain the device lock until it is stopped") from failure
            raise RuntimeError("restore-all failed or could not be safely attempted; recover settings before releasing lock") from failure


def main():
    parser = argparse.ArgumentParser(description="Run the Focus morning matrix with durable checkpoints")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--unknown-caller", default=DEFAULT_UNKNOWN,
                        help="synthetic owned E.164 test caller absent from the iPhone contacts")
    args = parser.parse_args()
    plan = make_plan(args.unknown_caller)
    if args.dry_run:
        dry_run(plan, args.unknown_caller)
        return 0
    return run_batch(plan, args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, RuntimeError, subprocess.TimeoutExpired, OSError, json.JSONDecodeError) as error:
        print("Morning batch stopped: " + str(error), file=sys.stderr)
        raise SystemExit(1)
