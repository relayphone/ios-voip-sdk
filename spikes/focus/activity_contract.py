"""Deterministic server-side Live Activity contract fixtures.

These tests use invented identities, tokens, timestamps, and delivery outcomes.
They do not contact APNs, inspect a device, measure Apple's push budget, or
establish that an ActivityKit update rendered.
"""

from dataclasses import dataclass
import json
from typing import Optional

MAX_PUSH_BYTES = 4096
MAX_ACTIVITY_BYTES = 4096
MAX_SENDS = 60
MAX_ACTIVITY_LIFETIME = 8 * 60 * 60
PRIVATE_PLACEHOLDER = "AI is handling a call"


def _json_bytes(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


@dataclass
class Registration:
    activity_id: str
    surface_id: str
    version: int
    token: str
    environment: str = "sandbox"
    valid: bool = True


class RegistrationStore:
    """Single-surface toy server registry; versions are assigned by the device."""

    def __init__(self):
        self.current = None

    def upsert(self, item):
        if not item.activity_id or not item.surface_id or not item.token or item.version < 1:
            raise ValueError("invalid simulated registration")
        old = self.current
        if old is None:
            self.current = item
            return True
        if (old.activity_id, old.surface_id, old.environment) != (item.activity_id, item.surface_id, item.environment):
            return False
        if item.version < old.version:
            return False
        if item.version == old.version:
            return item.token == old.token and old.valid
        self.current = item
        return True

    def invalidate(self, version):
        """An invalid-token response may revoke only the version actually sent."""
        if self.current is None or version != self.current.version:
            return False
        self.current.valid = False
        return True


class CadenceModel:
    """A configurable simulated priority budget, never Apple's actual budget."""

    def __init__(self, priority10_budget, spacing=5, cap=MAX_SENDS):
        if priority10_budget < 0 or spacing <= 0 or cap < 1 or cap > MAX_SENDS:
            raise ValueError("invalid simulated cadence parameters")
        self.remaining = priority10_budget
        self.spacing = spacing
        self.cap = cap
        self.sent = []
        self.latest_pending = None

    def offer(self, timestamp, revision, priority):
        if priority not in (5, 10):
            raise ValueError("invalid APNs priority")
        self.latest_pending = revision
        if (len(self.sent) >= self.cap or (self.sent and timestamp - self.sent[-1][0] < self.spacing)
                or (priority == 10 and self.remaining == 0)):
            return False
        if priority == 10:
            self.remaining -= 1
        self.sent.append((timestamp, revision, priority))
        self.latest_pending = None
        return True


class SnapshotProjection:
    """Illustrative coalescing model, not a claim about ActivityKit internals."""

    def __init__(self):
        self.latest = None
        self.rendered = None
        self.next_attempt = 0
        self.failures = 0

    def receive(self, revision, timestamp):
        candidate = (revision, timestamp)
        if self.latest is not None and (revision <= self.latest[0] or timestamp <= self.latest[1]):
            return False
        self.latest = candidate
        return True

    def accepted_by_apns(self):
        # Simulated acceptance is a transport outcome; it cannot assert rendering.
        return self.latest

    def producer_failure(self, now):
        self.failures += 1
        self.next_attempt = now + min(60, 5 * (2 ** (self.failures - 1)))
        return self.next_attempt

    def producer_success(self):
        self.failures = 0
        self.next_attempt = 0

    def observe_render(self, revision):
        # A fabricated render event never promotes a superseded snapshot.
        if self.latest is None or revision != self.latest[0]:
            return False
        self.rendered = self.latest
        return True

    def is_stale(self, now, stale_after):
        return self.rendered is None or now >= self.rendered[1] + stale_after


def encode_update(excerpt, *, preview, revision=1, timestamp=100, surface_id="fixture"):
    """Bound a silent update and attributes+state after UTF-8 JSON encoding.

    Retain a Unicode-codepoint prefix when previews are allowed; redact the
    complete excerpt otherwise. JSON is built normally so quotes, backslashes,
    and control characters count as encoded bytes. The ActivityKit combined
    measurement includes JSON container overhead, a conservative fixture bound.
    """
    if not isinstance(excerpt, str) or not isinstance(surface_id, str) or not surface_id:
        raise ValueError("invalid fixture payload")
    if not isinstance(revision, int) or not isinstance(timestamp, int):
        raise ValueError("invalid fixture revision or timestamp")
    source = excerpt if preview else PRIVATE_PLACEHOLDER

    def candidate(count):
        state = {"revision": revision, "excerpt": source[:count], "updatedAt": timestamp}
        body = {"aps": {"timestamp": timestamp, "event": "update", "content-state": state,
                        "stale-date": timestamp + 30}}
        combined = {"attributes": {"surfaceID": surface_id}, "content-state": state}
        return body, _json_bytes(body), _json_bytes(combined)

    body, data, combined = candidate(0)
    if len(data) > MAX_PUSH_BYTES or len(combined) > MAX_ACTIVITY_BYTES:
        raise ValueError("fixed payload exceeds budget")
    low, high = 0, len(source)
    while low < high:
        mid = (low + high + 1) // 2
        _, attempt, activity = candidate(mid)
        if len(attempt) <= MAX_PUSH_BYTES and len(activity) <= MAX_ACTIVITY_BYTES:
            low = mid
        else:
            high = mid - 1
    body, data, combined = candidate(low)
    return {"body": body, "encoded": data, "activityBytes": len(combined),
            "truncated": low < len(source), "redacted": not preview}


@dataclass
class Surface:
    """Contract fixture for local server registration/lifecycle decisions."""

    kind: str
    created_at: int
    session_id: Optional[str]
    consent: bool = True
    registered: bool = True
    ended: bool = False

    def __post_init__(self):
        if self.kind not in ("call", "monitor"):
            raise ValueError("unknown fixture surface")

    def may_update(self, now):
        return (not self.ended and self.consent and self.registered and
                self.created_at <= now < self.created_at + MAX_ACTIVITY_LIFETIME)

    def end_call(self):
        self.session_id = None
        if self.kind == "call":
            self.ended = True
            self.registered = False

    def revoke(self):
        self.consent = False
        self.registered = False
        self.ended = True
        self.session_id = None

    def expire(self, now):
        if now >= self.created_at + MAX_ACTIVITY_LIFETIME:
            self.revoke()


def simulate_row(row):
    """Return redacted fixture evidence for L10–L14, never real device evidence."""
    if row == "L10":
        store = RegistrationStore()
        old = Registration("fixture-activity", "fixture-surface", 1, "fixture-token-a")
        new = Registration("fixture-activity", "fixture-surface", 2, "fixture-token-b")
        checks = {"firstAccepted": store.upsert(old), "rotationAccepted": store.upsert(new),
                  "lateOldRejected": not store.upsert(old),
                  "oldInvalidationIgnored": not store.invalidate(1),
                  "currentValidBeforeInvalidation": store.current.valid,
                  "currentInvalidationAccepted": store.invalidate(2),
                  "currentRevoked": not store.current.valid,
                  "crossSurfaceRejected": not store.upsert(Registration("other-activity", "other-surface", 3, "fixture-token-c"))}
        limitation = "Token rotation, APNs invalid-token behavior, and device discovery are simulated, not observed."
    elif row == "L11":
        model = CadenceModel(priority10_budget=1)
        checks = {"firstSent": model.offer(0, 1, 10), "cadenceCoalesced": not model.offer(1, 2, 5),
                  "budgetExhaustionSimulated": not model.offer(5, 3, 10),
                  "priority5Allowed": model.offer(5, 4, 5), "noAlert": True}
        for timestamp in range(10, 310, 5):
            model.offer(timestamp, timestamp, 5)
        checks["hardCap"] = len(model.sent) == MAX_SENDS and not model.offer(1000, 1000, 5)
        checks["apnsAcceptanceIsNotRender"] = SnapshotProjection().accepted_by_apns() is None
        limitation = "The configured budget and delivery outcomes are synthetic; no system budget or device rendering is measured."
    elif row == "L12":
        state = SnapshotProjection()
        checks = {"newestAccepted": state.receive(2, 102), "olderRejected": not state.receive(1, 101),
                  "apnsAcceptanceNotRender": state.accepted_by_apns() == (2, 102) and state.rendered is None,
                  "staleWhenUnrendered": state.is_stale(120, 30), "initialBackoff": state.producer_failure(100) == 105,
                  "increasingBackoff": state.producer_failure(105) == 115,
                  "latestCoalesced": state.receive(3, 103) and state.latest == (3, 103),
                  "oldRenderRejected": not state.observe_render(2), "latestRenderAccepted": state.observe_render(3),
                  "becomesStale": state.is_stale(134, 30)}
        limitation = "Receipt, ordering, backoff and render events are synthetic; actual ActivityKit rendering remains unqualified."
    elif row == "L13":
        text = ('Private 😀 "quoted" \\ path\n' * 700)
        visible = encode_update(text, preview=True)
        hidden = encode_update(text, preview=False)
        checks = {"bodyWithinLimit": len(visible["encoded"]) <= MAX_PUSH_BYTES,
                  "attributesAndStateWithinLimit": visible["activityBytes"] <= MAX_ACTIVITY_BYTES,
                  "validUTF8JSON": json.loads(visible["encoded"])["aps"]["content-state"]["excerpt"] == visible["body"]["aps"]["content-state"]["excerpt"],
                  "truncatedOnCodepointBoundary": visible["truncated"] and text.startswith(visible["body"]["aps"]["content-state"]["excerpt"]),
                  "previewOffRedacted": b"Private" not in hidden["encoded"] and hidden["body"]["aps"]["content-state"]["excerpt"] == PRIVATE_PLACEHOLDER,
                  "noAlert": "alert" not in visible["body"]["aps"]}
        limitation = "Encoding and privacy are fixture checks; real Lock Screen preview settings and rendering are unobserved."
    elif row == "L14":
        call = Surface("call", 100, "fixture-call")
        monitor = Surface("monitor", 100, "fixture-call")
        checks = {"callInitiallyEligible": call.may_update(101), "monitorInitiallyEligible": monitor.may_update(101)}
        call.end_call(); monitor.end_call()
        checks.update(callEndedAndUnregistered=not call.may_update(101) and call.session_id is None,
                      monitorUnboundAndRetained=monitor.may_update(101) and monitor.session_id is None)
        monitor.expire(100 + MAX_ACTIVITY_LIFETIME)
        checks["monitorExpiresAtOriginalLimit"] = not monitor.may_update(100 + MAX_ACTIVITY_LIFETIME)
        for event in ("logout", "consent", "dismissal"):
            candidate = Surface("monitor", 100, "fixture-call")
            candidate.revoke()
            checks[event + "Revokes"] = not candidate.may_update(101)
        limitation = "End, dismissal, logout, consent and expiry are simulated policy events; no device or server lifecycle was observed."
    else:
        raise ValueError("unsupported simulated activity row")
    return {"row": row, "mode": "simulation", "status": "simulated" if all(checks.values()) else "simulation-failed",
            "checks": checks, "limitations": [limitation]}
