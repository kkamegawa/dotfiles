#!/bin/sh
# Install macOS packages managed directly by Homebrew.
# Node.js and Python runtimes are intentionally excluded; use Volta and uv instead.

set -e

if [ "$(uname -s)" != "Darwin" ]; then
  exit 0
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "==> Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

if [ -x /opt/homebrew/bin/brew ]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -x /usr/local/bin/brew ]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi

install_formulae() {
  while IFS= read -r formula; do
    [ -n "$formula" ] || continue
    brew install "$formula"
  done <<'EOF'
ansible
ansible-lint
azure-cli
azure/azd/azd
azure/bicep/bicep
azure/functions/azure-functions-core-tools@4
cmake
curl
docker-completion
docker-squash
gh
git
git-lfs
hashicorp/tap/packer
jq
komac
micro
microsoft/foundrylocal/foundrylocal
oh-my-posh
powershell
starship
termscp
uv
volta
wget
EOF
}

install_casks() {
  while IFS= read -r cask; do
    [ -n "$cask" ] || continue
    brew install --cask "$cask"
  done <<'EOF'
1password
1password-cli
adobe-creative-cloud
bing-wallpaper
blender
cleanshot
copilot-cli@prerelease
daisydisk
devtoys
discord
docker-desktop
dotnet-sdk
firefox
font-biz-udgothic
font-biz-udmincho
font-biz-udpgothic
font-biz-udpmincho
font-cica
font-jetbrains-mono-nerd-font
font-monaspace
font-noto-sans-cjk-jp
font-noto-sans-mono-cjk-jp
font-plemol-jp
font-plemol-jp-nf
ghostty
git-credential-manager
github
github-copilot-for-xcode
google-chrome
intune-company-portal
iterm2
jetbrains-toolbox
karabiner-elements
maccy
microsoft-auto-update
microsoft-azure-storage-explorer
microsoft-edge
microsoft-edge@beta
microsoft-edge@dev
microsoft-openjdk
microsoft-openjdk@17
spotify
visual-studio-code
visual-studio-code@insiders
zoom
EOF
}

install_formulae
install_casks
