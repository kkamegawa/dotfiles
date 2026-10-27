"""Integration tests for Git's managed config include.

Run with: python -m unittest scripts.tests.test_gitconfig_merge
"""

from __future__ import annotations

import os
import platform
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CHEZMOI = shutil.which("chezmoi")
GIT = shutil.which("git")


@unittest.skipUnless(CHEZMOI and GIT, "chezmoi and git are required")
class GitConfigMergeTests(unittest.TestCase):
    def setUp(self) -> None:
        scratch_root = Path(__file__).resolve().parent / ".tmp"
        scratch_root.mkdir(exist_ok=True)
        self.temp = Path(tempfile.mkdtemp(prefix="gitconfig-merge-", dir=scratch_root))
        self.addCleanup(shutil.rmtree, self.temp, ignore_errors=True)
        self.destination = self.temp / "home"
        self.destination.mkdir()
        self.bin = self.temp / "bin"
        self.bin.mkdir()
        self.git_global = self.temp / "gitconfig-global"
        self.git_global.write_text("", encoding="utf-8")
        self.config = self.temp / "chezmoi.toml"
        self.state = self.temp / "state.db"
        self._write_config("windows")

    def _write_config(self, os_name: str, *, credential_store: str | None = None) -> None:
        data = {
            "windows": (True, False, False),
            "darwin": (False, True, False),
            "linux": (False, False, True),
        }[os_name]
        lines = [
            "[data]",
            f"isWindows = {str(data[0]).lower()}",
            f"isMac = {str(data[1]).lower()}",
            f"isLinux = {str(data[2]).lower()}",
            "isWSL = false",
            "isDevContainer = false",
        ]
        self.config.write_text("\n".join(lines) + "\n", encoding="utf-8")
        self.git_global.write_text(
            "[credential]\n"
            + (f"  credentialStore = {credential_store}\n" if credential_store else ""),
            encoding="utf-8",
        )

    def _env(self) -> dict[str, str]:
        result = os.environ.copy()
        result["PATH"] = str(self.bin) + os.pathsep + result.get("PATH", "")
        # Git expands the include's home-relative path against these variables.
        result["HOME"] = str(self.destination)
        result["USERPROFILE"] = str(self.destination)
        result["GIT_CONFIG_GLOBAL"] = str(self.git_global)
        result["GIT_CONFIG_NOSYSTEM"] = "1"
        result.pop("GCM_CREDENTIAL_STORE", None)
        result.pop("GITHUB_TOKEN", None)
        result.pop("GH_TOKEN", None)
        return result

    def _install_fake_gcm(self) -> None:
        # LookPath only needs to find the executable; tests never invoke GCM.
        if os.name == "nt":
            (self.bin / "git-credential-manager.exe").write_bytes(b"")
        else:
            executable = self.bin / "git-credential-manager"
            executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            executable.chmod(0o755)

    def _apply(self, target: Path) -> subprocess.CompletedProcess[str]:
        target.parent.mkdir(parents=True, exist_ok=True)
        chezmoi_env = self._env()
        # Isolate LookPath so a host-installed GCM cannot change simulated OS results.
        chezmoi_env["PATH"] = os.pathsep.join((str(self.bin), str(Path(GIT).parent)))
        return subprocess.run(
            [
                CHEZMOI,
                "--source", str(REPO),
                "--destination", str(self.destination),
                "--persistent-state", str(self.state),
                "--config", str(self.config),
                "--no-tty",
                "apply", str(target),
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
            env=chezmoi_env,
            cwd=self.destination,
        )

    def _apply_gitconfig(self) -> None:
        result = self._apply(self.destination / ".gitconfig")
        self.assertEqual(result.returncode, 0, result.stderr)

    def _apply_managed_config(self) -> None:
        result = self._apply(self.destination / ".config/git/dotfiles.gitconfig")
        self.assertEqual(result.returncode, 0, result.stderr)

    def _values(self, key: str) -> list[str]:
        result = subprocess.run(
            [GIT, "config", "--file", str(self.destination / ".gitconfig"),
             "--includes", "--get-all", key],
            capture_output=True,
            text=True,
            encoding="utf-8",
            env=self._env(),
            cwd=self.destination,
        )
        if result.returncode == 1:
            return []
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.splitlines()

    def _apply_both(self) -> None:
        self._apply_gitconfig()
        self._apply_managed_config()

    def test_adds_one_include_and_preserves_local_config_byte_for_byte(self) -> None:
        original = (
            "# Keep local editor and helper setup\r\n"
            "[core]\r\n\teditor = \"C:/Tools/editor.exe\" --wait\r\n"
            "[credential]\r\n\thelper = custom-helper\r\n"
            "\thelper = second-helper\r\n"
            "[include]\r\n\tpath = ~/.config/git/local.gitconfig\r\n"
        ).encode("utf-8")
        path = self.destination / ".gitconfig"
        path.write_bytes(original)

        self._apply_both()

        result = path.read_bytes()
        self.assertTrue(result.startswith(original))
        self.assertEqual(result.count(b"[include]"), 2)
        self.assertEqual(result.count(b"~/.config/git/dotfiles.gitconfig"), 1)
        self.assertEqual(self._values("core.editor"), ["C:/Tools/editor.exe --wait"])
        helpers = self._values("credential.helper")
        self.assertEqual(helpers[:2], ["custom-helper", "second-helper"])
        self.assertEqual(helpers[-2:], ["", "manager"])
        for host in ("github.com", "gist.github.com"):
            self.assertEqual(
                self._values(f"credential.https://{host}.helper"), ["", "manager"]
            )
        self.assertIn("~/.config/git/local.gitconfig", self._values("include.path"))

    def test_include_injection_is_idempotent_across_reapplication(self) -> None:
        path = self.destination / ".gitconfig"
        path.write_text("[user]\n  name = Local Name\n", encoding="utf-8")

        self._apply_both()
        first = path.read_bytes()
        managed = (self.destination / ".config/git/dotfiles.gitconfig").read_bytes()
        self._apply_both()

        self.assertEqual(path.read_bytes(), first)
        self.assertEqual((self.destination / ".config/git/dotfiles.gitconfig").read_bytes(), managed)
        self.assertEqual(first.count(b"~/.config/git/dotfiles.gitconfig"), 1)
        self.assertEqual(self._values("user.name")[-1], "Kazushi Kamegawa")

    def test_existing_managed_include_after_local_helper_moves_to_end_once(self) -> None:
        path = self.destination / ".gitconfig"
        original = (
            "[include]\n  path = ~/.config/git/dotfiles.gitconfig\n"
            "[credential]\n  helper = local-helper\n"
        ).encode("utf-8")
        path.write_bytes(original)

        self._apply_both()

        first = path.read_bytes()
        self.assertTrue(first.startswith(b"[include]\n"))
        self.assertEqual(first.count(b"~/.config/git/dotfiles.gitconfig"), 1)
        self.assertLess(first.index(b"helper = local-helper"), first.index(b"path = ~/.config/git/dotfiles.gitconfig"))
        helpers = self._values("credential.helper")
        self.assertEqual(helpers, ["local-helper", "", "manager"])
        self.assertEqual(helpers[-2:], ["", "manager"])

        self._apply_both()
        self.assertEqual(path.read_bytes(), first)
        self.assertEqual(path.read_bytes().count(b"~/.config/git/dotfiles.gitconfig"), 1)

    def test_fresh_install_generates_valid_git_config(self) -> None:
        self._apply_both()
        self.assertTrue((self.destination / ".gitconfig").is_file())
        self.assertTrue((self.destination / ".config/git/dotfiles.gitconfig").is_file())
        self.assertEqual(self._values("init.defaultbranch"), ["main"])

    def test_windows_and_macos_use_gcm_and_keep_github_cli_helpers(self) -> None:
        self._install_fake_gcm()
        for os_name in ("windows", "darwin"):
            with self.subTest(os=os_name):
                self._write_config(os_name)
                self._apply_both()
                helpers = self._values("credential.helper")
                self.assertIn("manager", helpers)
                for host in ("github.com", "gist.github.com"):
                    self.assertEqual(
                        self._values(f"credential.https://{host}.helper"), ["", "manager"]
                    )

    def test_linux_uses_gcm_only_when_it_and_a_credential_store_are_available(self) -> None:
        self._install_fake_gcm()
        self._write_config("linux")
        self.destination.joinpath(".gitconfig").write_text(
            "[credential]\n  credentialStore = secretservice\n", encoding="utf-8"
        )
        self._apply_both()
        self.assertIn("manager", self._values("credential.helper"))
        self.assertEqual(self._values("credential.credentialstore"), ["secretservice"])

        # Linux with no configured secure store keeps its prior helper chain intact.
        self.destination = self.temp / "other-home"
        self.destination.mkdir()
        self.state = self.temp / "other-state.db"
        self._write_config("linux")
        self.git_global = self.temp / "other-git-global"
        self.git_global.write_text("", encoding="utf-8")
        gitconfig = self.destination / ".gitconfig"
        gitconfig.write_text("[credential]\n  helper = local-helper\n", encoding="utf-8")
        self._apply_both()
        helpers = self._values("credential.helper")
        self.assertIn("local-helper", helpers)
        self.assertNotIn("manager", helpers)

    def test_nonexistent_gcm_is_not_configured_on_linux(self) -> None:
        self._write_config("linux")
        self.destination.joinpath(".gitconfig").write_text(
            "[credential]\n  credentialStore = secretservice\n", encoding="utf-8"
        )
        self._apply_both()
        self.assertNotIn("manager", self._values("credential.helper"))

    def test_malformed_local_gitconfig_is_not_rewritten(self) -> None:
        path = self.destination / ".gitconfig"
        original = b"[credential\n  helper = local-helper\n"
        path.write_bytes(original)

        result = self._apply(path)

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(path.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
