"""Policy/recovery tests; no production, network, or service access."""
import importlib.util
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("deploy", Path(__file__).with_name("deploy.py"))
deploy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deploy)
A, B = "a" * 40, "b" * 40


class DeploymentTests(unittest.TestCase):
    def enterContext(self, manager):
        result = manager.__enter__()
        self.addCleanup(manager.__exit__, None, None, None)
        return result

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.previous = self.root / "old"
        self.previous.mkdir()
        (self.previous / ".release.env").write_text("JOBPILOT_RELEASE_SHA=" + A + "\n")
        (self.root / "current").symlink_to(self.previous)
        (self.root / "enabled").touch()
        self.data = self.root / "data"
        self.data.mkdir()
        self.uploads = self.root / "uploads"
        self.uploads.mkdir()
        for key, value in [("ROOT", self.root), ("DATA", self.data), ("UPLOADS", self.uploads)]:
            self.enterContext(patch.object(deploy, key, value))
        self.addCleanup(self.temporary.cleanup)

    def policy(self):
        for name, value in [("master_tip", B), ("ci_success", True), ("update_mirror", B), ("forward_only", None)]:
            self.enterContext(patch.object(deploy, name, return_value=value))

    def ci_run(self, **overrides):
        result = {"head_sha": B, "head_branch": "master", "event": "push", "path": ".github/workflows/ci.yml",
                  "head_repository": {"full_name": "VELIR5/jobpilot"}, "run_number": 1,
                  "status": "completed", "conclusion": "success"}
        result.update(overrides)
        return result

    def test_ci_requires_exact_push_workflow_and_success(self):
        for change in [{}, {"head_sha": A}, {"event": "pull_request"}, {"head_branch": "other"},
                       {"path": ".github/workflows/other.yml"}, {"conclusion": "failure"},
                       {"head_repository": {"full_name": "someone/fork"}}]:
            with self.subTest(change=change), patch.object(deploy, "api_json", return_value={"workflow_runs": [self.ci_run(**change)]}):
                self.assertEqual(deploy.ci_success(B), not change)

    def test_ci_newer_pending_run_revokes_old_success(self):
        runs = [self.ci_run(), self.ci_run(run_number=2, status="in_progress", conclusion=None)]
        with patch.object(deploy, "api_json", return_value={"workflow_runs": runs}):
            self.assertFalse(deploy.ci_success(B))

    def test_git_environment_ignores_credentials_and_parent_secrets(self):
        with patch.dict(os.environ, {"GITHUB_TOKEN": "secret", "RESEND_API_KEY": "secret"}):
            env = deploy.clean_env()
        self.assertNotIn("GITHUB_TOKEN", env)
        self.assertNotIn("RESEND_API_KEY", env)
        self.assertEqual(env["GIT_CONFIG_GLOBAL"], "/dev/null")
        self.assertNotEqual(env["NPM_CONFIG_USERCONFIG"], env["NPM_CONFIG_GLOBALCONFIG"])

    def test_non_forward_is_rejected(self):
        with patch.object(deploy, "git", return_value=Mock(returncode=1)):
            with self.assertRaisesRegex(RuntimeError, "Non-forward"):
                deploy.forward_only(B, A)

    def test_atomic_pointer_preserves_old_release(self):
        candidate = self.root / "candidate"
        candidate.mkdir()
        deploy.switch(candidate)
        self.assertEqual((self.root / "current").resolve(), candidate)
        self.assertTrue(self.previous.is_dir())

    def test_consistent_sqlite_backup_contains_committed_wal_data(self):
        with sqlite3.connect(self.data / "jobpilot.db") as database:
            database.execute("PRAGMA journal_mode=WAL")
            database.execute("CREATE TABLE evidence(value TEXT)")
            database.execute("INSERT INTO evidence VALUES ('preserved')")
            database.commit()
            backup = deploy.sqlite_backup(B)
        with sqlite3.connect(backup) as copied:
            self.assertEqual(copied.execute("SELECT value FROM evidence").fetchone(), ("preserved",))
        self.assertEqual(backup.stat().st_mode & 0o777, 0o600)

    def test_missing_database_is_not_created(self):
        with self.assertRaisesRegex(RuntimeError, "missing"):
            deploy.sqlite_backup(B)
        self.assertFalse((self.data / "jobpilot.db").exists())

    def test_disabled_and_blocked_never_build(self):
        (self.root / "enabled").unlink()
        with patch.object(deploy, "master_tip") as tip:
            deploy.deploy()
            tip.assert_not_called()
        (self.root / "enabled").touch()
        (self.root / "blocked-sha").write_text(B)
        with patch.object(deploy, "master_tip", return_value=B), patch.object(deploy, "ci_success") as ci:
            deploy.deploy()
            ci.assert_not_called()

    def test_explicit_sha_cannot_select_old_tip(self):
        with patch.object(deploy, "master_tip", return_value=B):
            with self.assertRaisesRegex(RuntimeError, "current master"):
                deploy.deploy(A)

    def test_interrupted_activation_fails_closed(self):
        (self.root / "transaction.json").write_text("{}")
        with self.assertRaisesRegex(RuntimeError, "Interrupted"):
            deploy.deploy()

    def test_dry_run_never_builds_or_restarts(self):
        self.policy()
        with patch.object(deploy, "build_release") as build, patch.object(deploy, "run") as run:
            deploy.deploy(dry_run=True)
            build.assert_not_called()
            run.assert_not_called()

    def test_prepare_builds_without_service_or_migration(self):
        self.policy()
        (self.data / "jobpilot.db").touch()
        (self.root / "enabled").unlink()
        with patch.object(deploy, "build_release", return_value=self.root / B) as build, \
                patch.object(deploy, "run") as run, patch.object(deploy, "migrate") as migration:
            deploy.deploy(prepare=True)
            build.assert_called_once_with(B)
            run.assert_not_called()
            migration.assert_not_called()

    def test_failed_migration_restores_code_without_database_restore(self):
        self.policy()
        (self.data / "jobpilot.db").touch()
        with patch.object(deploy, "build_release", return_value=self.root / B), patch.object(deploy, "run") as run, \
                patch.object(deploy, "sqlite_backup") as backup, \
                patch.object(deploy, "migrate", side_effect=RuntimeError("migration failed")), \
                patch.object(deploy, "restore_runtime") as restore:
            with self.assertRaisesRegex(RuntimeError, "migration failed"):
                deploy.deploy()
            self.assertEqual(run.call_args_list[0].args[0], ["systemctl", "stop", "jobpilot.service"])
            backup.assert_called_once_with(B)
            restore.assert_called_once_with(self.previous)
            self.assertEqual((self.root / "blocked-sha").read_text().strip(), B)
            self.assertFalse((self.root / "transaction.json").exists())


if __name__ == "__main__":
    unittest.main()
