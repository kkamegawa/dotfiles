import { readFileSync } from 'node:fs';

function main() {
  try {
    const input = readFileSync(0, 'utf8');
    if (input.trim()) {
      JSON.parse(input);
    }
  } catch {
    // Ignore hook payload parsing issues and keep the edit flow moving.
  }

  process.exit(0);
}

main();