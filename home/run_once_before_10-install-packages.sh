#!/bin/sh
# run_once_before_10-install-packages.sh
# パッケージマネージャー（Homebrew / apt）で基本パッケージをインストール
# chezmoi が初回実行時のみ実行する

set -e

OS="$(uname -s)"

if [ "$OS" = "Darwin" ]; then
  # macOS — Homebrew
  if ! command -v brew >/dev/null 2>&1; then
    echo "==> Homebrew をインストールします..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  brew install git curl fzf gh gitleaks

elif [ "$OS" = "Linux" ]; then
  # Linux / WSL — apt
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends \
      git curl unzip ca-certificates build-essential \
      fzf
  fi
fi
