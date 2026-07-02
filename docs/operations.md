# 日常操作ガイド

## chezmoi の日常操作

```sh
# dotfiles リポジトリの変更を適用
chezmoi apply

# ドライランで確認（実際には変更しない）
chezmoi apply --dry-run

# ソースディレクトリを開く
chezmoi cd

# 差分を確認
chezmoi diff

# 既存ファイルを chezmoi 管理に追加
chezmoi add ~/.zshrc
```

`chezmoi update` / `chezmoi apply` 実行時は `run_after_20-mise-upgrade.*` が動き、
`mise install` と `mise upgrade` もあわせて実行されます。

---

## mise の日常操作

```sh
# ツールをインストール（.mise.toml に従って）
mise install

# 利用可能なバージョン一覧
mise ls-remote node
mise ls-remote python

# バージョン更新
mise use node@lts
mise use python@3.13

# 現在のツールバージョン確認
mise ls
```

### npm バックエンド（グローバル CLI ツール）

このリポジトリでは、グローバル npm CLI ツールは `home/.mise.toml` の `[tools]` セクションに
`"npm:<package>" = "latest"` と記述して管理します。
`home/.mise.toml` は chezmoi により各マシンの `~/.mise.toml` として展開されます。

```sh
# npm ツールも含めて一括インストール
mise install

# npm ツールのみ更新
mise upgrade "npm:@vscode/vsce"

# 管理中のツール一覧（npm ツール含む）
mise ls
```

現在管理中の npm ツール:

| パッケージ         | 用途                       |
| ------------------ | -------------------------- |
| `@vscode/vsce`     | VS Code Extension Manager  |

Codex CLI / Claude Code CLI は WinGet（`reference/windows/configuration.dsc.yaml`）で管理します。npm バックエンドは使用しません。

### dotnet global tool の管理

このリポジトリでは、dotnet global tool も `home/run_after_20-mise-upgrade.*` で一覧管理しています。
`chezmoi apply` / `chezmoi update` 実行時に、一覧にあるツールを順に確認し、未導入なら `dotnet tool install --global`、導入済みなら `dotnet tool update --global` します。

現在管理中の dotnet global tool:

| ツール名               | 用途 |
| ---------------------- | ---- |
| `dotnet-ef`            | EF Core CLI |
| `csharpier`            | C# formatter |
| `dotnet-outdated-tool` | .NET パッケージ更新確認ツール |

追加・削除したい場合は、`home/run_after_20-mise-upgrade.ps1` または `home/run_after_20-mise-upgrade.sh` 内の管理対象一覧を更新してください。

---

## uv の日常操作

```sh
# ツールをインストール（グローバル）
uv tool install ruff

# ツールを実行（インストール不要）
uv tool run ruff check .

# Python スクリプト実行（依存関係を自動インストール）
uv run script.py

# 仮想環境の作成
uv venv
```

---

## git コミット署名の確認

```sh
# SSH エージェントにキーが登録されているか確認
ssh-add -L

# テストコミット
git commit --allow-empty -m "test: 署名確認"
git log --show-signature -1
```

### 1Password SSH エージェントが応答しない場合

| OS | エージェントソケット |
|----|---------------------|
| macOS | `~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock` |
| Linux | `~/.config/1Password/ssh/agent.sock` |
| WSL | `~/.1password/agent.sock` |

---

## APM の操作

```sh
# Copilot CLI 設定を適用
apm install

# 設定を更新
apm update

# 適用済み設定を確認
apm list
```

APM のユーザープロファイル管理では、スキル・エージェントを次のディレクトリに配置します。

- `~/.config/apm/skills`
- `~/.config/apm/agents`

互換性のため、次のパスは上記ディレクトリへのリンクとして作成されます。

- `~/.copilot/skills` -> `~/.config/apm/skills`
- `~/.github/agents` -> `~/.config/apm/agents`

---

## Renovate Bot

依存関係の自動更新 PR は Renovate Bot が作成します。
`.github/renovate.json` で設定を管理しています。

GitHub Actions（mise ツール・ GitHub Actions）は Renovate が定期的に更新 PR を作成します。

---

## Lint CI

`.github\workflows\lint.yml` は次を検証します。

- Ubuntu: `shellcheck`, `yamllint`, `chezmoi` dry-run
- Windows: `PSScriptAnalyzer`, `chezmoi` dry-run, `winget configure validate`

### CI が失敗したとき

- `main` への push で Ubuntu の検証 job が失敗した場合、GitHub Issue を自動作成または更新します。
- Windows では `winget configure validate` が失敗した場合に GitHub Issue を自動作成または更新します。
- あわせて Windows の `chezmoi` dry-run 失敗も Issue 化し、Windows 固有のテンプレート崩れを追跡できるようにしています。

Issue には失敗した job 名、Actions run URL、確認対象ファイルを含めています。

---

## ツール仕様変更ウォッチ CI

`.github\workflows\tool-spec-watch.yml` が毎月 **1日** と **15日** に実行され、次の upstream 変更を監視します。

- `chezmoi`
- `mise`
- `uv`
- `APM`
- Microsoft DSC / WinGet Configuration の公式ドキュメントと schema

検知条件は `reference\ci\tool-spec-watch.json` に置いています。
主に **メジャーバージョン更新**、**breaking / deprecation / migration 系キーワード**、
Microsoft Learn の **更新日変更**、schema の **既知値変更** を見ます。

### 検知されたときの対応

1. GitHub Actions が GitHub Issue を自動作成または更新します。
2. Issue に書かれた影響候補ファイルを確認します。
3. 必要な修正を行います。
4. 対応後に `reference\ci\tool-spec-watch.json` の基準値を最新に更新します。

### 手動実行

必要なときは Actions の `Tool spec watch` ワークフローを `workflow_dispatch` で手動実行できます。

---

## dotfiles を新しいマシンに適用する手順

### Linux / macOS / WSL

```sh
git clone https://github.com/kkamegawa/dotfiles.git ~/dotfiles
cd ~/dotfiles && ./install.sh
```

### Windows

```powershell
winget install twpayne.chezmoi
chezmoi init --apply kkamegawa
winget configure -f "$(chezmoi source-path)\reference\windows\configuration.dsc.yaml"
gh auth login
mise install
apm install
```
