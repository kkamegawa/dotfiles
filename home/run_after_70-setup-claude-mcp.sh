#!/bin/sh
# run_after_70-setup-claude-mcp.sh
# Register the user-scope MCP servers that the managed Claude Code permissions refer to by name.
# Runs on every chezmoi apply and is idempotent: servers that already exist are left untouched.

set -eu

if ! command -v claude >/dev/null 2>&1; then
  echo "==> Skip Claude Code MCP setup because claude was not found in PATH" >&2
  exit 0
fi

add_http_server() {
  name="$1"
  url="$2"

  if claude mcp get "$name" >/dev/null 2>&1; then
    return 0
  fi

  echo "==> Registering Claude Code MCP server: $name"
  if ! claude mcp add --scope user --transport http "$name" "$url"; then
    echo "==> Failed to register Claude Code MCP server: $name" >&2
  fi
}

# The tool name mcp__microsoft-learn__* in permissions.allow depends on this server name.
add_http_server microsoft-learn https://learn.microsoft.com/api/mcp
