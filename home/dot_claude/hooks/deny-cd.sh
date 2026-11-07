#!/bin/sh
# PreToolUse syntax guard, not a shell parser. Never execute the payload.
if ! command -v node >/dev/null 2>&1; then
  printf '%s\n' 'Blocked: directory guard requires Node.js on PATH. Install it and retry.' >&2
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
  // Keywords must follow a command boundary, not arbitrary argument text.
  // Quotes/escapes are not parsed: quoted separators can also trigger a match.
  const directoryChange = /(?:^|[;&|()\r\n{}`])[ \t]*(?:(?:if|then|elif|else|while|until|do|!)[ \t]+)*(?:cd|pushd|popd|chdir)(?=$|[\s;&|(){}<>`])/;
  if (directoryChange.test(data.tool_input.command)) {
    process.stderr.write("Blocked: directory changes are not allowed. Use direct absolute paths instead (git -C /absolute/repo status; python3 /absolute/path/script.py), without cd/pushd/popd/chdir.\n");
    process.exit(2);
  }
} catch {
  process.stderr.write("Blocked: directory guard expects a JSON object with tool_name and a string tool_input.command for Bash. Fix the hook payload and retry.\n");
  process.exit(2);
}
'
status=$?
if [ "$status" -ne 0 ] && [ "$status" -ne 2 ]; then
  printf '%s\n' 'Blocked: directory guard failed to run. Check Node.js and retry.' >&2
  exit 2
fi
exit "$status"
