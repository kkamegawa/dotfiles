#!/bin/sh
# run_once_before_10-install-packages.sh
# パッケージマネージャー（Homebrew / apt）で基本パッケージをインストール
# chezmoi が初回実行時のみ実行する

set -e

install_powershell_apt() {
  if command -v pwsh >/dev/null 2>&1; then
    return 0
  fi

  if [ ! -r /etc/os-release ]; then
    echo "==> /etc/os-release が見つからないため、PowerShell の自動インストールをスキップします" >&2
    return 0
  fi

  # shellcheck disable=SC1091
  . /etc/os-release

  case "$ID" in
    ubuntu|debian)
      ;;
    *)
      echo "==> $ID では PowerShell の自動インストールをスキップします" >&2
      return 0
      ;;
  esac

  sudo apt-get install -y --no-install-recommends apt-transport-https gpg

  if ! dpkg -s packages-microsoft-prod >/dev/null 2>&1; then
    tmp_deb="$(mktemp)"
    curl -fsSL "https://packages.microsoft.com/config/$ID/$VERSION_ID/packages-microsoft-prod.deb" -o "$tmp_deb"
    sudo dpkg -i "$tmp_deb"
    rm -f "$tmp_deb"
    sudo apt-get update -qq
  fi

  sudo apt-get install -y --no-install-recommends powershell
}

OS="$(uname -s)"

if [ "$OS" = "Darwin" ]; then
  # macOS — Homebrew
  if ! command -v brew >/dev/null 2>&1; then
    echo "==> Homebrew をインストールします..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  brew install git curl fzf gh gitleaks
  if ! command -v pwsh >/dev/null 2>&1; then
    brew install --cask powershell
  fi

elif [ "$OS" = "Linux" ]; then
  # Linux / WSL — apt
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends \
      git curl unzip ca-certificates build-essential \
      fzf
    install_powershell_apt
  fi
fi
