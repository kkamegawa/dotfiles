#!/bin/sh
# Install macOS packages managed directly by Homebrew.
# Node.js and Python runtimes are intentionally excluded; use Volta and uv instead.

set -e

if [ "$(uname -s)" != "Darwin" ]; then
  exit 0
fi

SUDO_KEEPALIVE_PID=

stop_sudo_keepalive() {
  if [ -n "$SUDO_KEEPALIVE_PID" ]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    SUDO_KEEPALIVE_PID=
  fi
}

start_sudo_keepalive() {
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi

  echo "==> Requesting sudo once for Homebrew cask installation..."
  sudo -v

  (
    while :; do
      sleep 60
      sudo -n -v || exit 0
    done
  ) &
  SUDO_KEEPALIVE_PID=$!
  trap stop_sudo_keepalive EXIT HUP INT TERM
}

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

cask_has_auto_updates() {
  printf '%s\n' "$1" | jq -e '.casks[0].auto_updates == true' >/dev/null
}

cask_is_recorded_installed() {
  printf '%s\n' "$1" | jq -e '
    .casks[0].installed as $installed
    | if $installed == null then false
      elif ($installed | type) == "array" then ($installed | length > 0)
      elif ($installed | type) == "string" then ($installed | length > 0)
      else true
      end
  ' >/dev/null
}

cask_app_paths() {
  printf '%s\n' "$1" | jq -r '
    def path_values:
      if type == "array" then
        .[]
        | if type == "string" then .
          elif type == "object" then (.target? // empty)
          else empty
          end
      elif type == "string" then .
      elif type == "object" then (.target? // empty)
      else empty
      end;

    (
      (
        .casks[0].artifacts[]?
        | objects
        | (
            (.app? // empty | path_values),
            (
              .uninstall? // empty
              | if type == "array" then .[] elif type == "object" then . else empty end
              | objects
              | .delete? // empty
              | path_values
            )
          )
      ),
      (.casks[0].name[]? | select(type == "string") | . + ".app")
    )
    | select(test("\\.app$"))
  ' | awk '!seen[$0]++'
}

path_exists() {
  candidate=$1

  case "$candidate" in
    \~/*)
      candidate="$HOME/${candidate#\~/}"
      ;;
  esac

  [ -e "$candidate" ]
}

cask_app_is_installed() {
  apps="$(cask_app_paths "$1")"

  [ -n "$apps" ] || return 1

  old_ifs=$IFS
  IFS='
'
  found=1
  for app in $apps; do
    case "$app" in
      /*|\~/*)
        if path_exists "$app"; then
          found=0
        fi
        ;;
      *)
        for app_dir in /Applications "$HOME/Applications"; do
          if [ -e "$app_dir/$app" ]; then
            found=0
            break
          fi
        done
        ;;
    esac
    [ "$found" -ne 0 ] || break
  done
  IFS=$old_ifs

  return "$found"
}

install_cask() {
  cask=$1
  metadata="$(brew info --cask --json=v2 "$cask")"

  if cask_has_auto_updates "$metadata"; then
    if cask_is_recorded_installed "$metadata"; then
      echo "==> Skipping self-updating cask $cask because Homebrew already records it as installed"
      return 0
    fi

    if cask_app_is_installed "$metadata"; then
      echo "==> Skipping self-updating cask $cask because its app is already installed"
      return 0
    fi
  fi

  if brew list --cask "$cask" >/dev/null 2>&1; then
    echo "==> Skipping installed cask $cask"
    return 0
  fi

  brew install --cask "$cask"
}

install_casks() {
  start_sudo_keepalive

  while IFS= read -r cask; do
    [ -n "$cask" ] || continue
    install_cask "$cask"
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

  stop_sudo_keepalive
  trap - EXIT HUP INT TERM
}

install_formulae
install_casks
