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

`chezmoi update` / `chezmoi apply` の後に OS 別の mise 更新フックが動きます。
macOS/Linux はシェル版、Windows は PowerShell 版を使い、Windows ではその後に
`mise bootstrap packages apply` を実行して `winget:` エントリのうち未インストールのパッケージを入れます
（詳細は [mise による Windows のパッケージ管理](winget_ja.md)）。

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

このリポジトリでは、グローバル npm CLI ツールは `home/dot_config/mise/config.toml.tmpl` の
`[tools]` セクションに `"npm:<package>" = "latest"` と記述して管理します。
このファイルは chezmoi により各マシンの `~/.config/mise/config.toml` として展開されます。

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

### Codex CLI / Claude Code CLI の管理

Codex CLI（OpenAI）・Claude Code CLI（Anthropic）は npm バックエンドでは管理せず、OS ごとに次の方法で管理します。

| OS | Claude Code CLI | Codex CLI |
| --- | --- | --- |
| Windows | mise bootstrap packages (`winget`) | mise bootstrap packages (`winget`) |
| macOS | mise bootstrap packages (`brew` / `brew-cask`) | mise bootstrap packages (`brew` / `brew-cask`) |
| Linux / WSL | apt 公式リポジトリ（`home/run_once_before_10-install-packages.sh`） | 公式スタンドアロンインストーラー（`home/run_once_before_10-install-packages.sh`） |

```sh
# 更新（Linux/WSL・apt 管理の Claude Code CLI）
sudo apt update && sudo apt upgrade claude-code

# 更新（Linux/WSL・スタンドアロンインストーラー管理の Codex CLI）
curl -fsSL https://chatgpt.com/codex/install.sh | sh
```

### .NET SDK と global tool の管理

macOS は mise の組み込み機能で共有 SDK を管理し、global tool の更新は `run_after_20-mise-upgrade.sh` だけが担当します。SDK の導入・更新が成功してからツールを処理します。PowerShell の更新フックは直接呼び出した場合も Windows 限定です。Linux はシェル版が担当します。

macOS の dotnet は `mise upgrade --global --no-prune dotnet` で別途更新し、`--bump` と自動 prune は使いません。プロジェクトが必要とする完全 SDK バージョンはローカルの保持リストからグローバル宣言へ反映します。DOTNET_CLI_HOME が異なっても保守先は既存の `~/.dotnet/tools` を明示します。macOS の Git はネイティブ Cask の GCM を使い、重複する dotnet tool は残しますが自動更新しません。

初回セットアップ・日常更新ともに SDK の導入を global tool より先に行います。bootstrap apply は宣言から外した導入済みパッケージを削除せず、旧 SDK Cask はユーザーの明示的な移行終了操作だけで削除します。移行フェーズ、.NET 10 task、登録、切り戻し、検証は [macOS .NET 管理](macos-dotnet-management_ja.md) を参照してください。移行は chezmoi の自動フックには登録しません。

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

## .NET の判断変更履歴

| 日付 | 従来の方針 | 新方針 | 理由 | 承認 |
|---|---|---|---|---|
| 2026-10-26 | システム SDK・継承 PATH、複数 OS でのツールフック実行 | 固定 mise ルート、OS 別の更新担当、明示的なエージェント環境、SDK 10 専用ラッパー | 手動移行の設計レビュー。macos-dotnet-management_ja.md を参照 | ユーザーが設計を承認。実機移行は明示的なユーザー操作として実施 |
