#!/usr/bin/env python3
"""成功した APM のステージング結果をユーザーのスキル・設定フォルダーへ反映する。"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import sys
import tempfile
import uuid
from pathlib import Path
from typing import Any


# Sections of the APM-generated settings.json files that are merged key by key into the user settings.
SETTINGS_SECTIONS = ("extraKnownMarketplaces", "enabledPlugins")
# Relative marketplace path APM writes for the native plugin tree; rewritten to the user profile.
PLUGINS_RELATIVE = "./.agents/plugins"


class PublishError(Exception):
    pass


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise PublishError(f"JSON 設定 {path} を読み込めません: {exc}") from exc


def require_safe_tree(path: Path) -> None:
    if not path.exists() and not is_reparse(path):
        return
    if is_reparse(path) or not path.is_dir():
        raise PublishError(f"実フォルダーが必要です: {path}")
    for item in path.rglob("*"):
        if is_reparse(item):
            raise PublishError(f"APM 出力にシンボリックリンクが含まれるため、反映を中止します: {item}")


def validate_apm_local_identity(path: Path) -> None:
    """Validate and ignore APM's local installation identity metadata."""
    if not path.exists() and not is_reparse(path):
        return
    if is_reparse(path) or not path.is_dir():
        raise PublishError(f"APM のローカル識別情報は実フォルダーである必要があります: {path}")

    expected = {".gitignore", "installation"}
    actual: set[str] = set()
    for item in path.iterdir():
        if item.name not in expected:
            raise PublishError(f"APM のローカル識別情報に未対応の項目があります: {item}")
        if is_reparse(item) or not item.is_file():
            raise PublishError(f"APM のローカル識別情報は直下の通常ファイルのみ許可します: {item}")
        actual.add(item.name)

    if actual != expected:
        missing = ", ".join(sorted(expected - actual))
        raise PublishError(f"APM のローカル識別情報に必要なファイルがありません: {missing}")


def is_reparse(path: Path) -> bool:
    try:
        mode = path.lstat()
        return path.is_symlink() or bool(getattr(mode, "st_file_attributes", 0) & 0x400)
    except FileNotFoundError:
        return False


def known_legacy_links(home: Path) -> dict[Path, Path]:
    config_home = Path(os.environ.get("XDG_CONFIG_HOME", home / ".config"))
    profile_home = Path(os.environ.get("APM_PROFILE_HOME", config_home / "apm"))
    expected = {
        home / ".github/agents": Path(os.environ.get("APM_AGENTS_DIR", profile_home / "agents")),
        home / ".copilot/skills": Path(os.environ.get("APM_SKILLS_DIR", profile_home / "skills")),
    }
    result: dict[Path, Path] = {}
    for link, destination in expected.items():
        if not is_reparse(link):
            continue
        try:
            actual = link.resolve(strict=True)
            wanted = destination.expanduser().resolve(strict=False)
        except OSError as exc:
            raise PublishError(f"旧 APM リンク {link} を解決できません: {exc}") from exc
        if actual != wanted:
            raise PublishError(f"不明なプロファイルリンクがあるため反映を中止します (変更しません): {link}")
        if not actual.is_dir():
            raise PublishError(f"旧 APM リンクの参照先がフォルダーではありません: {actual}")
        result[link] = actual
    return result


def import_legacy_tree(source: Path, destinations: list[Path], forced_destinations: set[Path], files: dict[Path, bytes]) -> set[Path]:
    require_safe_tree(source)
    imported: set[Path] = set()
    for file in source.rglob("*"):
        if file.is_file():
            tail = file.relative_to(source)
            data = file.read_bytes()
            for destination in destinations:
                output = destination / tail
                files.setdefault(output, data)
                if destination in forced_destinations:
                    imported.add(output)
    return imported


def rewrite_marketplace_paths(value: Any, home: Path) -> Any:
    """Return a copy of a marketplace entry with the relative plugin path made absolute."""
    if not isinstance(value, dict) or not isinstance(value.get("source"), dict):
        raise PublishError(f"マーケットプレース登録の形式が正しくありません: {value!r}")
    result = json.loads(json.dumps(value))
    source = result["source"]
    if source.get("source") == "directory":
        # Only the exact plugin tree published by this script may be registered.
        if source.get("path") != PLUGINS_RELATIVE:
            raise PublishError(f"未対応のマーケットプレース path です: {source.get('path')!r}")
        source["path"] = str(home / ".agents/plugins")
    elif "path" in source:
        raise PublishError(f"directory 以外のマーケットプレースに path は指定できません: {source.get('path')!r}")
    return result


def read_settings_source(path: Path, home: Path) -> dict[str, dict[str, Any]]:
    """Read an APM-generated settings.json and return the supported sections with absolute paths."""
    if is_reparse(path) or not path.is_file():
        raise PublishError(f"{path.name} の形式には対応していません: {path}")
    config = read_json(path, {})
    if not isinstance(config, dict):
        raise PublishError(f"APM 設定 {path} はオブジェクトである必要があります")
    unknown = sorted(set(config) - set(SETTINGS_SECTIONS))
    if unknown:
        raise PublishError(f"未対応の APM 設定キーがあります: {path}: {', '.join(unknown)}")
    result: dict[str, dict[str, Any]] = {}
    for section in SETTINGS_SECTIONS:
        values = config.get(section, {})
        if not isinstance(values, dict):
            raise PublishError(f"APM 設定 {path} の {section} はオブジェクトである必要があります")
        if section == "extraKnownMarketplaces":
            values = {name: rewrite_marketplace_paths(value, home) for name, value in values.items()}
        result[section] = values
    return result


def staged_files(root: Path) -> tuple[dict[Path, bytes], dict[str, Any] | None, dict[Path, dict[str, dict[str, Any]]]]:
    """宛先別ファイル、任意の Copilot MCP サーバーマップ、宛先別の設定マージ内容を返す。"""
    root_allowed = {"apm.yml", "apm.lock.yaml", "apm_modules", ".gitignore", ".apm-local", ".agents", ".claude", ".github", ".codex"}
    for item in root.iterdir():
        if item.name not in root_allowed:
            raise PublishError(f"未対応の APM 出力です: {item.name}")

    # APM writes this installation identity beside redirected --root output.
    # It is local bookkeeping and must never be copied into user profiles.
    validate_apm_local_identity(root / ".apm-local")

    output: dict[Path, bytes] = {}
    # Execute bits (st_mode & 0o111) of the staged source files, restored when publishing.
    modes: dict[Path, int] = {}
    mcp: dict[str, Any] | None = None
    settings: dict[Path, dict[str, dict[str, Any]]] = {}
    maps = {
        Path(".agents/skills"): [Path.home() / ".agents/skills"],
        Path(".agents/plugins"): [Path.home() / ".agents/plugins"],
        Path(".claude/skills"): [Path.home() / ".claude/skills"],
        Path(".claude/agents"): [Path.home() / ".claude/agents"],
        Path(".claude/rules"): [Path.home() / ".claude/rules"],
        Path(".claude/commands"): [Path.home() / ".claude/commands"],
        Path(".github/agents"): [Path.home() / ".copilot/agents", Path.home() / ".github/agents"],
        Path(".github/instructions"): [Path.home() / ".copilot/instructions"],
        Path(".github/hooks"): [Path.home() / ".copilot/hooks"],
    }

    for source, destinations in maps.items():
        src = root / source
        require_safe_tree(src)
        if not src.exists():
            continue
        for file in src.rglob("*"):
            if not file.is_file():
                continue
            tail = file.relative_to(src)
            for destination in destinations:
                output[destination / tail] = file.read_bytes()
                modes[destination / tail] = file.stat().st_mode & 0o111

    # APM の Copilot 用 MCP 出力はサーバー名単位でユーザー設定へ統合する。
    mcp_source = root / ".github/mcp.json"
    if mcp_source.exists():
        if mcp_source.is_symlink() or not mcp_source.is_file():
            raise PublishError(".github/mcp.json の形式には対応していません")
        config = read_json(mcp_source, {})
        if not isinstance(config, dict) or not isinstance(config.get("mcpServers"), dict):
            raise PublishError(".github/mcp.json の mcpServers はオブジェクトである必要があります")
        mcp = config["mcpServers"]

    generated_instructions = root / ".github/copilot-instructions.md"
    if generated_instructions.exists():
        if generated_instructions.is_symlink() or not generated_instructions.is_file():
            raise PublishError(".github/copilot-instructions.md の形式には対応していません")
        output[Path.home() / ".copilot/copilot-instructions.md"] = generated_instructions.read_bytes()

    # Native plugin registration: merge the generated settings into the user settings of each tool.
    claude_settings = root / ".claude/settings.json"
    if claude_settings.exists() or is_reparse(claude_settings):
        settings[Path.home() / ".claude/settings.json"] = read_settings_source(claude_settings, Path.home())
    copilot_dir = root / ".github/copilot"
    if copilot_dir.exists() or is_reparse(copilot_dir):
        require_safe_tree(copilot_dir)
        for item in copilot_dir.iterdir():
            if item.name != "settings.json":
                raise PublishError(f"未対応の APM 成果物です: {item.relative_to(root)}")
        copilot_settings = copilot_dir / "settings.json"
        if copilot_settings.exists():
            settings[Path.home() / ".copilot/settings.json"] = read_settings_source(copilot_settings, Path.home())

    # 対応済みのツリー・設定・MCP 出力以外は反映せず、エラーにする。
    allowed = {
        ".agents": {"skills", "plugins"},
        ".claude": {"skills", "agents", "rules", "commands", "settings.json"},
        ".github": {"agents", "instructions", "hooks", "mcp.json", "copilot-instructions.md", "copilot"},
        ".codex": set(),
    }
    for top, names in allowed.items():
        base = root / top
        if not base.exists():
            continue
        for item in base.iterdir():
            if top == ".codex":
                raise PublishError(f"Codex 成果物の反映先が未定義です: {item.relative_to(root)}")
            if item.name not in names:
                raise PublishError(f"未対応の APM 成果物です: {item.relative_to(root)}")
    return output, mcp, settings, modes


def validate_profile_path(rel: str, home: Path, resolve: bool = False) -> Path:
    """Validate a ledger path: absolute, no '..' elements and inside the home folder."""
    dest = Path(rel)
    if not dest.is_absolute() or ".." in dest.parts or home not in dest.parents:
        raise PublishError(f"所有台帳のパスがユーザープロファイル外を指しています: {rel}")
    if resolve:
        try:
            resolved = dest.resolve(strict=False)
            resolved_home = home.resolve(strict=False)
        except (OSError, RuntimeError) as exc:
            raise PublishError(f"所有台帳のパスを解決できません: {rel}: {exc}") from exc
        if resolved_home not in resolved.parents:
            raise PublishError(f"所有台帳のパスがユーザープロファイル外を指しています: {rel}")
    return dest


def file_mode(path: Path) -> int | None:
    return path.stat().st_mode & 0o777 if path.is_file() else None


def write_with_mode(dest: Path, content: bytes, mode: int) -> None:
    """Write through a temp file created with restrictive permissions, then replace the destination."""
    temp = dest.with_name(dest.name + ".apm-tmp")
    try:
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as handle:
            handle.write(content)
        if os.name != "nt":
            os.chmod(temp, mode)
        os.replace(temp, dest)
    except Exception:
        temp.unlink(missing_ok=True)
        raise


def make_dirs(path: Path, created: list[Path]) -> None:
    """Create a folder and remember which levels this run created, outermost first."""
    missing: list[Path] = []
    current = path
    while not current.exists() and not is_reparse(current):
        missing.append(current)
        current = current.parent
    path.mkdir(parents=True, exist_ok=True)
    created.extend(reversed(missing))


def prune_empty_plugin_dirs(dest: Path, home: Path) -> None:
    """Remove empty folders left under ~/.agents/plugins after a managed file was deleted."""
    plugin_root = home / ".agents/plugins"
    current = dest.parent
    while current == plugin_root or plugin_root in current.parents:
        try:
            current.rmdir()
        except OSError:
            break
        current = current.parent


def ensure_profile_path_not_linked(dest: Path, home: Path) -> None:
    """Reject a profile path that is, or is reached through, a link below the home folder."""
    parent = dest.parent
    while parent != home and home in parent.parents:
        if is_reparse(parent):
            raise PublishError(f"リンクを経由するため設定の書き込みを中止します: {parent}")
        parent = parent.parent
    if is_reparse(dest):
        raise PublishError(f"設定ファイルがリンクのため書き込みを中止します: {dest}")


def merge_settings(
    dest: Path,
    desired: dict[str, dict[str, Any]] | None,
    old: dict[str, dict[str, Any]],
    home: Path,
) -> tuple[bytes | None, dict[str, dict[str, Any]]]:
    """Merge the owned keys into a user settings file.

    Returns the new file content (None when nothing has to change) and the ledger entry
    describing the keys that are now owned. Keys not recorded in the ledger are never touched.
    """
    ensure_profile_path_not_linked(dest, home)
    existing = read_json(dest, {})
    if not isinstance(existing, dict):
        raise PublishError(f"{dest} はオブジェクトである必要があります")
    owned: dict[str, dict[str, Any]] = {}
    changed = False
    for section in SETTINGS_SECTIONS:
        old_values = old.get(section, {})
        new_values = desired[section] if desired is not None else {}
        current = existing.get(section)
        if current is not None and not isinstance(current, dict):
            raise PublishError(f"{dest} の {section} はオブジェクトである必要があります")
        for name, old_value in old_values.items():
            if current is not None and name in current and current[name] != old_value:
                raise PublishError(f"APM 管理の設定キーが編集されているため上書きを中止します: {dest}: {section}.{name}")
            if name not in new_values and current is not None and name in current:
                del current[name]
                changed = True
        for name, value in new_values.items():
            if name not in old_values and current is not None and name in current:
                raise PublishError(f"所有権のない設定キーと名前が重複しています: {dest}: {section}.{name}")
            if current is None:
                current = {}
                existing[section] = current
            if current.get(name) != value or name not in current:
                current[name] = value
                changed = True
        if current is not None and not current and old_values and section in existing:
            del existing[section]
        owned[section] = dict(new_values)
    if not changed:
        return None, owned
    return (json.dumps(existing, ensure_ascii=False, indent=2) + "\n").encode("utf-8"), owned


def main() -> int:
    if len(sys.argv) != 3:
        print("使い方: apm-profile-publish.py <候補ルート> <状態フォルダー>", file=sys.stderr)
        return 2
    candidate = Path(sys.argv[1]).resolve()
    state = Path(sys.argv[2]).resolve()
    home = Path.home()
    ledger_path = state / "ownership.json"
    state.mkdir(parents=True, exist_ok=True)

    try:
        files, mcp, settings, exec_bits = staged_files(candidate)
        ledger = read_json(ledger_path, {"files": {}, "mcpServers": {}, "settings": {}})
        if not isinstance(ledger, dict) or not isinstance(ledger.get("files"), dict) or not isinstance(ledger.get("mcpServers"), dict):
            raise PublishError("APM プロファイルの所有台帳の形式が正しくありません")
        # Ledgers written before native plugin support have no "settings" key.
        old_settings = ledger.get("settings", {})
        if not isinstance(old_settings, dict) or any(
            not isinstance(entry, dict) or any(not isinstance(entry.get(s, {}), dict) for s in SETTINGS_SECTIONS)
            for entry in old_settings.values()
        ):
            raise PublishError("APM プロファイルの所有台帳の settings の形式が正しくありません")

        old_file_owners: dict[str, str] = ledger["files"]
        new_file_owners: dict[str, str] = {}
        planned: dict[Path, bytes | None] = {}
        legacy_links = known_legacy_links(home)
        legacy_files: set[Path] = set()
        for link, source in legacy_links.items():
            if link == home / ".github/agents":
                legacy_files |= import_legacy_tree(source, [home / ".github/agents", home / ".copilot/agents"], {home / ".github/agents"}, files)
            elif link == home / ".copilot/skills":
                legacy_files |= import_legacy_tree(source, [home / ".copilot/skills", home / ".agents/skills"], {home / ".copilot/skills"}, files)

        # 現在の内容が記録済みハッシュと一致する古いファイルだけを削除する。
        for rel, old_hash in old_file_owners.items():
            dest = validate_profile_path(rel, home)
            ancestor = dest.parent
            while ancestor != home and home in ancestor.parents:
                if is_reparse(ancestor) and ancestor not in legacy_links:
                    raise PublishError(f"古い APM ファイルの削除先が不明なリンクを経由しています: {ancestor}")
                ancestor = ancestor.parent
            if is_reparse(dest):
                raise PublishError(f"古い APM ファイルの削除先がリンクです: {dest}")
            if dest not in files and dest.is_file() and digest(dest.read_bytes()) == old_hash:
                planned[dest] = None

        for dest, content in files.items():
            rel = str(dest)
            if home not in dest.parents:
                raise PublishError(f"反映先がユーザープロファイル外を指しています: {dest}")
            parent = dest.parent
            while parent != home and home in parent.parents:
                if is_reparse(parent) and parent not in legacy_links:
                    raise PublishError(f"不明なプロファイルリンクを経由するため書き込みを中止します: {parent}")
                parent = parent.parent
            if is_reparse(dest):
                raise PublishError(f"不明なプロファイルリンクを置き換えるため書き込みを中止します: {dest}")
            if dest.exists():
                if not dest.is_file():
                    raise PublishError(f"反映先にファイルが必要です: {dest}")
                current = dest.read_bytes()
                old_hash = old_file_owners.get(rel)
                if old_hash is None:
                    if current != content and dest not in legacy_files:
                        raise PublishError(f"所有権のない既存ファイルと競合しています: {dest}")
                    if dest in legacy_files:
                        planned[dest] = content
                        new_file_owners[rel] = digest(content)
                    continue
                if digest(current) != old_hash:
                    raise PublishError(f"APM 管理ファイルが編集されているため上書きを中止します: {dest}")
            planned[dest] = content
            new_file_owners[rel] = digest(content)

        # Copilot MCP サーバー名ごとに所有台帳と照合して統合する。
        copilot_mcp = home / ".copilot/mcp-config.json"
        old_server_values: dict[str, Any] = ledger["mcpServers"]
        old_servers = set(old_server_values)
        new_servers: set[str] = set()
        if mcp is not None:
            if is_reparse(copilot_mcp.parent):
                raise PublishError(f"Copilot プロファイルのリンクを経由するため書き込みを中止します: {copilot_mcp.parent}")
            existing = read_json(copilot_mcp, {"mcpServers": {}})
            if is_reparse(copilot_mcp):
                raise PublishError(f"Copilot MCP 設定がリンクのため書き込みを中止します: {copilot_mcp}")
            if not isinstance(existing, dict) or not isinstance(existing.get("mcpServers"), dict):
                raise PublishError(f"{copilot_mcp} は mcpServers を持つオブジェクトである必要があります")
            existing_servers = existing.setdefault("mcpServers", {})
            for name in old_servers:
                if name in existing_servers and existing_servers[name] != old_server_values[name]:
                    raise PublishError(f"APM 管理の Copilot MCP サーバーが編集されているため上書きを中止します: {name}")
                if name not in mcp:
                    existing_servers.pop(name, None)
            for name, value in mcp.items():
                if name not in old_servers and name in existing_servers:
                    raise PublishError(f"所有権のない Copilot MCP サーバーと名前が重複しています: {name}")
                existing_servers[name] = value
                new_servers.add(name)
            planned[copilot_mcp] = (json.dumps(existing, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
        elif old_servers:
            if is_reparse(copilot_mcp.parent):
                raise PublishError(f"Copilot プロファイルのリンクを経由するため書き込みを中止します: {copilot_mcp.parent}")
            existing = read_json(copilot_mcp, {"mcpServers": {}})
            if is_reparse(copilot_mcp):
                raise PublishError(f"Copilot MCP 設定がリンクのため書き込みを中止します: {copilot_mcp}")
            if not isinstance(existing, dict) or not isinstance(existing.get("mcpServers"), dict):
                raise PublishError(f"{copilot_mcp} は mcpServers を持つオブジェクトである必要があります")
            servers = existing.setdefault("mcpServers", {})
            for name in old_servers:
                if name in servers and servers[name] != old_server_values[name]:
                    raise PublishError(f"APM 管理の Copilot MCP サーバーが編集されているため削除を中止します: {name}")
                servers.pop(name, None)
            planned[copilot_mcp] = (json.dumps(existing, ensure_ascii=False, indent=2) + "\n").encode("utf-8")

        # Merge the plugin registration keys into the user settings files through the same ledger.
        new_settings_owned: dict[str, dict[str, dict[str, Any]]] = {}
        settings_dests: dict[str, Path] = {}
        for rel in old_settings:
            settings_dests[rel] = validate_profile_path(rel, home, resolve=True)
        for dest in settings:
            settings_dests[str(dest)] = dest
        for rel, dest in settings_dests.items():
            desired = settings.get(dest)
            old_entry = old_settings.get(rel, {})
            if desired is None and not any(old_entry.get(s) for s in SETTINGS_SECTIONS):
                continue
            content, owned = merge_settings(dest, desired, old_entry, home)
            if content is not None:
                planned[dest] = content
            if desired is not None:
                new_settings_owned[rel] = owned
        settings_key_count = sum(len(values) for entry in new_settings_owned.values() for values in entry.values())

        # 宛先に触れる前にすべての出力とバックアップを準備する。
        tx = Path(tempfile.mkdtemp(prefix="apm-publish-", dir=state))
        backups: dict[Path, bytes | None] = {}
        backup_modes: dict[Path, int | None] = {}
        final_modes: dict[Path, int] = {}
        try:
            for index, (dest, content) in enumerate(planned.items()):
                backups[dest] = dest.read_bytes() if dest.is_file() else None
                backup_modes[dest] = file_mode(dest)
                if content is not None:
                    previous_mode = backup_modes[dest]
                    if dest in files:
                        # Managed files keep the source execute bits; other bits follow the existing file.
                        base = (previous_mode & ~0o111) if previous_mode is not None else 0o644
                        final_modes[dest] = base | exec_bits.get(dest, 0)
                    else:
                        # User settings keep their permissions; new ones are private by default.
                        final_modes[dest] = previous_mode if previous_mode is not None else 0o600
                if content is not None:
                    staged = tx / str(index)
                    staged.parent.mkdir(parents=True, exist_ok=True)
                    staged.write_bytes(content)

            ledger_new = {"files": new_file_owners, "mcpServers": {name: mcp[name] for name in sorted(new_servers)} if mcp is not None else {}, "settings": new_settings_owned}
            ledger_backup = ledger_path.read_bytes() if ledger_path.exists() else None
            applied: list[Path] = []
            created_dirs: list[Path] = []
            materialized: list[tuple[Path, Path]] = []
            try:
                for link, target in legacy_links.items():
                    backup_link = link.with_name(f"{link.name}.apm-link-backup-{uuid.uuid4().hex}")
                    os.replace(link, backup_link)
                    materialized.append((link, backup_link))
                    link.mkdir(parents=True, exist_ok=True)
                for dest, content in planned.items():
                    make_dirs(dest.parent, created_dirs)
                    if content is None:
                        dest.unlink(missing_ok=True)
                    else:
                        write_with_mode(dest, content, final_modes[dest])
                    applied.append(dest)
                temp_ledger = ledger_path.with_name(ledger_path.name + ".apm-tmp")
                temp_ledger.write_text(json.dumps(ledger_new, indent=2) + "\n", encoding="utf-8")
                os.replace(temp_ledger, ledger_path)
            except Exception:
                for dest in reversed(applied):
                    previous = backups[dest]
                    if previous is None:
                        dest.unlink(missing_ok=True)
                    else:
                        dest.parent.mkdir(parents=True, exist_ok=True)
                        dest.write_bytes(previous)
                        if os.name != "nt" and backup_modes[dest] is not None:
                            os.chmod(dest, backup_modes[dest])
                for created in reversed(created_dirs):
                    try:
                        created.rmdir()
                    except OSError:
                        pass
                for link, backup_link in reversed(materialized):
                    shutil.rmtree(link, ignore_errors=True)
                    os.replace(backup_link, link)
                if ledger_backup is None:
                    ledger_path.unlink(missing_ok=True)
                else:
                    ledger_path.write_bytes(ledger_backup)
                raise
            for dest, content in planned.items():
                if content is None:
                    prune_empty_plugin_dirs(dest, home)
            for _, backup_link in materialized:
                try:
                    if backup_link.is_symlink():
                        backup_link.unlink()
                    elif is_reparse(backup_link):
                        os.rmdir(backup_link)
                except OSError as exc:
                    print(f"警告: 反映後の旧リンクバックアップを削除できませんでした: {backup_link}: {exc}", file=sys.stderr)
        finally:
            shutil.rmtree(tx, ignore_errors=True)
        plugin_root = home / ".agents/plugins"
        plugin_count = len({dest.relative_to(plugin_root).parts[0] for dest in files if plugin_root in dest.parents and not dest.relative_to(plugin_root).parts[0].startswith(".")})
        print(
            f"==> APM 管理ファイル {len(files)} 件(プラグイン {plugin_count} 件)、Copilot MCP サーバー {len(new_servers)} 件、"
            f"設定キー {settings_key_count} 件を反映しました"
        )
        return 0
    except (OSError, PublishError) as exc:
        print(f"==> APM プロファイルの反映に失敗しました: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
