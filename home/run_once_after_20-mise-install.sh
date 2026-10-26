#!/bin/sh
# run_once_after_20-mise-install.sh
# mise install でツールをインストール

set -e

if ! command -v mise >/dev/null 2>&1; then
  echo "⚠️  mise が見つかりません。run_once_before_20-install-mise.sh を確認してください" >&2
  exit 1
fi

echo "==> mise install を実行します..."
if [ "$(uname -s)" = "Darwin" ]; then
  MISE_CONFIG_FILE="$HOME/.config/mise/config.toml" mise -C "$HOME" install
  dotnet_root="$HOME/.local/share/mise/dotnet-root"
  dotnet_host=$(MISE_CONFIG_FILE="$HOME/.config/mise/config.toml" mise -C "$HOME" which dotnet)
  case "$dotnet_host" in
    "$dotnet_root"/*) ;;
    *) echo "mise selected dotnet outside the shared root: $dotnet_host" >&2; exit 1 ;;
  esac
  [ -x "$dotnet_host" ] || { echo "Managed dotnet host is missing: $dotnet_host" >&2; exit 1; }
  echo "==> mise bootstrap packages を適用します..."
  MISE_CONFIG_FILE="$HOME/.config/mise/config.toml" mise -C "$HOME" bootstrap packages apply
else
  mise install
fi
echo "==> mise install 完了"
