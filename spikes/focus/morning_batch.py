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
from work_path import (default_work, legacy_dir, legacy_hashes, legacy_snapshot, LEGACY_FILES,
                       validate_clean_journal, journal_restore_binding, LEGACY_RECEIPT, LEGACY_RESTORE_RECEIPT)

HERE = Path(__file__).resolve().parent
RUNNER = HERE / "run.sh"
DEFAULT_UNKNOWN = "+15555550200"
TEAM = "85A9MS6428"


def make_plan(unknown, quiet=False):
    """Give every sample a stable identity, so an interrupted attempt is never replayed."""
    if not re.fullmatch(r"\+[1-9][0-9]{7,14}", unknown) or unknown == "+15555550199":
        raise ValueError("unknown caller must be a different E.164 test handle")
    out = []

    def add(label, row, args=(), samples=1):
        for sample in range(1, samples + 1):
            skip = quiet and (row == "L15" or label == "microphone-positive")
            arguments = [*args, "--keep-setup"]
            if quiet:
                arguments = [arg for arg in arguments if arg != "--listen"] + ["--quiet"]
            item = {"id": f"{label}-{sample:02}", "row": row, "args": arguments, "sample": sample}
            if skip:
                item["skip"] = "skipped: quiet"
            out.append(item)

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
    for index in range(1, 7):
        focus = "on" if index % 2 == 0 else "off"
        add(f"activity-{index:02}-{focus}", f"L{index:02}", ["--activity-focus", focus])
    for index in range(7, 16):
        for focus in ["off", "on"]:
            add(f"activity-{index:02}-{focus}", f"L{index:02}", ["--activity-focus", focus])
    # The iPhone 13 has no Dynamic Island; record a hardware N/A once.
    add("activity-16", "L16")
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


def dry_run(plan, unknown, quiet=False):
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
                      "microphonePreflight": "skipped: quiet" if quiet else "compile listener and request authorization once (bounded 30 seconds, no recording)",
                      "quiet": "capture and durably back up ringtone volume before setting minimum; restore on exit" if quiet else False,
                      "deviceLock": "~/.device-locks/<FOCUS_DEVICE>.lock; no stealing; Phone priority"}))
    for item in plan:
        if item.get("skip"):
            print(json.dumps({"id": item["id"], "row": item["row"], "sample": item["sample"], "status": item["skip"]}, separators=(",", ":")))
            continue
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


def private_row_result(work, item, payload, *, require_restored=True, prior_entries=None):
    result_name = payload.get("result")
    if not isinstance(result_name, str):
        raise RuntimeError("row has no verifiable private result")
    result_path = Path(result_name).resolve()
    if not result_path.is_relative_to(work):
        raise RuntimeError("row result is outside the private work directory")
    if prior_entries is not None and result_path.relative_to(work).parts[0] in prior_entries:
        raise RuntimeError("row result does not belong to the current attempt")
    result = json.loads(result_path.read_text())
    if (result.get("row") != item["row"] or result.get("status") != payload.get("status")
            or (require_restored and result.get("restored") not in [True, "focus-off"])):
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
        coverage = result.get("coverage")
        summary["activityCoverage"] = "structured" if isinstance(coverage, dict) else (
            "single transport/presentation subcase" if coverage else "unqualified")
    return summary


def _read_private_json(path, work, parent=None):
    """Do not follow row-provided paths outside the private work tree."""
    if not isinstance(path, str) or not Path(path).is_absolute():
        return None, None
    try:
        target = Path(path).resolve()
        if not target.is_relative_to(work) or (parent is not None and target.parent != parent):
            return None, None
        if target.stat().st_size > 2_000_000:
            return None, None
        value = json.loads(target.read_text())
        return (target, value) if isinstance(value, dict) else (None, None)
    except (OSError, ValueError, RuntimeError):
        return None, None


def postclassify_activity_audio(work, state, plan):
    """Use only this batch's final positive C00; never infer alert or silence."""
    from activity_acoustics import classify_activity_audio

    work = Path(work).resolve()
    completed = state.get("completed", {})
    if not isinstance(completed, dict):
        raise ValueError("invalid batch checkpoint")
    positive = completed.get("microphone-positive-01", {})
    if not isinstance(positive, dict):
        positive = {}
    _, c00 = _read_private_json(positive.get("result"), work)
    _, calibration = _read_private_json(str(work / "audio-calibration.json"), work)
    c00_audio = c00.get("audio") if isinstance(c00, dict) else None
    keys = ("calibrationValid", "binding", "threshold", "quietP95", "signalP95", "createdAt")
    # A stale file from another C00 must not be used when this final control failed.
    if (positive.get("status") != "recorded" or not isinstance(c00, dict) or c00.get("row") != "C00"
            or c00.get("status") != "recorded" or c00.get("restored") not in [True, "focus-off"]
            or not isinstance(c00_audio, dict) or not isinstance(calibration, dict)
            or any(key not in c00_audio or c00_audio.get(key) != calibration.get(key) for key in keys)):
        calibration = {}

    for item in plan:
        if item.get("row") not in ["L01", "L02", "L15"] or item.get("id") not in completed:
            continue
        entry = completed[item["id"]]
        if not isinstance(entry, dict):
            raise ValueError("invalid completed row checkpoint")
        result_path, result = _read_private_json(entry.get("result"), work)
        window = result.get("activityAudioWindow") if isinstance(result, dict) else None
        audio_path = result.get("activityAudio") if isinstance(result, dict) else None
        _, envelope = _read_private_json(audio_path, work, parent=result_path.parent if result_path else None)
        args = item.get("args", [])
        def option(name, default):
            return args[args.index(name) + 1] if name in args and args.index(name) + 1 < len(args) else default
        expected = {"device": state.get("device"), "build": state.get("buildHash"),
                    "provider": option("--provider", "lck"), "callerFormat": option("--caller-format", "e164")}
        valid_binding = (isinstance(expected["device"], str) and DEVICE_ID_PATTERN.fullmatch(expected["device"])
                         and isinstance(expected["build"], str) and re.fullmatch(r"[0-9a-f]{64}", expected["build"]))
        if (not valid_binding or not isinstance(result, dict) or result.get("row") != item["row"]
                or result.get("restored") not in [True, "focus-off"]):
            envelope = None
        acoustic = classify_activity_audio(envelope, calibration, expected_binding=expected,
                                           window_start=window.get("start") if isinstance(window, dict) else None,
                                           window_end=window.get("end") if isinstance(window, dict) else None)
        if result_path is not None and isinstance(result, dict) and result.get("row") == item["row"]:
            result["activityAcoustic"] = acoustic
            atomic_json(result_path, result)
        entry["activityAcoustic"] = {key: acoustic[key] for key in ("status", "energyAboveThreshold", "reason") if key in acoustic}


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


def archive_legacy():
    """Explicit host-only handoff after restoration; leave original paths intact."""
    legacy = legacy_dir()
    # A successful restore may uninstall the disposable probe and remove its
    # journal. With no legacy state left, the persistent default is already usable.
    if not any((legacy / name).exists() or (legacy / name).is_symlink() for name in LEGACY_FILES):
        return None
    state, _ = legacy_snapshot(legacy)
    lock = DeviceLock(Path.home() / ".device-locks", state["device"])
    lock.acquire()
    try:
        state, contents = legacy_snapshot(legacy)
        if state["device"] != lock.path.name.removesuffix(".lock"):
            raise RuntimeError("legacy checkpoint device changed")
        archive_name = uuid.uuid4().hex
        archive_root = legacy / "legacy-archives"
        archive_root.mkdir(mode=0o700, exist_ok=True)
        if archive_root.is_symlink() or not archive_root.is_dir():
            raise RuntimeError("legacy archive directory is invalid")
        archive = archive_root / archive_name
        archive.mkdir(mode=0o700, exist_ok=False)
        for name, data in contents.items():
            if data is None:
                continue
            with (archive / name).open("xb") as stream:
                os.chmod(archive / name, 0o600)
                stream.write(data); stream.flush(); os.fsync(stream.fileno())
        fd = os.open(archive, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
        _, after = legacy_snapshot(legacy)
        if after != contents:
            raise RuntimeError("legacy state changed while archiving")
        atomic_json(legacy / LEGACY_RECEIPT, {"version": 1, "device": state["device"],
                                               "archive": archive_name, "files": legacy_hashes(contents)})
        fd = os.open(legacy, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
        return archive
    finally:
        lock.release()


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
        # A parent can exit successfully or unsuccessfully while descendants
        # remain. Never restore or release the device lock until the entire
        # command group is gone.
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


def set_supervisor_env(env, lock):
    """Bind a child row to this batch's live lock and process-group supervisor."""
    env["FOCUS_BATCH_OWNER_PID"] = str(os.getpid())
    env["FOCUS_BATCH_LOCK_NONCE"] = lock.nonce


def supervised_restore():
    """Run direct restore-all under a lock-owning, bounded group supervisor."""
    device = os.environ.get("FOCUS_DEVICE")
    source = Path(os.environ.get("FOCUS_XCTESTRUN", "/nonexistent"))
    if not device or not source.is_file():
        raise ValueError("Recovery needs the iPhone 13 UDID and original signed FOCUS_XCTESTRUN")
    os.umask(0o077)
    work = (Path(os.environ["FOCUS_WORK"]) if "FOCUS_WORK" in os.environ else default_work()).resolve()
    repo = HERE.parents[1]
    if work.is_relative_to(repo) and work != HERE / "out":
        raise ValueError("Use ignored spikes/focus/out or a private path outside the repository")
    work.mkdir(mode=0o700, parents=True, exist_ok=True)
    work.chmod(0o700)
    device = identify_iphone13(device, work)
    lock_dir = Path.home() / ".device-locks"
    if phone_wants_device(work, lock_dir, device):
        raise RuntimeError("Phone priority or PAUSE marker exists; no recovery action taken")
    lock = DeviceLock(lock_dir, device)
    lock.acquire()
    env = os.environ.copy()
    env["FOCUS_DEVICE"], env["FOCUS_WORK"], env["FOCUS_XCTESTRUN"] = device, str(work), str(source)
    env["FOCUS_REQUIRE_DEVICE_JOURNAL"] = "1"
    set_supervisor_env(env, lock)
    restored = False
    try:
        checkpoint = work / "morning-checkpoint.json"
        state = None
        if checkpoint.exists():
            state = json.loads(checkpoint.read_text())
            if (not isinstance(state, dict) or state.get("device") != device
                    or not isinstance(state.get("completed"), dict)
                    or state.get("buildHash") != hashlib.sha256(source.read_bytes()).hexdigest()):
                raise RuntimeError("checkpoint device or signed build mismatch; retain lock for review")
        command([str(RUNNER), "preflight"], env, work / "recovery-preflight.log", 660)
        command([str(RUNNER), "restore-all"], env, work / "recovery-restore.log", 660)
        if state is not None:
            interrupted = state.get("inFlight")
            if interrupted:
                state["completed"][interrupted] = {"status": "unqualified-interrupted", "result": None}
            state["inFlight"] = None
            state.pop("inFlightAttempt", None)
            state["dirty"] = False
            atomic_json(checkpoint, state)
        elif work == legacy_dir().resolve():
            # A journal-only legacy run has no device identity of its own.
            # Bind its verified clean bytes to the actually restored device
            # while still holding the same device lock.
            journal = work / "restore-state.json"
            if journal.is_symlink():
                raise RuntimeError("legacy journal cannot be a symlink")
            if journal.exists():
                content = journal.read_bytes()
                validate_clean_journal(content)
                if journal.read_bytes() != content:
                    raise RuntimeError("legacy journal changed after restoration")
                journal_hash = hashlib.sha256(content).hexdigest()
                atomic_json(work / LEGACY_RESTORE_RECEIPT,
                            {"version": 1, "device": device, "journalHash": journal_hash,
                             "binding": journal_restore_binding(device, journal_hash)})
                fd = os.open(work, os.O_RDONLY)
                try:
                    os.fsync(fd)
                finally:
                    os.close(fd)
        restored = True
    finally:
        if restored:
            lock.release()
        else:
            print("Recovery incomplete; device lock retained", file=sys.stderr)


def run_batch(plan, args):
    quiet = getattr(args, "quiet", False)
    device = os.environ.get("FOCUS_DEVICE")
    if not device:
        raise ValueError("FOCUS_DEVICE is required; no device selected automatically")
    os.umask(0o077)
    work = (Path(os.environ["FOCUS_WORK"]) if "FOCUS_WORK" in os.environ else default_work()).resolve()
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
    set_supervisor_env(env, lock)
    state = None
    dirty = checkpoint.exists()  # Unknown state is unsafe until a valid checkpoint proves it clean.
    verified = False
    stopped = False
    unsafe_processes = False
    recovery_failed = False
    quiet_applied = False
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
        state.pop("inFlightAttempt", None)
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
        if state.get("planHash") != checkpoint_id(plan):
            # A mode change may resume the same fixed matrix after recovering
            # the old journal; completed and interrupted attempts are never replayed.
            unknown = getattr(args, "unknown_caller", DEFAULT_UNKNOWN)
            old_mode = not quiet
            if state.get("planHash") != checkpoint_id(make_plan(unknown, quiet=old_mode)):
                raise RuntimeError("checkpoint plan changed; previous settings were restored, use the original plan")
            state["planHash"] = checkpoint_id(plan)
            state["modeChange"] = "quiet" if quiet else "normal"
            if not quiet:
                # Rows explicitly skipped in quiet mode have never been
                # attempted. Requeue only those, never interrupted or real rows.
                for item in plan:
                    prior = state["completed"].get(item["id"])
                    if isinstance(prior, dict) and prior.get("status") == "skipped: quiet":
                        del state["completed"][item["id"]]
            atomic_json(checkpoint, state)
        if pause_requested():
            raise BatchPaused("Phone priority or PAUSE requested")
        state["microphoneAuthorization"] = "skipped: quiet" if quiet else authorize_microphone(work, pause_requested)
        atomic_json(checkpoint, state)
        if not quiet and state["microphoneAuthorization"] != "authorized":
            print("mic permission pending or unavailable; continuing with visual evidence only", flush=True)
        for item in plan:
            if item["id"] in state["completed"]:
                continue
            if pause_requested():
                stopped = True
                break
            if item.get("skip") == "skipped: quiet":
                state["completed"][item["id"]] = {"status": "skipped: quiet", "result": None}
                atomic_json(checkpoint, state)
                print("Skipped", item["id"], "quiet", flush=True)
                continue
            if quiet and not quiet_applied:
                # Persist dirty before capture or mutation; recovery must run if
                # either UI session is interrupted. The runner backs up the
                # capture before starting the separate minimum-volume session.
                state["dirty"] = True
                atomic_json(checkpoint, state)
                dirty = True
                command([str(RUNNER), "preflight", "--quiet"], env, work / "quiet-setup.log", 660, pause_requested)
                quiet_applied = True
                if pause_requested():
                    stopped = True
                    break
            # Persist the attempt before a push can occur. Never replay an interrupted attempt.
            state["dirty"] = True
            state["inFlight"] = item["id"]
            attempt = uuid.uuid4().hex
            state["inFlightAttempt"] = attempt
            atomic_json(checkpoint, state)
            dirty = True
            print("Running", item["id"], flush=True)
            log = work / ("batch-" + item["id"] + "-" + attempt + ".log")
            # Each process gets an exclusive log and must create a new result
            # directory. Neither stale output nor an old result can certify this attempt.
            log.touch(mode=0o600, exist_ok=False)
            prior_entries = {entry.name for entry in work.iterdir()}
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
                if status == "restore-failed-use-restore-all":
                    # command() has already terminated and verified the entire failed
                    # row process group. Recover the newer device journal before
                    # continuing; never replay a possibly delivered invitation.
                    result_name, row_result = private_row_result(work, item, payload, require_restored=False, prior_entries=prior_entries)
                    if row_result.get("restored") is not False:
                        raise RuntimeError("failed row did not report a pending restoration")
                    env["FOCUS_REQUIRE_DEVICE_JOURNAL"] = "1"
                    try:
                        command([str(RUNNER), "restore-all"], env, work / "batch-restore.log", 660)
                    except (RuntimeError, subprocess.TimeoutExpired, OSError) as error:
                        # Do not try a second recovery in finally; retain the lock.
                        recovery_failed = True
                        raise RuntimeError("interrupted row restoration failed") from error
                    state["completed"][item["id"]] = {"status": "unqualified", "reason": status, "result": result_name,
                                                       **result_summary(item, row_result)}
                    state["completed"][item["id"]]["attempt"] = attempt
                    state["completed"][item["id"]]["log"] = str(log)
                    state["inFlight"] = None
                    state.pop("inFlightAttempt", None)
                    mark_restored()
                    quiet_applied = False
                    env.pop("FOCUS_REQUIRE_DEVICE_JOURNAL", None)
                    continue
                result_name, row_result = private_row_result(work, item, payload, prior_entries=prior_entries)
                if status in ["recorded", "restored"]:
                    raise RuntimeError("failed row restoration is not verified")
                state["completed"][item["id"]] = {"status": "unqualified", "reason": status, "result": result_name,
                                                    **result_summary(item, row_result)}
            elif status in ["recorded", "unqualified"]:
                result_name, row_result = private_row_result(work, item, payload, prior_entries=prior_entries)
                state["completed"][item["id"]] = {"status": status, "result": result_name, **result_summary(item, row_result)}
            elif status == "not-applicable-hardware" and item["row"] == "L16":
                result_name, row_result = private_row_result(work, item, payload, prior_entries=prior_entries)
                state["completed"][item["id"]] = {"status": status, "result": result_name, **result_summary(item, row_result)}
            elif status == "skipped-dependency-or-unsupported" and not re.fullmatch(r"L[0-9]{2}", item["row"]):
                state["completed"][item["id"]] = {"status": status, "result": None}
            else:
                raise RuntimeError("row did not finish with a recorded result or explicit skip")
            state["completed"][item["id"]]["attempt"] = attempt
            state["completed"][item["id"]]["log"] = str(log)
            state["inFlight"] = None
            state.pop("inFlightAttempt", None)
            atomic_json(checkpoint, state)
        if not quiet and "microphone-positive-01" in state["completed"]:
            # C00 is deliberately last; only now can earlier RMS envelopes be compared.
            postclassify_activity_audio(work, state, plan)
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
        elif recovery_failed:
            failure = RuntimeError("interrupted row restoration failed")
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
    parser.add_argument("--quiet", action="store_true", help="minimize ringtone volume and skip acoustic/vibration tests")
    parser.add_argument("--archive-legacy", action="store_true", help="archive restored checkout-local state and enable the persistent default")
    parser.add_argument("--unknown-caller", default=DEFAULT_UNKNOWN,
                        help="synthetic owned E.164 test caller absent from the iPhone contacts")
    args = parser.parse_args()
    if args.archive_legacy:
        if args.quiet or args.dry_run:
            raise ValueError("--archive-legacy cannot be combined with --quiet or --dry-run")
        archive = archive_legacy()
        print("Archived restored legacy state: " + str(archive) if archive else "No legacy state remains; persistent default is ready")
        return 0
    plan = make_plan(args.unknown_caller, quiet=args.quiet)
    if args.dry_run:
        dry_run(plan, args.unknown_caller, quiet=args.quiet)
        return 0
    return run_batch(plan, args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, RuntimeError, subprocess.TimeoutExpired, OSError, json.JSONDecodeError) as error:
        print("Morning batch stopped: " + str(error), file=sys.stderr)
        raise SystemExit(1)
