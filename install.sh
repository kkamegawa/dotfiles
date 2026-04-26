#!/bin/sh
# Linux / macOS / WSL bootstrap script.
# Usage: ./install.sh
set -e

OS="$(uname -s)"
SCRIPT_DIR=$(
  CDPATH='' cd -- "$(dirname -- "$0")" && pwd
)

case "$OS" in
  Linux|Darwin)
    ;;
  *)
    echo "==> install.sh supports Linux, macOS, and WSL only. Use install.ps1 on Windows." >&2
    exit 1
    ;;
esac

echo "==> Starting dotfiles setup (OS: $OS)"

if ! command -v chezmoi >/dev/null 2>&1; then
  echo "==> Installing chezmoi..."
  sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin"
  PATH="$HOME/.local/bin:$PATH"
  export PATH
fi

echo "==> Running chezmoi init & apply..."
if [ -f "$SCRIPT_DIR/.chezmoiroot" ]; then
  chezmoi init --apply "$SCRIPT_DIR"
else
  chezmoi init --apply kkamegawa
fi

echo "==> Setup complete. Run mise install next:"
echo "    cd ~ && mise install"
