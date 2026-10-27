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
    add("ck-person", "CK-F13", samples=3)
    add("ck-dnd-unknown", "F09", ["--provider", "callkit", "--focus-mode", "dnd",
                                    "--unknown-caller", "--caller-value", unknown], samples=3)
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
    add("callkit-dnd-answer", "F09", ["--provider", "callkit", "--focus-mode", "dnd",
                                       "--unknown-caller", "--caller-value", unknown, "--server-answer"], 3)
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
    print(json.dumps({"preflight": preflight, "signing": "xcodegen; xcodebuild build-for-testing -allowProvisioningUpdates with signed-in Xcode account and team " + TEAM,
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


def command(argv, env, log, timeout, should_pause=None):
    with log.open("ab") as stream:
        if should_pause is None:
            result = subprocess.run(argv, stdout=stream, stderr=subprocess.STDOUT, env=env, timeout=timeout)
        else:
            process = subprocess.Popen(argv, stdout=stream, stderr=subprocess.STDOUT, env=env, start_new_session=True)
            deadline = time.monotonic() + timeout
            try:
                while process.poll() is None:
                    if should_pause():
                        raise BatchPaused("Phone priority or PAUSE requested")
                    if time.monotonic() >= deadline:
                        raise subprocess.TimeoutExpired(argv, timeout)
                    time.sleep(1)
                result = process
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait(timeout=10)
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
    lock_dir = Path.home() / ".device-locks"
    if phone_wants_device(work, lock_dir, device):
        raise BatchPaused("PAUSE or Phone priority marker exists; no device action taken")
    lock = DeviceLock(lock_dir, device)
    lock.acquire()
    checkpoint = work / "morning-checkpoint.json"
    # Row execution needs APNs credentials. The runner only forwards them to the sender.
    env = os.environ.copy()
    env["FOCUS_DEVICE"], env["FOCUS_WORK"] = device, str(work)
    state = None
    dirty = checkpoint.exists()  # Unknown state is unsafe until a valid checkpoint proves it clean.
    verified = False
    stopped = False
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
        command([str(RUNNER), "preflight"], env, work / "preflight.log", 660, pause_requested)
        verified = True
        if dirty:
            # Previous crash: restore first, then account for the ambiguous attempt without retry.
            command([str(RUNNER), "restore-all"], env, work / "batch-restore.log", 660)
            mark_restored()
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
                result_name = payload.get("result")
                if not isinstance(result_name, str):
                    raise RuntimeError("failed row has no verifiable restoration result")
                result_path = Path(result_name).resolve()
                if not result_path.is_relative_to(work):
                    raise RuntimeError("failed row result is outside the private work directory")
                row_result = json.loads(result_path.read_text())
                if (row_result.get("row") != item["row"] or row_result.get("status") != status
                        or row_result.get("restored") not in [True, "focus-off"]
                        or status in ["recorded", "restored", "restore-failed-use-restore-all"]):
                    raise RuntimeError("failed row restoration is not verified")
                state["completed"][item["id"]] = {"status": "unqualified", "reason": status, "result": result_name}
            elif status in ["recorded", "skipped-dependency-or-unsupported"]:
                state["completed"][item["id"]] = {"status": status, "result": payload.get("result")}
            else:
                raise RuntimeError("row did not finish with a recorded result or explicit skip")
            state["inFlight"] = None
            atomic_json(checkpoint, state)
        return 75 if pause_requested() else 0
    except BatchPaused:
        return 75
    finally:
        failure = None
        if dirty:
            if verified and state is not None and env.get("FOCUS_XCTESTRUN"):
                try:
                    command([str(RUNNER), "restore-all"], env, work / "batch-restore.log", 660)
                    mark_restored()
                except (RuntimeError, subprocess.TimeoutExpired, OSError) as error:
                    failure = error
            else:
                failure = RuntimeError("restore required but Share Across Devices OFF could not be verified")
        if not dirty:
            lock.release()
        for signum, handler in old_handlers.items():
            signal.signal(signum, handler)
        if failure:
            print("Restoration incomplete; device lock retained for recovery", file=sys.stderr)
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
