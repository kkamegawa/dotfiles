#!/bin/sh
# Keep mise-managed tools up to date on every chezmoi apply/update.

set -eu

is_macos() {
  [ "$(uname -s)" = "Darwin" ]
}

mise_global() {
  MISE_CONFIG_FILE="$HOME/.config/mise/config.toml" mise -C "$HOME" "$@"
}

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
      if "$dotnet_host" tool list --tool-path "$tool_dir" 2>/dev/null | awk 'NR > 2 {print $1}' | grep -Fxq "$tool_name"; then
        echo "==> Updating dotnet tool: $tool_name"
        "$dotnet_host" tool update --tool-path "$tool_dir" "$tool_name"
      else
        echo "==> Installing dotnet tool: $tool_name"
        "$dotnet_host" tool install --tool-path "$tool_dir" "$tool_name"
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
  echo "==> Upgrading global mise tools except dotnet..."
  mise_global upgrade --global --exclude dotnet
  echo "==> Upgrading dotnet without pruning retained SDKs..."
  mise_global upgrade --global --no-prune dotnet

  dotnet_root="$HOME/.local/share/mise/dotnet-root"
  dotnet_host=$(mise_global which dotnet)
  case "$dotnet_host" in
    "$dotnet_root"/*) ;;
    *) echo "mise selected dotnet outside the managed root: $dotnet_host" >&2; exit 1 ;;
  esac
  [ -x "$dotnet_host" ] || { echo "Managed dotnet host is missing: $dotnet_host" >&2; exit 1; }
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
