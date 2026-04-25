#!/bin/sh
# run_once_after_10-setup-git-hooks.sh
# git core.hooksPath を ~/.config/git/hooks に設定し、
# pre-commit フックに実行権限を付与する

set -e

HOOKS_DIR="$HOME/.config/git/hooks"

echo "==> git hooks パスを設定します: $HOOKS_DIR"
git config --global core.hooksPath "$HOOKS_DIR"

# 実行権限付与
if [ -f "$HOOKS_DIR/pre-commit" ]; then
  chmod +x "$HOOKS_DIR/pre-commit"
fi

echo "==> git hooks セットアップ完了"
