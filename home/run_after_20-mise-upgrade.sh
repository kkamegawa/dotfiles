#!/bin/sh
# run_after_20-mise-upgrade.sh
# Keep mise-managed tools up to date on every chezmoi apply/update.

set -e

if ! command -v mise >/dev/null 2>&1; then
  echo "⚠️  mise が見つかりません。mise upgrade をスキップします" >&2
  exit 0
fi

echo "==> mise install を実行します..."
mise install

echo "==> mise upgrade を実行します..."
mise upgrade

echo "==> mise install/upgrade 完了"
