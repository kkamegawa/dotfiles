#!/bin/sh
# Linux / macOS / WSL ブートストラップスクリプト
# 使い方: ./install.sh
set -e

OS="$(uname -s)"
echo "==> dotfiles セットアップを開始します (OS: $OS)"

# chezmoi がなければインストール
if ! command -v chezmoi >/dev/null 2>&1; then
  echo "==> chezmoi をインストールします..."
  sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin"
fi

# chezmoi init & apply
echo "==> chezmoi init & apply を実行します..."
chezmoi init --apply kkamegawa

echo "==> セットアップ完了。mise install を実行してください:"
echo "    cd ~ && mise install"
