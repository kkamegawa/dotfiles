// trusted-repo-approval.mjs
//
// 既存の guard.mjs (PreToolUse hook) に組み込むための追加ロジック。
// 目的: kkamegawa/*, tfsugjp/* 配下のリポジトリに対する gh pr / gh issue
//       操作は自動承認し、それ以外は従来通り ask (確認プロンプト) に委ねる。
//
// 統合方針:
//   guard.mjs のメインハンドラで「破壊的操作の deny 判定」を行った *後*、
//   まだ deny されていない場合に isTrustedRepoCommand() を呼び、
//   true なら allow を返して終了する。deny 判定より前に置かないこと
//   (信頼リポジトリだからといって破壊的操作まで自動許可しないため)。

import { execSync } from "node:child_process";

// 自動承認の対象 owner (GitHub organization / user, 小文字で比較)
const TRUSTED_OWNERS = ["kkamegawa", "tfsugjp"];

// 自動承認の対象となる gh サブコマンド
// 必要に応じて調整可能。merge / close 等の破壊的寄りの操作を除外したい場合はここで絞る。
const GH_ALLOW_PATTERN =
  /^\s*gh\s+(pr|issue)\s+(create|edit|comment|close|reopen|review|merge|ready)\b/;

/**
 * Bash tool_input のコマンド文字列から対象リポジトリの owner を特定する。
 * 1. `--repo owner/repo` または `-R owner/repo` があればそれを優先
 * 2. 無ければ cwd の `git remote get-url origin` から解決
 */
function extractRepoOwner(command, cwd) {
  const flagMatch = command.match(/(?:--repo|-R)[\s=]+([^\s/]+)\/[^\s]+/);
  if (flagMatch) return flagMatch[1];

  try {
    const url = execSync("git remote get-url origin", {
      cwd,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    // 対応形式: git@host:owner/repo.git / https://host/owner/repo(.git)
    const m = url.match(/[:/]([^/]+)\/[^/]+?(?:\.git)?$/);
    if (m) return m[1];
  } catch {
    // git remote が取れない = 通常のgitリポジトリではない等。owner不明として扱う。
  }
  return null;
}

/**
 * この PreToolUse イベントを自動承認してよいか判定する。
 * @param {string} toolName - hook stdin の tool_name
 * @param {object} toolInput - hook stdin の tool_input
 * @param {string} cwd - hook stdin の cwd
 * @returns {boolean}
 */
export function isTrustedRepoCommand(toolName, toolInput, cwd) {
  if (toolName !== "Bash") return false;

  const command = toolInput?.command ?? "";
  if (!GH_ALLOW_PATTERN.test(command)) return false;

  const owner = extractRepoOwner(command, cwd);
  if (!owner) return false;

  return TRUSTED_OWNERS.includes(owner.toLowerCase());
}

/**
 * guard.mjs のメイン処理から呼び出す想定のヘルパー。
 * 信頼リポジトリなら allow の hookSpecificOutput を返し、
 * そうでなければ null を返す(呼び出し側で従来のフローに継続させる)。
 */
export function maybeAutoApprove(toolName, toolInput, cwd) {
  if (!isTrustedRepoCommand(toolName, toolInput, cwd)) return null;

  return {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      permissionDecisionReason:
        "trusted-repo-approval: kkamegawa/tfsugjp配下のPR/Issue操作のため自動承認",
    },
  };
}
