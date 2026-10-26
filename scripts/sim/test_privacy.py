#!/usr/bin/env python3
"""Host-only privacy-grant controls at the shared lifecycle interface."""
import json
import time
import unittest

import test_sim as controls


BUNDLE = 'dev.sim.privacy.fixture'
OTHER_BUNDLE = 'dev.sim.privacy.camera'

# The fake native service owns this permission state, independently of the
# helper's preparation record. A timeout can happen after native mutation.
PERMISSIONS = '''
permissions = native.setdefault('permissions', {})
if step == 'privacy' and len(command) == 5 and command[2] == 'grant' and rule.get('action') != 'failure':
    permissions.setdefault(command[1], {})[command[3] + ':' + command[4]] = True
if step == 'delete' and rule.get('action') != 'failure':
    permissions.pop(command[1], None)
'''


class PrivacyGrantTests(unittest.TestCase):
    def setUp(self):
        self.fixture = controls.LifecycleTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.tearDown)
        executable = self.fixture.root / 'bin/xcrun'
        source = executable.read_text()
        anchor = 'path.write_text(json.dumps(native))'
        self.assertEqual(source.count(anchor), 1)
        executable.write_text(source.replace(anchor, PERMISSIONS + '\n' + anchor))

    def prepare(self, install=True):
        device = self.fixture.create()
        self.fixture.call('boot', device)
        self.fixture.call('bootstatus', device, '-b')
        if install:
            self.fixture.call('install', device, 'privacy-fixture.app')
        return device

    def permissions(self):
        return json.loads((self.fixture.root / 'native.json').read_text())['permissions']

    def cleanup(self):
        self.fixture.cli('cleanup', self.fixture.state, '--timeout', .5)
        self.assertEqual(self.fixture.inventory(), [])
        self.assertEqual(self.permissions(), {})

    def test_timed_out_grant_recovers_on_fresh_device_replays_setup_and_cleans_both(self):
        original = self.prepare()
        self.fixture.rules(dict(step='privacy', action='timeout'))
        self.fixture.call('privacy', original, 'grant', 'microphone', BUNDLE, timeout=.5)
        replacement = self.fixture.current()
        self.assertNotEqual(original, replacement)
        self.assertEqual(self.fixture.calls('privacy'), [
            ['privacy', original, 'grant', 'microphone', BUNDLE],
            ['privacy', replacement, 'grant', 'microphone', BUNDLE]])
        self.assertEqual(self.fixture.calls('boot'), [['boot', original], ['boot', replacement]])
        self.assertEqual(self.fixture.calls('bootstatus'), [
            ['bootstatus', original, '-b'], ['bootstatus', replacement, '-b']])
        self.assertEqual(self.fixture.calls('install'), [
            ['install', original, 'privacy-fixture.app'], ['install', replacement, 'privacy-fixture.app']])
        self.assertEqual(self.permissions(), {replacement: {'microphone:' + BUNDLE: True}})
        summary = self.fixture.summary.read_text()
        self.assertIn('infra:privacy', summary)
        self.assertIn('recovered', summary)
        self.cleanup()
        self.assertEqual(self.fixture.calls('delete'), [['delete', original], ['delete', replacement]])

    def test_prior_setup_recovery_makes_next_grant_failure_final(self):
        original = self.prepare(install=False)
        self.fixture.rules(dict(step='install', action='failure'))
        self.fixture.call('install', original, 'privacy-fixture.app')
        replacement = self.fixture.current()
        self.fixture.rules(dict(step='privacy', action='failure'))
        self.fixture.call('privacy', replacement, 'grant', 'microphone', BUNDLE, expected=73)
        self.assertEqual(len(self.fixture.calls('create')), 2)
        self.assertEqual(self.fixture.calls('privacy'), [
            ['privacy', replacement, 'grant', 'microphone', BUNDLE]])
        self.assertIn('`infra:privacy`: exhausted', self.fixture.summary.read_text())
        self.cleanup()

    def test_grant_recovery_makes_later_install_failure_final(self):
        original = self.prepare()
        self.fixture.rules(dict(step='privacy', action='failure'))
        self.fixture.call('privacy', original, 'grant', 'microphone', BUNDLE)
        replacement = self.fixture.current()
        self.fixture.rules(dict(step='install', at=[3], action='failure'))
        self.fixture.call('install', replacement, 'second.app', expected=73)
        self.assertEqual(len(self.fixture.calls('create')), 2)
        self.assertEqual(self.fixture.calls('install'), [
            ['install', original, 'privacy-fixture.app'], ['install', replacement, 'privacy-fixture.app'],
            ['install', replacement, 'second.app']])
        self.assertIn('`infra:install`: exhausted', self.fixture.summary.read_text())
        self.cleanup()

    def test_grant_recovery_also_consumes_the_eligible_launch_retry(self):
        original = self.prepare()
        self.fixture.rules(dict(step='privacy', action='failure'))
        self.fixture.call('privacy', original, 'grant', 'microphone', BUNDLE)
        replacement = self.fixture.current()
        self.fixture.rules(dict(step='launch', action='launch-rejection'))
        self.fixture.call('launch', '--console', replacement, controls.BUNDLE, expected=3)
        self.assertEqual(len(self.fixture.calls('launch')), 1)
        self.assertEqual(len(self.fixture.calls('create')), 2)
        self.assertIn('`infra:launch`: exhausted', self.fixture.summary.read_text())
        self.cleanup()

    def test_checkpoint_forbids_grant_recovery_even_after_unknown_native_mutation(self):
        original = self.prepare()
        self.fixture.cli('checkpoint', self.fixture.state)
        self.fixture.rules(dict(step='privacy', action='timeout'))
        self.fixture.call('privacy', original, 'grant', 'microphone', BUNDLE, timeout=.5, expected=124)
        self.assertEqual(self.fixture.current(), original)
        self.assertEqual(len(self.fixture.calls('create')), 1)
        self.assertEqual(len(self.fixture.calls('privacy')), 1)
        self.assertEqual(self.permissions(), {original: {'microphone:' + BUNDLE: True}})
        self.assertIn('`infra:privacy`: not eligible', self.fixture.summary.read_text())
        self.cleanup()

    def test_later_install_recovery_replays_services_and_bundles_on_the_fresh_device(self):
        original = self.prepare()
        grants = [('microphone', BUNDLE), ('camera', OTHER_BUNDLE), ('photos', original)]
        for service, bundle in grants:
            self.fixture.call('privacy', original, 'grant', service, bundle)
        self.fixture.rules(dict(step='install', at=[2], action='failure'))
        self.fixture.call('install', original, 'second.app')
        replacement = self.fixture.current()
        expected = [['privacy', device, 'grant', service, bundle]
                    for device in (original, replacement) for service, bundle in grants]
        self.assertEqual(self.fixture.calls('privacy'), expected)
        self.assertEqual(self.permissions(), {replacement: {
            'microphone:' + BUNDLE: True, 'camera:' + OTHER_BUNDLE: True, 'photos:' + original: True}})
        self.cleanup()

    def test_grant_replay_preserves_a_literal_placeholder_bundle(self):
        original = self.prepare()
        self.fixture.call('privacy', original, 'grant', 'microphone', '{simulator}')
        self.fixture.rules(dict(step='install', at=[2], action='failure'))
        self.fixture.call('install', original, 'second.app')
        replacement = self.fixture.current()
        self.assertEqual(self.fixture.calls('privacy'), [
            ['privacy', original, 'grant', 'microphone', '{simulator}'],
            ['privacy', replacement, 'grant', 'microphone', '{simulator}']])
        self.assertEqual(self.permissions(), {replacement: {'microphone:{simulator}': True}})
        self.cleanup()

    def test_grant_retry_changes_only_target_when_bundle_equals_original_uuid(self):
        original = self.prepare()
        self.fixture.rules(dict(step='privacy', action='failure'))
        self.fixture.call('privacy', original, 'grant', 'microphone', original)
        replacement = self.fixture.current()
        self.assertEqual(self.fixture.calls('privacy'), [
            ['privacy', original, 'grant', 'microphone', original],
            ['privacy', replacement, 'grant', 'microphone', original]])
        self.assertEqual(self.permissions(), {replacement: {'microphone:' + original: True}})
        self.cleanup()

    def test_failed_grant_replay_exhausts_budget_without_retrying_original_step(self):
        original = self.prepare()
        self.fixture.call('privacy', original, 'grant', 'microphone', BUNDLE)
        self.fixture.rules(dict(step='privacy', at=[2, 3], action='failure'))
        self.fixture.call('privacy', original, 'grant', 'camera', OTHER_BUNDLE, expected=73)
        replacement = self.fixture.current()
        self.assertEqual(self.fixture.calls('privacy'), [
            ['privacy', original, 'grant', 'microphone', BUNDLE],
            ['privacy', original, 'grant', 'camera', OTHER_BUNDLE],
            ['privacy', replacement, 'grant', 'microphone', BUNDLE]])
        self.assertEqual(len(self.fixture.calls('create')), 2)
        self.assertIn('exhausted during fresh simulator preparation', self.fixture.summary.read_text())
        self.cleanup()

    def test_grant_replay_retains_its_original_bound_instead_of_install_budget(self):
        original = self.prepare()
        self.fixture.call('privacy', original, 'grant', 'microphone', BUNDLE, timeout=.5)
        self.fixture.rules(dict(step='install', at=[2], action='failure'),
                           dict(step='privacy', at=[2], action='timeout'))
        started = time.monotonic()
        self.fixture.call('install', original, 'second.app', timeout=2.5, expected=124)
        self.assertLess(time.monotonic() - started, 2,
                        'privacy replay must retain its .5s bound, not use the 2.5s install bound')
        self.assertEqual(len(self.fixture.calls('privacy')), 2)
        self.assertEqual(len(self.fixture.calls('create')), 2)
        self.assertEqual(len(self.fixture.calls('install')), 3)
        self.assertIn('`infra:privacy`: exhausted during fresh simulator preparation',
                      self.fixture.summary.read_text())
        self.cleanup()

    def test_non_grant_and_malformed_privacy_failures_are_bounded_without_recovery(self):
        original = self.prepare()
        shapes = [('reset', 'all'), ('revoke', 'microphone', BUNDLE),
                  ('grant', 'microphone'), ('grant', 'microphone', BUNDLE, 'extra'),
                  ('grant', '--microphone', BUNDLE), ('grant', 'microphone', '--bundle'),
                  ('grant', '', BUNDLE), ('grant', 'microphone', '')]
        for occurrence, shape in enumerate(shapes, 1):
            with self.subTest(shape=shape):
                self.fixture.rules(dict(step='privacy', at=[occurrence], action='timeout'))
                self.fixture.call('privacy', original, *shape, timeout=.5, expected=124)
                self.assertEqual(len(self.fixture.calls('privacy')), occurrence)
                self.assertEqual(len(self.fixture.calls('create')), 1)
        self.assertNotIn('scheduled', self.fixture.summary.read_text())
        self.cleanup()

    def test_successful_reset_and_revoke_are_not_replayed_with_setup(self):
        original = self.prepare()
        self.fixture.call('privacy', original, 'reset', 'all')
        self.fixture.call('privacy', original, 'revoke', 'microphone', BUNDLE)
        self.fixture.rules(dict(step='install', at=[2], action='failure'))
        self.fixture.call('install', original, 'second.app')
        self.assertNotEqual(self.fixture.current(), original)
        self.assertEqual(self.fixture.calls('privacy'), [
            ['privacy', original, 'reset', 'all'], ['privacy', original, 'revoke', 'microphone', BUNDLE]])
        self.assertEqual(self.permissions(), {})
        self.cleanup()


if __name__ == '__main__':
    unittest.main()
