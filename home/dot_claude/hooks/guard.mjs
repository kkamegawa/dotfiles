import { readFileSync } from 'node:fs';
import { execSync } from 'node:child_process';

const PIPE_TO_SHELL = /\|\s*(?:(?:\S*[\\/])?env\s+(?:-\S+\s+)*)?(?:\S*[\\/])?(bash|sh|zsh|fish|ksh|dash)(?:\.exe)?\b/i;

// --- trusted-repo auto-approve ---
// kkamegawa/*, tfsugjp/* 配下のリポジトリに対する gh pr / gh issue 操作は
// 破壊的操作チェックを通過した場合に限り自動承認する。

const TRUSTED_OWNERS = ['kkamegawa', 'tfsugjp'];

// 自動承認の対象となる gh サブコマンド。merge/close 等を除外したい場合はここを調整。
const GH_ALLOW_PATTERN =
  /^\s*gh\s+(pr|issue)\s+(create|edit|comment|close|reopen|review|merge|ready)\b/;

/**
 * Bash コマンド文字列と cwd から対象リポジトリの owner を特定する。
 * 1. `--repo owner/repo` / `-R owner/repo` があれば優先
 * 2. 無ければ cwd の `git remote get-url origin` から解決
 */
function extractRepoOwner(command, cwd) {
  const flagMatch = command.match(/(?:--repo|-R)[\s=]+([^\s/]+)\/[^\s]+/);
  if (flagMatch) return flagMatch[1];

  try {
    const url = execSync('git remote get-url origin', {
      cwd,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
    // 対応形式: git@host:owner/repo.git / https://host/owner/repo(.git)
    const m = url.match(/[:/]([^/]+)\/[^/]+?(?:\.git)?$/);
    if (m) return m[1];
  } catch {
    // git remote が取れない場合は owner 不明として扱う
  }
  return null;
}

function isTrustedRepoCommand(toolName, command, cwd) {
  if (toolName !== 'Bash') return false;
  if (!GH_ALLOW_PATTERN.test(command)) return false;

  const owner = extractRepoOwner(command, cwd);
  if (!owner) return false;

  return TRUSTED_OWNERS.includes(owner.toLowerCase());
}

function main() {
  try {
    const input = readFileSync(0, 'utf8');
    if (!input.trim()) {
      process.exit(0);
    }

    const data = JSON.parse(input);
    const toolName = data.tool_name ?? '';
    const command = data.tool_input?.command ?? '';
    const cwd = data.cwd ?? process.cwd();

    // 1) 破壊的操作の deny 判定 (既存ロジック、最優先)
    if (toolName === 'Bash' && PIPE_TO_SHELL.test(command)) {
      process.stderr.write('Blocked: piping command output directly to a shell is not allowed.\n');
      process.exit(2);
    }

    // 2) deny されなかった場合のみ、信頼リポジトリなら自動承認
    if (isTrustedRepoCommand(toolName, command, cwd)) {
      process.stdout.write(JSON.stringify({
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          permissionDecision: 'allow',
          permissionDecisionReason: 'trusted-repo-approval: kkamegawa/tfsugjp配下のPR/Issue操作のため自動承認',
        },
      }));
      process.exit(0);
    }

    // 3) それ以外は何も出力せず終了 → 通常の ask フローへパススルー
    process.exit(0);
  } catch {
    process.exit(0);
  }
}

main();
