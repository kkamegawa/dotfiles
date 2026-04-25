#!/bin/sh
# Linux / macOS / WSL bootstrap script.
# Usage: ./install.sh
set -e

OS="$(uname -s)"
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
fi

echo "==> Running chezmoi init & apply..."
chezmoi init --apply kkamegawa

echo "==> Setup complete. Run mise install next:"
echo "    cd ~ && mise install"
