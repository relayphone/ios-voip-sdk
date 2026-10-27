"""Device-facing Live Activity experiments; simulations never count as OS evidence."""
import json
import math
import subprocess
import time
import uuid
from pathlib import Path

from activity_contract import simulate_row


def activity_plan(row):
    cases = {
        "L01": "foreground start, 25 silent priority-5 updates across two minutes, observe rendered revisions",
        "L02": "same cadence with Focus enabled and app/person excluded",
        "L03": "pre-arm an activity, background app and project a synthetic session without SSE",
        "L04": "pre-arm, terminate the app and project a synthetic session under Focus",
        "L05": "reset activities, background without push or user action, verify inventory and card absence",
        "L06": "same no-start negative with Focus enabled",
        "L07": "start from the system Shortcuts UI with the app absent; export the update token",
        "L08": "journal and exercise Live Activity authorization and frequent-update settings",
        "L09": "verify wired transport, disconnect Wi-Fi/cellular, observe stale state, reconnect and update",
        "L10": "relaunch/token continuity, sandbox invalid-token control and simulated rotation ordering",
        "L11": "bounded priority-5/10 cadence with frequent updates off/on and a simulated budget",
        "L12": "send newer/older snapshots and simulate APNs acceptance, unrendered delivery and backoff",
        "L13": "send a bounded UTF-8/Unicode payload and exercise restored notification-preview settings",
        "L14": "end by APNs, dismiss a second card and simulate logout, consent and expiry",
        "L15": "explicit alerting push-to-start, then receive and use the per-activity update token",
        "L16": "identify the iPhone 13 and record Dynamic Island as not applicable",
    }
    if row not in cases:
        raise ValueError("unknown activity row")
    return ["verify device and Share Across Devices; journal reversible settings", cases[row],
            "record device evidence separately from simulations and unobserved lock/audio conditions",
            "restore settings and stop or preserve activity according to batch policy"]


def summarize_render(receipts, events, bounds):
    """Report observed revisions and conservative latency intervals, never APNs-as-render."""
    expected = {r["revision"]: r for r in receipts if accepted(r) and isinstance(r.get("revision"), int)}
    samples = [e for e in events if e.get("event") == "activity.renderSample" and e.get("revision") in expected]
    observed = {}
    for event in samples:
        observed.setdefault(event["revision"], event)
    synthetic_text = {event["revision"] for event in samples if event.get("syntheticTextVisible") is True}
    value = {"acceptedCount": len(expected), "observedRevisions": sorted(observed),
             "missingRevisions": sorted(set(expected) - set(observed)),
             "syntheticTextRevisions": sorted(synthetic_text),
             "revisionScope": "revision labels; synthetic-text flag is a generic prefix, not an exact excerpt",
             "latencyStatus": "unqualified"}
    if not observed or not isinstance(bounds, dict):
        return value
    low, high = bounds.get("deviceMinusHostMin"), bounds.get("deviceMinusHostMax")
    wall_anchor, mono_anchor = bounds.get("hostWallAnchorMs"), bounds.get("hostMonotonicAnchorMs")
    if (not all(isinstance(v, (int, float)) for v in (low, high, wall_anchor, mono_anchor))
            or high < low or high - low > 2000):
        return value
    clocks = [e.get("wallTimeMs") - e.get("uptimeMs") for e in events
              if e.get("event") == "activity.sample" and isinstance(e.get("wallTimeMs"), int) and isinstance(e.get("uptimeMs"), int)]
    if not clocks or max(clocks) - min(clocks) > 250:
        return value
    intervals = []
    for revision, event in observed.items():
        receipt = expected[revision]
        values = [event.get("wallTimeMs"), event.get("uptimeMs"), event.get("sampleStartUptimeMs"),
                  receipt.get("hostSendStart"), receipt.get("hostSendEnd"),
                  receipt.get("hostMonotonicStart"), receipt.get("hostMonotonicEnd")]
        if not all(isinstance(v, (int, float)) for v in values):
            return value
        wall, uptime, sample_start, sent, response, mono_start, mono_end = values
        if (sample_start > uptime or response < sent or mono_end < mono_start or
                abs(sent * 1000 - (wall_anchor + mono_start * 1000 - mono_anchor)) > 250 or
                abs(response * 1000 - (wall_anchor + mono_end * 1000 - mono_anchor)) > 250):
            return value
        latest = wall - low - sent * 1000
        if latest < 0:
            return value
        # Sparse screenshots prove the revision is visible by this sample, but
        # cannot exclude an earlier transient render and later reversion. Even
        # the preceding negative sample cannot bound the first-ever render.
        intervals.append({"revision": revision, "lowerMs": 0, "upperMs": latest})
    value["latencyBounds"] = intervals
    value["latencyScope"] = "first-ever rendering has zero lower bound; upper bound is first observed sample"
    value["latencyStatus"] = "bounded-observations"
    if len(intervals) >= 20 and not value["missingRevisions"]:
        # Nearest-rank order statistics: ceil(p*n)-1. This chooses the lower
        # middle observation for an even-sized median rather than interpolation.
        value["quantileMethod"] = "nearest-rank; lower median for even sample counts"
        for name, fraction in (("median", .5), ("p95", .95)):
            index = math.ceil(len(intervals) * fraction) - 1
            value[name + "BoundsMs"] = [sorted(x["lowerMs"] for x in intervals)[index], sorted(x["upperMs"] for x in intervals)[index]]
    return value


def offline_callback_after_settings(value, run_id, settings_uptime_ms):
    """An old/cached path cannot establish disconnection after Settings changed."""
    return (isinstance(value, dict) and type(settings_uptime_ms) is int and settings_uptime_ms >= 0
            and value.get("runID") == run_id and value.get("source") == "pathUpdate"
            and value.get("pathReady") is True and value.get("status") == "unsatisfied"
            and type(value.get("lastPathUpdateUptimeMs")) is int
            and value["lastPathUpdateUptimeMs"] > settings_uptime_ms)


class ActivityScenario:
    def __init__(self, run, result):
        self.run, self.result, self.row = run, result, run.p["row"]
        self.coverage = result.setdefault("coverage", {})
        self.sequence = 0
        self.result["activityReceipts"] = []

    def note(self, name, state, detail=None):
        item = {"status": state}
        if detail is not None:
            item["detail"] = detail
        self.coverage[name] = item

    def config(self, action="snapshot", start_token=False):
        self.run.arm({"rowID": self.row, "runID": self.run.run_id, "provider": self.run.p["provider"],
                      "armed": True, "activityAction": action, "exportPushToStart": start_token})

    def read_file(self, name, suffix):
        target = self.run.folder / (suffix + ".json")
        self.run.copy(name, target)
        return json.loads(target.read_text())

    def setup(self):
        self.config("reset")
        self.run.ui(["share-across-devices:check", "setup", "launch", "notifications:allow",
                     "app:exclude", "person:exclude", "calls:Allowed People Only", "repeated-calls:off",
                     "focus:" + ("on" if self.run.p["focus"] else "off")])
        self.config("snapshot")
        self.run.ui(["launch"])
        self.capabilities("initial", {"activeActivityCount": 0})

    def capabilities(self, suffix, expected=None, newer_than=None):
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            try:
                value = self.read_file("activity-capabilities.json", "capabilities-" + suffix)
                if (value.get("runID") == self.run.run_id and
                        (newer_than is None or value.get("observedAtMs", 0) > newer_than) and
                        (expected is None or all(value.get(k) == v for k, v in expected.items()))):
                    return value
            except (OSError, ValueError, RuntimeError):
                pass
            time.sleep(1)
        raise RuntimeError("Activity capabilities unavailable for this run")

    def start(self):
        self.config("start")
        self.run.ui(["launch", "activity-consent"])
        current = self.run.current_activity("initial")
        self.result["activityContinuity"] = {"activityID": current["activityID"], "surfaceID": current["surfaceID"]}
        return current

    def end_local(self):
        self.config("end")
        self.run.ui(["launch"])
        self.config("snapshot")

    def ui_card(self, text, suffix, action="activity-contains"):
        self.run.ui([action], text=text)
        self.run.copy("focus-activity.png", self.run.folder / ("activity-" + suffix + ".png"), test=True)

    def ui_visibility(self, text, suffix):
        # A missing or ambiguous card fails closed, rather than counting as hidden.
        self.ui_card(text, suffix, "activity-probe-text")
        target = self.run.folder / ("activity-visibility-" + suffix + ".json")
        self.run.copy("focus-ui-result.json", target, test=True)
        events = json.loads(target.read_text()).get("events", [])
        values = [e.get("visible") for e in events if e.get("event") == "activity.textVisibility"]
        if len(values) != 1 or not isinstance(values[0], bool):
            raise RuntimeError("synthetic activity text visibility unqualified")
        return values[0]

    def send(self, event="update", text="Synthetic caller: APNs update", priority=5, timestamp=None,
             revision=None, stale_after=30, surface=None, session=None, fit=False, invalid=False):
        self.sequence += 1
        suffix = "send-" + str(self.sequence)
        receipt = self.run.folder / ("activity-apns-" + str(self.sequence) + ".json")
        if event == "start":
            token = self.run.folder / "activity-start-token.json"
            deadline = time.monotonic() + 30
            while True:
                try:
                    self.run.copy("activity-start-token.json", token)
                    value = json.loads(token.read_text())
                    if value.get("runID") == self.run.run_id and value.get("tokenGeneration"):
                        break
                except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired):
                    pass
                if time.monotonic() >= deadline:
                    raise RuntimeError("current push-to-start token unavailable")
                time.sleep(1)
            registration = None
        elif invalid:
            token, registration = self.invalid_fixture()
        else:
            current = self.run.current_activity(suffix)
            expected = self.result.get("activityContinuity")
            if expected and (current["activityID"], current["surfaceID"]) != (expected["activityID"], expected["surfaceID"]):
                raise RuntimeError("activity identity changed before push")
            token = self.run.folder / "activity-token.json"
            registration = self.run.folder / ("activity-registration-" + suffix + ".json")
        stamp = int(time.time()) if timestamp is None else timestamp
        argv = ["node", str(Path(__file__).with_name("activity-payloads.mjs")),
                "--event", event, "--token-file", str(token), "--receipt-file", str(receipt),
                "--timestamp", str(stamp), "--revision", str(revision if revision is not None else self.sequence),
                "--excerpt", text, "--stale-after", str(stale_after), "--priority", str(priority)]
        if registration is not None:
            argv += ["--registration-file", str(registration)]
        if event == "start":
            argv += ["--allow-alert", "--surface-id", surface or str(uuid.uuid4())]
        if session:
            argv += ["--session-id", session]
        if fit:
            argv += ["--fit"]
        if invalid:
            argv += ["--test-invalid-token"]
        started = time.time()
        started_mono = time.monotonic()
        sender_ok = True
        try:
            self.run.command(argv, timeout=30)
        except RuntimeError:
            sender_ok = False
            if not receipt.exists():
                raise
        if not receipt.exists():
            raise RuntimeError("missing reserved APNs receipt")
        value = json.loads(receipt.read_text())
        value["hostSendStart"] = started
        value["hostSendEnd"] = time.time()
        value["hostMonotonicStart"] = started_mono
        value["hostMonotonicEnd"] = time.monotonic()
        # A 200 status alone is insufficient if the sender rejected its APNs ID
        # or otherwise could not validate the response.
        value["transportAcknowledged"] = sender_ok
        self.result["activityReceipts"].append(value)
        return value

    def invalid_fixture(self):
        # A dedicated all-zero token can never address the registered activity.
        marker = "synthetic-invalid-" + uuid.uuid4().hex
        value = {"activityID": "synthetic-invalid-token", "surfaceID": str(uuid.uuid4()),
                 "tokenGeneration": marker, "state": "active", "token": "00" * 32}
        token = self.run.folder / "invalid-activity-token.json"
        registration = self.run.folder / "invalid-activity-registration.json"
        token.write_text(json.dumps(value)); registration.write_text(json.dumps({k: v for k, v in value.items() if k != "token"}))
        token.chmod(0o600); registration.chmod(0o600)
        return token, registration

    def observer(self, duration):
        # Each concurrent UI session gets a fresh marker; a prior session's ready file is not valid.
        self.run.invitation = str(uuid.uuid4())
        host_start = time.time() * 1000
        host_mono_start = time.monotonic() * 1000
        process = self.run.ui(["activity-observe:" + str(duration)], background=True)
        ready = self.run.folder / "activity-ready.json"
        deadline = time.monotonic() + 90
        try:
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError("activity observer ended before readiness")
                try:
                    self.run.copy("activity-observation-ready.json", ready, test=True)
                    value = json.loads(ready.read_text())
                    if value.get("id") == self.run.invitation:
                        host_end = time.time() * 1000
                        host_mono_end = time.monotonic() * 1000
                        if (isinstance(value.get("wallTimeMs"), int) and
                                abs((host_end - host_start) - (host_mono_end - host_mono_start)) <= 250):
                            self.result.setdefault("clockOffsetBoundsMs", []).append({
                                "deviceMinusHostMin": value["wallTimeMs"] - host_end,
                                "deviceMinusHostMax": value["wallTimeMs"] - host_start,
                                "hostWallAnchorMs": host_end, "hostMonotonicAnchorMs": host_mono_end,
                                "qualification": "ready event bracket only; clocks may change"})
                        self.clock_ping(process)
                        return process
                except (OSError, ValueError, RuntimeError):
                    pass
                time.sleep(1)
            raise RuntimeError("activity observer readiness timeout")
        except BaseException:
            self.settle_observer(process)
            raise

    def clock_ping(self, process):
        """Bracket a fresh UI-side timestamp between host send and receipt."""
        nonce = str(uuid.uuid4())
        request = self.run.folder / "activity-clock-request.json"
        response = self.run.folder / "activity-clock-response.json"
        request.write_text(json.dumps({"id": self.run.invitation, "nonce": nonce}))
        request.chmod(0o600)
        host_start = time.time() * 1000
        mono_start = time.monotonic() * 1000
        try:
            self.run.copy("activity-clock-request.json", request, to=True, test=True)
            deadline = time.monotonic() + 12
            while time.monotonic() < deadline and process.poll() is None:
                try:
                    self.run.copy("activity-clock-response.json", response, test=True)
                    value = json.loads(response.read_text())
                    if value.get("id") == self.run.invitation and value.get("nonce") == nonce:
                        host_end = time.time() * 1000
                        mono_end = time.monotonic() * 1000
                        if (isinstance(value.get("wallTimeMs"), int) and
                                abs((host_end - host_start) - (mono_end - mono_start)) <= 250):
                            self.result.setdefault("clockOffsetBoundsMs", []).append({
                                "deviceMinusHostMin": value["wallTimeMs"] - host_end,
                                "deviceMinusHostMax": value["wallTimeMs"] - host_start,
                                "hostWallAnchorMs": host_end, "hostMonotonicAnchorMs": mono_end,
                                "qualification": "nonce ping bracket; later wall-clock jumps remain unqualified"})
                        return
                except (OSError, ValueError, RuntimeError):
                    pass
                time.sleep(0.25)
        except (OSError, RuntimeError, subprocess.TimeoutExpired):
            pass  # A missing handshake leaves latency unqualified, never inferred.

    def settle_observer(self, process):
        """Never restore while an observer may still be driving the phone."""
        try:
            code = process.wait(timeout=200)
        except Exception as error:
            self.run.unsafe_observer = True
            raise RuntimeError("activity observer could not be safely stopped") from error
        if code != 0:
            # Even an exited xcodebuild may have left a descendant alive. The
            # batch supervisor must terminate the row's complete process group.
            self.run.unsafe_observer = True
            raise RuntimeError("activity observer failed; group cleanup required")

    def begin_audio(self, seconds):
        binary = self.run.work / "listen"
        output = self.run.folder / "activity-audio.json"
        try:
            if not binary.exists():
                self.run.command(["swiftc", str(Path(__file__).with_name("listen.swift")), "-o", str(binary)], timeout=90)
            process = self.run.command([str(binary), "--output", str(output), "--seconds", str(seconds)], background=True)
        except (OSError, RuntimeError):
            self.note("acousticEnvelope", "unqualified", "microphone helper unavailable")
            return None, output
        deadline = time.monotonic() + 10
        while process.poll() is None and not Path(str(output) + ".ready").exists() and time.monotonic() < deadline:
            time.sleep(0.2)
        if process.poll() is None:
            time.sleep(5)  # Establish a quiet interval before the first update.
        return process, output

    def finish_audio(self, pair):
        process, output = pair
        if process is None:
            return
        try:
            if process.poll() is None:
                process.wait(timeout=180)
        except Exception:
            process.kill(); process.wait(timeout=10)
        if output.exists():
            value = json.loads(output.read_text())
            value["binding"] = self.run.binding
            output.write_text(json.dumps(value))
            output.chmod(0o600)
            self.result["activityAudio"] = str(output)
            sent = self.result.get("activityReceipts", [])
            if sent:
                self.result["activityAudioWindow"] = {"start": min(r["hostSendStart"] for r in sent),
                                                       "end": max(r["hostSendEnd"] for r in sent) + 5}
            self.note("acousticEnvelope", "recorded" if value.get("samples") else "unqualified",
                      "uncalibrated RMS proxy; compare with final C00, not proof of silence")
        else:
            self.note("acousticEnvelope", "unqualified", "microphone unavailable or capture incomplete")

    def finish_observer(self, process, suffix="observed"):
        self.settle_observer(process)
        self.run.recover(required=True)
        path = self.run.folder / ("activity-ui-" + suffix + ".json")
        self.run.copy("focus-ui-result.json", path, test=True)
        self.run.copy("focus-activity.png", self.run.folder / ("activity-" + suffix + ".png"), test=True)
        value = json.loads(path.read_text())
        self.result["activityObservation"] = value.get("events", [])
        self.result.setdefault("activityObservations", []).append({"case": suffix, "events": value.get("events", [])})
        observations = [e for e in value.get("events", []) if e.get("event") == "activity.observed"]
        if len(observations) != 1:
            raise RuntimeError("activity observer lacks a complete interval")
        return observations[0]

    def cadence(self, count, interval, priority=5, text_prefix="Synthetic cadence", session=None, observer=None):
        if not 1 <= count <= 60 or interval < 1:
            raise ValueError("activity cadence exceeds safe bounds")
        previous = None
        for index in range(count):
            if observer is not None and observer.poll() is not None:
                self.note("presentation", "unqualified", "observer ended before cadence completed")
                return False
            if previous is not None:
                delay = previous + interval - time.monotonic()
                if delay > 0:
                    time.sleep(delay)
            previous = time.monotonic()
            receipt = self.send(text=f"{text_prefix} {index + 1}", priority=priority,
                                revision=self.sequence + 1, session=session)
            if not accepted(receipt):
                self.note("transport", "unqualified", "APNs did not accept an update; no automatic retry")
                return False
        return True

    def fixture(self):
        value = simulate_row(self.row)
        self.coverage["offlineSimulation"] = value
        if value.get("status") != "simulated":
            raise RuntimeError("offline simulation failed")

    def trace(self):
        path = self.run.folder / "activity-trace.jsonl"
        self.run.copy("focus.jsonl", path)
        return [value for value in (json.loads(line) for line in path.read_text().splitlines() if line)
                if value.get("runID") == self.run.run_id]

    def verify_usb(self):
        self.run.usb_verified = False
        inventory = self.run.folder / "activity-usb-inventory.json"
        self.run.command(["xcrun", "devicectl", "list", "devices", "--json-output", str(inventory), "--quiet"], timeout=30)
        devices = json.loads(inventory.read_text()).get("result", {}).get("devices", [])
        matches = [d for d in devices if str((d.get("hardwareProperties") or {}).get("udid", "")).upper() == self.run.device.upper()]
        if len(matches) != 1:
            raise RuntimeError("USB device identity unavailable")
        connection = matches[0].get("connectionProperties") or {}
        if str(connection.get("transportType", "")).lower() != "wired" or str(connection.get("tunnelState", "")).lower() != "connected":
            raise RuntimeError("wired device transport not verified; do not disable radios")
        self.run.usb_verified = True

    def offline_settings_uptime(self):
        target = self.run.folder / "network-settings-observation.json"
        self.run.copy("focus-ui-result.json", target, test=True)
        result = json.loads(target.read_text())
        events = [event for event in result.get("events", []) if event.get("event") == "activity.networkSettings"]
        if (result.get("status") != "ok" or len(events) != 1 or events[0].get("wifi") is not False
                or events[0].get("cellularData") is not False or type(events[0].get("uptimeMs")) is not int):
            raise RuntimeError("offline settings readback marker unavailable")
        return events[0]["uptimeMs"]

    def network_offline_snapshot(self, newer_than):
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            try:
                value = self.read_file("activity-network-update.json", "network-offline")
                if offline_callback_after_settings(value, self.run.run_id, newer_than):
                    return value
            except (OSError, ValueError, RuntimeError):
                pass
            time.sleep(1)
        raise RuntimeError("offline network path not established")


def execute_activity(run, result):
    scenario = ActivityScenario(run, result)
    try:
        scenario.setup()
        run_activity_case(scenario)
        # `recorded` means every required non-simulated subcase was observed;
        # fixtures are never promoted into device or backend evidence.
        result["status"] = "unqualified" if any(v.get("status") == "unqualified" for v in scenario.coverage.values() if isinstance(v, dict)) else "recorded"
    except (OSError, ValueError, RuntimeError, TimeoutError) as error:
        scenario.note("execution", "unqualified", type(error).__name__)
        result["status"] = "unqualified"


def accepted(receipt):
    return receipt.get("status") == 200 and receipt.get("transportAcknowledged") is True


def run_activity_case(s):
    """Each scenario records OS observations and offline fixtures separately."""
    row = s.row
    if row in ("L05", "L06"):
        before = s.capabilities("before-background", {"activeActivityCount": 0})
        s.run.ui(["home"])
        time.sleep(15)  # No push, activity request or user action in the background interval.
        s.config("snapshot")
        s.run.ui(["launch"])
        after = s.capabilities("after-background", {"activeActivityCount": 0}, before["observedAtMs"])
        s.run.ui(["activity-absent"])
        trace = s.trace()
        attempts = [e.get("event") for e in trace if e.get("event") in ("activity.start", "activity.created", "activity.startFailed")]
        s.note("noAutomaticStart", "observed" if not attempts else "unqualified",
               {"before": before["activeActivityCount"], "after": after["activeActivityCount"], "pushes": 0, "traceAttempts": attempts})
        s.note("backgroundExecutionCoverage", "unqualified", "two snapshots and process trace cannot rule out an unobserved transient while suspended")
        s.note("historyFallback", "unqualified", "probe has no production backend/history adapter")
        return

    if row == "L07":
        s.run.ui(["terminate", "activity-shortcut"])
        # Every later UI invocation overwrites focus-ui-result.json; preserve
        # the shortcut evidence before relaunching the app.
        shortcut_path = s.run.folder / "activity-shortcut-ui.json"
        s.run.copy("focus-ui-result.json", shortcut_path, test=True)
        shortcut_ui = json.loads(shortcut_path.read_text())
        if shortcut_ui.get("status") != "ok" or not isinstance(shortcut_ui.get("events"), list):
            raise RuntimeError("shortcut UI observation is unavailable")
        shortcut_events = shortcut_ui["events"]
        s.result["shortcutObservation"] = shortcut_events
        s.config("snapshot")
        s.run.ui(["launch", "activity-consent"])
        current = s.run.current_activity("shortcut")
        s.result["activityContinuity"] = {"activityID": current["activityID"], "surfaceID": current["surfaceID"]}
        s.note("perActivityUpdateToken", "observed", "paired current token exported after app rediscovery; no update delivery inferred")
        events = s.trace()
        invocations = [event for event in shortcut_events if event.get("event") == "activity.shortcutInvoked"]
        observations = [event for event in shortcut_events if event.get("event") == "activity.shortcutObservation"]
        samples = [event for event in shortcut_events if event.get("event") == "activity.shortcutProbeState"]
        all_creations = [event for event in events if event.get("event") == "activity.created"]
        creations = [event for event in all_creations
                     if event.get("activityID") == current["activityID"] and event.get("surfaceID") == current["surfaceID"]]
        qualified = False
        detail = "creation trace or sampled nonforeground coverage unavailable"
        if len(invocations) == len(observations) == len(creations) == len(all_creations) == 1:
            invocation, observation, creation = invocations[0], observations[0], creations[0]
            start, tap_end, created = invocation.get("tapStartUptimeMs"), invocation.get("uptimeMs"), creation.get("monoMs")
            first, end = observation.get("firstSampleUptimeMs"), observation.get("endUptimeMs")
            timestamps = [event.get("uptimeMs") for event in samples]
            allowed = {"notRunning", "background", "backgroundSuspended"}
            if (all(type(value) is int for value in (start, tap_end, created, first, end, *timestamps))
                    and invocation.get("source") == "Shortcuts UI" and observation.get("allNonForeground") is True
                    and observation.get("samples") == len(samples) and len(samples) >= 2
                    and all(event.get("state") in allowed for event in samples)
                    and timestamps == sorted(timestamps) and timestamps[0] == first
                    and start <= tap_end <= first <= created <= timestamps[-1] <= end
                    and observation.get("startUptimeMs") == start and observation.get("tapEndUptimeMs") == tap_end
                    and all(0 <= b - a <= 1000 for a, b in zip(timestamps, timestamps[1:]))):
                qualified = True
                detail = {"activityID": current["activityID"], "createdUptimeMs": created,
                          "firstSampleUptimeMs": first, "lastSampleUptimeMs": timestamps[-1],
                          "maximumSampleGapMs": max(b - a for a, b in zip(timestamps, timestamps[1:])),
                          "qualification": "sampled nonforeground only; foreground between samples cannot be excluded"}
        s.note("systemShortcutCreation", "observed" if qualified else "unqualified", detail)
        return

    if row == "L08":
        s.run.ui(["activity-setting:disable"])
        s.config("start")
        s.run.ui(["launch"])
        denied = s.capabilities("disabled", {"activitiesEnabled": False, "activeActivityCount": 0})
        s.config("snapshot")
        s.run.ui(["launch"])
        s.capabilities("disabled-again", {"activitiesEnabled": False, "activeActivityCount": 0}, denied["observedAtMs"])
        attempts = [event for event in s.trace() if event.get("event") in ("activity.start", "activity.startFailed")]
        if len(attempts) != 1 or attempts[0]["event"] != "activity.startFailed":
            raise RuntimeError("disabled start attempt count or outcome was not qualified")
        s.run.ui(["activity-setting:enable"])
        for enabled in (False, True):
            s.run.ui(["activity-setting:frequent-" + ("on" if enabled else "off")])
            s.run.ui(["launch"])
            value = s.capabilities("frequent-" + str(enabled).lower(), {"activitiesEnabled": True, "frequentPushesEnabled": enabled})
            s.note("frequent-" + str(enabled).lower(), "observed", {"value": value["frequentPushesEnabled"]})
        s.note("disabledNoStart", "observed", "no active activity after disabled start and subsequent snapshot")
        s.note("backendCapabilityRegistration", "unqualified", "probe has no production backend registration")
        return

    if row == "L15":
        s.config("snapshot", start_token=True)
        s.run.ui(["launch"])
        audio = s.begin_audio(90)
        try:
            receipt = s.send(event="start", priority=10, text="Synthetic push-to-start")
        finally:
            s.finish_audio(audio)
        s.note("startTransport", "observed" if accepted(receipt) else "unqualified", "alerting mode; APNs acceptance does not prove presentation")
        if not accepted(receipt):
            raise RuntimeError("push-to-start not accepted")
        s.config("snapshot", start_token=True)
        s.run.ui(["launch", "activity-consent"])
        current = s.run.current_activity("remote-start")
        s.result["activityContinuity"] = {"activityID": current["activityID"], "surfaceID": current["surfaceID"]}
        if current["surfaceID"] != receipt.get("surfaceID"):
            raise RuntimeError("remote-start surface mismatch")
        update = s.send(text="Synthetic started activity update", priority=5)
        if accepted(update):
            s.ui_card("Synthetic started activity update", "remote-start-update")
            s.note("perActivityUpdateToken", "observed", "separate activity token used and synthetic content rendered")
        else:
            s.note("perActivityUpdateToken", "unqualified", "update not accepted")
        s.note("alertSoundAndWake", "unqualified", "alerting push was sent; sound and wake are not inferred")
        return

    initial = s.start()
    if row in ("L01", "L02", "L03", "L04"):
        s.config("snapshot")
        s.run.ui(["terminate" if row == "L04" else "home"])
        observer = s.observer(180 if row in ("L01", "L02") else 45)
        session = "focus-synthetic-" + str(uuid.uuid4()) if row in ("L03", "L04") else None
        s.result["syntheticSessionID"] = session
        audio = None
        try:
            audio = s.begin_audio(150) if row in ("L01", "L02") else None
            cadence_ok = s.cadence(25 if row in ("L01", "L02") else 4, 5,
                                   text_prefix="Synthetic cadence", session=session, observer=observer)
            observation = s.finish_observer(observer)
            samples = [e for e in s.result["activityObservation"] if e.get("event") == "activity.renderSample"]
            offsets = s.result.get("clockOffsetBoundsMs", [])
            summary = summarize_render(s.result["activityReceipts"], s.result["activityObservation"], offsets[-1] if offsets else None)
            s.note("renderCadence", "observed" if cadence_ok and summary["syntheticTextRevisions"] else "unqualified",
                   {"apnsAccepted": sum(accepted(r) for r in s.result["activityReceipts"]),
                    "renderSummary": summary, "observer": observation})
            expected = [r.get("revision") for r in s.result["activityReceipts"] if accepted(r)]
            last = samples[-1] if samples else {}
            latest = bool(expected and last.get("revision") == expected[-1] and last.get("syntheticTextVisible") is True)
            stale = bool(expected and last.get("stale") is True)
            s.note("latestOrStale", "observed" if latest or stale else "unqualified",
                   {"latestRevisionAndSyntheticText": latest, "staleLabel": stale,
                    "qualification": "generic synthetic text is not an exact excerpt match"})
            s.note("exactTranscriptContent", "unqualified", "revision and generic text do not verify the exact expected excerpt")
        finally:
            s.settle_observer(observer)
            if audio:
                s.finish_audio(audio)
        if row in ("L01", "L02", "L04"):
            s.note("lockScreenAndWake", "unqualified", "secure iPhone cannot be locked and automatically unlocked without an authorized unlock path")
        if row in ("L01", "L02"):
            s.note("soundAndHaptics", "unqualified", "RMS is an energy proxy and cannot prove no acoustic or haptic alert")
        if session:
            s.run.ui(["launch"])
            traces = s.trace()
            matching = [e for e in traces if e.get("event") in ("activity.current", "activity.content") and e.get("sessionID") == session]
            s.note("syntheticSessionState", "observed" if matching else "unqualified", "applied ActivityKit session snapshot after resume")
            call_events = [e.get("event") for e in traces if e.get("event") in ("push.received", "call.action", "call.audioActivated")]
            s.note("localCallAudioTrace", "observed" if not call_events else "unqualified", {"events": call_events, "scope": "recorded process trace only"})
            s.note("sessionBackend", "simulated", "synthetic ActivityKit session; no Phone AI/SIP backend")
            s.note("realBackend", "unqualified", "production AI/SIP binding is not available in this probe")
            if row == "L04":
                s.note("coldProcess", "unqualified", "termination was requested, but system wake/cold state was not independently established")
        return

    if row == "L09":
        s.verify_usb()
        s.run.ui(["launch"])
        sent = s.send(text="Synthetic before offline")
        if not accepted(sent):
            raise RuntimeError("initial update not accepted")
        time.sleep(8)
        s.ui_card("Synthetic before offline", "before-offline")
        s.note("initialPresentation", "observed")
        # Recheck after the preceding UI/push work, immediately before the
        # operation that could disconnect the only device transport.
        s.verify_usb()
        try:
            s.run.ui(["activity-network:offline"])
            settings_uptime = s.offline_settings_uptime()
            s.run.ui(["launch"])
            path = s.network_offline_snapshot(settings_uptime)
            s.note("offlinePath", "observed", {"status": path["status"], "source": path["source"],
                   "settingsUptimeMs": settings_uptime, "pathUpdateUptimeMs": path["lastPathUpdateUptimeMs"]})
            time.sleep(38)
            s.ui_card("Updates delayed", "stale")
            s.note("stalePresentation", "observed")
        finally:
            s.run.ui(["activity-network:restore"])
        s.run.ui(["launch"])
        resumed = s.send(text="Synthetic resumed update")
        if not accepted(resumed):
            raise RuntimeError("resumed update not accepted")
        time.sleep(8)
        s.ui_card("Synthetic resumed update", "resumed")
        s.note("resumedPresentation", "observed")
        s.note("backendAI", "unqualified", "synthetic probe has no AI backend")
        return

    if row == "L10":
        s.fixture()
        s.config("snapshot")
        s.run.ui(["launch", "activity-consent"])
        reloaded = s.run.current_activity("reloaded")
        if (reloaded["activityID"], reloaded["surfaceID"]) != (initial["activityID"], initial["surfaceID"]):
            raise RuntimeError("activity changed on relaunch")
        s.note("continuity", "observed", "same activity and current paired registration after relaunch")
        rejection = s.send(invalid=True)
        s.note("invalidToken", "observed" if rejection.get("expectedRejection") is True and rejection.get("transportAcknowledged") is True else "unqualified", rejection.get("reason"))
        s.note("actualTokenRotation", "unqualified", "rotation is system controlled; generation ordering tested in simulation")
        return

    if row == "L11":
        s.fixture()
        total = 0
        for frequent in (False, True):
            s.run.ui(["activity-setting:frequent-" + ("on" if frequent else "off"), "launch"])
            s.capabilities("budget-" + str(frequent).lower(), {"frequentPushesEnabled": frequent})
            first_receipt = len(s.result["activityReceipts"])
            observer = s.observer(90)
            try:
                for priority in (5, 10):
                    for interval in (5, 1):
                        if total + 3 > 60:
                            raise RuntimeError("activity send cap exceeded")
                        before = len(s.result["activityReceipts"])
                        cadence_ok = s.cadence(3, interval, priority, text_prefix=f"Synthetic p{priority} i{interval}", observer=observer)
                        attempted = len(s.result["activityReceipts"]) - before
                        total += attempted
                        s.note(f"frequent-{frequent}-p{priority}-i{interval}", "observed" if cadence_ok else "unqualified",
                               {"requested": 3, "attempted": attempted, "intervalSeconds": interval, "APNsAcceptanceOnly": True})
                observation = s.finish_observer(observer, "budget-" + str(frequent).lower())
                offsets = s.result.get("clockOffsetBoundsMs", [])
                receipts = s.result["activityReceipts"][first_receipt:]
                summaries = {str(priority): summarize_render([r for r in receipts if r.get("priority") == priority],
                             s.result["activityObservation"], offsets[-1] if offsets else None) for priority in (5, 10)}
                s.note("renderSamples-" + str(frequent).lower(),
                       "observed" if any(value["syntheticTextRevisions"] for value in summaries.values()) else "unqualified",
                       {"samples": observation.get("samples"), "byPriority": summaries})
            finally:
                s.settle_observer(observer)
        s.note("actualBudgetLimit", "unqualified", "bounded test never infers an Apple budget or exhaustion")
        return

    if row == "L12":
        s.fixture()
        now = int(time.time())
        newer = s.send(text="Synthetic ordering newest", timestamp=now, revision=20)
        older = s.send(text="Synthetic ordering old", timestamp=now - 10, revision=19)
        s.note("transportOrdering", "observed" if accepted(newer) and accepted(older) else "unqualified", {"newStatus": newer.get("status"), "oldStatus": older.get("status")})
        time.sleep(8)
        s.ui_card("Synthetic ordering newest", "ordering")
        s.note("latestPresentation", "observed", "newer synthetic content visible after older send")
        return

    if row == "L13":
        s.fixture()
        marker = 'Synthetic unicode 🧪 "'
        long_text = marker + ('é😀 "\\\n' * 900)
        receipt = s.send(text=long_text, fit=True)
        if not accepted(receipt) or receipt.get("bytes", 4097) > 4096:
            raise RuntimeError("Unicode update not accepted within byte limit")
        previews = {}
        for value in ("always", "never"):
            s.run.ui(["activity-preview:" + value])
            previews[value] = s.ui_visibility(marker, "preview-" + value)
        s.note("unicodePayloadTransport", "observed", {"bytes": receipt["bytes"], "truncated": receipt.get("truncated"),
                                                           "qualification": "APNs acceptance does not prove decoding"})
        s.note("previewSettingObservations", "observed", {"visibleInNotificationCenter": previews,
                                                              "qualification": "unlocked presentation only"})
        s.note("unicodeRendering", "observed" if previews.get("always") is True else "unqualified",
               "synthetic Unicode marker must be visible with previews set to Always")
        s.note("lockedPrivacy", "unqualified", "unlocked Notification Center preview is not Lock Screen redaction evidence")
        return

    if row == "L14":
        s.fixture()
        # A state event is attributable to this specific ActivityKit identity
        # only if it appears after a stable pre-send trace prefix. Even then,
        # it is temporal evidence, not proof that APNs caused the end.
        try:
            before_trace = s.trace()
        except (OSError, ValueError, RuntimeError):
            before_trace = None
        receipt = s.send(event="end", text="Synthetic activity ended")
        if not accepted(receipt):
            raise RuntimeError("end push not accepted")
        s.note("endTransport", "observed", "APNs accepted the end request; acceptance does not prove device delivery")
        time.sleep(8)
        s.config("snapshot")
        s.run.ui(["launch"])
        ended = s.capabilities("ended", {"activeActivityCount": 0})
        s.run.ui(["activity-absent"])
        s.note("postEndAbsence", "observed", "no active probe activity and no card after the request")
        registration_cleared = ended.get("registrationPresent") is False and ended.get("updateTokenPresent") is False
        s.note("localRegistrationCleanup", "observed" if registration_cleared else "unqualified",
               {"registrationPresent": ended.get("registrationPresent"), "updateTokenPresent": ended.get("updateTokenPresent")})
        try:
            after_trace = s.trace()
            tail = after_trace[len(before_trace):] if before_trace is not None and after_trace[:len(before_trace)] == before_trace else []
        except (OSError, ValueError, RuntimeError):
            tail = []
        terminal = [event.get("state") for event in tail if event.get("event") == "activity.state"
                    and event.get("activityID") == initial["activityID"] and event.get("state") in ("ended", "dismissed")]
        s.note("sameActivityTerminalState", "observed" if terminal else "unqualified", {"states": terminal})
        s.note("remoteEndCausality", "unqualified", "APNs acceptance and subsequent terminal state or absence do not prove the end push caused it")
        s.end_local()
        second = s.start()
        marker = "Synthetic dismissal " + str(uuid.uuid4())
        update = s.send(text=marker)
        if not accepted(update):
            raise RuntimeError("dismissal marker update not accepted")
        time.sleep(8)
        s.ui_card(marker, "before-dismissal")
        try:
            before_dismissal = s.trace()
        except (OSError, ValueError, RuntimeError):
            before_dismissal = None
        # The UI action rechecks the exact marker within the identified card
        # before dismissing; a replacement card must not be touched.
        s.run.ui(["activity-dismiss"], text=marker)
        s.config("snapshot")
        s.run.ui(["launch"])
        after = s.capabilities("dismissed")
        s.note("userDismissal", "observed", {"scope": "identified card disappeared after a verified marker",
                                               "activeActivityCount": after["activeActivityCount"], "uiAndActivityStateAreDistinct": True})
        try:
            after_dismissal = s.trace()
            dismiss_tail = (after_dismissal[len(before_dismissal):]
                            if before_dismissal is not None and after_dismissal[:len(before_dismissal)] == before_dismissal else [])
        except (OSError, ValueError, RuntimeError):
            dismiss_tail = []
        dismissed_states = [event.get("state") for event in dismiss_tail if event.get("event") == "activity.state"
                            and event.get("activityID") == second["activityID"] and event.get("state") in ("ended", "dismissed")]
        s.note("sameDismissedActivityTerminalState", "observed" if dismissed_states else "unqualified", {"states": dismissed_states})
        dismissed_clear = after.get("activeActivityCount") == 0 and after.get("registrationPresent") is False and after.get("updateTokenPresent") is False
        s.note("dismissalRegistrationCleanup", "observed" if dismissed_clear else "unqualified",
               {"activeActivityCount": after.get("activeActivityCount"), "registrationPresent": after.get("registrationPresent"), "updateTokenPresent": after.get("updateTokenPresent")})
        s.note("logoutConsentExpiry", "simulated", "probe has no production account or eight-hour staging run")
        s.note("actualLogoutConsentExpiry", "unqualified", "requires production account and a sustained staging run")
        return
    raise ValueError("unknown activity case")
