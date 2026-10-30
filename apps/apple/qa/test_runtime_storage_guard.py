"""Filesystem and failure cleanup regressions for the disposable simulator coordinator."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock

from runtime_storage_recovery import exclusive_output, fresh_artifacts, shutdown_and_cleanup, write_evidence


class StorageGuardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="reel-storage-guard-", dir="/tmp")
        self.root = Path(self.temporary.name).resolve()
        self.addCleanup(self.temporary.cleanup)

    def assert_restores_after_shutdown_error(self, process, expected):
        manifest = self.root / "files.json"
        original = b'[{"filename":"existing.pdf"}]'
        manifest.write_bytes(b"{corrupted")
        media = self.root / "existing.pdf"
        media.write_bytes(b"preserved content")
        observed = []

        def cleanup(error):
            observed.append(error)
            manifest.write_bytes(original)
            write_evidence(self.root / "cleanup.json", {"shutdown_error": type(error).__name__})

        with self.assertRaises(expected):
            shutdown_and_cleanup(process, cleanup)
        self.assertEqual(manifest.read_bytes(), original)
        self.assertEqual(media.read_bytes(), b"preserved content")
        self.assertEqual(len(observed), 1)
        self.assertEqual(json.loads((self.root / "cleanup.json").read_text())["shutdown_error"], expected.__name__)

    def test_poll_failure_still_restores(self):
        process = Mock(); process.poll.side_effect = OSError("poll")
        self.assert_restores_after_shutdown_error(process, OSError)

    def test_terminate_failure_still_restores(self):
        process = Mock(); process.poll.return_value = None; process.terminate.side_effect = OSError("terminate")
        self.assert_restores_after_shutdown_error(process, OSError)

    def test_kill_failure_still_restores(self):
        process = Mock(); process.poll.return_value = None
        process.wait.side_effect = subprocess.TimeoutExpired("native-test", 10)
        process.kill.side_effect = OSError("kill")
        self.assert_restores_after_shutdown_error(process, OSError)

    def test_second_wait_timeout_still_restores(self):
        process = Mock(); process.poll.return_value = None
        process.wait.side_effect = [subprocess.TimeoutExpired("native-test", 10), subprocess.TimeoutExpired("native-test", 5)]
        self.assert_restores_after_shutdown_error(process, subprocess.TimeoutExpired)
        process.kill.assert_called_once()

    def test_successful_kill_runs_cleanup_once(self):
        process = Mock(); process.poll.return_value = None
        process.wait.side_effect = [subprocess.TimeoutExpired("native-test", 10), 0]
        cleanup = Mock()
        shutdown_and_cleanup(process, cleanup)
        process.terminate.assert_called_once(); process.kill.assert_called_once(); cleanup.assert_called_once_with(None)

    def test_already_exited_process_runs_cleanup(self):
        process = Mock(); process.poll.return_value = 0
        cleanup = Mock(); shutdown_and_cleanup(process, cleanup)
        process.terminate.assert_not_called(); cleanup.assert_called_once_with(None)

    def test_missing_process_runs_cleanup(self):
        cleanup = Mock(); shutdown_and_cleanup(None, cleanup); cleanup.assert_called_once_with(None)

    def test_cleanup_failure_is_not_swallowed(self):
        cleanup = Mock(side_effect=RuntimeError("restore failed"))
        with self.assertRaisesRegex(RuntimeError, "restore failed"):
            shutdown_and_cleanup(None, cleanup)

    def test_all_existing_artifacts_are_refused_and_preserved(self):
        for index, suffix in enumerate((".xcresult", ".log", ".json", ".cleanup.json", ".private-backup")):
            with self.subTest(suffix=suffix):
                prefix = self.root / ("run" + str(index)); artifact = Path(str(prefix) + suffix)
                artifact.write_bytes(b"previous evidence")
                with self.assertRaisesRegex(ValueError, "existing QA artifacts"):
                    fresh_artifacts(prefix)
                self.assertEqual(artifact.read_bytes(), b"previous evidence")

    def test_all_derived_symlinks_are_refused_even_when_dangling(self):
        for index, suffix in enumerate((".xcresult", ".log", ".json", ".cleanup.json", ".private-backup")):
            with self.subTest(suffix=suffix):
                prefix = self.root / ("link" + str(index)); artifact = Path(str(prefix) + suffix)
                artifact.symlink_to(self.root / "absent-target")
                with self.assertRaisesRegex(ValueError, "existing QA artifacts"):
                    fresh_artifacts(prefix)
                self.assertTrue(artifact.is_symlink()); self.assertFalse(artifact.exists())

    def test_prefix_symlink_and_outside_tmp_are_refused(self):
        prefix = self.root / "redirected"; prefix.symlink_to(self.root / "new-prefix")
        with self.assertRaisesRegex(ValueError, "redirected"):
            fresh_artifacts(prefix)
        with self.assertRaisesRegex(ValueError, "must stay"):
            fresh_artifacts("/Users/shared-result")

    def test_exclusive_output_preserves_existing_file_and_symlink_target(self):
        target = self.root / "old.json"; target.write_bytes(b"private prior evidence")
        link = self.root / "link.json"; link.symlink_to(target)
        for path in (target, link):
            with self.subTest(path=path):
                with self.assertRaises(FileExistsError): exclusive_output(path)
                self.assertEqual(target.read_bytes(), b"private prior evidence")

    def test_fresh_evidence_is_private_and_cannot_be_overwritten(self):
        prefix = self.root / "fresh"; self.assertEqual(fresh_artifacts(prefix), prefix)
        output = Path(str(prefix) + ".json"); write_evidence(output, {"restored": True})
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        with self.assertRaises(FileExistsError): write_evidence(output, {"restored": False})
        self.assertTrue(json.loads(output.read_text())["restored"])


if __name__ == "__main__":
    unittest.main()
