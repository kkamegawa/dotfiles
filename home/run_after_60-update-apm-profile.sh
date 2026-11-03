#!/bin/sh
# APM プロファイル依存関係をステージングし、インストール成功後に反映する。

set -eu

STATE_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/apm-profile"
MANIFEST="${APM_MANIFEST:-$HOME/apm.yml}"
PUBLISHER="${APM_PROFILE_PUBLISHER:-$HOME/.config/apm-profile/apm-profile-publish.py}"

if ! command -v apm >/dev/null 2>&1; then
  echo "==> PATH に apm がないため、APM プロファイル更新をスキップします" >&2
  exit 0
fi
if [ ! -f "$MANIFEST" ]; then
  echo "==> $MANIFEST がないため、APM プロファイル更新をスキップします" >&2
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "==> PATH に python3 がないため、APM プロファイル更新をスキップします" >&2
  exit 0
fi
if [ ! -f "$PUBLISHER" ]; then
  echo "==> パブリッシャー $PUBLISHER がないため、APM プロファイル更新をスキップします" >&2
  exit 0
fi

mkdir -p "$STATE_HOME"
candidate="$(mktemp -d "$STATE_HOME/candidate.XXXXXX")"
cleanup() { rm -rf "$candidate"; }
trap cleanup EXIT HUP INT TERM
cp "$MANIFEST" "$candidate/apm.yml"
mkdir -p "$candidate"

(
  cd "$candidate"
  apm install --refresh --root "$candidate" --target claude,codex,copilot
)

python3 "$PUBLISHER" "$candidate" "$STATE_HOME"
