# Windows 固有の設定

## WinGet Configuration（DSC）

### 適用方法

```powershell
# 通常の適用
winget configure -f "$(chezmoi source-path)\reference\windows\configuration.dsc.yaml"

# ドライランで確認
winget configure test -f "$(chezmoi source-path)\reference\windows\configuration.dsc.yaml"

# 構成ファイルの検証
winget configure validate -f "$(chezmoi source-path)\reference\windows\configuration.dsc.yaml"
```

### 管理対象

| カテゴリ | 内容 |
|----------|------|
| シェル・ターミナル | PowerShell 7, Windows Terminal, Windows Terminal Preview, Intelligent Terminal, Oh My Posh |
| PowerShell モジュール | Az, Microsoft Entra, Microsoft Graph |
| バージョン管理 | Git, GitHub CLI |
| dotfiles・設定管理 | chezmoi, mise, Desired State Configuration, App Installer |
| 開発ツール | WinGet Studio, MSIX ツール, Windows App CLI, Core Utilities |
| .NET / Windows 開発 | .NET SDK 8 (LTS), .NET SDK Preview, .NET デスクトップランタイム 8, Web Deploy, Windows SDK 10.0.26100 / 10.0.28000 |
| データベース接続 | ODBC Driver 17 / 18 for SQL Server, Microsoft OLE DB Driver for SQL Server |
| エディタ・IDE | Visual Studio Enterprise Insiders |
| Azure・クラウド | Azure CLI, Functions Core Tools, AI Shell, Global Secure Access |
| AI 支援 | Codex アプリ (Store) |
| コンテナ・仮想化 | Docker Desktop, WSL, Ubuntu |
| セキュリティ | 1Password |
| 生産性・コミュニケーション | Microsoft 365, OneDrive, Teams, Copilot Keyboard, Discord |
| ブラウザ | Google Chrome, Microsoft Edge, Edge Beta / Dev / Canary |
| Windows アプリ基盤 | Windows App, UI.Xaml 2.7 / 2.8, VCLibs, VC++ Redistributable, Windows App Runtime 1.1 / 1.2 / 1.4-1.8 |
| Windows オプション機能 | OpenSSH クライアント, Hyper-V, 開発者モード |
| フォント | JetBrains Mono Nerd Font, Monaspace, PlemolJP Console NF, Noto Sans JP |

### mise で管理する winget パッケージ

ユーザースコープにインストールされる winget パッケージは DSC ではなく、
`home/dot_config/mise/config.toml.tmpl` の `[bootstrap.packages]` に `winget:` エントリとして宣言しています。
詳細は [mise による Windows のパッケージ管理](winget_ja.md) を参照してください。

| カテゴリ | 内容 |
|----------|------|
| CLI | ghq, Komac, APM, fzf, lastexecrecord, Edit, uv, Gitleaks, ripgrep, Helm |
| Azure・クラウド | azd, AzCopy, Bicep, Azure Storage Explorer |
| AI 支援 | Claude, Claude Code CLI, Codex CLI, GitHub Copilot CLI (Prerelease), GitHub Copilot App |
| エディタ・IDE | VS Code, VS Code Insiders, JetBrains Toolbox |
| GUI・ユーティリティ | GitHub Desktop, PowerToys, WinSCP |
| セキュリティ | 1Password CLI |
| メディア | FFmpeg, youtube-dl |

### DSC の種別について

このファイルは **WinGet Configuration schema 0.2**（`winget configure` コマンド用）です。
DSC v3 ネイティブ文書（`dsc config set` コマンド用）とは構造が異なります。

また、現在の `configuration.dsc.yaml` は WinGet export ベースラインに合わせているため、
一部のアプリは `msstore` ソースや依存ランタイムを含めて明示的に列挙しています。

PowerShell 7 の導入後に `pwsh` から `Az` / `Microsoft.Entra` / `Microsoft.Graph`
モジュールを CurrentUser スコープへ追加する Script リソースも含みます。

---

## Office アプリ設定

Microsoft 365（Office）は WinGet DSC でベースライン導入しつつ、必要に応じて
**ODT（Office Deployment Tool）** で詳細構成を上書きします。

```
reference/windows/office-config.xml  ← ODT 構成ファイル（手動適用）
```

詳細構成を適用する場合:

```powershell
# ODT をダウンロードし展開後
.\setup.exe /configure reference\windows\office-config.xml
```

---

## Visual Studio / Visual Studio Insiders の設定

`.vssettings` ファイルを `reference/windows/` に配置して手動インポートします。

Visual Studio → ツール → 設定のインポートとエクスポート → 選択された環境設定のエクスポート

---

## Rider の設定

JetBrains IDE Settings Sync（組み込み機能）を使用してクラウド同期します。
バックアップとして `reference/windows/` に設定ファイルのスナップショットを配置できます。

---

## WSL セットアップ

1. DSC で `Microsoft.WSL` と `Canonical.Ubuntu` をインストール
2. Ubuntu を起動してユーザー作成
3. chezmoi を WSL 内で実行:

```sh
sh -c "$(curl -fsLS get.chezmoi.io)" -- -b ~/.local/bin
chezmoi init --apply kkamegawa
```

---

## 1Password SSH エージェント（WSL 連携）

WSL から Windows の 1Password SSH エージェントを使う場合は npiperelay が必要です。

```sh
# npiperelay のインストール（Windows 側）
winget install jstarks.npiperelay

# WSL 側のソケット設定確認
ls ~/.1password/agent.sock
```
