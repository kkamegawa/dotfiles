#!/bin/sh
# run_once_after_60-setup-apm-profile.sh
# Prepare user-profile directories for APM-managed skills and agents.

set -eu

XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
APM_PROFILE_HOME="${APM_PROFILE_HOME:-$XDG_CONFIG_HOME/apm}"
APM_AGENTS_DIR="${APM_AGENTS_DIR:-$APM_PROFILE_HOME/agents}"
APM_SKILLS_DIR="${APM_SKILLS_DIR:-$APM_PROFILE_HOME/skills}"

mkdir -p "$APM_AGENTS_DIR" "$APM_SKILLS_DIR" "$HOME/.github" "$HOME/.copilot"

link_dir() {
  target="$1"
  link="$2"

  if [ -L "$link" ]; then
    current_target="$(readlink "$link")"
    if [ "$current_target" = "$target" ]; then
      return 0
    fi
    rm -f "$link"
  elif [ -d "$link" ]; then
    if [ -n "$(ls -A "$link" 2>/dev/null)" ]; then
      echo "==> Skip linking $link because the directory is not empty" >&2
      return 0
    fi
    rmdir "$link"
  elif [ -e "$link" ]; then
    echo "==> Skip linking $link because it is not a directory" >&2
    return 0
  fi

  ln -s "$target" "$link"
  echo "==> Linked $link -> $target"
}

link_dir "$APM_AGENTS_DIR" "$HOME/.github/agents"
link_dir "$APM_SKILLS_DIR" "$HOME/.copilot/skills"
