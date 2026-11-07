import { readFileSync, writeFileSync, mkdirSync, unlinkSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(fileURLToPath(import.meta.url));
const [client, event, host] = process.argv.slice(2);
const windows = host === 'windows' || process.platform === 'win32';
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
function emit(value) { process.stdout.write(JSON.stringify(value)); }
function deny(reason) {
  process.stderr.write(`${reason}\n`);
  if (client === 'copilot') emit({ permissionDecision: 'deny', permissionDecisionReason: reason });
  else emit({ hookSpecificOutput: {
    hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason,
  } });
  process.exit(2);
}
function run(executable, args, input, timeout) {
  const result = spawnSync(executable, args, { input: JSON.stringify(input), encoding: 'utf8', timeout });
  if (result.error || result.signal || result.status !== 0) {
    throw new Error(result.stderr?.trim() || result.error?.message || `Hook exited ${result.status}`);
  }
  return result.stdout.trim();
}

function toolPayload(data) {
  // PascalCase Copilot config requests compatible snake_case input. Also accept
  // its native camelCase wire for diagnostics and older configurations.
  const name = data.tool_name ?? data.toolName;
  let input = data.tool_input ?? data.toolArgs;
  if (typeof input === 'string') input = JSON.parse(input);
  if (typeof name !== 'string' || !name.trim()) throw new Error('Missing tool name');
  const shell = ['Bash', 'exec_command', 'shell_command', 'bash', 'powershell', 'PowerShell'].includes(name);
  if (shell && (!object(input) || typeof input.command !== 'string')) {
    throw new Error('Shell hook requires a string tool_input.command');
  }
  return { ...data, tool_name: shell ? 'Bash' : name, tool_input: input };
}

function preToolUse(data) {
  const payload = toolPayload(data);
  // Validate all denial rules before returning the shared guard's approval.
  // No rules are copied into this adapter; chezmoi distributes the Claude sources.
  for (const name of ['leading-assignment', 'deny-cd']) {
    if (windows) run('pwsh', ['-NoLogo', '-NoProfile', '-NonInteractive', '-File', join(root, `${name}.ps1`)], payload, 8000);
    else run('sh', [join(root, `${name}.sh`)], payload, 8000);
  }
  const output = run(process.execPath, [join(root, 'guard.mjs')], payload, 8000);
  if (output) {
    const parsed = JSON.parse(output);
    emit(client === 'copilot' ? parsed.hookSpecificOutput : parsed);
  }
}

function recovery(data) {
  if (client !== 'codex') throw new Error('Copilot has no PostCompact recovery contract');
  if (typeof data.session_id !== 'string' || !data.session_id.trim()) throw new Error('Missing session_id');
  // Hash identifiers so session-controlled strings cannot escape the state dir.
  const state = join(root, 'state', client);
  const file = join(state, `${createHash('sha256').update(data.session_id).digest('hex')}.summary`);
  if (event === 'PostCompact') {
    // Clear the old summary first: never inject a stale summary after a newer
    // compaction with an unavailable/unsupported transcript.
    try { unlinkSync(file); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    let summary = data.compact_summary;
    if (summary !== undefined && typeof summary !== 'string') throw new Error('Invalid compact_summary');
    if (!summary?.trim() && typeof data.transcript_path === 'string') {
      // Best effort only: Codex explicitly does not promise a stable transcript.
      // Read only compacted records, never arbitrary assistant/user messages.
      const records = readFileSync(data.transcript_path, 'utf8').split(/\r?\n/).filter(line => line.trim());
      for (const line of records) {
        const record = JSON.parse(line);
        if (record.type === 'compacted') summary = record.payload?.message;
      }
    }
    if (typeof summary !== 'string' || !summary.trim()) {
      process.stderr.write('Recovery skipped: Codex did not provide a recognized compaction summary.\n');
      return;
    }
    mkdirSync(state, { recursive: true, mode: 0o700 });
    writeFileSync(file, summary, { encoding: 'utf8', mode: 0o600 });
    return;
  }
  let summary;
  try { summary = readFileSync(file, 'utf8'); } catch (error) {
    if (error.code === 'ENOENT') return;
    throw error;
  }
  emit({ hookSpecificOutput: {
    hookEventName: 'UserPromptSubmit',
    additionalContext: `[Post-compact recovery] The context window was compacted. Summary of the previous session:\n${summary}`,
  } });
  unlinkSync(file); // Match Claude's one-shot restoration semantics.
}

try {
  if (!['codex', 'copilot'].includes(client)) throw new Error('Unknown hook client');
  const data = JSON.parse(readFileSync(0, 'utf8'));
  if (!object(data)) throw new Error('Hook input must be a JSON object');
  if (event === 'PreToolUse') preToolUse(data);
  else if (event === 'PostToolUse') {
    // The current Claude formatter only consumes JSON and exits. Preserve that
    // behavior, including apply_patch text; do not invent path-based formatting.
    run(process.execPath, [join(root, 'format.mjs')], toolPayload(data), 25000);
  } else if (['PostCompact', 'UserPromptSubmit'].includes(event)) recovery(data);
  else throw new Error('Unknown hook event');
} catch (error) {
  if (event === 'PreToolUse') deny(`Blocked: ${error.message}`);
  process.stderr.write(`Hook adapter failed: ${error.message}\n`);
  process.exit(1);
}
