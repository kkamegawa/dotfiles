# アーキテクチャと設計判断

## 概要

このリポジトリは Windows / Linux（サーバー）/ macOS / WSL / Dev Container を一つのリポジトリで管理する dotfiles です。

---

## ツール選定の根拠

### chezmoi（設定ファイル配布）

- テンプレートエンジン（Go template）でOS・環境ごとの差分を吸収
- `run_once_*` / `run_onchange_*` スクリプトによる冪等なブートストラップ
- `private_dot_` プレフィックスで機密ファイルのパーミッション（600）を自動設定
- 1Password / Bitwarden 等のシークレットマネージャーとネイティブ連携

### mise（ツールバージョン管理）

- Node.js・Python など複数ランタイムを一元管理
- `.mise.toml` のロックファイルで再現性を確保
- 参照リポジトリ（torumakabe/dotfiles）では mise を使用しており、同様の方針を採用
- **uv との分担**: mise = バージョン管理（Node.js, Python インタープリタ）、uv = Python パッケージ・ツール実行

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

### 1Password（シークレット・SSH署名）

- SSH キーを 1Password に保存し、SSH エージェント経由でコミット署名・認証を行う
- `op-ssh-sign` 実行ファイルが見つかる環境でのみ Git コミット署名を有効化する
- Dev Container のみ `commit.gpgsign = false`（コンテナからエージェントへの経路が複雑なため）

### APM（AI エージェント設定）

- Copilot CLI 向けのカスタム指示・フック・スキル・MCP サーバーは別リポジトリで管理
- `apm.yml` に依存関係を宣言し `apm install` で適用

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
