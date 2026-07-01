import { readFileSync } from 'node:fs';

const PIPE_TO_SHELL = /\|\s*(?:(?:\S*[\\/])?env\s+(?:-\S+\s+)*)?(?:\S*[\\/])?(bash|sh|zsh|fish|ksh|dash)(?:\.exe)?\b/i;

function main() {
  try {
    const input = readFileSync(0, 'utf8');
    if (!input.trim()) {
      process.exit(0);
    }

    const data = JSON.parse(input);
    const toolName = data.tool_name ?? '';
    const command = data.tool_input?.command ?? '';

    if (toolName === 'Bash' && PIPE_TO_SHELL.test(command)) {
      process.stderr.write('Blocked: piping command output directly to a shell is not allowed.\n');
      process.exit(2);
    }

    process.exit(0);
  } catch {
    process.exit(0);
  }
}

main();
