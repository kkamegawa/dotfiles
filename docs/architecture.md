# アーキテクチャと設計判断

## 概要

このリポジトリは Windows / Linux（サーバー）/ macOS / WSL / Dev Container を一つのリポジトリで管理する dotfiles です。

---

## ツール選定の根拠

### chezmoi（設定ファイル配布）

- テンプレートエンジン（Go template）でOS・環境ごとの差分を吸収
- `run_once_*` / `run_onchange_*` / `run_after_*` スクリプトによる冪等なブートストラップ
- `private_dot_` プレフィックスで機密ファイルのパーミッション（600）を自動設定
- 1Password / Bitwarden 等のシークレットマネージャーとネイティブ連携

### mise（ツールバージョン管理）

- Node.js・Python など複数ランタイムを一元管理
- `.mise.toml` のロックファイルで再現性を確保
- 参照リポジトリ（torumakabe/dotfiles）では mise を使用しており、同様の方針を採用
- **uv との分担**: mise = バージョン管理（Node.js, Python インタープリタ）、uv = Python パッケージ・ツール実行
- **npm バックエンド**: `npm:<package>` 形式でグローバル npm CLI ツールを管理（例: `@vscode/vsce`）
  - Node.js が mise 管理下にある環境で `mise install` と同時にインストール
  - 設定は `home/dot_config/mise/config.toml.tmpl`（`~/.config/mise/config.toml` として展開）に記述
  - Codex CLI / Claude Code CLI は npm バックエンドでは管理しない（後述の「Codex CLI / Claude Code CLI の管理」参照）
- **PowerShell（pwsh）連携**: `mise activate pwsh` を `$PROFILE` に記述し対話セッションで有効化
  - PATH への追加は OS ごとに分岐（Windows: `%LOCALAPPDATA%\mise\shims`、Linux/macOS: `~/.local/bin` と `~/.local/share/mise/shims`）
  - 既に PATH に含まれる場合は重複追加しない

### uv（Python パッケージ管理）

- `pip install` を使わず `uv run` / `uv tool run` で実行環境を分離
- mise で管理する Python インタープリタを uv のデフォルトとして使用

### Microsoft DSC / WinGet Configuration（Windows 構成管理）

- **DSC種別**: WinGet Configuration schema 0.2（`winget configure` コマンド用）
  - DSC v3 ネイティブ文書（`dsc config set`）とは別物
- **assertions セクション**: Windows 11 以上の事前確認
- **Windows オプション機能**: `PSDscResources/Script` リソースで DISM 経由管理
  （`WindowsOptionalFeature` は Windows Server 向けのため）
- **フォント**: JetBrains Mono Nerd Font は winget、Monaspace / PlemolJP Console NF / Noto Sans JP は GitHub Releases から管理
- **管理範囲**: `C:\Program Files` 配下にインストールされるアプリ（`Program Files\WindowsApps` の MSIX アプリを含む）、Microsoft Store アプリ、chezmoi / mise のブートストラップ、フォントのみ
  - ユーザースコープにインストールされる winget パッケージは、mise 組み込みの `winget` パッケージマネージャーで管理する（`home/dot_config/mise/config.toml.tmpl` の `[bootstrap.packages]` に `winget:` エントリとして宣言）。macOS の `brew:` / `brew-cask:` と同じ方式にそろえるため
  - 実際のインストール・更新は winget が行うため、既存のインストールはそのまま引き継げる

### Codex CLI / Claude Code CLI の管理

Codex CLI（OpenAI）・Claude Code CLI（Anthropic）は npm バックエンドでは管理せず、OS ネイティブのパッケージ管理に一元化する。

- **Windows**: mise bootstrap package manager (`winget`), configured in `home/dot_config/mise/config.toml.tmpl`
- **macOS**: mise bootstrap package managers (`brew` / `brew-cask`), configured in `home/dot_config/mise/config.toml.tmpl`
- **Linux / WSL**: `home/run_once_before_10-install-packages.sh`（Ubuntu/Debian のみ自動化。他ディストリビューションは手動インストール）
  - Claude Code CLI: 公式 apt リポジトリ（`downloads.claude.ai`）経由で `apt install claude-code`
  - Codex CLI: apt パッケージが存在しないため、OpenAI 公式スタンドアロンインストーラー（`curl -fsSL https://chatgpt.com/codex/install.sh | sh`）を使用

### 1Password（シークレット・SSH署名）

- SSH キーを 1Password に保存し、SSH エージェント経由でコミット署名・認証を行う
- `op-ssh-sign` 実行ファイルが見つかる環境でのみ Git コミット署名を有効化する
- Dev Container のみ `commit.gpgsign = false`（コンテナからエージェントへの経路が複雑なため）

### AI ツール カスタムインストラクション

ユーザーレベルのカスタムインストラクションは chezmoi で各ツールの設定ディレクトリに配布します。

| ファイル（chezmoi ソース） | デプロイ先 | 読み込むツール |
|---------------------------|-----------|---------------|
| `home/dot_github/copilot-instructions.md` | `~/.github/copilot-instructions.md` | GitHub Copilot CLI / Copilot Chat |
| `home/dot_codex/AGENTS.md` | `~/.codex/AGENTS.md` | Codex CLI |
| `home/dot_codex/modify_private_config.toml` | `~/.codex/config.toml` | Codex CLI config（管理キーのみマージ） |
| `home/dot_claude/CLAUDE.md` | `~/.claude/CLAUDE.md` | Claude Code |
| `home/dot_claude/modify_settings.json` | `~/.claude/settings.json` | Claude Code settings（管理キーのみマージ） |

`config.toml` と `settings.json` はアプリも書き換えるため、リポジトリが管理するキーだけを chezmoi の `modify_` テンプレートでマージします（詳細は [ai-tool-config.md](ai-tool-config.md)）。

プロジェクト固有の指示（`AGENTS.md` / `.github/copilot-instructions.md`）はリポジトリ側で管理し、
ここでは全プロジェクト共通のユーザーレベル指示のみを dotfiles に含めます。

#### Claude Code hooks and context compaction

Repository hooks are deployed under `~/.claude/hooks`; managed hook entries use absolute paths derived from the home directory. Automatic compaction remains at 60 percent, and C# hook timeouts remain 60 seconds.

PostCompact and UserPromptSubmit remain .NET 10 file-based programs: the former stores compact_summary by session and the latter injects it once and removes the saved summary. On macOS they invoke the absolute `dotfiles-dotnet10` runner. That runner selects SDK 10 from its own managed global.json directory, preserves JSON stdin/stdout and exit status, and is independent of a caller project's SDK 8 pin. It does not install SDKs. Other operating systems keep their existing invocation.

The four global mise cleanup tasks use the same macOS runner. Native apphosts without environment variables use the user-maintained architecture-specific system registration. CLI PATH, apphost runtime discovery, and project SDK selection remain distinct responsibilities. See [macOS .NET management](macos-dotnet-management.md) for ownership, registration, retention, and user-run migration.

#### Claude Code の作業フォルダー外の読み取り

- `permissions.blockReadsOutsideWorkingDirectories = true` のため、作業フォルダー外のログなどの読み取りは承認が必要になる
- Windows のみ、Visual Studio / Codex for Visual Studio のログ置き場を `permissions.additionalDirectories` に登録して承認を省く。パスは `.chezmoi.homeDir` から組み立てる
- Visual Studio のインスタンス ID を含む `VisualStudio/*/VSExtensions` は、`additionalDirectories` にワイルドカードを書かず、chezmoi の `glob` 関数で `chezmoi apply` 時に実在フォルダーへ展開する。新しいインスタンスが増えたら再度 `chezmoi apply` する
- `additionalDirectories` のフォルダーは読み取りだけでなく Edit / Write の対象にもなる

#### Claude Code の MCP サーバー登録

- `permissions.allow` の `mcp__microsoft-learn__microsoft_docs_search` は、MCP サーバー名が `microsoft-learn` であることに依存する。claude.ai のコネクタ経由だとサーバー名が UUID になり一致しないため、ユーザースコープのローカル登録に統一する
- 登録は `home/run_after_70-setup-claude-mcp.{sh,ps1}` が `chezmoi apply` のたびに冪等に行う。登録済みなら何もしない。`claude` が PATH にない場合は警告してスキップする
- 登録先の `~/.claude.json` はセッション状態も含むため、chezmoi では管理しない

### APM（AI エージェント設定）

- Copilot CLI 向けのカスタム指示・フック・スキル・MCP サーバーは別リポジトリで管理
- `apm.yml` に依存関係を宣言し `apm install` で適用
- スキル・エージェントはユーザープロファイル配下で一元管理
  - `~/.config/apm/skills`
  - `~/.config/apm/agents`
- 互換性のため `~/.copilot/skills` と `~/.github/agents` は上記ディレクトリへのリンクとして作成

### GitHub Actions（仕様変更ウォッチ）

- `lint.yml` とは別に、上流ツールの仕様変更候補を検知する定期ワークフローを分離
- 毎月 1 日・15 日に `chezmoi`、`mise`、`uv`、`APM`、Microsoft DSC / WinGet Configuration を監視
- 破壊的変更の可能性がある場合は GitHub Issue を自動作成し、対応履歴をリポジトリで追跡
- `lint.yml` では Linux / Windows の検証を分離し、`chezmoi` dry-run と `winget configure validate` を含める
- `main` への push で重要な検証 job が失敗した場合は GitHub Issue を自動作成または更新する

### GHAS Push Protection + gitleaks

- **多層防御**:
  1. `gitleaks` pre-commit フック（ローカルでコミット前にブロック）
  2. GHAS Push Protection（サーバー側でプッシュ前にブロック、パブリックリポジトリで無料）

---

## ディレクトリ構成の設計方針

```
dotfiles/
├── reference/windows/   # chezmoi 管理外の参照ファイル（DSC, Office ODT 等）
├── dot_config/          # → ~/.config/（chezmoi 管理）
├── private_dot_ssh/     # → ~/.ssh/（chezmoi 管理、パーミッション 600 自動設定）
├── run_once_before_*/   # chezmoi ブートストラップ（依存ツールのインストール）
├── run_once_after_*/    # chezmoi ブートストラップ（ツール設定の後処理）
└── docs/                # 日本語ドキュメント
```

---

## chezmoi 変数一覧

| 変数 | 型 | 内容 |
|------|----|------|
| `.chezmoi.os` | string | `linux` / `darwin` / `windows` |
| `.isLinux` | bool | Linux（WSL含む） |
| `.isMac` | bool | macOS |
| `.isWindows` | bool | Windows |
| `.isWSL` | bool | WSL（kernel に `microsoft` を含む Linux） |
| `.isDevContainer` | bool | Dev Container / Codespaces 判定 |
| `.windowsUser` | string | WSL 初回セットアップ時に入力（1Password WSL 連携パス用） |

---

## 参照リポジトリとの主な差分

| 項目 | 参照リポジトリ（torumakabe/dotfiles） | 本リポジトリ |
|------|--------------------------------------|-------------|
| Copilot CLI 設定 | 同リポジトリ管理 | APM 別リポジトリ参照 |
| GitHub Codespaces | 対応 | 対応しない |
| 秘匿スキャン | gitleaks のみ | gitleaks + GHAS Push Protection |
| 依存関係自動更新 | 記載なし | Renovate Bot |
| エディタ設定 | 記載なし | VS Code / Rider / Visual Studio |
| Python ツール実行 | 記載なし | uv で管理 |

## .NET decision change history

| Date | Previous decision | New decision | Reason | Approval |
|---|---|---|---|---|
| 2026-10-26 | System SDK and inherited PATH; shared OS tool hook execution | Stable mise root, one updater per OS, explicit agent environment and isolated SDK 10 runner | Manual migration design review; see macos-dotnet-management.md | User approved design; host migration remains an explicit user-run operation |
