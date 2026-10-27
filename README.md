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
| `dot_claude/modify_settings.json` | `~/.claude/settings.json` | Claude Code settings（管理キーのみマージ） |
| `run_once_after_60-setup-apm-profile.sh` | `~/.config/apm/{skills,agents}` | APM スキル/エージェント管理ディレクトリ作成とリンク設定（Linux/macOS/WSL） |
| `run_once_after_60-setup-apm-profile.ps1` | `%USERPROFILE%/.config/apm/{skills,agents}` | APM スキル/エージェント管理ディレクトリ作成とリンク設定（Windows） |
| `run_after_70-setup-claude-mcp.sh` | `~/.claude.json` | Claude Code の `microsoft-learn` MCP サーバーをユーザースコープに登録（Linux/macOS/WSL） |
| `run_after_70-setup-claude-mcp.ps1` | `%USERPROFILE%/.claude.json` | Claude Code の `microsoft-learn` MCP サーバーをユーザースコープに登録（Windows） |
| `dot_wslconfig` | `~/.wslconfig` | WSL2 メモリ・CPU 設定（Windows のみ） |
| `dot_lastexecrecord/config.json` | `~/.lastexecrecord/config.json` | lastexecrecord スケジュール設定 |
| `modify_dot_gitconfig` | `~/.gitconfig` | Git グローバル設定 |
| `dot_config/git/dotfiles.gitconfig.tmpl` | `~/.config/git/dotfiles.gitconfig` | Managed Git settings |

### Linux Git credentials

Install Git Credential Manager and make `git-credential-manager` available on
`PATH`. The .NET global tool requires the .NET 10 SDK and `~/.dotnet/tools` on
`PATH`. Configure a credential store in the main `~/.gitconfig`: use
`secretservice` with an available D-Bus Secret Service, or `gpg` after setting up
GPG and `pass`. Choose one store per machine. The managed configuration enables
GCM when the executable and a directly configured global store are present;
otherwise existing helpers remain unchanged. After changing the store, apply
the managed config again.

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

Replace `secretservice` with `gpg` for a prepared headless environment. Git
HTTPS and the GitHub CLI use separate authentication; sign in to `gh` separately.

## Repository Structure

```
dotfile/
├── home/                          # chezmoi source root (.chezmoiroot)
│   ├── dot_config/                # ~/.config/ (starship, oh-my-posh, mise, micro, git, VS Code)
│   ├── dot_codex/                 # ~/.codex/ (Codex CLI config)
│   ├── dot_lastexecrecord/        # ~/.lastexecrecord/ (scheduled command config)
│   ├── dot_visualstudio/          # ~/.visualstudio/ (Visual Studio settings export)
│   ├── private_dot_ssh/           # ~/.ssh/ (SSH config, excluded in Dev Containers)
│   ├── run_once_before_*/         # Bootstrap scripts (packages, mise, uv)
│   ├── run_once_after_*/          # Post-apply scripts (git hooks, 1Password, APM, VS settings)
│   └── dot_*, *.tmpl              # Dotfiles and chezmoi templates
├── docs/                          # Architecture and operation guides
├── reference/                     # Reference configs (Windows DSC, etc.)
├── scripts/                       # Helper scripts
├── .github/                       # GitHub Actions workflows
├── install.ps1 / install.sh       # Bootstrap installer
└── .chezmoiroot                   # Points chezmoi source root to home/
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

On macOS, mise installs the packages declared in `home/dot_config/mise/config.toml.tmpl`.
See [macOS package management](docs/homebrew_en.md) for migration and troubleshooting details.

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

# 6. APM で Copilot CLI 設定を適用
apm install

# 6.1 APM 管理先を確認（skills/agents はユーザープロファイル配下）
Get-ChildItem "$HOME/.config/apm"

# 7. Visual Studio の設定をインポート（手動）
#    Tools > Import and Export Settings > Import selected environment settings
#    ファイル: ~/.visualstudio/vscode2026insider.vssettings
```

## ドキュメント

- [アーキテクチャと設計判断](docs/architecture.md)
- [Homebrew パッケージ管理](docs/homebrew_ja.md)
- [winget パッケージ管理](docs/winget_ja.md)
- [日常操作ガイド](docs/operations.md)
- [Windows 固有の設定](docs/windows.md)
- [トラブルシューティング](docs/troubleshooting.md)

## GitHub Actions

- `lint.yml`: Linux / Windows の Shell / PowerShell / YAML / chezmoi / WinGet Configuration を検証し、push-to-main の失敗は GitHub Issue を自動作成
- `tool-spec-watch.yml`: 毎月 1 日・15 日に upstream ツールの仕様変更候補を検知し、対応用の GitHub Issue を自動作成

## ライセンス

MIT
