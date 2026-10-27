"""Synthetic RMS envelope tests; no microphone, network, or device is used."""
import unittest
from activity_acoustics import classify_activity_audio

BINDING = {"device": "fixture-device", "build": "fixture-build", "provider": "lck", "callerFormat": "e164"}


def fixture(signal=0.01):
    start = 1000.0
    samples = [{"wallTime": start + index / 10, "rms": 0.0001 if index < 30 else signal} for index in range(200)]
    envelope = {"startedAt": start, "samples": samples, "binding": dict(BINDING),
                # Existing listener uses visual-only when no earlier calibration exists.
                "mode": "visual evidence only", "calibrationValid": False}
    calibration = {"calibrationValid": True, "threshold": 0.0025, "quietP95": 0.0001,
                   "signalP95": 0.01, "createdAt": 1030.0, "binding": dict(BINDING)}
    return envelope, calibration


def classify(envelope, calibration, **kwargs):
    return classify_activity_audio(envelope, calibration, window_start=1005.0, window_end=1010.0,
                                   expected_binding=BINDING, **kwargs)


class RetrospectiveActivityAcousticsTests(unittest.TestCase):
    def test_later_positive_control_classifies_only_energy_proxy(self):
        envelope, calibration = fixture()
        result = classify(envelope, calibration)
        self.assertEqual(result["status"], "qualified-energy-proxy")
        self.assertTrue(result["energyAboveThreshold"])
        self.assertNotIn("ringtoneConfirmed", result)
        self.assertIn("cannot prove or rule out", result["limitation"])
        quiet, calibration = fixture(signal=0.0002)
        self.assertIs(classify(quiet, calibration)["energyAboveThreshold"], False)
        self.assertIn("cannot prove or rule out", classify(quiet, calibration)["limitation"])

    def test_unavailable_or_unbound_calibration_is_unknown_not_silence(self):
        envelope, calibration = fixture()
        for changed in [{**calibration, "calibrationValid": False},
                        {**calibration, "binding": {**BINDING, "device": "other"}},
                        {**calibration, "threshold": 0.0},
                        {**calibration, "signalP95": 0.0002},
                        {**calibration, "createdAt": 1009.0},
                        {**calibration, "createdAt": 100000.0}]:
            with self.subTest(changed=changed):
                result = classify(envelope, changed)
                self.assertEqual(result["status"], "unqualified")
                self.assertIsNone(result["energyAboveThreshold"])
        envelope["binding"] = {**BINDING, "build": "other"}
        self.assertEqual(classify(envelope, calibration)["reason"], "binding-mismatch")

    def test_missing_permissions_invalid_samples_and_gaps_do_not_qualify(self):
        _, calibration = fixture()
        for envelope in [{"mode": "visual evidence only", "reason": "mic permission pending", "binding": BINDING},
                         {**fixture()[0], "samples": []},
                         {**fixture()[0], "samples": [{"wallTime": 1000, "rms": float("nan")}]},
                         {**fixture()[0], "samples": list(reversed(fixture()[0]["samples"]))},
                         {**fixture()[0], "samples": [s for s in fixture()[0]["samples"] if not 1006 < s["wallTime"] < 1009]}]:
            with self.subTest(envelope=envelope.get("reason", "samples")):
                result = classify(envelope, calibration)
                self.assertEqual(result["status"], "unqualified")
                self.assertIsNone(result["energyAboveThreshold"])

    def test_high_ambient_noise_and_window_errors_are_unknown(self):
        envelope, calibration = fixture()
        for sample in envelope["samples"][:30]:
            sample["rms"] = 0.003
        self.assertEqual(classify(envelope, calibration)["reason"], "ambient-noise-exceeds-calibration")
        envelope, calibration = fixture()
        calibration["signalP95"] = 0.003
        for sample in envelope["samples"][:30]:
            sample["rms"] = 0.002
        self.assertEqual(classify(envelope, calibration)["reason"], "ambient-noise-masks-positive-control")
        envelope, calibration = fixture()
        result = classify_activity_audio(envelope, calibration, window_start=1001.0, window_end=1002.0, expected_binding=BINDING)
        self.assertEqual(result["reason"], "invalid-window-or-calibration-age")
        result = classify_activity_audio(envelope, calibration, window_start=1005.0, window_end=1006.0,
                                         expected_binding=BINDING, max_calibration_gap=float("inf"))
        self.assertEqual(result["status"], "unqualified")


if __name__ == "__main__":
    unittest.main()
