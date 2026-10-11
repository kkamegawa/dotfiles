# mise による Windows のパッケージ管理

winget が**ユーザースコープ**にインストールするパッケージは、mise に組み込まれた `winget` パッケージマネージャーを使い、`home/dot_config/mise/config.toml.tmpl` の `[bootstrap.packages]` に `winget:` エントリとして宣言します。各エントリには `os = ["windows"]` を付けて Windows 専用にします。macOS の `brew:` / `brew-cask:` と同じ方式です。

mise が管理するのは「どのパッケージを入れておくか」という宣言だけです。インストール・更新・アンインストールは引き続き winget が行います。そのため、すでに winget で入っているパッケージはそのまま認識され、入れ直す必要はありません。

## 管理先の振り分け

| インストール先 | 管理方法 | 例 |
| --- | --- | --- |
| ユーザースコープ（`%LOCALAPPDATA%\Microsoft\WinGet\Packages`、`%LOCALAPPDATA%\Programs` などのユーザー別フォルダー） | mise の `winget:` エントリ | ghq, fzf, uv, azd, Bicep, Codex CLI, Claude Code CLI, Copilot CLI, VS Code, WinSCP, PowerToys |
| `C:\Program Files`（`Program Files\WindowsApps` にある MSIX アプリを含む） | `reference/windows/configuration.dsc.yaml` | PowerShell, Git, GitHub CLI, Azure CLI, Visual Studio, Docker Desktop, Windows Terminal, oh-my-posh |
| Microsoft Store（`msstore` ソース） | `reference/windows/configuration.dsc.yaml` | Desired State Configuration, Codex アプリ, 1Password, Discord |
| ブートストラップ | `install.ps1` / `run_once_before_10-install-packages.ps1` と DSC ファイル | chezmoi, mise |
| フォント | `reference/windows/configuration.dsc.yaml` | JetBrains Mono Nerd Font と GitHub Releases から取得するフォント |

新しいパッケージをどちらで管理するかは、インストール先で判断します。`C:\Program Files` 配下に入るものは DSC ファイルに残し、それ以外でユーザー単位にインストールできるものは mise で管理します。

## パッケージが適用されるタイミング

- `run_once_after_20-mise-install.ps1` が、最初の `chezmoi apply` の後に `mise install` と `mise bootstrap packages apply --yes` を 1 回だけ実行します。
- `run_after_20-mise-upgrade.ps1` が、`chezmoi apply` / `chezmoi update` のたびに `mise install` と `mise upgrade` に続けて `mise bootstrap packages apply --yes` を実行します。

`apply` は未インストールのパッケージを入れるだけで、インストール済みのパッケージは更新しません。更新するには `mise bootstrap packages upgrade` または `winget upgrade` を実行します。

## 日常操作

PowerShell 7:

```powershell
# 宣言したパッケージのインストール状況を確認
mise bootstrap packages status

# 未インストールのパッケージを確認してからインストール
mise bootstrap packages apply --manager winget --dry-run
mise bootstrap packages apply --manager winget

# 宣言済みでインストール済みのパッケージを更新
mise bootstrap packages upgrade
```

bash（Git Bash）:

```bash
mise bootstrap packages status
mise bootstrap packages apply --manager winget --dry-run
mise bootstrap packages apply --manager winget
mise bootstrap packages upgrade
```

## パッケージの追加・削除

追加するときは、`winget search` または `winget show --id <ID>` で winget ID を調べ、次のエントリを追加します。

```toml
"winget:<PackageIdentifier>" = { os = ["windows"] }
```

`winget` マネージャーは `state = "absent"` と `prune` に対応していないため、エントリを削除してもパッケージはアンインストールされません。winget で手動でアンインストールしてください。

PowerShell 7 / bash:

```bash
winget uninstall --id <PackageIdentifier>
```

## DSC ファイルから mise へ移す手順

1. パッケージがユーザースコープにインストールされることを確認します。インストール先を確認するか、`winget show --id <ID> --scope user` を実行します。
2. `reference/windows/configuration.dsc.yaml` から該当する `Microsoft.WinGet.DSC/WinGetPackage` リソースを削除します。
3. `home/dot_config/mise/config.toml.tmpl` に `winget:` エントリを追加し、`chezmoi apply` を実行します。
4. `mise bootstrap packages status` を実行し、パッケージが `installed` と表示されることを確認します。

`C:\Program Files` 配下にインストール済みのパッケージは、winget にユーザースコープ用のインストーラーがあっても DSC ファイルに残してください。移すと既存のインストールを引き継ぐのではなく、2 つ目のコピーが入ってしまいます。
