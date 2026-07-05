# 閾値超で compact-prep 警告 marker を書く（cooldown 中でなければ）
COMPACT_WARN_THRESHOLD=60
if [ -n "$session_id" ] && [ "$int_pct" -ge "$COMPACT_WARN_THRESHOLD" ] 2>/dev/null; then
  _warn_dir="${TMPDIR:-/tmp}/claude-compact-warned"
  if [ ! -f "$_warn_dir/$session_id" ]; then
    _ctx_warn_dir="${TMPDIR:-/tmp}/claude-compact-warn"
    mkdir -p "$_ctx_warn_dir" 2>/dev/null || true
    printf '%s\n' "$int_pct" > "$_ctx_warn_dir/$session_id" 2>/dev/null || true
  fi
fi
