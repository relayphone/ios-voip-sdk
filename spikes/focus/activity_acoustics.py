"""Host-only retrospective analysis of a bounded RMS envelope.

No microphone, APNs, file, or device access occurs here. A valid result is only
an energy proxy. It does not establish an alert, ring, vibration, or silence.
"""
import math


def _number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def _percentile95(values):
    values = sorted(values)
    return values[min(len(values) - 1, int(len(values) * 0.95))]


def _unqualified(reason):
    return {"status": "unqualified", "energyAboveThreshold": None, "reason": reason,
            "limitation": "RMS energy cannot prove or rule out an alert, ring, vibration, or silence."}


def classify_activity_audio(envelope, calibration, *, window_start, window_end,
                            expected_binding, max_calibration_gap=7200):
    """Compare an earlier host-wall-clock window with the later C00 control.

    The capture must carry a `binding` copied from the row at capture time; the
    caller must supply that row's expected binding separately. C00's calibration
    must be valid, bound to the same identity, and no more than two hours after
    the measured window by default. Both timestamps use the Mac wall clock;
    this function cannot align a device clock or verify microphone placement.
    """
    if not isinstance(envelope, dict) or not isinstance(calibration, dict):
        return _unqualified("missing-envelope-or-calibration")
    if (not isinstance(expected_binding, dict) or not expected_binding or
            envelope.get("binding") != expected_binding or calibration.get("binding") != expected_binding):
        return _unqualified("binding-mismatch")
    if calibration.get("calibrationValid") is not True:
        return _unqualified("invalid-positive-control")
    threshold, control_quiet, control_signal = (calibration.get(key) for key in ("threshold", "quietP95", "signalP95"))
    if (not all(_number(value) for value in (threshold, control_quiet, control_signal)) or
            control_quiet < 0 or threshold < max(control_quiet * 3, 0.001) or
            control_signal <= max(control_quiet * 3, 0.001) or threshold >= control_signal):
        return _unqualified("invalid-positive-control-threshold")
    started, created = envelope.get("startedAt"), calibration.get("createdAt")
    if (not all(_number(value) for value in (window_start, window_end, started, created, max_calibration_gap)) or
            not 0 < window_end - window_start <= 180 or max_calibration_gap <= 0 or
            window_start < started + 3 or not 0 <= created - window_end <= max_calibration_gap):
        return _unqualified("invalid-window-or-calibration-age")
    raw = envelope.get("samples")
    if not isinstance(raw, list) or not 1 <= len(raw) <= 2000:
        return _unqualified("missing-or-invalid-samples")
    samples = []
    for item in raw:
        if not isinstance(item, dict):
            return _unqualified("invalid-sample")
        timestamp, rms = item.get("wallTime"), item.get("rms")
        if (not _number(timestamp) or not _number(rms) or rms < 0 or timestamp < started - 1 or
                (samples and timestamp <= samples[-1][0])):
            return _unqualified("invalid-or-unordered-sample")
        samples.append((timestamp, rms))
    quiet = [rms for timestamp, rms in samples if started <= timestamp < started + 3]
    window = [(timestamp, rms) for timestamp, rms in samples if window_start <= timestamp <= window_end]
    if (len(quiet) < 15 or len(window) < 15 or window[0][0] - window_start > 0.5 or
            window_end - window[-1][0] > 0.5 or any(b[0] - a[0] > 1.5 for a, b in zip(window, window[1:]))):
        return _unqualified("insufficient-sample-coverage")
    local_quiet = _percentile95(quiet)
    if local_quiet >= threshold:
        return _unqualified("ambient-noise-exceeds-calibration")
    effective_threshold = max(threshold, local_quiet * 3)
    if effective_threshold >= control_signal:
        return _unqualified("ambient-noise-masks-positive-control")
    signal = _percentile95([rms for _, rms in window])
    return {"status": "qualified-energy-proxy", "energyAboveThreshold": signal > effective_threshold,
            "p95RMS": signal, "threshold": effective_threshold, "baselineP95": local_quiet,
            "windowSampleCount": len(window),
            "limitation": "RMS energy cannot prove or rule out an alert, ring, vibration, or silence; same microphone and placement are not verified."}
