#!/bin/sh
# Keep mise-managed tools up to date on every chezmoi apply/update.

set -eu

is_macos() {
  [ "$(uname -s)" = "Darwin" ]
}

mise_global() {
  MISE_CONFIG_FILE="$HOME/.config/mise/config.toml" mise -C "$HOME" "$@"
}

prune_dotnet_runtimes() {
  runtime_root=$1
  sdk_root=$2
  prune_dry_run=${DOTFILES_DOTNET_RUNTIME_PRUNE_DRY_RUN:-0}

  case "$prune_dry_run" in
    0 | 1) ;;
    *) echo "DOTFILES_DOTNET_RUNTIME_PRUNE_DRY_RUN must be 0 or 1." >&2; return 2 ;;
  esac

  [ -d "$runtime_root" ] || return 0

  sdk_found=false
  for sdk_dir in "$sdk_root"/*; do
    [ -d "$sdk_dir" ] || continue
    sdk_version=${sdk_dir##*/}
    case "$sdk_version" in
      *.*.*) : ;;
      *) continue ;;
    esac
    case "$sdk_version" in
      *[!0-9.]* | .* | *. | *.*.*.* | *..*) continue ;;
    esac
    sdk_found=true
    break
  done
  if [ "$sdk_found" != true ]; then
    echo "No installed SDK versions were found under $sdk_root; refusing to prune runtimes from $runtime_root." >&2
    return 1
  fi

  echo "==> Pruning obsolete .NET runtimes from $runtime_root..."
  for runtime_parent in "$runtime_root"/shared/* "$runtime_root"/host/fxr; do
    [ -d "$runtime_parent" ] || continue

    for runtime_dir in "$runtime_parent"/*; do
      [ -d "$runtime_dir" ] || continue
      runtime_version=${runtime_dir##*/}
      case "$runtime_version" in
        *.*.*) : ;;
        *) continue ;;
      esac
      case "$runtime_version" in
        *[!0-9.]* | .* | *. | *.*.*.* | *..*) continue ;;
      esac

      runtime_major=${runtime_version%%.*}
      case "$runtime_major" in
        '' | *[!0-9]*) continue ;;
      esac

      sdk_major_installed=false
      for sdk_dir in "$sdk_root"/"$runtime_major".*; do
        [ -d "$sdk_dir" ] || continue
        sdk_major_installed=true
        break
      done
      if [ "$sdk_major_installed" != true ]; then
        if [ "$prune_dry_run" = 1 ]; then
          echo "    Would remove runtime $runtime_dir (no matching SDK major)"
        else
          echo "    Removing runtime $runtime_dir (no matching SDK major)"
          rm -rf "$runtime_dir"
        fi
        continue
      fi

      latest_runtime_version=
      latest_minor=-1
      latest_patch=-1
      for candidate_dir in "$runtime_parent"/"$runtime_major".*; do
        [ -d "$candidate_dir" ] || continue
        candidate_version=${candidate_dir##*/}
        case "$candidate_version" in
          *.*.*) : ;;
          *) continue ;;
        esac
        case "$candidate_version" in
          *[!0-9.]* | .* | *. | *.*.*.* | *..*) continue ;;
        esac
        candidate_minor=${candidate_version#*.}
        candidate_minor=${candidate_minor%%.*}
        candidate_patch=${candidate_version##*.}
        if [ "$candidate_minor" -gt "$latest_minor" ] || {
          [ "$candidate_minor" -eq "$latest_minor" ] && [ "$candidate_patch" -gt "$latest_patch" ];
        }; then
          latest_runtime_version=$candidate_version
          latest_minor=$candidate_minor
          latest_patch=$candidate_patch
        fi
      done
      if [ -n "$latest_runtime_version" ] && [ "$runtime_version" != "$latest_runtime_version" ]; then
        if [ "$prune_dry_run" = 1 ]; then
          echo "    Would remove obsolete runtime $runtime_dir (keeping $runtime_parent/$latest_runtime_version)"
        else
          echo "    Removing obsolete runtime $runtime_dir (keeping $runtime_parent/$latest_runtime_version)"
          rm -rf "$runtime_dir"
        fi
      elif [ -n "$latest_runtime_version" ]; then
        echo "    Keeping runtime $runtime_dir (latest for SDK major $runtime_major)"
      fi
    done
  done
}

if [ "${1:-}" = "--prune-dotnet-runtimes" ]; then
  if ! is_macos; then
    echo "Runtime pruning is only supported on macOS." >&2
    exit 2
  fi
  if [ "$#" -gt 2 ]; then
    echo "Usage: $0 --prune-dotnet-runtimes [--apply]" >&2
    exit 2
  fi
  case "${2:-}" in
    "") DOTFILES_DOTNET_RUNTIME_PRUNE_DRY_RUN=1 ;;
    --apply) DOTFILES_DOTNET_RUNTIME_PRUNE_DRY_RUN=0 ;;
    *) echo "Usage: $0 --prune-dotnet-runtimes [--apply]" >&2; exit 2 ;;
  esac
  export DOTFILES_DOTNET_RUNTIME_PRUNE_DRY_RUN
  dotnet_root="$HOME/.local/share/mise/dotnet-root"
  dotnet_host=$(mise_global which dotnet)
  case "$dotnet_host" in
    "$dotnet_root"/*) ;;
    *) echo "mise selected dotnet outside the managed root: $dotnet_host" >&2; exit 1 ;;
  esac
  [ -x "$dotnet_host" ] || { echo "Managed dotnet host is missing: $dotnet_host" >&2; exit 1; }
  prune_dotnet_runtimes "$dotnet_root" "$dotnet_root/sdk"
  prune_dotnet_runtimes "$HOME/.dotnet" "$dotnet_root/sdk"
  exit 0
fi

update_dotnet_global_tools() {
  dotnet_host=$1
  if [ -z "$dotnet_host" ] || [ ! -x "$dotnet_host" ]; then
    echo "dotnet was not found; skipping global tool updates." >&2
    return 0
  fi
  tool_dir="$HOME/.dotnet/tools"
  mkdir -p "$tool_dir"

  managed_tools='dotnet-ef
csharpier
docfx
dotnet-counters
ilspycmd
microsoft.dotnet-scaffold
microsoft.dataapibuilder
microsoft.openapi.kiota
microsoft.sqlpackage
microsoft.web.librarymanager.cli
nbgv
microsoft.playwright.cli
terminalguidesigner
upgrade-assistant
dotnet-outdated-tool'

  if ! is_macos; then
    managed_tools="$managed_tools
git-credential-manager"
  fi

  echo "==> Ensuring managed dotnet global tools in $tool_dir..."
  (
    tools_cwd=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-dotnet-tools.XXXXXX")
    trap 'rm -rf "$tools_cwd"' EXIT HUP INT TERM
    cd "$tools_cwd"
    for tool_name in $managed_tools; do
      if "$dotnet_host" tool list --global 2>/dev/null | awk 'NR > 2 {print $1}' | grep -Fxq "$tool_name"; then
        echo "==> Updating dotnet tool: $tool_name"
        "$dotnet_host" tool update --global "$tool_name"
      else
        echo "==> Installing dotnet tool: $tool_name"
        "$dotnet_host" tool install --global "$tool_name"
      fi
    done
  )
}

if is_macos; then
  if ! command -v mise >/dev/null 2>&1; then
    echo "mise was not found; skipping managed updates." >&2
    exit 0
  fi

  echo "==> Installing configured mise tools from the global config..."
  mise_global install
  echo "==> Upgrading dotnet and pruning replaced SDKs..."
  mise_global upgrade --global --prune dotnet
  echo "==> Pruning dotnet SDKs no longer requested by the global config..."
  mise_global prune --tools dotnet
  echo "==> Upgrading global mise tools except dotnet..."
  mise_global upgrade --global --exclude dotnet

  claude_settings="$HOME/.claude/settings.json"
  claude_permissions_helper="$HOME/.claude/hooks/mise-permissions.mjs"
  if [ -f "$claude_settings" ] && [ -f "$claude_permissions_helper" ]; then
    state_home=${XDG_STATE_HOME:-"$HOME/.local/state"}
    case "$state_home" in
      /*) ;;
      *) echo "XDG_STATE_HOME must be an absolute path: $state_home" >&2; exit 1 ;;
    esac
    echo "==> Updating Claude Code permissions for installed mise executables..."
    mise_path=$(command -v mise)
    mise_global exec -- node "$claude_permissions_helper" --discover \
      "$claude_settings" \
      "$state_home/dotfiles/claude-mise-permissions.json" \
      "$mise_path"
  fi

  dotnet_root="$HOME/.local/share/mise/dotnet-root"
  dotnet_host=$(mise_global which dotnet)
  case "$dotnet_host" in
    "$dotnet_root"/*) ;;
    *) echo "mise selected dotnet outside the managed root: $dotnet_host" >&2; exit 1 ;;
  esac
  [ -x "$dotnet_host" ] || { echo "Managed dotnet host is missing: $dotnet_host" >&2; exit 1; }
  prune_dotnet_runtimes "$dotnet_root" "$dotnet_root/sdk"
  prune_dotnet_runtimes "$HOME/.dotnet" "$dotnet_root/sdk"
  export DOTNET_ROOT="$dotnet_root"
  if [ "$(sysctl -in hw.optional.arm64 2>/dev/null || true)" = "1" ] || [ "$(uname -m)" = "arm64" ]; then
    export DOTNET_ROOT_ARM64="$dotnet_root"
    unset DOTNET_ROOT_X64
  else
    export DOTNET_ROOT_X64="$dotnet_root"
    unset DOTNET_ROOT_ARM64
  fi
  if [ -n "${MSBuildSDKsPath:-}" ]; then
    echo "MSBuildSDKsPath is set and can redirect SDK resolution: $MSBuildSDKsPath" >&2
    exit 1
  fi
  unset DOTNET_HOST_PATH

  echo "==> Applying mise bootstrap packages..."
  mise_global bootstrap packages apply
  echo "==> Upgrading Homebrew runtime libraries..."
  mise_global bootstrap packages upgrade --manager brew --yes
  echo "==> Upgrading mise-managed Homebrew casks..."
  mise_global bootstrap packages upgrade --manager brew-cask --yes

  if command -v brew >/dev/null 2>&1; then
    echo "==> Upgrading Homebrew-managed casks..."
    brew upgrade --cask
  else
    echo "Homebrew was not found; skipping Homebrew-managed cask updates." >&2
  fi

  update_dotnet_global_tools "$dotnet_host"
else
  update_dotnet_global_tools "$(command -v dotnet || true)"

  if ! command -v mise >/dev/null 2>&1; then
    echo "mise was not found; skipping mise upgrade." >&2
    exit 0
  fi

  echo "==> Running mise install..."
  mise install
  echo "==> Running mise upgrade..."
  mise upgrade
fi

echo "==> mise install/upgrade complete"
