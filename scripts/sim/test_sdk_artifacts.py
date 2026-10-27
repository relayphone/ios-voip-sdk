"""Producer/consumer transfer tests; no Apple tools or simulator is used."""
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

HELPER = Path(__file__).resolve().parents[1] / 'ci/sdk_artifacts.py'
spec = importlib.util.spec_from_file_location('sdk_artifacts', HELPER)
artifacts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artifacts)
IDENTITY = dict(sourceCommit='a' * 40, sourceInputsSHA256='b' * 64)


class IdentityInterfaceTests(unittest.TestCase):
    def test_real_sdk_identity_interface_needs_no_dirty_flag(self):
        with tempfile.TemporaryDirectory(prefix='sdk-source-contract-') as temporary:
            root = Path(temporary)
            (root / 'Sources').mkdir(); (root / 'Sources/marker.swift').write_text('fixture input\n')
            for args in (('init',), ('add', '.'), ('commit', '-m', 'fixture')):
                subprocess.run(['git', '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false',
                    '-c', 'user.name=SDK Fixture', '-c', 'user.email=fixture@example.invalid', *args],
                    cwd=root, check=True, timeout=10, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            sdk_identity = artifacts.source_identity
            expected = sdk_identity(root)
            with patch.object(artifacts, 'REPO', root), \
                 patch.object(artifacts, 'source_identity', side_effect=lambda: sdk_identity(root)):
                self.assertEqual(artifacts.source(), expected)


class TransferTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='sdk-transfer-host-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.producer, self.incoming, self.consumer = [self.root / n for n in ('producer', 'incoming', 'consumer')]
        self.producer.mkdir()
        app = self.producer / 'example/Example.app'; app.mkdir(parents=True)
        (app / 'Example').write_bytes(b'compiled-fixture')
        (app / 'Example').chmod(0o775)
        (app / 'Current').symlink_to('Example')
        logs = self.producer / 'build-logs'; logs.mkdir(); (logs / 'example.log').write_text('build passed\n')
        mocked = patch.object(artifacts, 'source', return_value=IDENTITY)
        mocked.start(); self.addCleanup(mocked.stop)
        artifacts.begin('example', self.producer)
        artifacts.pack('example', self.producer, self.incoming)

    def test_artifact_preserves_executable_bytes_modes_and_symlinks(self):
        artifacts.unpack('example', self.consumer, self.incoming)
        app = self.consumer / 'example/Example.app'
        self.assertEqual((app / 'Example').read_bytes(), b'compiled-fixture')
        self.assertEqual((app / 'Example').stat().st_mode & 0o777, 0o775)
        self.assertTrue((app / 'Current').is_symlink())
        self.assertEqual((app / 'Current').read_bytes(), b'compiled-fixture')
        self.assertTrue((self.consumer / 'build-logs/example-artifact.json').is_file())

    def test_modified_archive_is_rejected_before_materialization(self):
        with (self.incoming / 'example.tgz').open('ab') as stream: stream.write(b'tampered')
        with self.assertRaisesRegex(ValueError, 'identity differs'):
            artifacts.unpack('example', self.consumer, self.incoming)
        self.assertFalse(self.consumer.exists())

    def test_different_checkout_is_rejected(self):
        with patch.object(artifacts, 'source', return_value={**IDENTITY, 'sourceCommit': 'c' * 40}):
            with self.assertRaisesRegex(ValueError, 'identity differs'):
                artifacts.unpack('example', self.consumer, self.incoming)
        self.assertFalse(self.consumer.exists())

    def test_incompatible_host_architecture_is_rejected_before_installation(self):
        path = self.incoming / 'example.json'
        receipt = json.loads(path.read_text()); receipt['hostArchitecture'] = 'incompatible'
        path.write_text(json.dumps(receipt))
        with self.assertRaisesRegex(ValueError, 'identity differs'):
            artifacts.unpack('example', self.consumer, self.incoming)
        self.assertFalse(self.consumer.exists())

    def test_duplicate_component_cannot_overwrite_a_previous_product(self):
        artifacts.unpack('example', self.consumer, self.incoming)
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            artifacts.unpack('example', self.consumer, self.incoming)

    def test_archive_cannot_write_outside_the_component_root(self):
        archive = self.incoming / 'example.tgz'
        with tarfile.open(archive, 'w:gz') as bundle:
            item = tarfile.TarInfo('../escape'); item.size = 1
            bundle.addfile(item, io.BytesIO(b'x'))
        receipt = json.loads((self.incoming / 'example.json').read_text())
        receipt['archiveSHA256'] = artifacts.digest(archive)
        (self.incoming / 'example.json').write_text(json.dumps(receipt))
        with self.assertRaisesRegex(ValueError, 'Unexpected'):
            artifacts.unpack('example', self.consumer, self.incoming)
        self.assertFalse((self.root / 'escape').exists())


if __name__ == '__main__':
    unittest.main()
