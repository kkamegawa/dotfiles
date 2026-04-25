#!/bin/sh
# run_once_before_30-install-uv.sh
# uv をインストール

set -e

if command -v uv >/dev/null 2>&1; then
  echo "==> uv は既にインストール済みです: $(uv --version)"
  exit 0
fi

echo "==> uv をインストールします..."
curl -LsSf https://astral.sh/uv/install.sh | sh
