import { readFileSync } from 'node:fs';

function main() {
  try {
    const input = readFileSync(0, 'utf8');
    if (!input.trim()) {
      process.exit(0);
    }

    JSON.parse(input);
    process.exit(0);
  } catch {
    process.exit(0);
  }
}

main();