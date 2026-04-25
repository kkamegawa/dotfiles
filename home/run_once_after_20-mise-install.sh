#!/bin/sh
# run_once_after_20-mise-install.sh
# mise install でツールをインストール

set -e

if ! command -v mise >/dev/null 2>&1; then
  echo "⚠️  mise が見つかりません。run_once_before_20-install-mise.sh を確認してください" >&2
  exit 1
fi

echo "==> mise install を実行します..."
mise install
echo "==> mise install 完了"
