#!/bin/sh
# PreToolUse syntax guard. The payload is data and is never executed.
if ! command -v node >/dev/null 2>&1; then
  printf '%s\n' 'Blocked: assignment guard requires Node.js on PATH. Install it and retry.' >&2
  exit 2
fi

node -e '
const { readFileSync } = require("node:fs");
const isObject = value => value !== null && typeof value === "object" && !Array.isArray(value);
try {
  const data = JSON.parse(readFileSync(0, "utf8"));
  if (!isObject(data) || typeof data.tool_name !== "string" || !data.tool_name.trim()) {
    throw new Error("invalid tool payload");
  }
  if (data.tool_name !== "Bash") process.exit(0);
  if (!isObject(data.tool_input) || typeof data.tool_input.command !== "string") {
    throw new Error("invalid command field");
  }
  if (/^\s*[A-Za-z_][A-Za-z0-9_]*(?:\+)?=/.test(data.tool_input.command)) {
    process.stderr.write("Blocked: leading variable assignments are not allowed. Rewrite the command using direct absolute paths instead of assigning a path to a variable.\n");
    process.exit(2);
  }
} catch {
  process.stderr.write("Blocked: assignment guard expects a JSON object with tool_name and a string tool_input.command for Bash. Fix the hook payload and retry.\n");
  process.exit(2);
}
'
status=$?
if [ "$status" -ne 0 ] && [ "$status" -ne 2 ]; then
  printf '%s\n' 'Blocked: assignment guard failed to run. Check Node.js and retry.' >&2
  exit 2
fi
exit "$status"
