import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

/**
 * statusLine script for Claude Code.
 * Receives JSON session data on stdin, outputs a formatted context bar.
 * Creates ~/.claude/hooks-state/{session_id}.warned when context >= 60%.
 */

function buildBar(pct, width) {
  const filled = Math.round((pct / 100) * width);
  const empty = width - filled;
  const color =
    pct >= 80 ? '\x1b[31m' : pct >= 60 ? '\x1b[33m' : '\x1b[32m';
  const reset = '\x1b[0m';
  return `${color}[${'█'.repeat(filled)}${'░'.repeat(empty)}]${reset}`;
}

function main() {
  try {
    const raw = readFileSync(0, 'utf8').trim();
    if (!raw) return;

    const data = JSON.parse(raw);
    const model = data.model?.display_name ?? 'Claude';
    const pct = Math.max(0, Math.min(100, Math.round(+data.context_window?.used_percentage || 0)));
    const cwd = data.cwd ?? '';
    const sessionId = data.session_id ?? 'unknown';

    // Write warned marker once when context reaches 60%
    const stateDir = join(homedir(), '.claude', 'hooks-state');
    mkdirSync(stateDir, { recursive: true });
    const warnFile = join(stateDir, `${sessionId}.warned`);
    if (pct >= 60 && !existsSync(warnFile)) {
      writeFileSync(warnFile, new Date().toISOString(), 'utf8');
    }

    const dirName = cwd.split(/[/\\]/).pop() || cwd;
    const bar = buildBar(pct, 20);
    process.stdout.write(`[${model}] 📁 ${dirName} | ${bar} ${pct}%\n`);
  } catch {
    // Silent failure: never crash the status line
  }
}

main();
