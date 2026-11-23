"""Tests for the APM profile publisher's staged output validation and native plugin publishing."""

import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
PUBLISHER = REPO / "home/dot_config/apm-profile/apm-profile-publish.py"

spec = importlib.util.spec_from_file_location("apm_profile_publish", PUBLISHER)
publish = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publish)

MARKET = "apm-p-0ce338d3"


def candidate_settings(*plugins):
    return {
        "extraKnownMarketplaces": {MARKET: {"source": {"source": "directory", "path": "./.agents/plugins"}}},
        "enabledPlugins": {f"{name}@{MARKET}": True for name in plugins},
    }


class PublishTestBase(unittest.TestCase):
    def setUp(self):
        self.scratch = Path(tempfile.mkdtemp(prefix="apm-publish-test-")).resolve()
        self.addCleanup(shutil.rmtree, self.scratch, ignore_errors=True)
        self.home = self.scratch / "home"
        self.root = self.scratch / "candidate"
        self.state = self.scratch / "state"
        self.home.mkdir()
        (self.root / ".claude/skills/x").mkdir(parents=True)
        (self.root / ".claude/skills/x/SKILL.md").write_text("skill", encoding="utf-8")
        patcher = mock.patch.object(Path, "home", return_value=self.home)
        patcher.start()
        self.addCleanup(patcher.stop)

    def write(self, rel, text):
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def write_json(self, rel, data):
        return self.write(rel, json.dumps(data))

    def add_plugins(self, *plugins, extra_file=None):
        self.write_json(".agents/plugins/.claude-plugin/marketplace.json", {"name": MARKET, "plugins": []})
        for name in plugins:
            self.write_json(f".agents/plugins/{name}/.claude-plugin/plugin.json", {"name": name})
        if extra_file:
            self.write(extra_file, "x")
        self.write_json(".claude/settings.json", candidate_settings(*plugins))
        self.write_json(".github/copilot/settings.json", candidate_settings(*plugins))

    def run_main(self):
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(sys, "argv", ["apm-profile-publish.py", str(self.root), str(self.state)]):
            with redirect_stdout(out), redirect_stderr(err):
                code = publish.main()
        return code, out.getvalue(), err.getvalue()

    def load(self, rel):
        return json.loads((self.home / rel).read_text(encoding="utf-8"))

    def ledger(self):
        return json.loads((self.state / "ownership.json").read_text(encoding="utf-8"))

    def reset_candidate_plugins(self):
        shutil.rmtree(self.root / ".agents")
        (self.root / ".claude/settings.json").unlink()
        shutil.rmtree(self.root / ".github")


class StagedFilesTest(PublishTestBase):
    def test_github_copilot_settings_are_merged_not_ignored(self):
        self.write_json(".github/copilot/settings.json", candidate_settings("azure"))
        files, mcp, settings, _ = publish.staged_files(self.root)
        self.assertEqual(list(files), [self.home / ".claude/skills/x/SKILL.md"])
        self.assertIsNone(mcp)
        sections = settings[self.home / ".copilot/settings.json"]
        self.assertEqual(sections["enabledPlugins"], {f"azure@{MARKET}": True})
        self.assertEqual(
            sections["extraKnownMarketplaces"][MARKET]["source"]["path"],
            str(self.home / ".agents/plugins"),
        )

    def test_plugins_are_staged_under_home_agents_plugins(self):
        self.add_plugins("azure")
        files, _, settings, _ = publish.staged_files(self.root)
        self.assertIn(self.home / ".agents/plugins/.claude-plugin/marketplace.json", files)
        self.assertIn(self.home / ".agents/plugins/azure/.claude-plugin/plugin.json", files)
        self.assertEqual(set(settings), {self.home / ".claude/settings.json", self.home / ".copilot/settings.json"})

    def test_unknown_github_item_still_aborts(self):
        (self.root / ".github/other").mkdir(parents=True)
        with self.assertRaises(publish.PublishError):
            publish.staged_files(self.root)

    def test_unknown_artifacts_abort(self):
        for rel in (".agents/other/a.txt", ".claude/other/a.txt", ".github/copilot/other.json", ".codex/config.toml"):
            with self.subTest(rel=rel):
                self.write(rel, "x")
                with self.assertRaises(publish.PublishError):
                    publish.staged_files(self.root)
                top = rel.split("/")[0]
                if top == ".claude":
                    shutil.rmtree(self.root / ".claude/other")
                else:
                    shutil.rmtree(self.root / top)

    def test_unknown_settings_key_aborts(self):
        self.write_json(".claude/settings.json", {"hooks": {}})
        with self.assertRaises(publish.PublishError):
            publish.staged_files(self.root)


class PublishPluginsTest(PublishTestBase):
    def test_plugins_copied_and_settings_merged_with_ledger(self):
        self.add_plugins("azure")
        code, out, err = self.run_main()
        self.assertEqual(code, 0, err)
        self.assertTrue((self.home / ".agents/plugins/azure/.claude-plugin/plugin.json").is_file())
        ledger = self.ledger()
        self.assertIn(str(self.home / ".agents/plugins/.claude-plugin/marketplace.json"), ledger["files"])
        for rel in (".claude/settings.json", ".copilot/settings.json"):
            data = self.load(rel)
            self.assertEqual(data["enabledPlugins"], {f"azure@{MARKET}": True})
            self.assertEqual(
                data["extraKnownMarketplaces"][MARKET]["source"],
                {"source": "directory", "path": str(self.home / ".agents/plugins")},
            )
            self.assertEqual(ledger["settings"][str(self.home / rel)]["enabledPlugins"], {f"azure@{MARKET}": True})
        self.assertIn("プラグイン 1 件", out)
        self.assertIn("設定キー 4 件", out)

    def test_plugin_count_is_exact(self):
        self.add_plugins("azure", "other")
        code, out, err = self.run_main()
        self.assertEqual(code, 0, err)
        self.assertIn("プラグイン 2 件", out)
        self.assertIn("設定キー 6 件", out)

    def test_existing_keys_are_preserved(self):
        self.add_plugins("azure")
        settings = self.home / ".claude/settings.json"
        settings.parent.mkdir(parents=True)
        settings.write_text(
            json.dumps({"model": "x", "enabledPlugins": {"other@m": True}, "extraKnownMarketplaces": {"m": {"source": {"source": "git"}}}}),
            encoding="utf-8",
        )
        code, _, err = self.run_main()
        self.assertEqual(code, 0, err)
        data = self.load(".claude/settings.json")
        self.assertEqual(data["model"], "x")
        self.assertEqual(data["enabledPlugins"], {"other@m": True, f"azure@{MARKET}": True})
        self.assertEqual(set(data["extraKnownMarketplaces"]), {"m", MARKET})

    def test_second_run_is_stable(self):
        self.add_plugins("azure")
        self.assertEqual(self.run_main()[0], 0)
        before = (self.home / ".claude/settings.json").read_bytes()
        self.assertEqual(self.run_main()[0], 0)
        self.assertEqual((self.home / ".claude/settings.json").read_bytes(), before)

    def test_removed_candidate_entries_are_deleted_via_ledger(self):
        self.add_plugins("azure", "other")
        settings = self.home / ".claude/settings.json"
        settings.parent.mkdir(parents=True)
        settings.write_text(json.dumps({"enabledPlugins": {"keep@m": True}}), encoding="utf-8")
        self.assertEqual(self.run_main()[0], 0)
        shutil.rmtree(self.root / ".agents/plugins/other")
        self.write_json(".claude/settings.json", candidate_settings("azure"))
        self.write_json(".github/copilot/settings.json", candidate_settings("azure"))
        code, _, err = self.run_main()
        self.assertEqual(code, 0, err)
        data = self.load(".claude/settings.json")
        self.assertEqual(data["enabledPlugins"], {"keep@m": True, f"azure@{MARKET}": True})
        self.assertFalse((self.home / ".agents/plugins/other/.claude-plugin/plugin.json").exists())

    def test_removing_all_plugins_cleans_up_owned_keys_only(self):
        self.add_plugins("azure")
        settings = self.home / ".claude/settings.json"
        settings.parent.mkdir(parents=True)
        settings.write_text(json.dumps({"enabledPlugins": {"keep@m": True}}), encoding="utf-8")
        self.assertEqual(self.run_main()[0], 0)
        self.reset_candidate_plugins()
        code, _, err = self.run_main()
        self.assertEqual(code, 0, err)
        self.assertEqual(self.load(".claude/settings.json"), {"enabledPlugins": {"keep@m": True}})
        # Empty plugin folders are pruned, but ~/.agents itself stays.
        self.assertFalse((self.home / ".agents/plugins").exists())
        self.assertEqual(list((self.home / ".agents").rglob("*")), [])
        self.assertEqual(self.ledger()["settings"], {})
        # The Copilot file only held owned keys, so they are gone.
        self.assertEqual(self.load(".copilot/settings.json"), {})

    def test_unowned_same_name_with_different_value_aborts(self):
        self.add_plugins("azure")
        settings = self.home / ".claude/settings.json"
        settings.parent.mkdir(parents=True)
        original = json.dumps({"enabledPlugins": {f"azure@{MARKET}": False}})
        settings.write_text(original, encoding="utf-8")
        code, _, err = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("azure", err)
        self.assertEqual(settings.read_text(encoding="utf-8"), original)
        self.assertFalse((self.home / ".agents/plugins").exists())

    def test_unowned_same_name_with_same_value_aborts(self):
        self.add_plugins("azure")
        settings = self.home / ".claude/settings.json"
        settings.parent.mkdir(parents=True)
        original = json.dumps({"enabledPlugins": {f"azure@{MARKET}": True}})
        settings.write_text(original, encoding="utf-8")
        code, _, err = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("azure", err)
        self.assertEqual(settings.read_text(encoding="utf-8"), original)
        self.assertFalse((self.home / ".agents").exists())

    def test_hand_edited_owned_key_aborts(self):
        self.add_plugins("azure")
        self.assertEqual(self.run_main()[0], 0)
        settings = self.home / ".claude/settings.json"
        data = self.load(".claude/settings.json")
        data["enabledPlugins"][f"azure@{MARKET}"] = False
        settings.write_text(json.dumps(data), encoding="utf-8")
        before = settings.read_bytes()
        code, _, err = self.run_main()
        self.assertEqual(code, 1)
        self.assertEqual(settings.read_bytes(), before)

    def test_hand_edited_plugin_file_aborts(self):
        self.add_plugins("azure")
        self.assertEqual(self.run_main()[0], 0)
        plugin = self.home / ".agents/plugins/azure/.claude-plugin/plugin.json"
        plugin.write_text("edited", encoding="utf-8")
        code, _, _ = self.run_main()
        self.assertEqual(code, 1)
        self.assertEqual(plugin.read_text(encoding="utf-8"), "edited")

    def test_broken_settings_json_aborts(self):
        self.add_plugins("azure")
        settings = self.home / ".claude/settings.json"
        settings.parent.mkdir(parents=True)
        settings.write_text("{broken", encoding="utf-8")
        code, _, err = self.run_main()
        self.assertEqual(code, 1)
        self.assertEqual(settings.read_text(encoding="utf-8"), "{broken")
        self.assertFalse((self.home / ".agents/plugins").exists())

    def test_legacy_ledger_without_settings_key_is_accepted(self):
        self.add_plugins("azure")
        self.state.mkdir()
        (self.state / "ownership.json").write_text(json.dumps({"files": {}, "mcpServers": {}}), encoding="utf-8")
        code, _, err = self.run_main()
        self.assertEqual(code, 0, err)
        self.assertIn("settings", self.ledger())

    def test_malformed_ledger_settings_aborts(self):
        self.add_plugins("azure")
        self.state.mkdir()
        (self.state / "ownership.json").write_text(json.dumps({"files": {}, "mcpServers": {}, "settings": []}), encoding="utf-8")
        self.assertEqual(self.run_main()[0], 1)

    def test_removing_only_claude_settings_deletes_its_ledger_keys(self):
        self.add_plugins("azure")
        self.assertEqual(self.run_main()[0], 0)
        (self.root / ".claude/settings.json").unlink()
        code, _, err = self.run_main()
        self.assertEqual(code, 0, err)
        self.assertEqual(self.load(".claude/settings.json"), {})
        self.assertEqual(self.load(".copilot/settings.json")["enabledPlugins"], {f"azure@{MARKET}": True})
        self.assertEqual(set(self.ledger()["settings"]), {str(self.home / ".copilot/settings.json")})

    def test_ledger_settings_path_outside_home_aborts(self):
        self.add_plugins("azure")
        self.state.mkdir()
        outside = self.scratch / "outside.json"
        outside.write_text("{}", encoding="utf-8")
        ledger = {"files": {}, "mcpServers": {}, "settings": {str(outside): {"enabledPlugins": {"a@b": True}}}}
        (self.state / "ownership.json").write_text(json.dumps(ledger), encoding="utf-8")
        code, _, _ = self.run_main()
        self.assertEqual(code, 1)
        self.assertEqual(outside.read_text(encoding="utf-8"), "{}")

    def test_ledger_paths_with_dotdot_abort(self):
        self.add_plugins("azure")
        self.state.mkdir()
        outside = self.scratch / "outside.json"
        outside.write_text("{}", encoding="utf-8")
        sneaky = str(self.home / ".." / "outside.json")
        cases = {
            "settings": {"files": {}, "mcpServers": {}, "settings": {sneaky: {"enabledPlugins": {"a@b": True}}}},
            "files": {"files": {sneaky: publish.digest(b"{}")}, "mcpServers": {}, "settings": {}},
        }
        for label, ledger in cases.items():
            with self.subTest(label=label):
                (self.state / "ownership.json").write_text(json.dumps(ledger), encoding="utf-8")
                code, _, _ = self.run_main()
                self.assertEqual(code, 1)
                self.assertEqual(outside.read_text(encoding="utf-8"), "{}")


@unittest.skipIf(os.name == "nt", "POSIX permission bits are not meaningful on Windows")
class PermissionTest(PublishTestBase):
    def test_existing_settings_mode_is_kept_and_new_settings_are_private(self):
        self.add_plugins("azure")
        claude = self.home / ".claude/settings.json"
        claude.parent.mkdir(parents=True)
        claude.write_text("{}", encoding="utf-8")
        os.chmod(claude, 0o640)
        code, _, err = self.run_main()
        self.assertEqual(code, 0, err)
        self.assertEqual(claude.stat().st_mode & 0o777, 0o640)
        self.assertEqual((self.home / ".copilot/settings.json").stat().st_mode & 0o777, 0o600)

    def test_mode_is_restored_on_rollback(self):
        self.add_plugins("azure")
        claude = self.home / ".claude/settings.json"
        claude.parent.mkdir(parents=True)
        claude.write_text("{}", encoding="utf-8")
        os.chmod(claude, 0o600)
        real_replace = os.replace

        def failing_replace(src, dst, *args, **kwargs):
            if Path(dst).parent.name == ".copilot":
                raise OSError("simulated failure")
            return real_replace(src, dst, *args, **kwargs)

        with mock.patch.object(publish.os, "replace", side_effect=failing_replace):
            code, _, _ = self.run_main()
        self.assertEqual(code, 1)
        self.assertEqual(claude.read_text(encoding="utf-8"), "{}")
        self.assertEqual(claude.stat().st_mode & 0o777, 0o600)

    def test_plugin_execute_bits_are_preserved_and_updates_apply(self):
        self.add_plugins("azure")
        script = self.write(".agents/plugins/azure/run.sh", "echo")
        os.chmod(script, 0o755)
        plain = self.write(".agents/plugins/azure/readme.md", "doc")
        os.chmod(plain, 0o644)
        self.assertEqual(self.run_main()[0], 0)
        dest = self.home / ".agents/plugins/azure/run.sh"
        self.assertEqual(dest.stat().st_mode & 0o777, 0o755)
        self.assertEqual((self.home / ".agents/plugins/azure/readme.md").stat().st_mode & 0o111, 0)
        # An execute-bit-only change on the source is applied on the next run.
        os.chmod(script, 0o644)
        os.chmod(plain, 0o755)
        self.assertEqual(self.run_main()[0], 0)
        self.assertEqual(dest.stat().st_mode & 0o111, 0)
        self.assertEqual((self.home / ".agents/plugins/azure/readme.md").stat().st_mode & 0o111, 0o111)

    def test_legacy_link_import_keeps_execute_bits(self):
        profile = self.scratch / "apm-profile"
        agents = profile / "agents"
        agents.mkdir(parents=True)
        script = agents / "helper.sh"
        script.write_text("echo", encoding="utf-8")
        os.chmod(script, 0o755)
        plain = agents / "note.md"
        plain.write_text("doc", encoding="utf-8")
        os.chmod(plain, 0o644)
        (self.home / ".github").mkdir()
        os.symlink(agents, self.home / ".github/agents", target_is_directory=True)
        env = {"APM_AGENTS_DIR": str(agents), "APM_PROFILE_HOME": str(profile)}
        with mock.patch.dict(os.environ, env):
            code, _, err = self.run_main()
        self.assertEqual(code, 0, err)
        for base in (self.home / ".github/agents", self.home / ".copilot/agents"):
            self.assertEqual((base / "helper.sh").stat().st_mode & 0o111, 0o111, base)
            self.assertEqual((base / "note.md").stat().st_mode & 0o111, 0, base)

    def test_execute_bit_is_restored_when_a_deleted_file_is_rolled_back(self):
        self.add_plugins("azure")
        script = self.write(".agents/plugins/azure/run.sh", "echo")
        os.chmod(script, 0o755)
        self.assertEqual(self.run_main()[0], 0)
        script.unlink()
        real_replace = os.replace

        def failing_replace(src, dst, *args, **kwargs):
            if Path(dst).name == "ownership.json":
                raise OSError("simulated failure")
            return real_replace(src, dst, *args, **kwargs)

        with mock.patch.object(publish.os, "replace", side_effect=failing_replace):
            code, _, _ = self.run_main()
        self.assertEqual(code, 1)
        restored = self.home / ".agents/plugins/azure/run.sh"
        self.assertEqual(restored.read_text(encoding="utf-8"), "echo")
        self.assertEqual(restored.stat().st_mode & 0o777, 0o755)


class MarketplacePathTest(PublishTestBase):
    def test_invalid_marketplace_sources_abort(self):
        cases = {
            "parent": {"source": "directory", "path": "../x"},
            "other-relative": {"source": "directory", "path": "./other"},
            "subdir": {"source": "directory", "path": "./.agents/plugins/azure"},
            "dotdot": {"source": "directory", "path": "./.agents/plugins/.."},
            "windows-separator": {"source": "directory", "path": ".\\.agents\\plugins"},
            "absolute": {"source": "directory", "path": "/etc"},
            "relative-non-directory": {"source": "git", "path": "./.agents/plugins"},
        }
        for label, source in cases.items():
            with self.subTest(label=label):
                self.write_json(".claude/settings.json", {"extraKnownMarketplaces": {MARKET: {"source": source}}})
                with self.assertRaises(publish.PublishError):
                    publish.staged_files(self.root)

    def test_git_marketplace_without_path_is_kept(self):
        value = {"source": {"source": "git", "url": "placeholder"}}
        self.write_json(".claude/settings.json", {"extraKnownMarketplaces": {"m": value}})
        _, _, settings, _ = publish.staged_files(self.root)
        self.assertEqual(settings[self.home / ".claude/settings.json"]["extraKnownMarketplaces"], {"m": value})


class LinkAndRollbackTest(PublishTestBase):
    def symlink_or_skip(self, link, target):
        try:
            os.symlink(target, link, target_is_directory=Path(target).is_dir())
        except (OSError, NotImplementedError) as exc:
            if Path(target).is_dir() and sys.platform == "win32":
                import _winapi

                # Junctions need no privilege and exercise the same reparse-point checks.
                _winapi.CreateJunction(str(target), str(link))
                return
            self.skipTest(f"symlink creation is not permitted: {exc}")

    def test_candidate_settings_symlink_aborts(self):
        real = self.scratch / "real-settings.json"
        real.write_text(json.dumps(candidate_settings("azure")), encoding="utf-8")
        self.symlink_or_skip(self.root / ".claude/settings.json", real)
        code, _, err = self.run_main()
        self.assertEqual(code, 1)
        self.assertFalse((self.home / ".claude/settings.json").exists())

    def test_candidate_plugin_tree_symlink_aborts(self):
        real = self.scratch / "real-plugins"
        real.mkdir()
        (self.root / ".agents").mkdir()
        self.symlink_or_skip(self.root / ".agents/plugins", real)
        with self.assertRaises(publish.PublishError):
            publish.staged_files(self.root)

    def test_candidate_junction_is_detected(self):
        try:
            import _winapi

            create_junction = _winapi.CreateJunction
        except (ImportError, AttributeError):
            self.skipTest("junctions need Windows")

        real = self.scratch / "real-plugins"
        real.mkdir()
        (self.root / ".agents").mkdir()
        create_junction(str(real), str(self.root / ".agents/plugins"))
        with self.assertRaises(publish.PublishError):
            publish.staged_files(self.root)

    def test_destination_settings_through_link_aborts(self):
        self.add_plugins("azure")
        elsewhere = self.scratch / "elsewhere"
        elsewhere.mkdir()
        self.symlink_or_skip(self.home / ".claude", elsewhere)
        code, _, err = self.run_main()
        self.assertEqual(code, 1)
        self.assertEqual(list(elsewhere.iterdir()), [])
        self.assertFalse((self.home / ".agents").exists())

    def test_mid_write_failure_restores_settings_plugins_and_folders(self):
        self.add_plugins("azure")
        claude = self.home / ".claude/settings.json"
        claude.parent.mkdir(parents=True)
        original = json.dumps({"model": "x"})
        claude.write_text(original, encoding="utf-8")
        real_replace = os.replace

        def failing_replace(src, dst, *args, **kwargs):
            if Path(dst).name == "settings.json" and Path(dst).parent.name == ".copilot":
                raise OSError("simulated failure")
            return real_replace(src, dst, *args, **kwargs)

        with mock.patch.object(publish.os, "replace", side_effect=failing_replace):
            code, _, err = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("simulated failure", err)
        self.assertEqual(claude.read_text(encoding="utf-8"), original)
        self.assertFalse((self.home / ".agents").exists())
        self.assertFalse((self.home / ".copilot").exists())
        self.assertFalse((self.state / "ownership.json").exists())
        self.assertEqual([p for p in self.home.rglob("*") if p.is_file()], [claude])


if __name__ == "__main__":
    unittest.main()
