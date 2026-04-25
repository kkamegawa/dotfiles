#!/bin/sh
# run_once_before_20-install-mise.sh
# mise をインストール

set -e

if command -v mise >/dev/null 2>&1; then
  echo "==> mise は既にインストール済みです: $(mise --version)"
  exit 0
fi

echo "==> mise をインストールします..."
curl -fsSL https://mise.run | sh
