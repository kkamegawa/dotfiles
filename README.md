# dotfiles

Windows / Linux（サーバー）/ macOS / WSL / Dev Container を一つのリポジトリで管理する dotfiles です。

## 対応環境

| 環境 | シェル |
|------|--------|
| Windows | PowerShell 7 |
| macOS | zsh |
| Linux（サーバー） | zsh |
| WSL | zsh |
| Dev Container | zsh |

## ツール構成

| 役割 | ツール |
|------|--------|
| 設定ファイル配布 | [chezmoi](https://www.chezmoi.io/) |
| Windows 構成管理 | [Microsoft DSC / WinGet Configuration](https://learn.microsoft.com/windows/package-manager/configuration/) |
| ツールバージョン管理 | [mise](https://mise.jdx.dev/) |
| Python パッケージ実行 | [uv](https://docs.astral.sh/uv/) |
| シークレット管理 | [1Password](https://1password.com/) |
| AI エージェント設定 | [APM](https://github.com/github/apm)（別リポジトリ参照） |
| JS ランタイム管理 | [mise](https://mise.jdx.dev/) |

## 管理対象設定ファイル

| chezmoi パス | 展開先 | 説明 |
|---|---|---|
| `dot_config/starship.toml` | `~/.config/starship.toml` | Starship プロンプト設定 |
| `dot_config/oh-my-posh/mytheme.omp.json` | `~/.config/oh-my-posh/mytheme.omp.json` | Oh My Posh カスタムテーマ |
| `dot_config/mise/config.toml.tmpl` | `~/.config/mise/config.toml` | mise グローバル設定 |
| `dot_config/micro/bindings.json` | `~/.config/micro/bindings.json` | micro エディタ キーバインド |
| `dot_config/git/hooks/` | `~/.config/git/hooks/` | Git グローバルフック |
| `dot_config/Code/User/` | `~/.config/Code/User/` | VS Code ユーザー設定 |
| `dot_codex/modify_private_config.toml` | `~/.codex/config.toml` | OpenAI Codex CLI 設定（管理キーのみマージ） |
| `dot_claude/modify_settings.json` | `~/.claude/settings.json` | Claude Code の設定（管理キーのみマージ） |
| `apm.yml` | `~/apm.yml` | APM の依存関係（Copilot 設定リポジトリと利用する7つのマーケットプレース） |
| `run_after_60-update-apm-profile.sh` | `~/.agents/skills`、`~/.claude/`、`~/.copilot/` | APM を候補フォルダーへ更新し、成功後に反映（Linux/macOS/WSL） |
| `run_after_60-update-apm-profile.ps1` | `~/.agents/skills`、`~/.claude/`、`~/.copilot/` | APM を候補フォルダーへ更新し、成功後に反映（Windows） |
| `dot_config/apm-profile/apm-profile-publish.py` | `~/.config/apm-profile/` | APM の反映と所有台帳の管理 |
| `run_after_70-setup-claude-mcp.sh` | `~/.claude.json` | Claude Code の `microsoft-learn` MCP サーバーをユーザースコープに登録（Linux/macOS/WSL） |
| `run_after_70-setup-claude-mcp.ps1` | `%USERPROFILE%/.claude.json` | Claude Code の `microsoft-learn` MCP サーバーをユーザースコープに登録（Windows） |
| `dot_wslconfig` | `~/.wslconfig` | WSL2 メモリ・CPU 設定（Windows のみ） |
| `dot_lastexecrecord/config.json` | `~/.lastexecrecord/config.json` | lastexecrecord スケジュール設定 |
| `modify_dot_gitconfig` | `~/.gitconfig` | Git グローバル設定 |
| `dot_config/git/dotfiles.gitconfig.tmpl` | `~/.config/git/dotfiles.gitconfig` | 管理対象の Git 設定 |

### Linux の Git 認証情報

Git Credential Manager をインストールし、`git-credential-manager` を `PATH` から実行できるようにします。.NET global tool の実行には .NET 10 SDK と `~/.dotnet/tools` の `PATH` 登録が必要です。メインの `~/.gitconfig` で認証情報ストアを設定します。利用可能な D-Bus Secret Service がある場合は `secretservice` を、GPG と `pass` を設定している場合は `gpg` を使います。1台のマシンではどちらか一方を選んでください。管理設定は、実行ファイルと明示的に設定されたグローバルストアがある場合に GCM を有効にし、それ以外では既存の helper 設定を維持します。ストアを変更した後は、管理設定を再適用してください。

Bash / zsh:

```sh
dotnet tool install --global git-credential-manager
git config --global credential.credentialStore secretservice
chezmoi apply ~/.config/git/dotfiles.gitconfig
```

PowerShell 7:

```powershell
dotnet tool install --global git-credential-manager
git config --global credential.credentialStore secretservice
chezmoi apply "$HOME/.config/git/dotfiles.gitconfig"
```

ヘッドレス環境で GPG を設定済みの場合は、`secretservice` を `gpg` に置き換えます。Git HTTPS と GitHub CLI は認証を別々に管理するため、`gh` にも個別にサインインしてください。

## レポジトリ構成

```
dotfiles/
├── home/                          # chezmoi のソースルート（.chezmoiroot）
│   ├── dot_config/                # ~/.config/（starship、oh-my-posh、mise、micro、git、VS Code）
│   ├── dot_codex/                 # ~/.codex/（Codex CLI 設定）
│   ├── dot_lastexecrecord/        # ~/.lastexecrecord/（スケジュール済みコマンド設定）
│   ├── dot_visualstudio/          # ~/.visualstudio/（Visual Studio 設定のエクスポート）
│   ├── private_dot_ssh/           # ~/.ssh/（SSH 設定、Dev Container では除外）
│   ├── run_once_before_*/         # 初期セットアップスクリプト（パッケージ、mise、uv）
│   ├── run_once_after_*/          # 初期適用後のスクリプト（Git フック、1Password、APM、VS 設定）
│   └── dot_*, *.tmpl              # dotfile と chezmoi テンプレート
├── docs/                          # アーキテクチャと運用のガイド
├── reference/                     # 参照設定（Windows DSC など）
├── scripts/                       # 補助スクリプト
├── .github/                       # GitHub Actions ワークフロー
├── install.ps1 / install.sh       # 初期セットアップ用インストーラー
└── .chezmoiroot                   # chezmoi のソースルートを home/ に指定
```

## セットアップ

### Linux / macOS / WSL

```sh
git clone https://github.com/kkamegawa/dotfiles.git ~/dotfiles
cd ~/dotfiles
./install.sh
```

apt ベースの Linux / WSL では、ブートストラップ中に PowerShell 7 と
`Az` / `Microsoft.Entra` / `Microsoft.Graph` モジュールもセットアップします。
macOS の PowerShell 7 は Intune で管理します。

macOS では mise が `home/dot_config/mise/config.toml.tmpl` に宣言したパッケージをインストールします。移行とトラブルシューティングは[macOS のパッケージ管理](docs/homebrew_ja.md)を参照してください。

### Windows

```powershell
# 1. chezmoi をインストール
winget install twpayne.chezmoi

# 2. dotfiles を適用
chezmoi init --apply kkamegawa

# 3. Windows DSC で残りのアプリ・設定を適用
winget configure -f "$(chezmoi source-path)\..\reference\windows\configuration.dsc.yaml"

# 4. mise でツールとユーザースコープの winget パッケージをインストール
#    （初回の chezmoi apply で実行済み。手動で再適用する場合）
gh auth login
mise install
mise bootstrap packages apply

# 5. PowerShell モジュール（Az / Microsoft.Entra / Microsoft.Graph）は
#    winget configure でセットアップ済み

# 6. APM のユーザー設定を反映（`chezmoi apply` / `chezmoi update` のたびに自動更新）
chezmoi apply

# 6.1 APM の候補と所有台帳を確認
Get-ChildItem "$HOME/.config/apm-profile"

# 7. Visual Studio の設定をインポート（手動）
#    ツール > インポートとエクスポートの設定 > 選択した環境設定をインポート
#    ファイル: ~/.visualstudio/vscode2026insider.vssettings
```

## ドキュメント

- [アーキテクチャと設計判断](docs/architecture.md)
- [Homebrew パッケージ管理](docs/homebrew_ja.md)
- [winget パッケージ管理](docs/winget_ja.md)
- [日常操作ガイド](docs/operations.md)
- [Windows 固有の設定](docs/windows.md)
- [Claude Code command hooks](docs/claude-command-hooks.md) / [日本語](docs/claude-command-hooks_ja.md)
- [トラブルシューティング](docs/troubleshooting.md)

## GitHub Actions の自動処理

- `lint.yml`: Linux / Windows の Shell / PowerShell / YAML / chezmoi / WinGet Configuration を検証し、push-to-main の失敗は GitHub Issue を自動作成
- `tool-spec-watch.yml`: 毎月 1 日・15 日に upstream ツールの仕様変更候補を検知し、対応用の GitHub Issue を自動作成

## ライセンス

MIT
