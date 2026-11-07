#!/bin/sh
# Payload stays on stdin; no part of it is evaluated by a shell.
if ! command -v node >/dev/null 2>&1; then
  printf '%s\n' 'Hook adapter requires Node.js on PATH.' >&2
  if [ "$2" = "PreToolUse" ]; then exit 2; fi
  exit 1
fi
node "$(dirname "$0")/adapter.mjs" "$@"
status=$?
if [ "$status" -ne 0 ]; then
  if [ "$2" = "PreToolUse" ]; then exit 2; fi
  exit 1
fi
