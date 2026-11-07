#!/bin/sh
# POSIX sh (including macOS Bash 3.2); JSON/text are never shell commands.
fail() { printf '%s\n' "Japanese response hook: $1" >&2; exit 1; }
skip() { printf '%s\n' "Japanese response hook: $1" >&2; exit 0; }

[ "$#" -eq 1 ] || fail 'expected one client argument: claude, codex, or copilot.'
client=$1
case "$client" in claude|codex|copilot) ;; *) fail 'unsupported client.' ;; esac
command -v jq >/dev/null 2>&1 || fail 'jq is required on PATH.'
payload=$(cat) || fail 'cannot read stdin.'
printf '%s' "$payload" | jq -e -s '
  length == 1 and (.[0] | type == "object"
    and (.stop_hook_active | type == "boolean")
    and ((has("hook_event_name") | not) or .hook_event_name == "Stop"))
' >/dev/null 2>&1 || fail 'expected one Stop JSON object with boolean stop_hook_active.'
active=$(printf '%s' "$payload" | jq -r '.stop_hook_active') || fail 'cannot parse stop state.'
[ "$active" = true ] && exit 0

if [ "$client" = copilot ]; then
  path=$(printf '%s' "$payload" | jq -er '
    (.transcriptPath // .transcript_path) | select(type == "string" and length > 0)
  ' 2>/dev/null) || fail 'Copilot requires transcriptPath or transcript_path.'
  [ -f "$path" ] && [ -r "$path" ] || fail 'Copilot transcript is not a readable file.'
  # Copilot's persisted SDK events, NOT Claude message.content or Codex rollout.
  # Reset at turn/user boundaries and at every root assistant message: never
  # fall back to stale prose when the latest message is empty or tool-only.
  text=$(jq -ejr -s '
    reduce .[] as $e (null;
      if ($e | type) != "object" then error("invalid event")
      elif $e.agentId != null or $e.checkpoint == true
        or $e.data.parentToolCallId != null then .
      elif $e.type == "user.message" or $e.type == "assistant.turn_start" then null
      elif $e.type == "assistant.message" then
        if ($e.data.content | type) == "string"
          and (($e.data.toolRequests // []) | length) == 0
          and ($e.data.phase == null or $e.data.phase == "final" or $e.data.phase == "final_answer")
        then $e.data.content else null end
      else . end)
    | (if . == null then "" else . end) + "\u0001"
  ' -- "$path" 2>/dev/null) || fail 'cannot parse Copilot transcript JSONL.'
else
  printf '%s' "$payload" | jq -e '
    .last_assistant_message == null or (.last_assistant_message | type) == "string"
  ' >/dev/null 2>&1 || fail 'last_assistant_message must be a string or null.'
  text=$(printf '%s' "$payload" | jq -jr '(.last_assistant_message // "") + "\u0001"') ||
    fail 'cannot read last_assistant_message.'
fi
# The sentinel preserves trailing newlines through shell command substitution.
text=${text%?}
[ -n "$text" ] || skip 'final assistant text unavailable; check the client version/transcript format.'
command -v perl >/dev/null 2>&1 || fail 'Perl is required on PATH.'

# UTF-8 decoding does not depend on the locale. Count Unicode letters only.
# These kana/Han ranges are shared with the PowerShell implementation.
verdict=$(printf '%s' "$text" | perl -MEncode=decode,FB_CROAK -e '
  local $/;
  my $text = decode("UTF-8", scalar <STDIN>, FB_CROAK);
  my ($fence, $width, @prose);
  for my $line (split /\r?\n/, $text, -1) {
    if (defined $fence) {
      if ($line =~ /^ {0,3}\Q$fence\E{$width,}[ \t]*$/) { undef $fence; }
    } elsif ($line =~ /^ {0,3}(`{3,}|~{3,})/) {
      $fence = substr($1, 0, 1); $width = length($1);
    } else { push @prose, $line; }
  }
  $text = join("\n", @prose);
  $text =~ s/(?<!`)(`+)(?!`).*?(?<!`)\1(?!`)//gs;
  my ($letters, $japanese) = (0, 0);
  for my $char (split //, $text) {
    next unless $char =~ /\p{L}/;
    ++$letters;
    ++$japanese if $char =~ /[\x{3040}-\x{309F}\x{30A0}-\x{30FF}\x{31F0}-\x{31FF}\x{3400}-\x{4DBF}\x{4E00}-\x{9FFF}\x{F900}-\x{FAFF}\x{FF66}-\x{FF9D}\x{20000}-\x{2FA1F}\x{30000}-\x{323AF}]/;
  }
  print (($letters >= 30 && $japanese * 5 < $letters) ? "block" : "allow");
') || fail 'cannot inspect UTF-8 response text.'
if [ "$verdict" = block ]; then
  printf '%s\n' '{"decision":"block","reason":"最終応答の説明文を日本語で書き直してください。コード・コマンド・パス・識別子は変更せず、作業やツール実行を繰り返さずに回答だけを修正してください。"}'
fi
exit 0
