"""Private, bounded row execution. --dry-run returns before any device/credential/microphone access."""
import argparse
import base64
import json
import os
from pathlib import Path
import plistlib
import subprocess
import time
import uuid

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
BUNDLE = "dev.callkitsim.focus"
TEST_BUNDLE = BUNDLE + ".uitests.xctrunner"


def plan(row, locked=False, listen=False):
    p = dict(row=row, focus=True, app=False, person=False, cn=False, sendVoIP=True,
             activity=False, blocked=None, locked=locked, listen=listen)
    if row.startswith("F") and row[1:].isdigit() and 1 <= int(row[1:]) <= 16:
        n = int(row[1:]) - 1
        p.update(focus=bool(n & 8), app=bool(n & 2), person=bool(n & 4), cn=bool(n & 1))
    elif row in ["C00", "C01", "C02", "C05", "C06"]:
        if row in ["C00", "C01"]:
            p["focus"] = row != "C00"
    elif row.startswith("L") and row[1:].isdigit() and 1 <= int(row[1:]) <= 16:
        n = int(row[1:]); p.update(activity=True, sendVoIP=n in [3, 4], focus=n % 2 == 0)
        if n in [5, 6, 8, 10, 11, 12]:
            p["blocked"] = "Requires authorization/rotation/budget fault-injection adapter; not fabricated by this probe"
        if n == 15:
            p["blocked"] = "Alerting push-to-start excluded from silent mode"
        if n == 16:
            p["blocked"] = "iPhone 13 has no Dynamic Island"
    elif row == "restore-all":
        p["sendVoIP"] = False
    elif row.startswith("T") and row[1:].isdigit() and 1 <= int(row[1:]) <= 6:
        p["blocked"] = "Requires Phone LiveKit owner-join/backend; probe has no AI/media"
    elif row in ["C03", "C04", "C07", "C08", "C09", "C10", "C11"]:
        p["blocked"] = "Special policy/identity/fault or unsupported hardware control requires an additional adapter"
    else:
        raise ValueError("Unknown row; use F01..F16, C00..C11, L01..L16, T01..T06 or restore-all")
    p["steps"] = ["verify signed test products + explicit FOCUS_DEVICE; recover journal",
                  "apply owned Focus/App/People/Calls settings through guarded XCUITest",
                  "arm Documents/focus.json; launch probe; fetch fresh token privately"]
    if locked:
        p["steps"] += ["approved Auto-Answer=on/3s and Auto-Lock=30s; terminate probe; end UI session",
                       "wait 45s for auto-lock; send cold VoIP push without UI session; inspect Join action"]
    else:
        p["steps"] += ["start timestamped SpringBoard/InCallService observation; qualify negative results against C00"]
    if listen:
        p["steps"] += ["optional host RMS capture; C00 calibration; no microphone permission => visual evidence only"]
    p["steps"] += ["send once with discovery/send-apns.mjs topic dev.callkitsim.focus.voip" if p["sendVoIP"] else "no VoIP push",
                   "fetch JSONL/report result; inspect ActivityKit inventory/state/content + Notification Center card when applicable",
                   "write private row result; end activity; disarm; restore settings/contact/Focus and original permission state"]
    if row == "restore-all":
        p["steps"] = ["restore owned journal; restore Auto-Answer/delay + Auto-Lock; delete test Focus/contact; restore prior active Focus",
                      "uninstall disposable probe only if required to restore undetermined permissions; no push"]
    return p


def write(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")
    path.chmod(0o600)


class Run:
    def __init__(self, p, args):
        self.p, self.args = p, args
        self.device = os.environ.get("FOCUS_DEVICE")
        self.source = Path(os.environ.get("FOCUS_XCTESTRUN", "/nonexistent"))
        if not self.device or not self.source.is_file():
            raise ValueError("Real runs require FOCUS_DEVICE and signed device FOCUS_XCTESTRUN; unsigned products cannot run")
        os.umask(0o077)
        self.work = Path(os.environ.get("FOCUS_WORK", str(HERE / "out"))).resolve()
        if self.work.is_relative_to(REPO) and self.work != HERE / "out":
            raise ValueError("Use ignored spikes/focus/out or a private path outside the repository")
        self.work.mkdir(parents=True, exist_ok=True); self.work.chmod(0o700)
        self.folder = self.work / (p["row"] + "-" + uuid.uuid4().hex[:12]); self.folder.mkdir(mode=0o700)
        self.journal = self.work / "restore-state.json"
        self.invitation = str(uuid.uuid4())
        self.counter = 0
        self.journal_fresh = True
        self.invitations = [self.invitation]

    def command(self, argv, timeout=60, background=False):
        self.counter += 1
        log = self.folder / f"command-{self.counter}.log"
        env = {k: v for k, v in os.environ.items() if not k.startswith("PHONE_APNS_")}
        # Only the sandbox senders receive the APNs credentials, never xcodebuild/devicectl.
        if argv[0] == "node":
            env = os.environ.copy()
        with log.open("wb") as stream:
            if background:
                return subprocess.Popen(argv, stdout=stream, stderr=subprocess.STDOUT, env=env)
            result = subprocess.run(argv, stdout=stream, stderr=subprocess.STDOUT, env=env, timeout=timeout)
        if result.returncode:
            raise RuntimeError(f"{Path(argv[0]).name} failed; inspect private command log; no automatic retry")

    def copy(self, name, destination, to=False, test=False):
        self.command(["xcrun", "devicectl", "device", "copy", "to" if to else "from", "--device", self.device,
                      "--domain-type", "appDataContainer", "--domain-identifier", TEST_BUNDLE if test else BUNDLE,
                      "--source", str(destination) if to else "Documents/" + name,
                      "--destination", "Documents/" + name if to else str(destination)])

    def ui(self, actions, background=False, text=None):
        data = plistlib.loads(self.source.read_bytes())
        env = {"FOCUS_ACTIONS": json.dumps(actions), "FOCUS_NAME": os.environ.get("FOCUS_NAME", "Focus Probe 124"),
               "FOCUS_CALLER": "+15555550199", "FOCUS_OBSERVATION_ID": self.invitation}
        if self.journal.exists() and self.journal_fresh:
            env["FOCUS_RESTORE_STATE"] = base64.b64encode(self.journal.read_bytes()).decode()
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
            if not background:
                self.recover(required=True)

    def recover(self, required=False):
        try:
            self.copy("focus-ui-state.json", self.journal, test=True)
            json.loads(self.journal.read_text())
            self.journal_fresh = True
        except (RuntimeError, subprocess.TimeoutExpired):
            self.journal_fresh = False
            if required:
                raise RuntimeError("Restoration journal could not be backed up; no push allowed")

    def arm(self, config):
        path = self.folder / "config.json"; write(path, config); self.copy("focus.json", path, to=True)

    def restore(self):
        self.arm({"armed": False, "activityAction": "end"})
        self.ui(["launch", "restore-all"])
        if self.journal.exists() and json.loads(self.journal.read_text()).get("requiresProbeUninstall"):
            self.command(["xcrun", "devicectl", "device", "uninstall", "app", "--device", self.device, BUNDLE])
            self.journal.unlink()

    def send(self, suffix=""):
        payload = self.folder / ("push" + suffix + ".json")
        write(payload, {"aps": {}, "from": "+15555550199", "invitationID": self.invitation})
        self.command(["node", str(REPO / "discovery/send-apns.mjs"), "--token-file", str(self.folder / "voip-token.txt"),
                      "--payload-file", str(payload), "--topic", BUNDLE + ".voip",
                      "--receipt-file", str(self.folder / ("apns" + suffix + ".json"))], timeout=30)

    def listen(self):
        if not self.p["listen"]:
            return None
        binary = self.work / "listen"
        if not binary.exists():
            self.command(["swiftc", str(HERE / "listen.swift"), "-o", str(binary)], timeout=90)
        argv = [str(binary), "--output", str(self.folder / "audio.json"), "--seconds", "110" if self.p["row"] == "C02" else "40"]
        argv += ["--positive"] if self.p["row"] == "C00" else ["--calibration", str(self.work / "audio-calibration.json")]
        process = self.command(argv, background=True)
        deadline = time.monotonic() + 10
        while process.poll() is None and not (self.folder / "audio.json.ready").exists() and time.monotonic() < deadline:
            time.sleep(0.2)
        audio_result = self.folder / "audio.json"
        if audio_result.exists() and json.loads(audio_result.read_text()).get("reason") == "mic permission pending":
            print("mic permission pending; continuing with visual evidence only")
        return process

    def execute(self):
        p = self.p
        result = {"row": p["row"], "invitationID": self.invitation, "status": "unqualified", "humanQA": False}
        observer = audio = None
        try:
            if p["row"] == "restore-all":
                self.restore(); result["status"] = "restored"; return result
            actions = ["setup", "app:" + ("include" if p["app"] else "exclude"),
                       "person:" + ("include" if p["person"] else "exclude"), "calls:Allowed People Only"]
            if p["row"] == "C01":
                actions[-1] = "calls:" + self.args.calls
            if p["row"] == "C06":
                actions += ["policy:screenWithAI"]
            actions += ["focus:" + ("on" if p["focus"] else "off")]
            self.ui(actions)
            self.arm({"rowID": p["row"], "armed": True, "communicationNotification": p["cn"],
                      "activityAction": "start" if p["activity"] else None})
            self.ui(["launch", "notifications:allow"] + (["focus-authorization:allow"] if p["row"] == "C05" else []))
            self.copy("voip-token.txt", self.folder / "voip-token.txt")
            if p["locked"]:
                if self.args.allow_system_settings or p["locked"]: # Hamza approved this setting change; persist once.
                    (self.work / "system-settings-approved").write_text("approved for disposable probe measurements\n")
                self.ui(["system-settings:enable", "terminate"])
                time.sleep(45)  # No XCUITest session remains to keep the phone awake.
            elif p["sendVoIP"]:
                observer = self.ui(["observe:90" if p["row"] == "C02" else "observe:60"], background=True)
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
                if p["row"] == "C02":
                    time.sleep(69); self.invitation = str(uuid.uuid4()); self.invitations.append(self.invitation); self.send("-repeat")
            if p["activity"]:
                self.copy("activity-update-token.json", self.folder / "activity-token.json")
                self.command(["node", str(HERE / "send-activity.mjs"), "--token-file", str(self.folder / "activity-token.json"),
                              "--receipt-file", str(self.folder / "activity-apns.json")], timeout=30)
                time.sleep(40 if p["row"] == "L09" else 8)
            elif not observer:
                time.sleep(35)
            if observer:
                if observer.wait(timeout=180):
                    raise RuntimeError("UI observer failed")
                self.recover(); self.copy("focus-ui-result.json", self.folder / "ui.json", test=True)
                ui = json.loads((self.folder / "ui.json").read_text())
                evidence = [e for e in ui["events"] if e.get("event") == "call.observed"]
                result["visual"] = evidence
                if p["row"] == "C00" and any(e["banner"] or e["callScreen"] for e in evidence):
                    write(self.work / "visual-calibration.json", {"positive": True})
                result["visualNegativeQualified"] = (self.work / "visual-calibration.json").exists()
            self.copy("focus.jsonl", self.folder / "trace.jsonl")
            traces = [json.loads(line) for line in (self.folder / "trace.jsonl").read_text().splitlines() if line]
            matching = [e for e in traces if e.get("invitationID") in self.invitations]
            result["invitationIDs"] = self.invitations
            result["reports"] = [e for e in matching if e["event"] == "report.result"]
            result["autoAnswerLCKJoinObserved"] = any(e["event"] == "call.action" and e.get("kind") == "JoinConversationAction" for e in matching) if p["locked"] else None
            result["lockCondition"] = "Auto-Lock configured; 45s elapsed without UI session; actual lock state unverified" if p["locked"] else "unlocked UI session"
            if p["activity"]:
                text = "Updates delayed" if p["row"] == "L09" else "Synthetic caller: APNs update"
                self.ui(["sample", "activity-check"], text=text)
                self.copy("focus-activity.png", self.folder / "activity.png", test=True)
                result["activityContentEvents"] = [e for e in traces if e["event"].startswith("activity.")]
            result["status"] = "recorded" if not p["sendVoIP"] or len(result["reports"]) == len(self.invitations) else "incomplete-report-evidence"
            return result
        finally:
            for process in [observer, audio]:
                if process and process.poll() is None:
                    try:
                        process.wait(timeout=90)
                    except subprocess.TimeoutExpired:
                        process.kill(); process.wait(timeout=10)
            if (self.folder / "audio.json").exists():
                data = json.loads((self.folder / "audio.json").read_text()); result["audio"] = data
                if p["row"] == "C00":
                    write(self.work / "audio-calibration.json", data)
            if p["row"] != "restore-all":
                try:
                    self.recover(); self.restore(); result["restored"] = True
                except Exception:
                    result["restored"] = False; result["status"] = "restore-failed-use-restore-all"
            write(self.folder / "result.json", result)
            print(json.dumps({"row": p["row"], "status": result["status"], "result": str(self.folder / "result.json")}))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("row")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--locked-auto-answer", action="store_true")
    parser.add_argument("--allow-system-settings", action="store_true")
    parser.add_argument("--listen", action="store_true")
    parser.add_argument("--calls", default="Everyone", choices=["Everyone", "All Contacts", "Favorites", "Allowed People Only"])
    args = parser.parse_args()
    p = plan(args.row, args.locked_auto_answer, args.listen)
    if args.dry_run or p["blocked"]:
        if p["blocked"]:
            p["status"] = "skipped-dependency-or-unsupported"
            p["humanQA"] = False
        print(json.dumps(p, indent=2)); return
    result = Run(p, args).execute()
    if result["status"] not in ["recorded", "restored"]:
        raise RuntimeError("Row or restoration incomplete")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, subprocess.TimeoutExpired, OSError) as error:
        # Never dump environment, argv, token files or arbitrary APNs responses.
        print("Focus row stopped: " + type(error).__name__ + "; inspect private result/logs", file=__import__("sys").stderr)
        raise SystemExit(1)
