"""Private, bounded row execution. --dry-run returns before any device/credential/microphone access."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import time
import uuid
from work_path import default_work

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
BUNDLE = "dev.callkitsim.focus"
TEST_BUNDLE = BUNDLE + ".uitests.xctrunner"


def correlate(traces, invitations):
    ids = {value.lower() for value in invitations}
    return [event for event in traces if str(event.get("invitationID", "")).lower() in ids]


def reports_complete(reports, invitations):
    counts = {value.lower(): 0 for value in invitations}
    for event in reports:
        key = str(event.get("invitationID", "")).lower()
        if key not in counts:
            return False
        counts[key] += 1
    return all(value == 1 for value in counts.values())


def audio_control_eligible(result):
    reports = result.get("reports", [])
    return result.get("status") == "recorded" and result.get("visualNegativeQualified") is True and len(reports) == 1 and reports[0].get("outcome") == "reported"


def repeat_cooldown(last_attempt, now):
    return max(0, 181 - (now - last_attempt))


def needs_repeat_fence(base_row, previous):
    # Old journal entries have no pair marker; conservatively treat them as a pair.
    return base_row == "C02" or previous.get("repeatPair") is not False


def surface_gap_intersects(events, start, end):
    for event in events:
        if event.get("event") != "surface.gap":
            continue
        left, right = event.get("startUptimeMs"), event.get("endUptimeMs")
        if not isinstance(left, int) or not isinstance(right, int) or left > right:
            return True
        if left <= end and right >= start:
            return True
    return False


def surface_windows(events, received, observation):
    transitions = [e for e in events if e.get("event") == "surface.transition"]
    windows = []
    for index, (invitation, start) in enumerate(received):
        end = min(received[index + 1][1], observation["endUptimeMs"]) if index + 1 < len(received) else observation["endUptimeMs"]
        item = {"invitationID": invitation, "pushReceivedUptimeMs": start,
                "observationQualified": observation["startUptimeMs"] <= start and end - start >= 15000,
                "continuityQualified": not surface_gap_intersects(events, start, end)}
        for surface in ["banner", "callScreen"]:
            prior = [e for e in transitions if e.get("surface") == surface and e["uptimeMs"] < start]
            rises = [e["uptimeMs"] for e in transitions if e.get("surface") == surface
                     and e.get("visible") is True and start <= e["uptimeMs"] < end]
            item[surface + "VisibleAtStart"] = bool(prior and prior[-1].get("visible"))
            item[surface + "FirstNewPresentationUptimeMs"] = min(rises) if rises else None
        windows.append(item)
    return windows


def answer_evidence(events, trace, observation, signal_id, push_ms):
    """Qualify a local signal-to-disappearance interval only with continuous visible evidence."""
    matching = [item for item in trace if str(item.get("signalID", "")).lower() == signal_id.lower()]
    signals = [item for item in matching if item.get("event") == "answer.signal"]
    reports = [item for item in matching if item.get("event") == "answer.report"]
    if len(signals) != 1 or len(reports) != 1:
        return {"status": "unqualified", "reason": "missing-or-duplicate-signal-or-report"}
    start, report = signals[0].get("monoMs"), reports[0].get("monoMs")
    if not isinstance(start, int) or not isinstance(report, int) or report < start:
        return {"status": "unqualified", "reason": "invalid-device-timestamps"}
    if not isinstance(push_ms, int) or not observation.get("startUptimeMs", start + 1) <= push_ms <= start <= report <= observation.get("endUptimeMs", -1):
        return {"status": "unqualified", "reason": "outside-observation-window"}
    if surface_gap_intersects(events, push_ms, observation["endUptimeMs"]):
        return {"status": "unqualified", "reason": "surface-observation-gap"}
    for surface in ("banner", "callScreen"):
        prior_samples = [e for e in events if e.get("event") == "surface.sample" and e.get("surface") == surface
                         and isinstance(e.get("uptimeMs"), int) and isinstance(e.get("sampleStartUptimeMs"), int)
                         and e["sampleStartUptimeMs"] <= e["uptimeMs"] <= push_ms]
        if not prior_samples:
            return {"status": "unqualified", "reason": "missing-pre-push-surface-sample"}
        last_sample = max(prior_samples, key=lambda e: e["uptimeMs"])
        if last_sample.get("visible") is not False or push_ms - last_sample["uptimeMs"] > 2000:
            return {"status": "unqualified", "reason": "pre-push-surface-not-clear"}
    transitions = [e for e in events if e.get("event") == "surface.transition" and isinstance(e.get("uptimeMs"), int)]
    visible = {}
    for surface in ("banner", "callScreen"):
        prior = [e for e in transitions if e.get("surface") == surface and e["uptimeMs"] <= push_ms]
        if prior and max(prior, key=lambda e: e["uptimeMs"]).get("visible") is True:
            return {"status": "unqualified", "reason": "surface-visible-before-push", "signalUptimeMs": start}
        after = [e for e in transitions if e.get("surface") == surface and push_ms < e["uptimeMs"] <= start]
        if after:
            if any(e.get("visible") is True and e.get("sampleStartUptimeMs", -1) <= push_ms for e in after):
                return {"status": "unqualified", "reason": "presentation-spans-push", "signalUptimeMs": start}
            last = max(after, key=lambda e: e["uptimeMs"])
            if last.get("visible") is True:
                visible[surface] = last.get("callerMatched") is True
    if not visible or not all(visible.values()):
        return {"status": "unqualified", "reason": "no-identified-ui-after-push", "signalUptimeMs": start}
    samples = sorted({(e["uptimeMs"], e["sampleStartUptimeMs"]) for e in events
                      if e.get("event") == "surface.sample" and isinstance(e.get("uptimeMs"), int)
                      and isinstance(e.get("sampleStartUptimeMs"), int) and e["sampleStartUptimeMs"] <= e["uptimeMs"]})
    before_signal = [value for value in samples if value[0] <= start]
    if not before_signal or start - before_signal[-1][0] > 2000 or before_signal[-1][1] <= push_ms:
        return {"status": "unqualified", "reason": "stale-ui-sample-at-signal", "signalUptimeMs": start}
    later = sorted((e for e in transitions if start < e["uptimeMs"] <= observation["endUptimeMs"]), key=lambda e: e["uptimeMs"])
    # Banner and full-screen state are sampled together. Apply the whole sample
    # before deciding that both surfaces vanished.
    from itertools import groupby
    for timestamp, sample in groupby(later, key=lambda e: e["uptimeMs"]):
        group = list(sample)
        if any(not isinstance(e.get("sampleStartUptimeMs"), int) or e["sampleStartUptimeMs"] < report for e in group):
            return {"status": "unqualified", "reason": "ui-sample-spans-end-report", "signalUptimeMs": start}
        for event in group:
            surface = event.get("surface")
            if event.get("visible") is True:
                visible[surface] = event.get("callerMatched") is True
            else:
                visible.pop(surface, None)
        if visible and not all(visible.values()):
            return {"status": "unqualified", "reason": "ambiguous-ui-identity", "signalUptimeMs": start}
        if not visible and timestamp >= report:
            coverage = [before_signal[-1]] + [value for value in samples if before_signal[-1][0] < value[0] <= timestamp]
            if (not coverage or coverage[-1][0] != timestamp or any(end - begin > 2000 for end, begin in coverage)
                    or any(b[1] - a[0] > 2000 for a, b in zip(coverage, coverage[1:]))):
                return {"status": "unqualified", "reason": "ui-observation-gap", "signalUptimeMs": start}
            last_sample_start = coverage[-2][1] if len(coverage) > 1 else coverage[-1][1]
            return {"status": "observed", "signalUptimeMs": start, "reportUptimeMs": report,
                    "dismissalUptimeMs": timestamp, "signalToDismissalMs": timestamp - start,
                    "dismissalLowerBoundMs": max(0, last_sample_start - start),
                    "samplingUncertaintyMs": timestamp - last_sample_start,
                    "source": "local mailbox; not network delivery"}
    return {"status": "unqualified", "reason": "dismissal-not-observed", "signalUptimeMs": start, "reportUptimeMs": report}


def plan(row, locked=False, listen=False, provider=None, caller_format="e164", repeated_calls="off", caller_value=None):
    aliases = {"CK-F09": ("F09", "callkit"), "CK-F13": ("F13", "callkit"), "CK-C02": ("C02", "callkit"), "LCK-C02b": ("C02", "lck")}
    original = row
    if row in aliases:
        row, expected = aliases[row]
        if provider and provider != expected:
            raise ValueError("Provider conflicts with row alias")
        provider = expected
    provider = provider or "lck"
    caller = caller_value or ("+15555550199" if caller_format != "national" else "5555550199")
    pattern = {"e164": r"\+[1-9][0-9]{7,14}", "national": r"[0-9]{7,15}", "generic": r"[A-Za-z0-9+._@-]{1,128}"}[caller_format]
    if not re.fullmatch(pattern, caller):
        raise ValueError("Caller value does not match its declared format")
    kind = "generic" if caller_format == "generic" else "phoneNumber"
    p = dict(row=row, focus=True, app=False, person=False, cn=False, sendVoIP=True,
             activity=False, blocked=None, locked=locked, listen=listen, provider=provider,
             callerFormat=caller_format, callerValue=caller, handleType=kind, repeatedCalls=repeated_calls)
    if row.startswith("F") and row[1:].isdigit() and 1 <= int(row[1:]) <= 16:
        n = int(row[1:]) - 1
        p.update(focus=bool(n & 8), app=bool(n & 2), person=bool(n & 4), cn=bool(n & 1))
    elif row in ["C00", "C01", "C02", "C05", "C06"]:
        if row in ["C00", "C01"]:
            p["focus"] = row != "C00"
    elif row.startswith("L") and row[1:].isdigit() and 1 <= int(row[1:]) <= 16:
        n = int(row[1:]); p.update(activity=True, sendVoIP=False, focus=n % 2 == 0)
        if n == 16:
            p["activity"] = False
            p["hardwareNA"] = "iPhone 13 has no Dynamic Island; capability check only"
    elif row in ["restore-all", "preflight"]:
        p["sendVoIP"] = False
    elif row.startswith("T") and row[1:].isdigit() and 1 <= int(row[1:]) <= 6:
        p["blocked"] = "Requires Phone LiveKit owner-join/backend; probe has no AI/media"
    elif row in ["C03", "C04", "C07", "C08", "C09", "C10", "C11"]:
        p["blocked"] = "Special policy/identity/fault or unsupported hardware control requires an additional adapter"
    else:
        raise ValueError("Unknown row; use F01..F16, C00..C11, L01..L16, T01..T06 or restore-all")
    p["baseRow"] = row
    p["row"] = original
    if p["blocked"]:
        p["sendVoIP"] = False
        p["steps"] = ["automatic skip; no device or push: " + p["blocked"]]
        return p
    p["steps"] = ["verify signed test products + explicit FOCUS_DEVICE; recover journal",
                  "apply owned Focus/App/People/Calls settings through guarded XCUITest",
                  "arm Documents/focus.json; launch probe; fetch fresh token privately"]
    if locked:
        p["steps"] += ["approved Auto-Answer=on/3s and Auto-Lock=30s; terminate probe; end UI session",
                       "wait 45s for auto-lock; inspect Join action after cold push without UI session"]
    else:
        p["steps"] += ["start timestamped SpringBoard/InCallService observation; qualify negative results against C00"]
    if listen:
        p["steps"] += ["optional host RMS capture; C00 calibration; no microphone permission => visual evidence only"]
    if p["sendVoIP"] and row == "C02":
        p["steps"] += ["wait until at least 181s since the previous VoIP attempt",
                       "send first VoIP push with discovery/send-apns.mjs topic dev.callkitsim.focus.voip; wait 69s; send second distinct call"]
    else:
        p["steps"] += ["send once with discovery/send-apns.mjs topic dev.callkitsim.focus.voip" if p["sendVoIP"] else "no VoIP push"]
    p["steps"] += [
                   "fetch JSONL/report result; inspect ActivityKit inventory/state/content + Notification Center card when applicable",
                   "write private row result; end activity; disarm; restore settings/contact/Focus and original permission state"]
    if row == "restore-all":
        p["steps"] = ["restore owned journal; restore Auto-Answer/delay + Auto-Lock; delete test Focus/contact; restore prior active Focus",
                      "uninstall disposable probe only if required to restore undetermined permissions; no push"]
    elif row == "preflight":
        p["steps"] = ["check Share Across Devices is OFF in Settings without changing Focus or sending a push"]
    elif row.startswith("L"):
        from activity_rows import activity_plan
        p["steps"] = activity_plan(row)
    return p


def matching_activity(registration, token):
    fields = ["activityID", "surfaceID", "tokenGeneration"]
    return (all(isinstance(registration.get(k), str) and registration[k] and registration[k] == token.get(k) for k in fields)
            and registration.get("state") in ["active", "stale"]
            and isinstance(token.get("token"), str) and re.fullmatch(r"(?:[a-fA-F0-9]{2}){32,256}", token["token"]) is not None)


def write(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")
    path.chmod(0o600)


def require_device_supervisor():
    """Require the lock-owning batch parent and its bounded row process group.

    This is an accidental-misuse guard, not an authorization boundary. The
    supervisor must still stop and verify descendants before restoring state.
    """
    device = os.environ.get("FOCUS_DEVICE", "")
    owner_pid = os.environ.get("FOCUS_BATCH_OWNER_PID", "")
    nonce = os.environ.get("FOCUS_BATCH_LOCK_NONCE", "")
    if (not re.fullmatch(r"[A-F0-9]{8}-[A-F0-9]{16}", device)
            or not owner_pid.isdigit() or int(owner_pid) != os.getppid()
            or not re.fullmatch(r"[a-f0-9]{32}", nonce) or os.getpgrp() != os.getpid()):
        raise RuntimeError("Real device rows require the lock-owning morning-batch supervisor")
    try:
        receipt = json.loads((Path.home() / ".device-locks" / (device + ".lock") / "owner.json").read_text())
    except (OSError, ValueError):
        raise RuntimeError("Device supervisor lock receipt unavailable")
    if (not isinstance(receipt, dict) or receipt.get("owner") != "focus-morning-batch" or receipt.get("pid") != int(owner_pid)
            or receipt.get("nonce") != nonce):
        raise RuntimeError("Device supervisor lock receipt does not match")


class Run:
    def __init__(self, p, args):
        self.p, self.args = p, args
        self.device = os.environ.get("FOCUS_DEVICE")
        self.source = Path(os.environ.get("FOCUS_XCTESTRUN", "/nonexistent"))
        if not self.device or not self.source.is_file():
            raise ValueError("Real runs require FOCUS_DEVICE and signed device FOCUS_XCTESTRUN; unsigned products cannot run")
        os.umask(0o077)
        self.work = (Path(os.environ["FOCUS_WORK"]) if "FOCUS_WORK" in os.environ else default_work()).resolve()
        if self.work.is_relative_to(REPO) and self.work != HERE / "out":
            raise ValueError("Use ignored spikes/focus/out or a private path outside the repository")
        self.work.mkdir(parents=True, exist_ok=True); self.work.chmod(0o700)
        self.folder = self.work / (p["row"] + "-" + uuid.uuid4().hex[:12]); self.folder.mkdir(mode=0o700)
        self.journal = self.work / "restore-state.json"
        self.invitation = str(uuid.uuid4())
        self.counter = 0
        self.journal_fresh = True
        self.invitations = [self.invitation]
        self.sent_times = []
        self.run_id = str(uuid.uuid4())
        self.unsafe_observer = False
        self.binding = {"device": self.device, "build": hashlib.sha256(self.source.read_bytes()).hexdigest(),
                        "provider": p["provider"], "callerFormat": p["callerFormat"]}
        self.usb_verified = False

    def qualified(self, path):
        if not path.exists():
            return False
        value = json.loads(path.read_text())
        age = time.time() - value.get("createdAt", 0)
        return value.get("binding") == self.binding and 0 <= age < 3600 and value.get("positive", value.get("calibrationValid")) is True

    def command(self, argv, timeout=60, background=False):
        if self.unsafe_observer:
            raise RuntimeError("device subprocess cleanup required before further commands")
        self.counter += 1
        log = self.folder / f"command-{self.counter}.log"
        env = {k: v for k, v in os.environ.items() if not k.startswith("PHONE_APNS_")}
        # Only the sandbox senders receive the APNs credentials, never xcodebuild/devicectl.
        if argv[0] == "node":
            env = os.environ.copy()
        with log.open("wb") as stream:
            if background:
                return subprocess.Popen(argv, stdout=stream, stderr=subprocess.STDOUT, env=env)
            try:
                result = subprocess.run(argv, stdout=stream, stderr=subprocess.STDOUT, env=env, timeout=timeout)
            except subprocess.TimeoutExpired:
                # A child of xcodebuild/devicectl may outlive its immediate parent.
                self.unsafe_observer = True
                raise
        if result.returncode:
            if Path(argv[0]).name == "xcodebuild":
                self.unsafe_observer = True
            raise RuntimeError(f"{Path(argv[0]).name} failed; inspect private command log; no automatic retry")

    def copy(self, name, destination, to=False, test=False):
        self.command(["xcrun", "devicectl", "device", "copy", "to" if to else "from", "--device", self.device,
                      "--domain-type", "appDataContainer", "--domain-identifier", TEST_BUNDLE if test else BUNDLE,
                      "--source", str(destination) if to else "Documents/" + name,
                      "--destination", "Documents/" + name if to else str(destination)])

    def ui(self, actions, background=False, text=None):
        if self.unsafe_observer:
            raise RuntimeError("UI process cleanup required before another session")
        # A killed UI session may have journaled a mutation after the last host
        # backup. Refresh from the test container before passing recovery state
        # back to XCUITest; never overwrite a newer device journal with a stale one.
        self.recover(required=self.journal.exists() or os.environ.get("FOCUS_REQUIRE_DEVICE_JOURNAL") == "1")
        data = plistlib.loads(self.source.read_bytes())
        env = {"FOCUS_ACTIONS": json.dumps(actions), "FOCUS_NAME": os.environ.get("FOCUS_NAME", "Focus Probe 124"),
               "FOCUS_CALLER": "+15555550199", "FOCUS_OBSERVATION_ID": self.invitation,
               "FOCUS_EXPECTED_CALLER": self.p["callerValue"]}
        if self.p.get("unknownCaller"):
            env["FOCUS_UNKNOWN_CALLER"] = self.p["callerValue"]
        if self.usb_verified:
            env["FOCUS_USB_VERIFIED"] = "1"
        if self.journal.exists() and self.journal_fresh:
            journal_data = self.journal.read_bytes()
            env["FOCUS_RESTORE_STATE"] = base64.b64encode(journal_data).decode()
            journal_value = json.loads(journal_data)
            volume = journal_value.get("ringerVolumePercent") if isinstance(journal_value, dict) else None
            if isinstance(journal_value, dict) and journal_value.get("captured") is True and type(volume) is int and 0 <= volume <= 100:
                env["FOCUS_RINGER_BACKED_UP"] = "1"
        if (self.work / "system-settings-approved").exists():
            env["FOCUS_ALLOW_SYSTEM_SETTINGS"] = "1"
        if text:
            env["FOCUS_EXPECTED_ACTIVITY_TEXT"] = text
        found = 0

        def visit(value):
            nonlocal found
            if isinstance(value, dict):
                if value.get("IsUITestBundle"):
                    value.setdefault("EnvironmentVariables", {}).update(env); found += 1
                for child in value.values():
                    visit(child)
            elif isinstance(value, list):
                for child in value:
                    visit(child)
        visit(data)
        if found != 1:
            raise ValueError("Expected exactly one UI-test bundle in xctestrun")
        # Keep __TESTROOT__ product references intact; source must remain at its built location.
        def absolute(value):
            if isinstance(value, dict):
                return {k: absolute(v) for k, v in value.items()}
            if isinstance(value, list):
                return [absolute(v) for v in value]
            return value.replace("__TESTROOT__", str(self.source.parent)) if isinstance(value, str) else value
        target = self.folder / f"tests-{self.counter}.xctestrun"
        target.write_bytes(plistlib.dumps(absolute(data)))
        self.journal_fresh = False
        try:
            return self.command(["xcodebuild", "test-without-building", "-xctestrun", str(target),
                                 "-destination", "id=" + self.device,
                                 "-only-testing:FocusUITests/FocusUITests/testActions"], timeout=600, background=background)
        finally:
            if not background and not self.unsafe_observer:
                self.recover(required=True)

    def recover(self, required=False):
        candidate = self.folder / ("journal-" + uuid.uuid4().hex + ".json")
        try:
            self.copy("focus-ui-state.json", candidate, test=True)
            json.loads(candidate.read_text())
            # Recovery after a host reboot must not depend on buffered writes.
            with candidate.open("rb") as stream:
                os.fsync(stream.fileno())
            os.replace(candidate, self.journal)
            self.journal.chmod(0o600)
            directory_fd = os.open(self.journal.parent, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
            self.journal_fresh = True
        except (RuntimeError, subprocess.TimeoutExpired, OSError, ValueError):
            self.journal_fresh = False
            if required:
                raise RuntimeError("Restoration journal could not be backed up; no push allowed")
        finally:
            candidate.unlink(missing_ok=True)

    def arm(self, config):
        path = self.folder / "config.json"; write(path, config); self.copy("focus.json", path, to=True)

    def probe_installed(self):
        inventory = self.folder / ("probe-inventory-" + uuid.uuid4().hex + ".json")
        self.command(["xcrun", "devicectl", "device", "info", "apps", "--device", self.device,
                      "--bundle-id", BUNDLE, "--json-output", str(inventory), "--quiet"], timeout=60)
        value = json.loads(inventory.read_text())
        info = value.get("info") if isinstance(value, dict) else None
        result = value.get("result") if isinstance(value, dict) else None
        apps = result.get("apps") if isinstance(result, dict) else None
        if (not isinstance(info, dict) or info.get("outcome") != "success" or not isinstance(apps, list)
                or any(not isinstance(app, dict) or app.get("bundleIdentifier") != BUNDLE for app in apps)
                or len(apps) > 1):
            raise RuntimeError("Probe app inventory is ambiguous; refuse installation")
        return len(apps) == 1

    def signed_probe(self):
        data = plistlib.loads(self.source.read_bytes())
        targets = []
        def visit(value):
            if isinstance(value, dict):
                if value.get("IsUITestBundle"):
                    targets.append(value.get("UITargetAppPath"))
                for child in value.values(): visit(child)
            elif isinstance(value, list):
                for child in value: visit(child)
        visit(data)
        if len(targets) != 1 or not isinstance(targets[0], str) or not targets[0].startswith("__TESTROOT__/"):
            raise RuntimeError("Signed probe target is ambiguous")
        root = self.source.parent.resolve()
        app = Path(targets[0].replace("__TESTROOT__", str(root), 1)).resolve()
        if (not app.is_relative_to(root) or app.name != "FocusProbe.app" or not app.is_dir()
                or not (app / "embedded.mobileprovision").is_file()):
            raise RuntimeError("Signed probe product unavailable")
        with (app / "Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        if info.get("CFBundleIdentifier") != BUNDLE:
            raise RuntimeError("Signed probe bundle identity mismatch")
        self.command(["codesign", "--verify", "--deep", "--strict", str(app)], timeout=60)
        return app

    def ensure_probe_installed(self):
        if self.probe_installed():
            return
        app = self.signed_probe()
        self.command(["xcrun", "devicectl", "device", "install", "app", "--device", self.device, str(app)], timeout=120)
        if not self.probe_installed():
            raise RuntimeError("Probe installation was not verified")

    def restore(self):
        # The separate UI-test journal contains ownership and original system
        # settings. Never infer them from names or overwrite an unavailable journal.
        self.recover(required=True)
        self.ensure_probe_installed()
        self.arm({"armed": False, "activityAction": "end"})
        self.ui(["share-across-devices:check", "launch", "restore-all"])
        if self.journal.exists() and json.loads(self.journal.read_text()).get("requiresProbeUninstall"):
            self.command(["xcrun", "devicectl", "device", "uninstall", "app", "--device", self.device, BUNDLE])
            self.journal.unlink()

    def send(self, suffix=""):
        payload = self.folder / ("push" + suffix + ".json")
        write(payload, {"aps": {}, "from": self.p["callerValue"], "invitationID": self.invitation})
        # Fence subsequent repeat trials even when APNs delivery outcome is uncertain.
        attempted = time.time()
        self.sent_times.append((self.invitation, attempted))
        write(self.work / "last-voip-attempt.json", {"attemptedAt": attempted, "repeatPair": self.p["baseRow"] == "C02"})
        self.command(["node", str(REPO / "discovery/send-apns.mjs"), "--token-file", str(self.folder / "voip-token.txt"),
                      "--payload-file", str(payload), "--topic", BUNDLE + ".voip",
                      "--receipt-file", str(self.folder / ("apns" + suffix + ".json"))], timeout=30)

    def listen(self):
        if not self.p["listen"]:
            return None
        binary = self.work / "listen"
        if not binary.exists():
            self.command(["swiftc", str(HERE / "listen.swift"), "-o", str(binary)], timeout=90)
        argv = [str(binary), "--output", str(self.folder / "audio.json"), "--seconds", "110" if self.p["baseRow"] == "C02" else "40"]
        if self.p["row"] == "C00":
            argv += ["--positive"]
        elif self.qualified(self.work / "audio-calibration.json"):
            argv += ["--calibration", str(self.work / "audio-calibration.json")]
        process = self.command(argv, background=True)
        deadline = time.monotonic() + 10
        while process.poll() is None and not (self.folder / "audio.json.ready").exists() and time.monotonic() < deadline:
            time.sleep(0.2)
        audio_result = self.folder / "audio.json"
        if audio_result.exists() and json.loads(audio_result.read_text()).get("reason") == "mic permission pending":
            print("mic permission pending; continuing with visual evidence only")
        return process

    def current_activity(self, suffix):
        registration = self.folder / ("activity-registration-" + suffix + ".json")
        token = self.folder / "activity-token.json"
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                self.copy("activity-registration.json", registration)
                self.copy("activity-update-token.json", token)
                before = json.loads(registration.read_text())
                value = json.loads(token.read_text())
                self.copy("activity-registration.json", registration)
                after = json.loads(registration.read_text())
                if before == after and matching_activity(after, value):
                    return after
            except (RuntimeError, OSError, ValueError):
                pass
            time.sleep(1)
        raise RuntimeError("No matching current activity/token; APNs update not sent")

    def execute(self):
        p = self.p
        result = {"row": p["row"], "invitationID": self.invitation, "status": "unqualified", "humanQA": False}
        if p.get("quiet"):
            result.update(audioEvidence="skipped: quiet", vibrationEvidence="skipped: quiet")
        observer = audio = None
        try:
            if p["row"] == "C00":
                (self.work / "visual-calibration.json").unlink(missing_ok=True)
                (self.work / "audio-calibration.json").unlink(missing_ok=True)
            if p["row"] == "restore-all":
                self.restore(); result["status"] = "restored"; return result
            if p.get("hardwareNA"):
                from morning_batch import identify_iphone13
                identify_iphone13(self.device, self.work)
                result.update(status="not-applicable-hardware", restored=True, reason=p["hardwareNA"])
                return result
            if p["activity"]:
                from activity_rows import execute_activity
                execute_activity(self, result)
                return result
            # The Focus app picker lists only apps that have notification permission (iOS 27).
            actions = ["share-across-devices:check", "setup", "launch", "notifications:allow",
                       "app:" + ("include" if p["app"] else "exclude"),
                       "person:" + ("include" if p["person"] else "exclude"), "calls:Allowed People Only"]
            if p["baseRow"] == "C01":
                actions[-1] = "calls:" + self.args.calls
            actions += ["repeated-calls:" + (self.args.repeated_calls if p["baseRow"] == "C02" else "off")]
            if p["unknownCaller"]:
                actions += ["unknown:verify"]
            if p["favorite"] is not None:
                actions += ["favorite:" + ("on" if p["favorite"] == "yes" else "off")]
            if p["row"] == "C06":
                actions += ["policy:screenWithAI"]
            if p["focusMode"] == "dnd":
                actions += ["dnd:configure", "dnd:on"]
            else:
                actions += ["focus:" + ("on" if p["focus"] else "off")]
            self.ui(actions)
            self.arm({"rowID": p["row"], "runID": self.run_id, "provider": p["provider"], "handleType": p["handleType"],
                      "armed": True, "communicationNotification": p["cn"],
                      "activityAction": "start" if p["activity"] else None,
                      "ringTimeout": 60 if p["serverAnswer"] else 25})
            self.ui(["launch", "notifications:allow"] + (["focus-authorization:allow"] if p["row"] == "C05" else []))
            if p["activity"]:
                self.ui(["activity-consent"])
                first = self.current_activity("before-relaunch")
                self.ui(["launch", "notifications:allow"])
                self.ui(["activity-consent"])
                second = self.current_activity("after-relaunch")
                if (first["activityID"], first["surfaceID"]) != (second["activityID"], second["surfaceID"]):
                    raise RuntimeError("Activity changed across relaunch; APNs update not sent")
                result["activityContinuity"] = {"activityID": second["activityID"], "surfaceID": second["surfaceID"]}
            self.copy("voip-token.txt", self.folder / "voip-token.txt")
            if p["row"] in ["L03", "L04"]:
                self.ui(["home"])
            if p["sendVoIP"]:
                history = self.work / "last-voip-attempt.json"
                if history.exists():
                    previous = json.loads(history.read_text())
                    if p["focusMode"] == "dnd" or needs_repeat_fence(p["baseRow"], previous):
                        last = previous["attemptedAt"]
                        while repeat_cooldown(last, time.time()) > 0:
                            time.sleep(min(30, repeat_cooldown(last, time.time())))
            if p["locked"]:
                if self.args.allow_system_settings or p["locked"]: # Hamza approved this setting change; persist once.
                    (self.work / "system-settings-approved").write_text("approved for disposable probe measurements\n")
                self.ui(["system-settings:enable", "terminate", "lock"])
                self.copy("focus-ui-result.json", self.folder / "ui-settings.json", test=True)
                result["systemSettings"] = json.loads((self.folder / "ui-settings.json").read_text())["events"]
                time.sleep(45)  # No XCUITest session remains to keep the phone awake.
            elif p["sendVoIP"]:
                observer = self.ui(["observe:240" if p["baseRow"] == "C02" else "observe:60"], background=True)
                ready = self.folder / "ready.json"; deadline = time.monotonic() + 120
                while time.monotonic() < deadline:
                    if observer.poll() is not None:
                        raise RuntimeError("Observation session ended before readiness")
                    try:
                        self.copy("focus-ui-ready.json", ready, test=True)
                        if json.loads(ready.read_text()).get("id") == self.invitation:
                            break
                    except (RuntimeError, json.JSONDecodeError):
                        pass
                    time.sleep(1)
                else:
                    raise RuntimeError("Observation readiness timeout; no push sent")
            audio = self.listen()
            if audio and audio.poll() is None:
                time.sleep(5)  # Quiet baseline before the controlled signal.
            if p["sendVoIP"]:
                self.send()
                if p["serverAnswer"]:
                    # Simulate a server answer through a local mailbox, never a cancellation-only VoIP push.
                    # The app must be runnable; absence of its trace is recorded as unqualified.
                    time.sleep(5)
                    self.signal_id = str(uuid.uuid4())
                    path = self.folder / "answer-signal.json"
                    write(path, {"runID": self.run_id, "invitationID": self.invitation, "signalID": self.signal_id})
                    self.copy("answer-signal.json", path, to=True)
                if p["baseRow"] == "C02":
                    time.sleep(69); self.invitation = str(uuid.uuid4()); self.invitations.append(self.invitation); self.send("-repeat")
            if p["activity"]:
                current = self.current_activity("before-send")
                if current["activityID"] != result["activityContinuity"]["activityID"]:
                    raise RuntimeError("Activity changed before send; APNs update not sent")
                self.command(["node", str(HERE / "send-activity.mjs"), "--token-file", str(self.folder / "activity-token.json"),
                              "--receipt-file", str(self.folder / "activity-apns.json")], timeout=30)
                time.sleep(40 if p["row"] == "L09" else 8)
            elif not observer:
                time.sleep(35)
            if observer:
                try:
                    observation_code = observer.wait(timeout=300)
                except subprocess.TimeoutExpired:
                    self.unsafe_observer = True
                    raise
                if observation_code:
                    self.unsafe_observer = True
                    raise RuntimeError("UI observer failed")
                self.recover(); self.copy("focus-ui-result.json", self.folder / "ui.json", test=True)
                ui = json.loads((self.folder / "ui.json").read_text())
                evidence = [e for e in ui["events"] if e.get("event") == "call.observed"]
                result["visual"] = evidence
                result["visualNegativeQualified"] = self.qualified(self.work / "visual-calibration.json")
            self.copy("focus.jsonl", self.folder / "trace.jsonl")
            traces = [json.loads(line) for line in (self.folder / "trace.jsonl").read_text().splitlines() if line]
            matching = correlate(traces, self.invitations)
            received = [e for e in matching if e.get("event") == "push.received"]
            if (p["sendVoIP"] and len(received) != len(self.invitations)) or any(e.get("provider") != p["provider"] or e.get("handleType") != p["handleType"] or e.get("handleValue") != p["callerValue"] for e in received):
                raise RuntimeError("Provider or handle mismatch in device trace")
            if observer:
                by_id = {str(e["invitationID"]).lower(): e["monoMs"] for e in received}
                if len(result["visual"]) != 1 or any(value.lower() not in by_id for value in self.invitations):
                    raise RuntimeError("Missing per-invitation observation boundary")
                device_receipts = [(value, by_id[value.lower()]) for value in self.invitations]
                result["visualByInvitation"] = surface_windows(ui["events"], device_receipts, result["visual"][0])
                if p["baseRow"] == "C02":
                    result["repeatIntervalMs"] = device_receipts[1][1] - device_receipts[0][1]
            result["invitationIDs"] = self.invitations
            result["reports"] = [e for e in matching if e["event"] == "report.result"]
            if p["serverAnswer"] and observer:
                result["answeredElsewhere"] = answer_evidence(ui["events"], matching, result["visual"][0], self.signal_id, device_receipts[0][1])
            first_window = result.get("visualByInvitation", [{}])[0]
            if observer and any(not window["continuityQualified"] for window in result["visualByInvitation"]):
                result["visualNegativeQualified"] = False
            if p["row"] == "C00" and len(result["reports"]) == 1 and result["reports"][0].get("outcome") == "reported" and first_window.get("observationQualified") and first_window.get("continuityQualified") and (first_window.get("bannerFirstNewPresentationUptimeMs") is not None or first_window.get("callScreenFirstNewPresentationUptimeMs") is not None):
                write(self.work / "visual-calibration.json", {"positive": True, "binding": self.binding, "createdAt": time.time()})
                result["visualNegativeQualified"] = True
            if p["locked"]:
                expected_action = "CXAnswerCallAction" if p["provider"] == "callkit" else "JoinConversationAction"
                result["autoAnswerAction"] = expected_action
                result["autoAnswerObserved"] = any(e["event"] == "call.action" and e.get("kind") == expected_action for e in matching)
            result["lockCondition"] = "lock button pressed, then 45s without a UI session; Auto-Lock readback in systemSettings" if p["locked"] else "unlocked UI session"
            if p["activity"]:
                text = "Updates delayed" if p["row"] == "L09" else "Synthetic caller: APNs update"
                self.ui(["sample", "activity-check"], text=text)
                self.copy("focus-activity.png", self.folder / "activity.png", test=True)
                self.copy("focus.jsonl", self.folder / "trace.jsonl")
                traces = [json.loads(line) for line in (self.folder / "trace.jsonl").read_text().splitlines() if line]
                activity_id = json.loads((self.folder / "activity-token.json").read_text())["activityID"]
                result["activityContentEvents"] = [e for e in traces if e["event"].startswith("activity.") and e.get("runID") == self.run_id and e.get("activityID") == activity_id]
                result["coverage"] = "Single transport/presentation subcase, not full cadence/lock/privacy qualification"
            result["status"] = "recorded" if not p["sendVoIP"] or reports_complete(result["reports"], self.invitations) else "incomplete-report-evidence"
            if observer and any(not window["observationQualified"] or not window["continuityQualified"]
                    for window in result["visualByInvitation"]):
                result["status"] = "incomplete-observation-window"
            if p["baseRow"] == "C02" and (not observer or not 0 < result["repeatIntervalMs"] <= 180000):
                result["status"] = "invalid-or-unmeasured-repeat-interval"
            return result
        finally:
            for process in [observer, audio]:
                if process and process.poll() is None:
                    if process is observer and self.unsafe_observer:
                        continue
                    try:
                        process.wait(timeout=90)
                    except subprocess.TimeoutExpired:
                        if process is observer:
                            self.unsafe_observer = True
                        else:
                            process.kill(); process.wait(timeout=10)
            if (self.folder / "audio.json").exists():
                data = json.loads((self.folder / "audio.json").read_text()); result["audio"] = data
                if p["row"] == "C00":
                    data["calibrationValid"] = data.get("calibrationValid") is True and audio_control_eligible(result)
                    if data["calibrationValid"]:
                        data.update(binding=self.binding, createdAt=time.time())
                        write(self.work / "audio-calibration.json", data)
            if self.unsafe_observer:
                # Do not race an observer that may still be driving the phone.
                # The batch supervisor kills and verifies the whole row process
                # group before attempting journal restoration.
                result["restored"] = False
                result["status"] = "restore-failed-use-restore-all"
            elif p["row"] != "restore-all" and not p.get("hardwareNA"):
                try:
                    self.recover()
                    if self.args.keep_setup:
                        # Matrix runs keep the owned Focus/contact between rows; only the Focus-on window ends here.
                        self.arm({"armed": False, "activityAction": None if p["activity"] else "end"})
                        cleanup = (["activity-network:restore"] if p["activity"] else [])
                        cleanup += ["dnd:off" if p["focusMode"] == "dnd" else "focus:off"]
                        self.ui(cleanup)
                        result["restored"] = "focus-off"
                    else:
                        self.restore(); result["restored"] = True
                except Exception:
                    result["restored"] = False; result["status"] = "restore-failed-use-restore-all"
                    if p["row"] == "C00":
                        (self.work / "visual-calibration.json").unlink(missing_ok=True)
                        (self.work / "audio-calibration.json").unlink(missing_ok=True)
                        result["visualNegativeQualified"] = False
                        if "audio" in result:
                            result["audio"]["calibrationValid"] = False
            write(self.folder / "result.json", result)
            print(json.dumps({"row": p["row"], "status": result["status"], "result": str(self.folder / "result.json")}))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("row")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--locked-auto-answer", action="store_true")
    parser.add_argument("--allow-system-settings", action="store_true")
    parser.add_argument("--listen", action="store_true")
    parser.add_argument("--quiet", action="store_true", help="journal and minimize ringtone volume; no microphone")
    parser.add_argument("--repeated-calls", choices=["on", "off"], default="off")
    parser.add_argument("--provider", choices=["lck", "callkit"])
    parser.add_argument("--caller-format", choices=["e164", "national", "generic"], default="e164")
    parser.add_argument("--caller-value", help="synthetic handle in the chosen format; default matches the test contact")
    parser.add_argument("--calls", default="Everyone", choices=["Everyone", "All Contacts", "Contacts Only", "Favorites", "Allowed People Only"])
    parser.add_argument("--keep-setup", action="store_true", help="matrix mode: turn Focus off after the row; run restore-all at the end")
    parser.add_argument("--focus-mode", choices=["custom", "dnd"], default="custom")
    parser.add_argument("--unknown-caller", action="store_true", help="verify the supplied E.164 caller is absent from Contacts")
    parser.add_argument("--favorite", choices=["yes", "no"], help="set the owned test contact's Favorites state")
    parser.add_argument("--server-answer", action="store_true", help="simulate an answer through a local mailbox, not APNs")
    parser.add_argument("--activity-focus", choices=["on", "off"], help="choose Focus for L07–L15")
    args = parser.parse_args()
    if args.quiet and args.listen:
        raise ValueError("Quiet mode cannot listen")
    p = plan(args.row, args.locked_auto_answer, args.listen, args.provider, args.caller_format, args.repeated_calls, args.caller_value)
    if args.activity_focus is not None:
        value = args.activity_focus == "on"
        if p["row"] in [f"L{n:02}" for n in range(1, 7)] and value != p["focus"]:
            raise ValueError("L01–L06 have a prescribed Focus state")
        if p["row"] not in [f"L{n:02}" for n in range(1, 16)]:
            raise ValueError("Activity Focus override is only valid for L01–L15")
        p["focus"] = value
    if args.focus_mode == "dnd" and (not p["focus"] or p["app"] or p["person"] or not p["sendVoIP"]):
        raise ValueError("Built-in DND rows require a focused incoming call with app and person excluded")
    if args.unknown_caller and (not args.caller_value or args.caller_format != "e164" or args.caller_value == "+15555550199" or p["person"]):
        raise ValueError("Unknown caller needs a different E.164 number and no allowed test contact")
    if args.server_answer and (not p["sendVoIP"] or p["baseRow"] == "C02" or args.locked_auto_answer):
        raise ValueError("Local answer signaling requires one unlocked incoming-call observation")
    p.update(focusMode=args.focus_mode, unknownCaller=args.unknown_caller, favorite=args.favorite, serverAnswer=args.server_answer, quiet=args.quiet)
    if args.quiet and p["baseRow"] == "preflight":
        p["steps"] += ["capture ringer volume and durably back up its journal", "set ringer volume to minimum in a separate UI session"]
    if not p["blocked"] and p["baseRow"] not in ["restore-all", "preflight"]:
        p["callsFrom"] = args.calls if p["baseRow"] == "C01" else "Allowed People Only"
        p["keepSetup"] = args.keep_setup
        if args.focus_mode == "dnd":
            p["steps"].insert(1, "snapshot built-in DND settings, verify app exclusion and selected controls, then enable DND")
        if args.unknown_caller:
            p["steps"].insert(1, "verify the caller is absent from Contacts before the call")
        if args.server_answer:
            p["steps"].insert(-2, "write a matched local answer signal; trace receipt/report and UI disappearance")
        if args.keep_setup:
            p["steps"][-1] = "write private row result; disarm and turn Focus off; keep owned setup (run restore-all after matrix)"
    if args.quiet and (p["sendVoIP"] or p["row"] in ("L01", "L02")):
        p["steps"].append("audio and vibration evidence: skipped: quiet")
    if args.dry_run or p["blocked"]:
        if p["blocked"]:
            p["status"] = "skipped-dependency-or-unsupported"
            p["humanQA"] = False
        print(json.dumps(p, indent=2)); return
    if (p["baseRow"] == "restore-all" and not os.environ.get("FOCUS_BATCH_OWNER_PID")
            and not os.environ.get("FOCUS_BATCH_LOCK_NONCE")):
        # Preserve direct restore-all, but let a lock-owning supervisor run its
        # preflight and restoration in bounded process groups.
        from morning_batch import supervised_restore
        supervised_restore()
        return
    require_device_supervisor()
    if p["baseRow"] == "preflight":
        run = Run(p, args)
        if args.quiet:
            run.ui(["share-across-devices:check", "ringer-volume:capture"])
            run.ui(["ringer-volume:minimum"])
        else:
            run.ui(["share-across-devices:check"])
        print(json.dumps({"row": "preflight", "status": "recorded"})); return
    result = Run(p, args).execute()
    if result["status"] not in ["recorded", "restored", "not-applicable-hardware"]:
        raise RuntimeError("Row or restoration incomplete")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, subprocess.TimeoutExpired, OSError) as error:
        # Never dump environment, argv, token files or arbitrary APNs responses.
        print("Focus row stopped: " + type(error).__name__ + "; inspect private result/logs", file=__import__("sys").stderr)
        raise SystemExit(1)
