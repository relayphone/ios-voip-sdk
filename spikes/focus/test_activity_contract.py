"""Host-only behavior checks; these are not ActivityKit device tests."""
import json
import unittest

from activity_contract import (
    CadenceModel,
    MAX_ACTIVITY_LIFETIME,
    MAX_SENDS,
    Registration,
    RegistrationStore,
    SnapshotProjection,
    Surface,
    encode_update,
    simulate_row,
)


class ActivityContractTests(unittest.TestCase):
    def test_registration_rejects_old_cross_surface_and_stale_invalidation(self):
        store = RegistrationStore()
        a = Registration("a", "surface", 1, "synthetic-a")
        b = Registration("a", "surface", 2, "synthetic-b")
        self.assertTrue(store.upsert(a))
        self.assertTrue(store.upsert(b))
        self.assertFalse(store.upsert(a))
        self.assertFalse(store.upsert(Registration("a", "other", 3, "synthetic-c")))
        self.assertFalse(store.invalidate(1))
        self.assertEqual((store.current.version, store.current.valid), (2, True))
        self.assertTrue(store.invalidate(2))
        self.assertFalse(store.current.valid)
        self.assertFalse(store.upsert(b))  # An invalid token is not revived by a duplicate upsert.
        self.assertTrue(store.upsert(Registration("a", "surface", 3, "synthetic-c")))

    def test_cadence_cap_and_coalescing_do_not_claim_apple_budget(self):
        model = CadenceModel(priority10_budget=1)
        self.assertTrue(model.offer(0, 1, 10))
        self.assertFalse(model.offer(1, 2, 5))
        self.assertFalse(model.offer(5, 3, 10))
        self.assertEqual(model.latest_pending, 3)
        self.assertTrue(model.offer(5, 4, 5))
        for t in range(10, 310, 5):
            model.offer(t, t, 5)
        self.assertEqual(len(model.sent), MAX_SENDS)
        self.assertFalse(model.offer(1000, 1000, 5))
        with self.assertRaises(ValueError):
            CadenceModel(priority10_budget=1, cap=61)

    def test_acceptance_is_not_render_and_old_revision_cannot_be_promoted(self):
        state = SnapshotProjection()
        self.assertTrue(state.receive(8, 100))
        self.assertEqual(state.accepted_by_apns(), (8, 100))
        self.assertIsNone(state.rendered)
        self.assertTrue(state.is_stale(101, 30))
        self.assertFalse(state.receive(7, 101))
        self.assertFalse(state.receive(9, 99))
        self.assertEqual(state.producer_failure(10), 15)
        self.assertEqual(state.producer_failure(15), 25)
        self.assertTrue(state.receive(9, 110))
        self.assertFalse(state.observe_render(8))
        self.assertTrue(state.observe_render(9))
        self.assertFalse(state.is_stale(139, 30))
        self.assertTrue(state.is_stale(140, 30))

    def test_payload_uses_encoded_bytes_and_redacts_before_size_check(self):
        source = '😀"\\\n' * 4000
        result = encode_update(source, preview=True)
        payload = json.loads(result["encoded"].decode("utf-8"))
        excerpt = payload["aps"]["content-state"]["excerpt"]
        self.assertTrue(source.startswith(excerpt))
        self.assertTrue(result["truncated"])
        self.assertLessEqual(len(result["encoded"]), 4096)
        self.assertLessEqual(result["activityBytes"], 4096)
        self.assertNotIn("alert", payload["aps"])
        private = encode_update("secret-private-😀", preview=False)
        self.assertNotIn(b"secret-private", private["encoded"])
        self.assertTrue(private["redacted"])
        with self.assertRaises(ValueError):
            encode_update("x", preview=True, surface_id="x" * 5000)

    def test_surface_retirement_and_monitor_expiry_are_terminal(self):
        call = Surface("call", 100, "session")
        self.assertTrue(call.may_update(101))
        call.end_call()
        self.assertFalse(call.may_update(101))
        monitor = Surface("monitor", 100, "session")
        monitor.end_call()
        self.assertTrue(monitor.may_update(100 + MAX_ACTIVITY_LIFETIME - 1))
        self.assertIsNone(monitor.session_id)
        monitor.expire(100 + MAX_ACTIVITY_LIFETIME)
        self.assertFalse(monitor.may_update(100 + MAX_ACTIVITY_LIFETIME))
        monitor.consent = True  # A revoked registration must not revive by toggling consent alone.
        self.assertFalse(monitor.may_update(101))

    def test_matrix_reports_simulated_not_device_success(self):
        for row in ["L10", "L11", "L12", "L13", "L14"]:
            with self.subTest(row=row):
                outcome = simulate_row(row)
                self.assertEqual(outcome["status"], "simulated")
                self.assertEqual(outcome["mode"], "simulation")
                self.assertTrue(all(outcome["checks"].values()))
                self.assertTrue(outcome["limitations"])
                self.assertNotIn("fixture-token", json.dumps(outcome))
        with self.assertRaises(ValueError):
            simulate_row("L15")


if __name__ == "__main__":
    unittest.main()
