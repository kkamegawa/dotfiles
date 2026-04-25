#!/bin/sh
# run_once_after_30-setup-1password.sh
# 1Password SSH エージェントの設定確認

set -e

OS="$(uname -s)"

if [ "$OS" = "Darwin" ]; then
  AGENT_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
  if [ -S "$AGENT_SOCK" ]; then
    echo "==> 1Password SSH エージェント（macOS）が利用可能です"
  else
    echo "⚠️  1Password SSH エージェントが見つかりません。"
    echo "   1Password > 設定 > 開発者 > SSH エージェントを有効化してください。"
  fi

elif [ "$OS" = "Linux" ]; then
  AGENT_SOCK="$HOME/.config/1Password/ssh/agent.sock"
  WSL_SOCK="$HOME/.1password/agent.sock"
  if [ -S "$AGENT_SOCK" ] || [ -S "$WSL_SOCK" ]; then
    echo "==> 1Password SSH エージェント（Linux/WSL）が利用可能です"
  else
    echo "⚠️  1Password SSH エージェントが見つかりません。"
    echo "   詳細は docs/operations.md を参照してください。"
  fi
fi

echo "==> SSH 公開鍵一覧:"
ssh-add -L 2>/dev/null || echo "   （エージェントにキーがありません）"
