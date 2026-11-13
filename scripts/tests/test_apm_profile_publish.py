"""Tests for the APM profile publisher's staged output validation."""

import importlib.util
import io
import shutil
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
PUBLISHER = REPO / "home/dot_config/apm-profile/apm-profile-publish.py"

spec = importlib.util.spec_from_file_location("apm_profile_publish", PUBLISHER)
publish = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publish)


class StagedFilesTest(unittest.TestCase):
    def setUp(self):
        self.scratch = Path(tempfile.mkdtemp(prefix="apm-publish-test-")).resolve()
        self.addCleanup(shutil.rmtree, self.scratch, ignore_errors=True)
        self.home = self.scratch / "home"
        self.root = self.scratch / "candidate"
        self.home.mkdir()
        (self.root / ".claude/skills/x").mkdir(parents=True)
        (self.root / ".claude/skills/x/SKILL.md").write_text("skill", encoding="utf-8")
        patcher = mock.patch.object(Path, "home", return_value=self.home)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_github_copilot_is_ignored_with_warning(self):
        (self.root / ".github/copilot").mkdir(parents=True)
        (self.root / ".github/copilot/settings.json").write_text("{}", encoding="utf-8")
        err = io.StringIO()
        with redirect_stderr(err):
            files, mcp = publish.staged_files(self.root)
        self.assertIn(self.home / ".claude/skills/x/SKILL.md", files)
        self.assertEqual(len(files), 1)
        self.assertIsNone(mcp)
        self.assertIn(".github", err.getvalue())

    def test_unknown_github_item_still_aborts(self):
        (self.root / ".github/other").mkdir(parents=True)
        with self.assertRaises(publish.PublishError):
            publish.staged_files(self.root)


if __name__ == "__main__":
    unittest.main()
