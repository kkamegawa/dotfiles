#!/bin/bash
# User-run, resumable macOS .NET SDK migration to the shared mise root.
# Sourceable by isolated repository tests; sourcing never runs the migration.
set -u

MIGRATION_STATE_DIR=${MIGRATION_STATE_DIR:-}
MIGRATION_PROJECTS=()
MIGRATION_SDKS=()
MIGRATION_PHASE=plan
MIGRATION_IDE_CHECKS_CONFIRMED=0
MIGRATION_LOCK_HELD=0
MIGRATION_INITIALIZED=0
MIGRATION_PREPARE_ACTIVE=0

migration_init_defaults() {
  [ "$MIGRATION_INITIALIZED" -eq 1 ] && return 0
  MIGRATION_HOME=${HOME:-}
  MIGRATION_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P)
  MIGRATION_ARCH=$(migration_detect_arch) || return 1
  MIGRATION_SYSTEM_ROOT=/usr/local/share/dotnet
  MIGRATION_USER_ROOT=$MIGRATION_HOME/.dotnet
  MIGRATION_SHARED_ROOT=$MIGRATION_HOME/.local/share/mise/dotnet-root
  MIGRATION_REGISTRATION=/etc/dotnet/install_location_$MIGRATION_ARCH
  MIGRATION_MISE_BIN=${MIGRATION_MISE_BIN:-$(command -v mise 2>/dev/null || true)}
  MIGRATION_CHEZMOI_BIN=${MIGRATION_CHEZMOI_BIN:-$(command -v chezmoi 2>/dev/null || true)}
  MIGRATION_JQ_BIN=${MIGRATION_JQ_BIN:-$(command -v jq 2>/dev/null || true)}
  MIGRATION_CURL_BIN=${MIGRATION_CURL_BIN:-$(command -v curl 2>/dev/null || true)}
  MIGRATION_BREW_BIN=${MIGRATION_BREW_BIN:-$(command -v brew 2>/dev/null || true)}
  MIGRATION_SHASUM_BIN=${MIGRATION_SHASUM_BIN:-$(command -v shasum 2>/dev/null || true)}
  MIGRATION_PKGUTIL_BIN=${MIGRATION_PKGUTIL_BIN:-$(command -v pkgutil 2>/dev/null || true)}
  MIGRATION_PYTHON_BIN=${MIGRATION_PYTHON_BIN:-$(command -v python3 2>/dev/null || true)}
  MIGRATION_FILE_BIN=${MIGRATION_FILE_BIN:-$(command -v file 2>/dev/null || true)}
  MIGRATION_SUDO_BIN=${MIGRATION_SUDO_BIN:-$(command -v sudo 2>/dev/null || true)}
  MIGRATION_PACKAGE_TOOL=${MIGRATION_PACKAGE_TOOL:-$(command -v installer 2>/dev/null || true)}
  MIGRATION_STATE_FILE=${MIGRATION_STATE_FILE:-$MIGRATION_HOME/.config/dotfiles/dotnet-retained-sdks.json}
  MIGRATION_INITIALIZED=1
}

migration_detect_arch() {
  local arm64 uname_arch
  arm64=$(sysctl -in hw.optional.arm64 2>/dev/null || true)
  uname_arch=$(uname -m 2>/dev/null || true)
  if [ "$arm64" = 1 ] || [ "$uname_arch" = arm64 ] || [ "$uname_arch" = aarch64 ]; then
    printf arm64
  elif [ "$uname_arch" = x86_64 ]; then
    printf x64
  else
    migration_die "Unsupported native architecture: $uname_arch"
    return 1
  fi
}
migration_check_host_architecture() {
  local host=$1 expected description
  [ -x "$host" ] || return 0
  expected=$MIGRATION_ARCH
  [ -n "$MIGRATION_FILE_BIN" ] || migration_die 'file is required to inspect dotnet host architecture.' || return 1
  description=$("$MIGRATION_FILE_BIN" -Lb "$host" 2>/dev/null) || migration_die "Could not inspect dotnet host: $host" || return 1
  case "$expected:$description" in
    arm64:*arm64*) :;;
    x64:*x86_64*) :;;
    *) migration_die "dotnet host architecture does not match native $expected: $host ($description)" || return 1;;
  esac
}

migration_state_path() { printf '%s/state.json' "$MIGRATION_STATE_DIR"; }
migration_manifest_path() { printf '%s/.config/dotfiles/dotnet-retained-sdks.json' "$MIGRATION_HOME"; }
migration_ensure_manifest_directory() {
  local config="$MIGRATION_HOME/.config" dotfiles="$MIGRATION_HOME/.config/dotfiles"
  if [ -e "$config" ]; then [ -d "$config" ] && [ ! -L "$config" ] && [ -O "$config" ] || migration_die "$MIGRATION_HOME/.config must be a user-owned real directory." || return 1
  else (umask 077 && mkdir -m 700 "$config") || return 1; fi
  if [ -e "$dotfiles" ]; then [ -d "$dotfiles" ] && [ ! -L "$dotfiles" ] && [ -O "$dotfiles" ] || migration_die "$MIGRATION_HOME/.config/dotfiles must be a user-owned real directory." || return 1
  else (umask 077 && mkdir -m 700 "$dotfiles") || return 1; fi
}
migration_die() { printf 'ERROR: %s\n' "$*" >&2; return 1; }
migration_note() { printf '%s\n' "$*"; }
migration_require_macos() {
  [ "$(uname -s 2>/dev/null || true)" = Darwin ] || { migration_die 'This migration is supported only on macOS.'; return 1; }
  [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ] || { migration_die 'Run as the regular user; this driver never runs as root.'; return 1; }
}
migration_require_tools() {
  local name path
  for name in jq mise chezmoi; do
    case "$name" in jq) path=$MIGRATION_JQ_BIN;; mise) path=$MIGRATION_MISE_BIN;; chezmoi) path=$MIGRATION_CHEZMOI_BIN;; esac
    [ -n "$path" ] && [ -x "$path" ] || migration_die "Required executable is unavailable: $name" || return 1
  done
}
migration_exact_version() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
migration_abs_path() { [[ "$1" = /* ]]; }
migration_validate_inputs() {
  local project sdk
  migration_abs_path "$MIGRATION_STATE_DIR" || migration_die '--state-dir must be an absolute path.' || return 1
  case "$MIGRATION_STATE_DIR" in */../*|*/./*|*/..|*/.) migration_die '--state-dir must not contain dot or parent components.' || return 1;; esac
  [ -n "$MIGRATION_HOME" ] && [ -d "$MIGRATION_HOME" ] || migration_die 'HOME must exist.' || return 1
  for sdk in ${MIGRATION_SDKS[@]+"${MIGRATION_SDKS[@]}"}; do migration_exact_version "$sdk" || migration_die "SDK must be exact X.Y.Z: $sdk" || return 1; done
  for project in ${MIGRATION_PROJECTS[@]+"${MIGRATION_PROJECTS[@]}"}; do
    migration_abs_path "$project" || migration_die "Project paths must be absolute: $project" || return 1
    [ -e "$project" ] || migration_die "Project path does not exist: $project" || return 1
  done
  [ "$MIGRATION_ARCH" = arm64 ] || [ "$MIGRATION_ARCH" = x64 ] || migration_die "Unsupported native architecture: $MIGRATION_ARCH" || return 1
  case "$MIGRATION_REGISTRATION" in /etc/dotnet/install_location_arm64|/etc/dotnet/install_location_x64) :;; *) migration_die 'Unexpected architecture registration path.' || return 1;; esac
}
migration_check_mise() {
  local version newer
  version=$(env MISE_OFFLINE=1 MISE_SELF_UPDATE_AUTO=0 "$MIGRATION_MISE_BIN" --version 2>/dev/null | sed -n '1s/[^0-9]*\([0-9][0-9.]*\).*/\1/p')
  [ -n "$version" ] || migration_die 'Could not read mise version.' || return 1
  newer=$(awk -v v="$version" 'BEGIN { split(v,a,"."); split("2026.10.17",b,"."); for(i=1;i<=3;i++){if(a[i]+0>b[i]+0){print 1;exit} if(a[i]+0<b[i]+0){print 0;exit}} print 1 }')
  [ "$newer" = 1 ] || migration_die "mise $version is older than supported baseline 2026.10.17." || return 1
  (cd / && env MISE_OFFLINE=1 MISE_SELF_UPDATE_AUTO=0 MISE_CONFIG_FILE="$MIGRATION_HOME/.config/mise/config.toml" MISE_DOTNET_ROOT="$MIGRATION_SHARED_ROOT" MISE_DOTNET_ISOLATED=0 "$MIGRATION_MISE_BIN" settings dotnet.dotnet_root) >/dev/null 2>&1 || migration_die 'mise lacks dotnet.dotnet_root support.' || return 1
  (cd / && env MISE_OFFLINE=1 MISE_SELF_UPDATE_AUTO=0 MISE_CONFIG_FILE="$MIGRATION_HOME/.config/mise/config.toml" MISE_DOTNET_ROOT="$MIGRATION_SHARED_ROOT" MISE_DOTNET_ISOLATED=0 "$MIGRATION_MISE_BIN" settings dotnet.isolated) >/dev/null 2>&1 || migration_die 'mise lacks dotnet.isolated support.' || return 1
  (cd / && env MISE_OFFLINE=1 MISE_SELF_UPDATE_AUTO=0 "$MIGRATION_MISE_BIN" upgrade --help 2>&1) | grep -q -- '--global' || migration_die 'mise lacks upgrade --global.' || return 1
  (cd / && env MISE_OFFLINE=1 MISE_SELF_UPDATE_AUTO=0 "$MIGRATION_MISE_BIN" upgrade --help 2>&1) | grep -q -- '--no-prune' || migration_die 'mise lacks upgrade --no-prune.' || return 1
  (cd / && env MISE_OFFLINE=1 MISE_SELF_UPDATE_AUTO=0 "$MIGRATION_MISE_BIN" upgrade --help 2>&1) | grep -q -- '--exclude' || migration_die 'mise lacks upgrade --exclude.' || return 1
}
migration_sdk_list() {
  if [ -x "$1" ]; then
    local output; output=$("$1" --list-sdks 2>/dev/null) || return 1
    printf '%s\n' "$output" | awk 'NF {print $1}' | sort -u
  else return 0; fi
}
migration_runtime_list() {
  if [ -x "$1" ]; then
    local output; output=$("$1" --list-runtimes 2>/dev/null) || return 1
    printf '%s\n' "$output" | awk 'NF {print $1 " " $2}' | sort -u
  else return 0; fi
}
migration_cask_status() {
  local inventory cask_inventory
  if inventory=$("$MIGRATION_BREW_BIN" list --cask --versions dotnet-sdk 2>&1); then
    if printf '%s\n' "$inventory" | awk '$1=="dotnet-sdk" { found=1 } END { exit(found ? 0 : 1) }'; then printf 'installed\n'; else printf 'absent\n'; fi
    return 0
  fi
  case "$inventory" in
    *"Cask 'dotnet-sdk' is not installed."*) printf 'absent\n'; return 0;;
    *)
      # Some Homebrew versions return a non-zero status with no diagnostic
      # when the named cask is absent. Confirm against the complete local cask
      # inventory before deciding; never infer absence from an empty error.
      if cask_inventory=$("$MIGRATION_BREW_BIN" list --cask 2>&1); then
        if printf '%s\n' "$cask_inventory" | awk '$1=="dotnet-sdk" { found=1 } END { exit(found ? 0 : 1) }'; then
          printf 'installed\n'
        else
          printf 'absent\n'
        fi
        return 0
      fi
      [ -z "$inventory" ] || printf '%s\n' "$inventory" >&2
      [ -z "$cask_inventory" ] || printf '%s\n' "$cask_inventory" >&2
      migration_die 'Homebrew dotnet-sdk cask inventory failed; cannot decide whether it is installed.'
      return 1
      ;;
  esac
}
migration_report_package_paths() {
  local path
  for path in /etc/paths.d/dotnet /etc/paths.d/dotnet-cli-tools /opt/homebrew/bin/dotnet /usr/local/bin/dotnet /etc/dotnet; do
    if [ -L "$path" ]; then printf '%s -> %s\n' "$path" "$(readlink "$path")"
    elif [ -e "$path" ]; then printf '%s exists (%s)\n' "$path" "$(stat -f '%Sp' "$path" 2>/dev/null || echo unknown type)"
    else printf '%s absent\n' "$path"; fi
  done
}
migration_host_inventory() {
  local label=$1 host=$2/dotnet sdk_output sdks
  printf '%s host: %s\n' "$label" "$host"
  if [ -x "$host" ]; then
    sdk_output=$(migration_sdk_list "$host") || return 1
    sdks=$(printf '%s\n' "$sdk_output" | awk 'NF { if (seen++) printf ","; printf "%s", $0 } END { print "" }') || return 1
    printf '  SDKs: %s\n' "$sdks"
    printf '  runtimes:\n'; migration_runtime_list "$host" | sed 's/^/    /'
  else printf '  dotnet host: absent\n'; fi
}
migration_find_global_json() {
  local start=$1 dir
  [ -d "$start" ] || start=$(dirname "$start")
  dir=$(cd "$start" 2>/dev/null && pwd -P) || return 0
  while [ -n "$dir" ]; do
    if [ -f "$dir/global.json" ]; then printf '%s\n' "$dir/global.json"; return 0; fi
    [ "$dir" = / ] && break
    dir=$(dirname "$dir")
  done
}
migration_project_pins() {
  local project file version roll_forward allow_prerelease sdk_paths
  for project in ${MIGRATION_PROJECTS[@]+"${MIGRATION_PROJECTS[@]}"}; do
    file=$(migration_find_global_json "$project")
    if [ -n "$file" ]; then
      version=$("$MIGRATION_JQ_BIN" -r '.sdk.version // empty' "$file" 2>/dev/null) || migration_die "Cannot parse SDK version in $file" || return 1
      if [ -n "$version" ]; then migration_exact_version "$version" || migration_die "global.json SDK version must be exact X.Y.Z: $file" || return 1; fi
      roll_forward=$("$MIGRATION_JQ_BIN" -r '.sdk.rollForward // "default"' "$file") || return 1
      allow_prerelease=$("$MIGRATION_JQ_BIN" -r '.sdk.allowPrerelease // "default"' "$file") || return 1
      sdk_paths=$("$MIGRATION_JQ_BIN" -c '.sdk.paths // []' "$file") || return 1
      [ -n "$version" ] || version='(none)'
      printf '%s\t%s\t%s\t%s\t%s\n' "$version" "$file" "$roll_forward" "$allow_prerelease" "$sdk_paths"
    fi
  done
}
migration_inventory() {
  migration_init_defaults; migration_require_macos || return 1; migration_validate_inputs || return 1; migration_require_tools || return 1; migration_check_mise || return 1
  printf 'macOS .NET migration inventory\nArchitecture: %s\nShared mise root: %s\n' "$MIGRATION_ARCH" "$MIGRATION_SHARED_ROOT"
  migration_host_inventory 'Homebrew/system' "$MIGRATION_SYSTEM_ROOT"
  migration_host_inventory 'user' "$MIGRATION_USER_ROOT"
  migration_host_inventory 'mise shared' "$MIGRATION_SHARED_ROOT"
  migration_check_host_architecture "$MIGRATION_SYSTEM_ROOT/dotnet" || return 1
  migration_check_host_architecture "$MIGRATION_USER_ROOT/dotnet" || return 1
  migration_check_host_architecture "$MIGRATION_SHARED_ROOT/dotnet" || return 1
  printf 'Architecture registration: %s\n' "$MIGRATION_REGISTRATION"
  if [ -e "$MIGRATION_REGISTRATION" ]; then
    [ ! -L "$MIGRATION_REGISTRATION" ] || migration_die 'Architecture registration is a symlink; manual inspection required.' || return 1
    [ "$(stat -f '%Su' "$MIGRATION_REGISTRATION" 2>/dev/null)" = root ] || migration_die 'Architecture registration is not root-owned.' || return 1
    printf '  current value: %s\n' "$(cat "$MIGRATION_REGISTRATION")"
  else printf '  absent\n'; fi
  printf 'Package-owned paths:\n'; migration_report_package_paths | sed 's/^/  /'
  [ ! -e /etc/dotnet/install_location ] || printf 'Legacy registration (preserved): %s\n' /etc/dotnet/install_location
  printf 'Project global.json SDK policies (version, file, rollForward, allowPrerelease, sdk.paths):\n'
  local project_pins
  project_pins=$(migration_project_pins) || return 1
  if [ -n "$project_pins" ]; then printf '%s\n' "$project_pins" | sed 's/^/  /'; else printf '  (none supplied)\n'; fi
  printf 'Relevant environment overrides:\n'
  for name in DOTNET_ROOT DOTNET_ROOT_ARM64 DOTNET_ROOT_X64 DOTNET_CLI_HOME DOTNET_HOST_PATH MISE_DOTNET_ROOT MISE_DOTNET_ISOLATED; do
    value=$(printenv "$name" 2>/dev/null || true)
    [ -z "$value" ] || printf '  %s=%s\n' "$name" "$value"
  done
  value=$(printenv MSBuildSDKsPath 2>/dev/null || true)
  [ -z "$value" ] || printf '  MSBuildSDKsPath=%s (conflict; remove before migration)\n' "$value"
  if [ "${#MIGRATION_SDKS[@]}" -gt 0 ]; then printf 'Requested exact SDKs: %s\n' "${MIGRATION_SDKS[*]}"; else printf 'Requested exact SDKs: (none)\n'; fi
  printf 'Running affected apps:\n'
  ps -axo comm 2>/dev/null | grep -Ei '/(Code|Rider|Claude|Codex)(\.app)?/|(^|/)(Code|Rider|claude|codex)( |$)' | sort -u | sed 's/^/  /' || true
  local workload_host workload_output tool_output system_sdks
  workload_host=''
  system_sdks=$(migration_sdk_list "$MIGRATION_SYSTEM_ROOT/dotnet") || return 1
  if [ -x "$MIGRATION_SYSTEM_ROOT/dotnet" ] && [ -n "$system_sdks" ]; then workload_host="$MIGRATION_SYSTEM_ROOT/dotnet"; fi
  if [ -z "$workload_host" ] && [ -x "$MIGRATION_USER_ROOT/dotnet" ] && [ -n "$(migration_sdk_list "$MIGRATION_USER_ROOT/dotnet")" ]; then workload_host="$MIGRATION_USER_ROOT/dotnet"; fi
  if [ -n "$workload_host" ]; then
    workload_output=$(cd / && "$workload_host" workload list --machine-readable 2>/dev/null) || workload_output=''
    if [ -n "$workload_output" ]; then
      printf 'Installed workloads:\n'
      printf '%s\n' "$workload_output" | "$MIGRATION_JQ_BIN" -r '[..|objects|select(has("id"))|.id]|unique|.[]' 2>/dev/null | sed 's/^/  /' || true
    else printf 'Installed workloads: machine-readable inventory unavailable\n'; fi
    tool_output=$(cd / && DOTNET_CLI_HOME="$MIGRATION_HOME" "$workload_host" tool list --global 2>/dev/null) || tool_output=''
    printf 'Global tools in %s/.dotnet/tools:\n' "$MIGRATION_HOME"
    if [ -n "$tool_output" ]; then printf '%s\n' "$tool_output" | sed -n '3,$p' | sed '/^[[:space:]]*$/d;s/^/  /'; else printf '  (none or unavailable)\n'; fi
  else printf 'Workloads/global tools: no SDK host available for inventory.\n'; fi
  printf 'dotnet-sdk cask: '
  if [ -n "$MIGRATION_BREW_BIN" ]; then migration_cask_status || printf 'inventory unavailable\n'; else printf 'brew unavailable\n'; fi
  printf 'Plan is read-only. No state or SDK files were written.\n'
}
migration_mkdir_state() {
  [ ! -L "$MIGRATION_STATE_DIR" ] || migration_die 'State directory must not be a symlink.' || return 1
  [ "$MIGRATION_STATE_DIR" != "$MIGRATION_HOME" ] && [ "$MIGRATION_STATE_DIR" != / ] || migration_die 'State directory must be a dedicated child directory, not HOME or filesystem root.' || return 1
  if [ ! -e "$MIGRATION_STATE_DIR" ]; then
    (umask 077 && mkdir -p "$MIGRATION_STATE_DIR") || return 1
    chmod 700 "$MIGRATION_STATE_DIR" || return 1
  fi
  [ -d "$MIGRATION_STATE_DIR" ] && [ -O "$MIGRATION_STATE_DIR" ] || migration_die 'State directory must be user-owned.' || return 1
  MIGRATION_STATE_DIR=$(cd "$MIGRATION_STATE_DIR" && pwd -P) || return 1
  [ "$(stat -f '%Lp' "$MIGRATION_STATE_DIR" 2>/dev/null)" = 700 ] || migration_die 'Existing state directory must already have mode 0700.' || return 1
  if [ ! -f "$(migration_state_path)" ]; then
    [ -z "$(find "$MIGRATION_STATE_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ] || migration_die 'State directory is nonempty but has no recognized state file; refusing to overwrite it.' || return 1
  fi
}
migration_lock() {
  mkdir "$MIGRATION_STATE_DIR/.lock" 2>/dev/null || migration_die "Migration lock exists; inspect $MIGRATION_STATE_DIR/.lock before resuming." || return 1
  chmod 700 "$MIGRATION_STATE_DIR/.lock" || { rmdir "$MIGRATION_STATE_DIR/.lock" 2>/dev/null || true; return 1; }
  MIGRATION_LOCK_HELD=1; trap 'migration_on_exit' EXIT; trap 'migration_on_exit; exit 1' HUP INT TERM
}
migration_unlock() { if [ "$MIGRATION_LOCK_HELD" -eq 1 ]; then rmdir "$MIGRATION_STATE_DIR/.lock" 2>/dev/null || true; MIGRATION_LOCK_HELD=0; fi; }
migration_on_exit() {
  local item
  if [ "$MIGRATION_PREPARE_ACTIVE" -eq 1 ] && [ ! -f "$(migration_state_path)" ]; then
    for item in "$MIGRATION_STATE_DIR"/* "$MIGRATION_STATE_DIR"/.[!.]*; do
      [ -e "$item" ] || [ -L "$item" ] || continue
      [ "$item" = "$MIGRATION_STATE_DIR/.lock" ] && continue
      [ -f "$item" ] || [ -L "$item" ] || continue
      rm -f "$item" 2>/dev/null || true
    done
  fi
  migration_unlock
  if [ "$MIGRATION_PREPARE_ACTIVE" -eq 1 ] && [ ! -f "$(migration_state_path)" ]; then rmdir "$MIGRATION_STATE_DIR" 2>/dev/null || true; fi
}
migration_sha() { "$MIGRATION_SHASUM_BIN" -a 256 "$1" | awk '{print $1}'; }
migration_sha512() { "$MIGRATION_SHASUM_BIN" -a 512 "$1" | awk '{print tolower($1)}'; }
migration_kind() { if [ -L "$1" ]; then printf symlink; elif [ -f "$1" ]; then printf file; elif [ -e "$1" ]; then printf other; else printf absent; fi; }
migration_targets() {
  cat <<EOF
$MIGRATION_HOME/.config/mise/config.toml
$MIGRATION_HOME/.profile
$MIGRATION_HOME/PowerShell_profile.ps1
$MIGRATION_HOME/.gitconfig
$MIGRATION_HOME/.local/bin/dotfiles-dotnet10
$MIGRATION_HOME/.local/share/dotfiles/dotnet10-runner/global.json
$MIGRATION_HOME/.codex/config.toml
$MIGRATION_HOME/.claude/settings.json
EOF
}
migration_backup_targets() {
  local path index=0 kind backup mode uid sha link_target result='[]'
  while IFS= read -r path; do
    [ -n "$path" ] || continue; kind=$(migration_kind "$path")
    [ "$kind" != other ] || migration_die "Refusing non-file target: $path" || return 1
    backup=''; mode=''; uid=''; sha=''; link_target=''
    if [ "$kind" = file ]; then
      backup="$MIGRATION_STATE_DIR/backup.$index"; cp -p "$path" "$backup" || return 1; chmod 600 "$backup" || return 1
      mode=$(stat -f '%Lp' "$path"); uid=$(stat -f '%u' "$path"); sha=$(migration_sha "$path")
    elif [ "$kind" = symlink ]; then
      backup="$MIGRATION_STATE_DIR/link.$index"; link_target=$(readlink "$path") || return 1; printf '%s\n' "$link_target" > "$backup" || return 1; chmod 600 "$backup" || return 1
    fi
    result=$(printf '%s' "$result" | "$MIGRATION_JQ_BIN" --arg path "$path" --arg kind "$kind" --arg mode "$mode" --arg uid "$uid" --arg backup "$backup" --arg sha "$sha" --arg link "$link_target" '. + [{path:$path,kind:$kind,mode:$mode,uid:$uid,backupFile:$backup,originalSha256:$sha,originalLink:$link,appliedSha256:null}]') || return 1
    index=$((index + 1))
  done <<EOF
$(migration_targets)
EOF
  printf '%s\n' "$result"
}
migration_registration_snapshot() {
  local kind mode='' uid='' sha='' backup=''
  [ -d /etc/dotnet ] && [ ! -L /etc/dotnet ] || migration_die '/etc/dotnet must be a real directory.' || return 1
  [ "$(stat -f '%Su' /etc/dotnet 2>/dev/null)" = root ] || migration_die '/etc/dotnet must be root-owned.' || return 1
  kind=$(migration_kind "$MIGRATION_REGISTRATION")
  [ "$kind" = file ] || [ "$kind" = absent ] || migration_die 'Registration must be a regular file or absent.' || return 1
  if [ "$kind" = file ]; then
    [ "$(stat -f '%Su' "$MIGRATION_REGISTRATION")" = root ] || migration_die 'Registration must be root-owned.' || return 1
    mode=$(stat -f '%Lp' "$MIGRATION_REGISTRATION"); uid=$(stat -f '%u' "$MIGRATION_REGISTRATION"); sha=$(migration_sha "$MIGRATION_REGISTRATION")
    backup="$MIGRATION_STATE_DIR/registration.original"; cp "$MIGRATION_REGISTRATION" "$backup" || return 1; chmod 600 "$backup" || return 1
  fi
  "$MIGRATION_JQ_BIN" -n --arg path "$MIGRATION_REGISTRATION" --arg kind "$kind" --arg mode "$mode" --arg uid "$uid" --arg sha "$sha" --arg backup "$backup" --arg desired "$MIGRATION_SHARED_ROOT" '{path:$path,kind:$kind,mode:$mode,uid:$uid,originalSha256:$sha,backupFile:$backup,desired:$desired}'
}
migration_normalize_workload_json() {
  local file=$1 normalized="${1}.normalized"
  awk '
    !copy && ($0 ~ /^[[:space:]]*\{/ || $0 ~ /^[[:space:]]*\[/) { copy=1 }
    copy && $0 == "==workloadListJsonOutputEnd==" { exit }
    copy { print }
  ' "$file" > "$normalized" || return 1
  "$MIGRATION_JQ_BIN" -e 'type == "object" or type == "array"' "$normalized" >/dev/null 2>&1 || { rm -f "$normalized"; return 1; }
  mv -f "$normalized" "$file" || return 1
}
migration_collect_inventory_json() {
  local system="$MIGRATION_STATE_DIR/inventory-system.txt" user="$MIGRATION_STATE_DIR/inventory-user.txt" shared="$MIGRATION_STATE_DIR/inventory-shared.txt" workloads="$MIGRATION_STATE_DIR/workloads.json" tools="$MIGRATION_STATE_DIR/tools.txt" host workload_host
  migration_sdk_list "$MIGRATION_SYSTEM_ROOT/dotnet" > "$system" || return 1
  migration_sdk_list "$MIGRATION_USER_ROOT/dotnet" > "$user" || return 1
  migration_sdk_list "$MIGRATION_SHARED_ROOT/dotnet" > "$shared" || return 1
  chmod 600 "$system" "$user" "$shared" || return 1
  # Query workloads only through a root that has an SDK; the current shared
  # root is runtime-only, so dotnet workload list cannot inventory it reliably.
  workload_host=''
  if [ -x "$MIGRATION_SYSTEM_ROOT/dotnet" ] && [ -s "$system" ]; then workload_host="$MIGRATION_SYSTEM_ROOT/dotnet"; fi
  if [ -z "$workload_host" ] && [ -x "$MIGRATION_USER_ROOT/dotnet" ] && [ -s "$user" ]; then workload_host="$MIGRATION_USER_ROOT/dotnet"; fi
  if [ -n "$workload_host" ]; then
    if "$workload_host" workload list --machine-readable > "$workloads" 2>/dev/null; then
      migration_normalize_workload_json "$workloads" || migration_die 'Workload output was not JSON.' || return 1
      "$MIGRATION_JQ_BIN" -e '[..|objects|select(has("id"))|.id] | length == 0' "$workloads" >/dev/null 2>&1 || migration_die 'Existing workloads need a supported restore plan; refusing to proceed.' || return 1
    else
      "$workload_host" workload list > "$workloads" 2>&1 || return 1
      if grep -Eq '(^|[[:space:]])(wasm-tools|maui|android|ios|maccatalyst|aspire)([[:space:]]|$)' "$workloads"; then migration_die 'Workloads exist but machine-readable inventory is unavailable; refusing to proceed.' || return 1; fi
    fi
  else printf '{}\n' > "$workloads"; fi
  # Inventory the old user root too. Any installed workload needs an explicitly
  # supported restore path before migration can proceed.
  if [ -n "$workload_host" ] && [ "$workload_host" != "$MIGRATION_USER_ROOT/dotnet" ] && [ -x "$MIGRATION_USER_ROOT/dotnet" ] && [ -s "$user" ]; then
    local old_workloads="$MIGRATION_STATE_DIR/workloads-old-user.txt"
    if "$MIGRATION_USER_ROOT/dotnet" workload list --machine-readable > "$old_workloads" 2>/dev/null; then
      migration_normalize_workload_json "$old_workloads" || migration_die 'Old-root workload output was not JSON.' || return 1
      "$MIGRATION_JQ_BIN" -e '[..|objects|select(has("id"))|.id] | length == 0' "$old_workloads" >/dev/null 2>&1 || migration_die 'Old-root workloads need an explicitly supported restore path.' || return 1
    else
      "$MIGRATION_USER_ROOT/dotnet" workload list > "$old_workloads" 2>&1 || return 1
      if grep -Eq '(^|[[:space:]])(wasm-tools|maui|android|ios|maccatalyst|aspire)([[:space:]]|$)' "$old_workloads"; then migration_die 'Old-root workloads exist; refusing migration without a restore plan.' || return 1; fi
    fi
    chmod 600 "$old_workloads" || return 1
  fi
  if [ -x "$MIGRATION_USER_ROOT/dotnet" ]; then DOTNET_CLI_HOME="$MIGRATION_HOME" "$MIGRATION_USER_ROOT/dotnet" tool list --global > "$tools" 2>&1 || return 1; else printf 'Package Id Version Commands\n' > "$tools"; fi
  chmod 600 "$workloads" "$tools" || return 1
  "$MIGRATION_JQ_BIN" -n --argjson system "$(cat "$system" | "$MIGRATION_JQ_BIN" -Rsc 'split("\n")|map(select(length>0))')" --argjson user "$(cat "$user" | "$MIGRATION_JQ_BIN" -Rsc 'split("\n")|map(select(length>0))')" --argjson shared "$(cat "$shared" | "$MIGRATION_JQ_BIN" -Rsc 'split("\n")|map(select(length>0))')" --arg workloads "$workloads" --arg tools "$tools" '{oldSystemSdks:$system,oldUserSdks:$user,oldSharedSdks:$shared,workloadsFile:$workloads,globalToolsFile:$tools}'
}
migration_write_state() {
  local temp
  temp=$(mktemp "$MIGRATION_STATE_DIR/state.XXXXXX") || return 1
  printf '%s\n' "$1" > "$temp" && chmod 600 "$temp" && mv -f "$temp" "$(migration_state_path)"
}
migration_read_state() {
  local file allowed_targets; file=$(migration_state_path)
  [ -d "$MIGRATION_STATE_DIR" ] && [ ! -L "$MIGRATION_STATE_DIR" ] || migration_die 'State directory is missing or is a symlink.' || return 1
  MIGRATION_STATE_DIR=$(cd "$MIGRATION_STATE_DIR" && pwd -P) || return 1
  [ -O "$MIGRATION_STATE_DIR" ] && [ "$(stat -f '%Lp' "$MIGRATION_STATE_DIR" 2>/dev/null)" = 700 ] || migration_die 'State directory must remain user-owned with mode 0700.' || return 1
  file=$(migration_state_path)
  [ -f "$file" ] && [ ! -L "$file" ] || migration_die 'State is missing or not a regular file.' || return 1
  [ "$(stat -f '%Su' "$file")" = "$(id -un)" ] || migration_die 'State is not owned by current user.' || return 1
  [ "$(stat -f '%Lp' "$file")" = 600 ] || migration_die 'State file must have mode 0600.' || return 1
  allowed_targets=$(migration_targets | "$MIGRATION_JQ_BIN" -Rsc 'split("\n")|map(select(length>0))') || return 1
  "$MIGRATION_JQ_BIN" -e --arg home "$MIGRATION_HOME" --arg root "$MIGRATION_SHARED_ROOT" --arg arch "$MIGRATION_ARCH" --arg state "$MIGRATION_STATE_DIR" --arg registration "$MIGRATION_REGISTRATION" --arg repo "$MIGRATION_REPO" --arg manifest "$(migration_manifest_path)" --argjson allowed "$allowed_targets" '
    .schemaVersion==1 and .home==$home and .sharedRoot==$root and .architecture==$arch and .repo==$repo and
    (.phase=="preparing" or .phase=="prepared" or .phase=="switched" or .phase=="verified" or .phase=="finalizing" or .phase=="awaiting-final-attestation" or .phase=="finalized" or .phase=="rollback-awaiting-homebrew" or .phase=="rolled-back") and
    (.projectPaths|type)=="array" and all(.projectPaths[]; type=="string" and startswith("/")) and
    (.retainedVersions|type)=="array" and all(.retainedVersions[]; type=="string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
    (.targets|type)=="array" and ([.targets[].path]|sort)==($allowed|sort) and all(.targets|to_entries[]; (.value.path as $p | ($allowed|index($p))!=null) and
      ((.value.kind=="file" and .value.backupFile==($state+"/backup."+(.key|tostring))) or
       (.value.kind=="symlink" and .value.backupFile==($state+"/link."+(.key|tostring))) or
       (.value.kind=="absent" and .value.backupFile==""))) and
    .registration.path==$registration and .registration.desired==$root and
      ((.registration.kind=="absent" and .registration.backupFile=="") or (.registration.kind=="file" and .registration.backupFile==($state+"/registration.original"))) and
    .manifest.path==$manifest and
      ((.manifest.originalKind=="absent" and .manifest.backupFile=="") or (.manifest.originalKind=="file" and .manifest.backupFile==($state+"/manifest.original"))) and
    (.package.version|test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
    .package.rid==("osx-"+$arch) and (.package.sha512|test("^[a-fA-F0-9]{128}$")) and .package.signatureVerified==true and
    .package.file==($state+"/dotnet-sdk-"+.package.version+"-osx-"+$arch+".pkg")
  ' "$file" >/dev/null 2>&1 || migration_die 'State schema, host identity, or recovery paths are invalid.' || return 1
  local recovery_file
  for recovery_file in "$MIGRATION_STATE_DIR"/backup.* "$MIGRATION_STATE_DIR"/link.* "$MIGRATION_STATE_DIR"/registration.original "$MIGRATION_STATE_DIR"/manifest.original "$MIGRATION_STATE_DIR"/dotnet-sdk-*.pkg; do
    [ -e "$recovery_file" ] || continue
    [ -f "$recovery_file" ] && [ ! -L "$recovery_file" ] && [ -O "$recovery_file" ] && [ "$(stat -f '%Lp' "$recovery_file")" = 600 ] || migration_die "Recovery file has unsafe type, owner, or mode: $recovery_file" || return 1
  done
  local backup kind expected actual index
  while IFS= read -r backup; do
    [ -n "$backup" ] || continue
    kind=$("$MIGRATION_JQ_BIN" -r --arg p "$backup" '.targets[]|select(.backupFile==$p)|.kind' "$file") || return 1
    if [ "$kind" = file ]; then
      expected=$("$MIGRATION_JQ_BIN" -r --arg p "$backup" '.targets[]|select(.backupFile==$p)|.originalSha256' "$file")
      actual=$(migration_sha "$backup") || return 1
      [ "$expected" = "$actual" ] || migration_die "Configuration backup hash mismatch: $backup" || return 1
    elif [ "$kind" = symlink ]; then
      expected=$("$MIGRATION_JQ_BIN" -r --arg p "$backup" '.targets[]|select(.backupFile==$p)|.originalLink' "$file")
      [ "$(cat "$backup")" = "$expected" ] || migration_die "Symlink backup mismatch: $backup" || return 1
    fi
  done <<EOF
$("$MIGRATION_JQ_BIN" -r '.targets[].backupFile|select(length>0)' "$file")
EOF
  backup=$("$MIGRATION_JQ_BIN" -r '.registration.backupFile' "$file")
  if [ -n "$backup" ]; then
    expected=$("$MIGRATION_JQ_BIN" -r '.registration.originalSha256' "$file"); actual=$(migration_sha "$backup") || return 1
    [ "$expected" = "$actual" ] || migration_die 'Registration backup hash mismatch.' || return 1
  fi
  backup=$("$MIGRATION_JQ_BIN" -r '.manifest.backupFile' "$file")
  if [ -n "$backup" ]; then
    expected=$("$MIGRATION_JQ_BIN" -r '.manifest.originalSha256' "$file"); actual=$(migration_sha "$backup") || return 1
    [ "$expected" = "$actual" ] || migration_die 'Manifest backup hash mismatch.' || return 1
  fi
}
migration_reconcile_state_inputs() {
  local expected actual project
  expected=$("$MIGRATION_JQ_BIN" -r '.projectPaths[]' "$(migration_state_path)") || return 1
  if [ "${#MIGRATION_PROJECTS[@]}" -eq 0 ]; then
    while IFS= read -r project; do [ -z "$project" ] || MIGRATION_PROJECTS+=("$project"); done <<EOF
$expected
EOF
    return 0
  fi
  actual=$(printf '%s\n' ${MIGRATION_PROJECTS[@]+"${MIGRATION_PROJECTS[@]}"} | sed '/^$/d' | sort)
  expected=$(printf '%s\n' "$expected" | sed '/^$/d' | sort)
  [ "$actual" = "$expected" ] || migration_die 'Project inputs differ from the prepared state; resume with the same project roots/solutions.' || return 1
}
migration_update_state() {
  local filter arg_count=$# temp; local -a jq_args=()
  [ "$arg_count" -gt 0 ] || return 1
  while [ "$#" -gt 1 ]; do jq_args+=("$1"); shift; done
  filter=$1
  temp=$(mktemp "$MIGRATION_STATE_DIR/state.XXXXXX") || return 1
  if [ "$arg_count" -gt 1 ]; then
    "$MIGRATION_JQ_BIN" "${jq_args[@]}" "$filter" "$(migration_state_path)" > "$temp" || return 1
  else
    "$MIGRATION_JQ_BIN" "$filter" "$(migration_state_path)" > "$temp" || return 1
  fi
  chmod 600 "$temp" && mv -f "$temp" "$(migration_state_path)"
}

migration_archive_old_installer() {
  local version=$1 index metadata url expected file actual
  index="$MIGRATION_STATE_DIR/releases-index.json"; metadata="$MIGRATION_STATE_DIR/dotnet-releases.json"
  "$MIGRATION_CURL_BIN" --fail --location --silent --show-error 'https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/releases-index.json' -o "$index" || migration_die 'Official release index download failed; reversible finalize is unavailable.' || return 1
  local release_url
  release_url=$("$MIGRATION_JQ_BIN" -er '[.["releases-index"][]|select(.["channel-version"]=="10.0")|.["releases.json"]]|first' "$index") || return 1
  "$MIGRATION_CURL_BIN" --fail --location --silent --show-error "$release_url" -o "$metadata" || return 1
  url=$("$MIGRATION_JQ_BIN" -er --arg v "$version" --arg rid "osx-$MIGRATION_ARCH" '[.releases[]|(.sdks // [.sdk])[]|select(.version==$v)|.files[]|select(.rid==$rid)|select(.name|endswith(".pkg"))|.url]|first' "$metadata") || migration_die 'Exact architecture package is absent from official release metadata.' || return 1
  expected=$("$MIGRATION_JQ_BIN" -er --arg v "$version" --arg rid "osx-$MIGRATION_ARCH" '[.releases[]|(.sdks // [.sdk])[]|select(.version==$v)|.files[]|select(.rid==$rid)|select(.name|endswith(".pkg"))|.hash]|first' "$metadata") || return 1
  file="$MIGRATION_STATE_DIR/dotnet-sdk-$version-osx-$MIGRATION_ARCH.pkg"
  "$MIGRATION_CURL_BIN" --fail --location --silent --show-error "$url" -o "$file" || return 1
  actual=$("$MIGRATION_SHASUM_BIN" -a 512 "$file" | awk '{print tolower($1)}') || return 1
  [ "$(printf '%s' "$actual" | tr 'A-F' 'a-f')" = "$(printf '%s' "$expected" | tr 'A-F' 'a-f')" ] || migration_die 'Rollback package SHA512 mismatch.' || return 1
  migration_verify_package_signature "$file" > "$MIGRATION_STATE_DIR/package-signature.txt" 2>&1 || migration_die 'Rollback package is not signed by Microsoft or signature verification failed.' || return 1
  chmod 600 "$file" "$metadata" "$index" "$MIGRATION_STATE_DIR/package-signature.txt" || return 1
  "$MIGRATION_JQ_BIN" -n --arg version "$version" --arg rid "osx-$MIGRATION_ARCH" --arg url "$url" --arg file "$file" --arg sha512 "$actual" '{version:$version,rid:$rid,url:$url,file:$file,sha512:$sha512,signatureVerified:true}'
}
migration_verify_package_signature() {
  local output
  output=$("$MIGRATION_PKGUTIL_BIN" --check-signature "$1" 2>&1) || { printf '%s\n' "$output"; return 1; }
  printf '%s\n' "$output" | grep -Fq 'Developer ID Installer: Microsoft Corporation (UBF8T346G9)' || { printf '%s\n' "$output"; return 1; }
  printf '%s\n' "$output"
}
migration_global_context() {
  MISE_CONFIG_FILE="$MIGRATION_HOME/.config/mise/config.toml" MISE_DOTNET_ROOT="$MIGRATION_SHARED_ROOT" MISE_DOTNET_ISOLATED=0 "$@"
}
migration_install_retained_sdks() {
  local state version already; state=$(migration_state_path)
  for version in $("$MIGRATION_JQ_BIN" -r '.retainedVersions[]' "$state"); do
    already=$("$MIGRATION_JQ_BIN" --arg v "$version" '.checkpoints.installedVersions|index($v)!=null' "$state") || return 1
    [ "$already" = true ] && continue
    (cd "$MIGRATION_HOME" && migration_global_context "$MIGRATION_MISE_BIN" install "dotnet@$version") || migration_die "mise could not install $version" || return 1
    migration_update_state --arg v "$version" '.checkpoints.installedVersions += [$v] | .checkpoints.installedVersions |= unique' || return 1
  done
  (cd "$MIGRATION_HOME" && migration_global_context "$MIGRATION_MISE_BIN" install dotnet@10 dotnet@8) || migration_die 'mise failed to install .NET 10/.NET 8 channels.' || return 1
  "$MIGRATION_SHARED_ROOT/dotnet" --list-sdks | grep -q '^10\.' || migration_die 'No .NET 10 SDK is present in shared root.' || return 1
  "$MIGRATION_SHARED_ROOT/dotnet" --list-sdks | grep -q '^8\.' || migration_die 'No .NET 8 SDK is present in shared root.' || return 1
}
migration_apply_manifest() {
  local state path original_kind original_sha expected applied current_kind current_sha scratch temp desired_sha
  state=$(migration_state_path)
  path=$("$MIGRATION_JQ_BIN" -r '.manifest.path' "$state") || return 1
  original_kind=$("$MIGRATION_JQ_BIN" -r '.manifest.originalKind' "$state") || return 1
  original_sha=$("$MIGRATION_JQ_BIN" -r '.manifest.originalSha256' "$state") || return 1
  expected=$("$MIGRATION_JQ_BIN" -r '.manifest.expectedSha256 // empty' "$state") || return 1
  applied=$("$MIGRATION_JQ_BIN" -r '.manifest.appliedSha256 // empty' "$state") || return 1
  scratch=$(mktemp "$MIGRATION_STATE_DIR/manifest.expected.XXXXXX") || return 1
  "$MIGRATION_JQ_BIN" -S '{schemaVersion:1,versions:.}' < <("$MIGRATION_JQ_BIN" -c '.retainedVersions' "$state") > "$scratch" || { rm -f "$scratch"; return 1; }
  desired_sha=$(migration_sha "$scratch") || { rm -f "$scratch"; return 1; }
  chmod 600 "$scratch" || { rm -f "$scratch"; return 1; }
  [ -z "$expected" ] || [ "$expected" = "$desired_sha" ] || { rm -f "$scratch"; migration_die 'Retained SDK manifest expectation conflicts with saved state.'; return 1; }

  current_kind=$(migration_kind "$path") || { rm -f "$scratch"; return 1; }
  current_sha=absent
  if [ "$current_kind" = file ]; then current_sha=$(migration_sha "$path") || { rm -f "$scratch"; return 1; }
  elif [ "$current_kind" != absent ]; then rm -f "$scratch"; migration_die 'Retained SDK manifest changed type during prepare.'; return 1; fi

  if [ "$current_sha" = "$desired_sha" ]; then
    rm -f "$scratch"
    migration_update_state --arg h "$desired_sha" '.manifest.expectedSha256=$h | .manifest.appliedSha256=$h | .checkpoints.manifestAppliedSha256=$h' || return 1
    return 0
  fi
  if [ "$original_kind" = file ]; then
    [ "$current_kind" = file ] && [ "$current_sha" = "$original_sha" ] || { rm -f "$scratch"; migration_die 'Retained SDK manifest changed after backup; refusing to overwrite it.'; return 1; }
  else
    [ "$original_kind" = absent ] && [ "$current_kind" = absent ] || { rm -f "$scratch"; migration_die 'Retained SDK manifest is not in its recorded original state.'; return 1; }
  fi

  temp="$path.tmp"
  if [ -e "$temp" ] || [ -L "$temp" ]; then
    [ -f "$temp" ] && [ ! -L "$temp" ] && [ "$(migration_sha "$temp")" = "$desired_sha" ] || { rm -f "$scratch"; migration_die 'Retained SDK manifest temporary file is unexpected.'; return 1; }
    rm -f "$scratch" || return 1
  else
    mv "$scratch" "$temp" || { rm -f "$scratch"; return 1; }
  fi
  migration_update_state --arg h "$desired_sha" '.manifest.expectedSha256=$h' || return 1
  mv -f "$temp" "$path" || return 1
  migration_update_state --arg h "$desired_sha" '.manifest.appliedSha256=$h | .checkpoints.manifestAppliedSha256=$h' || return 1
}
migration_prepare() {
  migration_init_defaults; migration_require_macos || return 1; migration_validate_inputs || return 1; migration_require_tools || return 1; migration_check_mise || return 1
  migration_mkdir_state || return 1; migration_lock || return 1
  MIGRATION_PREPARE_ACTIVE=1
  if [ -f "$(migration_state_path)" ]; then
    migration_read_state || return 1
    if [ "$("$MIGRATION_JQ_BIN" -r '.phase' "$(migration_state_path)")" = preparing ]; then
      migration_apply_manifest || return 1
      migration_install_retained_sdks || return 1
      migration_update_state '.phase="prepared"' || return 1
      migration_note 'prepare resumed; retained SDKs are available.'
      return 0
    fi
    migration_note 'State exists beyond prepare; backups are preserved. Continue with the recorded phase.'
    return 0
  fi
  [ -n "$MIGRATION_CURL_BIN" ] && [ -n "$MIGRATION_SHASUM_BIN" ] && [ -n "$MIGRATION_PKGUTIL_BIN" ] || migration_die 'curl, shasum, and pkgutil are required.' || return 1
  [ -x "$MIGRATION_SYSTEM_ROOT/dotnet" ] || migration_die 'Expected system SDK host is absent.' || return 1
  migration_check_host_architecture "$MIGRATION_SYSTEM_ROOT/dotnet" || return 1
  "$MIGRATION_SYSTEM_ROOT/dotnet" --list-sdks | grep -q '^10\.0\.401 ' || migration_die 'Expected system SDK 10.0.401 baseline was not found.' || return 1
  local projects_json pins versions targets registration inventory package state_json version manifest_state manifest_kind manifest_mode manifest_sha
  projects_json=$(printf '%s\n' ${MIGRATION_PROJECTS[@]+"${MIGRATION_PROJECTS[@]}"} | "$MIGRATION_JQ_BIN" -Rsc 'split("\n")|map(select(length>0))') || return 1
  pins=$(migration_project_pins) || return 1
  if [ -n "$pins" ] && printf '%s\n' "$pins" | awk -F '\t' '$5 != "[]" { found=1 } END { exit found ? 0 : 1 }'; then
    migration_die 'A selected global.json contains sdk.paths outside the shared SDK search policy; review it before migration.'
    return 1
  fi
  [ -z "$(printenv MSBuildSDKsPath 2>/dev/null || true)" ] || migration_die 'MSBuildSDKsPath overrides SDK resolution; remove it before prepare.' || return 1
  inventory=$(migration_collect_inventory_json) || return 1
  local system_versions user_versions shared_versions
  system_versions=$(cat "$MIGRATION_STATE_DIR/inventory-system.txt")
  user_versions=$(cat "$MIGRATION_STATE_DIR/inventory-user.txt")
  shared_versions=$(cat "$MIGRATION_STATE_DIR/inventory-shared.txt")
  versions=$(printf '%s\n' 10.0.401 8.0.404 ${MIGRATION_SDKS[@]+"${MIGRATION_SDKS[@]}"} "$pins" "$system_versions" "$user_versions" "$shared_versions" | sed '/^$/d' | awk -F '\t' '$1 != "(none)" {print $1}' | sort -u | "$MIGRATION_JQ_BIN" -Rsc 'split("\n")|map(select(length>0))') || return 1
  for version in $("$MIGRATION_JQ_BIN" -r '.[]' <<EOF
$versions
EOF
); do migration_exact_version "$version" || migration_die "Invalid SDK pin: $version" || return 1; done
  targets=$(migration_backup_targets) || return 1
  registration=$(migration_registration_snapshot) || return 1
  if [ -n "$MIGRATION_BREW_BIN" ]; then
    "$MIGRATION_BREW_BIN" info --cask --json=v2 dotnet-sdk > "$MIGRATION_STATE_DIR/cask-receipt.json" 2>/dev/null || migration_die 'Could not capture Homebrew cask metadata.' || return 1
  fi
  "$MIGRATION_PKGUTIL_BIN" --pkgs 2>/dev/null | grep -Ei 'dotnet|microsoft.*net' > "$MIGRATION_STATE_DIR/pkgutil-receipts.txt" || true
  chmod 600 "$MIGRATION_STATE_DIR/cask-receipt.json" "$MIGRATION_STATE_DIR/pkgutil-receipts.txt" 2>/dev/null || true
  migration_ensure_manifest_directory || return 1
  if [ -e "$(migration_manifest_path)" ]; then
    [ -f "$(migration_manifest_path)" ] && [ ! -L "$(migration_manifest_path)" ] || migration_die 'Manifest must be a regular file.' || return 1
    "$MIGRATION_JQ_BIN" -e '.schemaVersion==1 and (keys|sort)==["schemaVersion","versions"] and (.versions|type)=="array" and all(.versions[];type=="string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' "$(migration_manifest_path)" >/dev/null 2>&1 || migration_die 'Existing retained SDK manifest is invalid.' || return 1
    cp -p "$(migration_manifest_path)" "$MIGRATION_STATE_DIR/manifest.original" || return 1
    manifest_kind='file'; manifest_mode=$(stat -f '%Lp' "$(migration_manifest_path)"); manifest_sha=$(migration_sha "$(migration_manifest_path)")
    versions=$(printf '%s' "$versions" | "$MIGRATION_JQ_BIN" --slurpfile old "$(migration_manifest_path)" '. + $old[0].versions | unique') || return 1
  else : > "$MIGRATION_STATE_DIR/manifest.was-absent"; manifest_kind=absent; manifest_mode=''; manifest_sha=''; fi
  manifest_state=$("$MIGRATION_JQ_BIN" -n --arg path "$(migration_manifest_path)" --arg kind "$manifest_kind" --arg mode "$manifest_mode" --arg sha "$manifest_sha" --arg backup "$MIGRATION_STATE_DIR/manifest.original" '{path:$path,originalKind:$kind,originalMode:$mode,originalSha256:$sha,backupFile:(if $kind=="file" then $backup else "" end),appliedSha256:null}')
  chmod 600 "$MIGRATION_STATE_DIR/manifest.original" 2>/dev/null || true
  printf '%s\n' "$inventory" > "$MIGRATION_STATE_DIR/inventory.json"; chmod 600 "$MIGRATION_STATE_DIR/inventory.json" || return 1
  version=$(sort -t. -k1,1n -k2,2n -k3,3n "$MIGRATION_STATE_DIR/inventory-system.txt" | tail -n 1)
  [ -n "$version" ] || migration_die 'No system SDK version is available to preserve for rollback.' || return 1
  package=$(migration_archive_old_installer "$version") || return 1
  state_json=$("$MIGRATION_JQ_BIN" -n --arg home "$MIGRATION_HOME" --arg repo "$MIGRATION_REPO" --arg arch "$MIGRATION_ARCH" --arg root "$MIGRATION_SHARED_ROOT" --argjson projects "$projects_json" --argjson versions "$versions" --argjson targets "$targets" --argjson registration "$registration" --argjson inventory "$inventory" --argjson package "$package" --argjson manifest "$manifest_state" '{schemaVersion:1,phase:"preparing",home:$home,repo:$repo,architecture:$arch,sharedRoot:$root,projectPaths:$projects,retainedVersions:$versions,targets:$targets,registration:$registration,manifest:$manifest,checkpoints:{installedVersions:[],appliedTargets:[],registration:"pending",caskRemoved:false,guiAttested:false,manifestAppliedSha256:null},package:$package,inventory:$inventory}') || return 1
  migration_write_state "$state_json" || return 1
  MIGRATION_PREPARE_ACTIVE=0
  migration_apply_manifest || return 1
  migration_install_retained_sdks || return 1
  migration_update_state '.phase="prepared"' || return 1
  migration_note 'prepare completed; old roots, workloads, and rollback package remain intact.'
}
migration_running_apps() {
  local matches
  matches=$(ps -axo comm 2>/dev/null | grep -Ei '(^|/)(Code|Code - Insiders|Rider|Claude|Codex)(\.app)?(/|$)|/(Code|Rider|Claude|Codex)( |$)' | grep -v 'grep -E' || true)
  [ -z "$matches" ] || { printf '%s\n' "$matches"; migration_die 'Close IDEs and affected agents before switch.'; return 1; }
}
migration_write_registration() {
  local value=$1 temp
  [ "$value" = "$MIGRATION_SHARED_ROOT" ] || migration_die 'Registration must point to the approved shared root.' || return 1
  if [ ! -e /etc/dotnet ]; then "$MIGRATION_SUDO_BIN" mkdir -m 0755 /etc/dotnet || return 1; fi
  [ -d /etc/dotnet ] && [ ! -L /etc/dotnet ] && [ "$(stat -f '%Su' /etc/dotnet 2>/dev/null)" = root ] || migration_die '/etc/dotnet is missing or has unexpected ownership/type.' || return 1
  local original_kind original_value phase
  original_kind=$("$MIGRATION_JQ_BIN" -r '.registration.kind' "$(migration_state_path)")
  original_value=''
  if [ "$original_kind" = file ]; then
    local original_backup; original_backup=$("$MIGRATION_JQ_BIN" -r '.registration.backupFile' "$(migration_state_path)")
    original_value=$(cat "$original_backup") || return 1
  fi
  phase=$("$MIGRATION_JQ_BIN" -r '.phase' "$(migration_state_path)")
  if [ -L "$MIGRATION_REGISTRATION" ]; then migration_die 'Architecture registration became a symlink after prepare.' || return 1
  elif [ -e "$MIGRATION_REGISTRATION" ]; then
    [ -f "$MIGRATION_REGISTRATION" ] && [ "$(stat -f '%Su' "$MIGRATION_REGISTRATION" 2>/dev/null)" = root ] || migration_die 'Architecture registration changed type or owner after prepare.' || return 1
    local current_value; current_value=$(cat "$MIGRATION_REGISTRATION")
    if [ "$current_value" = "$value" ]; then
      [ "$(stat -f '%Lp' "$MIGRATION_REGISTRATION" 2>/dev/null)" = 644 ] || migration_die 'Managed architecture registration mode changed.' || return 1
    elif [ "$original_kind" = file ] && [ "$current_value" = "$original_value" ]; then
      [ "$(stat -f '%Lp' "$MIGRATION_REGISTRATION" 2>/dev/null)" = "$("$MIGRATION_JQ_BIN" -r '.registration.mode' "$(migration_state_path)")" ] || migration_die 'Original architecture registration mode changed.' || return 1
    else
      migration_die 'Architecture registration changed after prepare.'
      return 1
    fi
  elif [ "$original_kind" != absent ] && [ "$phase" != finalizing ] && [ "$("$MIGRATION_JQ_BIN" -r '.checkpoints.caskRemoved // false' "$(migration_state_path)")" != true ]; then
    migration_die 'Architecture registration disappeared after prepare.'
    return 1
  fi
  temp=$("$MIGRATION_SUDO_BIN" mktemp /etc/dotnet/.install_location_XXXXXX) || migration_die 'Could not create privileged registration temp file.' || return 1
  if ! printf '%s\n' "$value" | "$MIGRATION_SUDO_BIN" tee "$temp" >/dev/null; then "$MIGRATION_SUDO_BIN" rm -f "$temp"; return 1; fi
  "$MIGRATION_SUDO_BIN" chown root:wheel "$temp" && "$MIGRATION_SUDO_BIN" chmod 0644 "$temp" && "$MIGRATION_SUDO_BIN" mv -f "$temp" "$MIGRATION_REGISTRATION" || { "$MIGRATION_SUDO_BIN" rm -f "$temp"; return 1; }
}
migration_apply_targets() {
  local state path applied previous current apply_status
  state=$(migration_state_path); migration_running_apps || return 1
  [ -x "$MIGRATION_CHEZMOI_BIN" ] || migration_die 'chezmoi is required.' || return 1
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    [ "$("$MIGRATION_JQ_BIN" --arg p "$path" '[.targets[].path]|index($p)!=null' "$state")" = true ] || migration_die "Unapproved target: $path" || return 1
    if [ "$("$MIGRATION_JQ_BIN" --arg p "$path" '.checkpoints.appliedTargets|index($p)!=null' "$state")" = true ]; then
      local previous current
      previous=$("$MIGRATION_JQ_BIN" -r --arg p "$path" '.targets[]|select(.path==$p)|.appliedSha256' "$state") || return 1
      if [ "$previous" = absent ]; then
        [ ! -e "$path" ] || migration_die "Previously absent target changed since checkpoint: $path" || return 1
        # A failed chezmoi apply may checkpoint an absent result. Retry it on
        # resume instead of treating that partial attempt as a completed target.
      else
        [ -f "$path" ] || migration_die "Previously applied target changed kind: $path" || return 1
        current=$(migration_sha "$path") || return 1
        [ "$current" = "$previous" ] && continue
        migration_die "Previously applied target changed since checkpoint: $path" || return 1
      fi
    fi
    [ -f "$MIGRATION_REPO/.chezmoiroot" ] && [ "$(cat "$MIGRATION_REPO/.chezmoiroot")" = home ] || migration_die 'Approved chezmoi source root is missing or invalid.' || return 1
    apply_status=0
    "$MIGRATION_CHEZMOI_BIN" --source "$MIGRATION_REPO" --destination "$MIGRATION_HOME" apply --parent-dirs --exclude=scripts "$path" || apply_status=$?
    if [ -f "$path" ]; then applied=$(migration_sha "$path") || return 1; else applied=absent; fi
    migration_update_state --arg p "$path" --arg h "$applied" '.checkpoints.appliedTargets += [$p] | .checkpoints.appliedTargets |= unique | (.targets[]|select(.path==$p)|.appliedSha256)=$h' || return 1
    [ "$apply_status" -eq 0 ] || migration_die "chezmoi apply failed for $path (partial change checkpointed for rollback)." || return 1
  done <<EOF
$(migration_targets)
EOF
}
migration_print_gui_checklist() {
  cat <<'EOF'
Manual GUI acceptance required; no result is inferred:
  - VS Code and Insiders launched from Finder/Dock and a fresh terminal; C# project-system logs and build/run/test show the shared SDK.
  - Rider per solution uses the shared dotnet, matching SDK resolution, automatic downloads disabled; build/run/test and Bicep work.
  - Claude/Codex restarted; Claude hooks and Codex non-login commands work.
After cask removal, repeat these checks with the old system SDK absent, close the applications, then rerun finalize --ide-checks-confirmed to record the post-removal attestation.
EOF
}
migration_switch() {
  migration_init_defaults; migration_require_macos || return 1; migration_require_tools || return 1; migration_validate_inputs || return 1; migration_read_state || return 1; migration_reconcile_state_inputs || return 1; migration_lock || return 1
  [ "$("$MIGRATION_JQ_BIN" -r '.phase' "$(migration_state_path)")" = prepared ] || migration_die 'switch requires prepared state.' || return 1
  migration_running_apps || return 1
  [ -n "$MIGRATION_SUDO_BIN" ] || migration_die 'sudo is required for the architecture registration.' || return 1
  migration_write_registration "$MIGRATION_SHARED_ROOT" || return 1
  migration_update_state '.checkpoints.registration="registered"' || return 1
  migration_apply_targets || return 1
  migration_update_state '.phase="switched"' || return 1
  migration_print_gui_checklist
}
migration_dotnet_env() {
  local root=$1; shift
  if [ "$MIGRATION_ARCH" = arm64 ]; then
    env -u DOTNET_ROOT_X64 -u DOTNET_HOST_PATH DOTNET_ROOT="$root" DOTNET_ROOT_ARM64="$root" "$@"
  else
    env -u DOTNET_ROOT_ARM64 -u DOTNET_HOST_PATH DOTNET_ROOT="$root" DOTNET_ROOT_X64="$root" "$@"
  fi
}
migration_select_projects() {
  local input=$1 candidate direct=''
  if [ -f "$input" ]; then printf '%s\n' "$input"; return 0; fi
  for candidate in "$input"/*.sln "$input"/*.slnx; do
    [ -f "$candidate" ] || continue
    direct+="$candidate"$'\n'
  done
  if [ -n "$direct" ]; then printf '%s' "$direct"; return 0; fi
  for candidate in "$input"/*.csproj; do
    [ -f "$candidate" ] || continue
    direct+="$candidate"$'\n'
  done
  if [ -n "$direct" ]; then printf '%s' "$direct"; return 0; fi
  find "$input" \( -type d \( -name .git -o -name .agents -o -name .claude -o -name .codex -o -name apm_modules -o -name bin -o -name obj -o -name artifacts -o -name node_modules \) -prune \) -o \( -type f \( -name '*.sln' -o -name '*.slnx' -o -name '*.csproj' \) -print \) | sort
}
migration_is_test_target() {
  local name=${1##*/}
  case "$name" in
    *.sln|*.slnx|*Test*.csproj|*test*.csproj) return 0;;
  esac
  grep -Eiq '<IsTestProject>[[:space:]]*true|Microsoft\.NET\.Test\.Sdk|xunit|nunit|MSTest\.TestFramework' "$1"
}
migration_verify_runner_fixture() {
  local runner fixture output
  runner="$MIGRATION_HOME/.local/bin/dotfiles-dotnet10"
  fixture="$MIGRATION_STATE_DIR/dotnet10-runner-fixture.cs"
  [ -x "$runner" ] || migration_die "Managed .NET 10 file runner is missing: $runner" || return 1
  cat > "$fixture" <<'EOF'
System.Console.WriteLine("dotfiles-dotnet10-ok");
EOF
  chmod 600 "$fixture" || return 1
  output=$("$runner" run --file "$fixture") || migration_die 'Managed .NET 10 file runner fixture failed.' || return 1
  [ "$output" = dotfiles-dotnet10-ok ] || migration_die 'Managed .NET 10 file runner returned unexpected output.' || return 1
}
migration_verify_apphost() {
  local dir project exe output
  dir="$MIGRATION_STATE_DIR/apphost-probe"
  mkdir -p "$dir" || return 1
  project="$dir/ApphostProbe.csproj"
  cat > "$project" <<'EOF'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
    <UseAppHost>true</UseAppHost>
  </PropertyGroup>
</Project>
EOF
  cat > "$dir/global.json" <<'EOF'
{"sdk":{"version":"10.0.401","rollForward":"latestPatch","allowPrerelease":false}}
EOF
  cat > "$dir/Program.cs" <<'EOF'
System.Console.WriteLine(System.Runtime.InteropServices.RuntimeEnvironment.GetRuntimeDirectory());
EOF
  if [ "$MIGRATION_ARCH" = arm64 ]; then
    (cd "$dir" && env -u DOTNET_ROOT_X64 -u DOTNET_HOST_PATH -u MSBuildSDKsPath DOTNET_ROOT="$MIGRATION_SHARED_ROOT" DOTNET_ROOT_ARM64="$MIGRATION_SHARED_ROOT" "$MIGRATION_SHARED_ROOT/dotnet" build ApphostProbe.csproj --nologo --verbosity quiet) || migration_die 'Minimal apphost probe build failed.' || return 1
  else
    (cd "$dir" && env -u DOTNET_ROOT_ARM64 -u DOTNET_HOST_PATH -u MSBuildSDKsPath DOTNET_ROOT="$MIGRATION_SHARED_ROOT" DOTNET_ROOT_X64="$MIGRATION_SHARED_ROOT" "$MIGRATION_SHARED_ROOT/dotnet" build ApphostProbe.csproj --nologo --verbosity quiet) || migration_die 'Minimal apphost probe build failed.' || return 1
  fi
  exe="$dir/bin/Debug/net10.0/ApphostProbe"
  [ -x "$exe" ] || migration_die 'Framework-dependent apphost was not generated.' || return 1
  output=$(env -u DOTNET_ROOT -u DOTNET_ROOT_ARM64 -u DOTNET_ROOT_X64 -u DOTNET_HOST_PATH -u MSBuildSDKsPath "$exe") || migration_die 'Minimal-environment apphost failed; check architecture registration.' || return 1
  case "$output" in "$MIGRATION_SHARED_ROOT"/shared/Microsoft.NETCore.App/*) :;; *) migration_die "Apphost resolved a runtime outside the shared root: $output" || return 1;; esac
}
migration_verify_credential_helper() {
  local configured helper
  configured=$(git config --global --get credential.helper 2>/dev/null) || migration_die 'Global Git credential.helper is not configured.' || return 1
  helper=/usr/local/share/gcm-core/git-credential-manager
  [ "$configured" = "$helper" ] || migration_die "Git credential.helper does not select the native cask executable: $configured" || return 1
  [ -x "$helper" ] || migration_die "Native Git Credential Manager is unavailable: $helper" || return 1
  env -u DOTNET_ROOT -u DOTNET_ROOT_ARM64 -u DOTNET_ROOT_X64 -u DOTNET_HOST_PATH "$helper" --version >/dev/null || migration_die 'Native Git Credential Manager version check failed.' || return 1
}
migration_verify_critical_consumers() {
  local host version installed
  host="$MIGRATION_SHARED_ROOT/dotnet"
  [ -x "$host" ] || migration_die 'Shared SDK host is unavailable.' || return 1
  migration_check_host_architecture "$host" || return 1
  migration_dotnet_env "$MIGRATION_SHARED_ROOT" "$host" --info || return 1
  installed=$(migration_dotnet_env "$MIGRATION_SHARED_ROOT" "$host" --list-sdks) || return 1
  for version in $("$MIGRATION_JQ_BIN" -r '.retainedVersions[]' "$(migration_state_path)"); do
    printf '%s\n' "$installed" | grep -Fq "$version [" || migration_die "Retained SDK $version is missing from the shared root." || return 1
  done
  migration_verify_runner_fixture || return 1
  migration_verify_apphost || return 1
  migration_verify_credential_helper || return 1
}
migration_verify() {
  migration_init_defaults; migration_require_macos || return 1; migration_require_tools || return 1; migration_validate_inputs || return 1; migration_read_state || return 1; migration_reconcile_state_inputs || return 1; migration_lock || return 1
  local phase root host project; phase=$("$MIGRATION_JQ_BIN" -r '.phase' "$(migration_state_path)"); root=$("$MIGRATION_JQ_BIN" -r '.sharedRoot' "$(migration_state_path)"); host="$root/dotnet"
  [ "$phase" = switched ] || [ "$phase" = verified ] || migration_die 'verify requires switched state.' || return 1
  [ -z "$(printenv MSBuildSDKsPath 2>/dev/null || true)" ] || migration_die 'MSBuildSDKsPath overrides SDK resolution; remove it before verify.' || return 1
  [ -x "$host" ] || migration_die 'Shared mise host is unavailable.' || return 1
  local project_file version project_files
  for project in ${MIGRATION_PROJECTS[@]+"${MIGRATION_PROJECTS[@]}"}; do
    project_files=$(migration_select_projects "$project") || return 1
    [ -n "$project_files" ] || migration_die "No solution or project files found under: $project" || return 1
    while IFS= read -r project_file; do
      [ -n "$project_file" ] || continue
      version=$(cd "$(dirname "$project_file")" && migration_dotnet_env "$root" "$host" --version) || return 1
      printf 'Project %s selected SDK %s\n' "$project_file" "$version"
      (cd "$(dirname "$project_file")" && migration_dotnet_env "$root" "$host" build "$project_file") || return 1
      if migration_is_test_target "$project_file"; then
        (cd "$(dirname "$project_file")" && migration_dotnet_env "$root" "$host" test "$project_file" --no-restore) || return 1
      else
        printf 'Skipping direct test command for non-test project %s\n' "$project_file"
      fi
    done <<EOF
$project_files
EOF
  done
  migration_verify_critical_consumers || return 1
  migration_print_gui_checklist
  migration_update_state '.phase="verified" | .verification={timestamp:(now|todate),automated:true,guiAttested:false}' || return 1
  migration_note 'Automated checks completed. GUI checks remain pending.'
}
migration_finalize() {
  migration_init_defaults; migration_require_macos || return 1; migration_require_tools || return 1; migration_validate_inputs || return 1; migration_read_state || return 1; migration_reconcile_state_inputs || return 1; migration_lock || return 1
  [ "$MIGRATION_IDE_CHECKS_CONFIRMED" -eq 1 ] || migration_die 'finalize requires --ide-checks-confirmed after all consumer checks.' || return 1
  local phase package_file package_sha
  phase=$("$MIGRATION_JQ_BIN" -r '.phase' "$(migration_state_path)")
  [ "$phase" = verified ] || [ "$phase" = finalizing ] || [ "$phase" = awaiting-final-attestation ] || migration_die 'finalize requires verified state.' || return 1
  package_file=$("$MIGRATION_JQ_BIN" -r '.package.file' "$(migration_state_path)")
  package_sha=$("$MIGRATION_JQ_BIN" -r '.package.sha512' "$(migration_state_path)")
  [ -f "$package_file" ] && [ "$(migration_sha512 "$package_file")" = "$package_sha" ] || migration_die 'Verified rollback installer is missing or has changed; finalization is blocked.' || return 1
  migration_verify_package_signature "$package_file" >/dev/null 2>&1 || migration_die 'Rollback installer signature check failed.' || return 1
  local registration cask_status; registration=$("$MIGRATION_JQ_BIN" -r '.registration.desired' "$(migration_state_path)")
  migration_running_apps || return 1
  if [ "$phase" = verified ]; then
    [ "$(cat "$MIGRATION_REGISTRATION" 2>/dev/null || true)" = "$registration" ] || migration_die 'Architecture registration differs from expected shared root.' || return 1
  elif [ -e "$MIGRATION_REGISTRATION" ] && [ "$(cat "$MIGRATION_REGISTRATION" 2>/dev/null || true)" != "$registration" ]; then
    migration_die 'Architecture registration conflicts with the approved shared root.'
    return 1
  fi
  [ -n "$MIGRATION_BREW_BIN" ] || migration_die 'Homebrew is required.' || return 1
  [ -n "$MIGRATION_SUDO_BIN" ] && [ -n "$MIGRATION_PKGUTIL_BIN" ] || migration_die 'sudo and pkgutil are required to finalize the architecture registration and package signature.' || return 1
  if [ "$phase" = verified ]; then
    migration_update_state '.phase="finalizing" | .checkpoints.finalizeIntent=true | .checkpoints.guiAttested=true' || return 1
  fi
  cask_status=$(migration_cask_status) || return 1
  if [ "$("$MIGRATION_JQ_BIN" -r '.checkpoints.caskRemoved // false' "$(migration_state_path)")" = true ] && [ "$cask_status" = installed ]; then
    migration_die 'dotnet-sdk was reinstalled after removal; inspect state before finalizing.'
    return 1
  fi
  if [ "$("$MIGRATION_JQ_BIN" -r '.checkpoints.caskRemoved // false' "$(migration_state_path)")" != true ] && [ "$cask_status" = installed ]; then
    migration_note 'Removing only the dotnet-sdk cask; no --zap or --prune.'
    "$MIGRATION_BREW_BIN" uninstall --cask dotnet-sdk || migration_die 'Homebrew cask removal failed; preserve recovery files and resume finalize.' || return 1
  else
    migration_note 'dotnet-sdk cask is already absent; resuming its finalization checkpoint.'
  fi
  cask_status=$(migration_cask_status) || return 1
  [ "$cask_status" = absent ] || migration_die 'Homebrew still reports dotnet-sdk installed after uninstall.' || return 1
  printf 'Post-uninstall package path inventory:\n'
  migration_report_package_paths
  migration_update_state '.checkpoints.caskRemoved=true | .checkpoints.guiAttested=true' || return 1
  migration_write_registration "$registration" || return 1
  [ "$(cat "$MIGRATION_REGISTRATION")" = "$registration" ] || migration_die 'Registration did not persist after cask removal.' || return 1
  if [ -x "$MIGRATION_SYSTEM_ROOT/dotnet" ]; then
    local old_system_sdks
    old_system_sdks=$("$MIGRATION_SYSTEM_ROOT/dotnet" --list-sdks 2>/dev/null) || migration_die 'Could not inspect the old system SDK host after cask removal.' || return 1
    if [ -n "$old_system_sdks" ]; then
      migration_die 'The old system SDK remains after cask removal; inspect package state before continuing.'
      return 1
    fi
  fi
  migration_verify_critical_consumers || return 1
  if [ "$phase" != awaiting-final-attestation ]; then
    migration_update_state '.phase="awaiting-final-attestation" | .checkpoints.postRemovalChecks=true' || return 1
    migration_note 'Automated post-removal checks passed. Recheck VS Code, Insiders, Rider, Claude, and Codex with the old system SDK absent, close them, then rerun finalize --ide-checks-confirmed.'
    migration_print_gui_checklist
    return 0
  fi
  migration_update_state '.phase="finalized" | .checkpoints.postRemovalGuiAttested=true' || return 1
  migration_note 'Finalized. Retain backups/package; inspect /etc/paths.d and Homebrew links.'
}
migration_preflight_rollback_conflicts() {
  local state path applied kind current original expected reg_kind reg_value reg_sha reg_original manifest_path manifest_kind manifest_current manifest_original manifest_expected manifest_original_kind restored
  state=$(migration_state_path)
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    applied=$("$MIGRATION_JQ_BIN" -r --arg p "$path" '.targets[]|select(.path==$p)|.appliedSha256 // empty' "$state") || return 1
    [ -n "$applied" ] || continue
    original=$("$MIGRATION_JQ_BIN" -r --arg p "$path" '.targets[]|select(.path==$p)|.kind' "$state") || return 1
    kind=$(migration_kind "$path")
    restored=$("$MIGRATION_JQ_BIN" --arg p "$path" '.checkpoints.restoredTargets|index($p)!=null' "$state") || return 1
    if [ "$restored" = true ]; then
      case "$original" in
        absent) [ "$kind" = absent ] || migration_die "Rollback conflict: restored target was recreated: $path" || return 1;;
        file) [ "$kind" = file ] && [ "$(migration_sha "$path")" = "$("$MIGRATION_JQ_BIN" -r --arg p "$path" '.targets[]|select(.path==$p)|.originalSha256' "$state")" ] && [ "$(stat -f '%Lp' "$path")" = "$("$MIGRATION_JQ_BIN" -r --arg p "$path" '.targets[]|select(.path==$p)|.mode' "$state")" ] && [ "$(stat -f '%u' "$path")" = "$("$MIGRATION_JQ_BIN" -r --arg p "$path" '.targets[]|select(.path==$p)|.uid' "$state")" ] || migration_die "Rollback conflict: restored target changed: $path" || return 1;;
        symlink) [ "$kind" = symlink ] && [ "$(readlink "$path")" = "$(cat "$("$MIGRATION_JQ_BIN" -r --arg p "$path" '.targets[]|select(.path==$p)|.backupFile' "$state")")" ] || migration_die "Rollback conflict: restored symlink changed: $path" || return 1;;
      esac
    elif [ "$original" = absent ] && [ "$kind" = absent ]; then
      continue
    elif [ "$original" = file ] && [ "$kind" = file ] && [ "$(migration_sha "$path")" = "$("$MIGRATION_JQ_BIN" -r --arg p "$path" '.targets[]|select(.path==$p)|.originalSha256' "$state")" ] && [ "$(stat -f '%Lp' "$path")" = "$("$MIGRATION_JQ_BIN" -r --arg p "$path" '.targets[]|select(.path==$p)|.mode' "$state")" ] && [ "$(stat -f '%u' "$path")" = "$("$MIGRATION_JQ_BIN" -r --arg p "$path" '.targets[]|select(.path==$p)|.uid' "$state")" ]; then
      continue
    elif [ "$original" = symlink ] && [ "$kind" = symlink ] && [ "$(readlink "$path")" = "$(cat "$("$MIGRATION_JQ_BIN" -r --arg p "$path" '.targets[]|select(.path==$p)|.backupFile' "$state")")" ]; then
      continue
    elif [ "$applied" = absent ]; then [ "$kind" = absent ] || migration_die "Rollback conflict: target recreated: $path" || return 1
    else
      [ "$kind" = file ] || migration_die "Rollback conflict: target kind changed: $path" || return 1
      current=$(migration_sha "$path") || return 1
      [ "$current" = "$applied" ] || migration_die "Rollback conflict: target changed: $path" || return 1
    fi
  done <<EOF
$(migration_targets)
EOF
  manifest_path=$("$MIGRATION_JQ_BIN" -r '.manifest.path' "$state")
  manifest_kind=$(migration_kind "$manifest_path")
  manifest_current=absent
  if [ "$manifest_kind" = file ]; then manifest_current=$(migration_sha "$manifest_path") || return 1
  elif [ "$manifest_kind" != absent ]; then migration_die 'Rollback conflict: retained SDK manifest changed type.'; return 1; fi
  manifest_original_kind=$("$MIGRATION_JQ_BIN" -r '.manifest.originalKind' "$state")
  manifest_original=$("$MIGRATION_JQ_BIN" -r '.manifest.originalSha256' "$state")
  manifest_expected=$("$MIGRATION_JQ_BIN" -r '.manifest.appliedSha256 // .manifest.expectedSha256 // empty' "$state")
  if [ "$manifest_original_kind" = absent ] && [ "$manifest_current" = absent ]; then
    :
  elif [ "$manifest_kind" = file ] && { [ "$manifest_original_kind" = file ] && [ "$manifest_original" = "$manifest_current" ] || [ -n "$manifest_expected" ] && [ "$manifest_expected" = "$manifest_current" ]; }; then
    :
  else
    migration_die 'Rollback conflict: retained SDK manifest changed since prepare.'
    return 1
  fi
  reg_kind=$("$MIGRATION_JQ_BIN" -r '.registration.kind' "$state")
  reg_value=$("$MIGRATION_JQ_BIN" -r '.registration.desired' "$state")
  reg_sha=$("$MIGRATION_JQ_BIN" -r '.registration.originalSha256' "$state")
  reg_original=''
  [ ! -f "$MIGRATION_REGISTRATION" ] || reg_original=$(migration_sha "$MIGRATION_REGISTRATION") || return 1
  if [ -L "$MIGRATION_REGISTRATION" ]; then
    migration_die 'Rollback conflict: architecture registration became a symlink.'
    return 1
  elif [ -f "$MIGRATION_REGISTRATION" ]; then
    current=$(cat "$MIGRATION_REGISTRATION")
    if [ "$current" = "$reg_value" ]; then
      [ "$(stat -f '%Su' "$MIGRATION_REGISTRATION" 2>/dev/null)" = root ] && [ "$(stat -f '%Lp' "$MIGRATION_REGISTRATION" 2>/dev/null)" = 644 ] || { migration_die 'Rollback conflict: managed registration owner or mode changed.'; return 1; }
    elif [ "$reg_kind" = file ] && [ "$reg_sha" = "$reg_original" ]; then
      [ "$(stat -f '%u' "$MIGRATION_REGISTRATION" 2>/dev/null)" = "$("$MIGRATION_JQ_BIN" -r '.registration.uid' "$state")" ] && [ "$(stat -f '%Lp' "$MIGRATION_REGISTRATION" 2>/dev/null)" = "$("$MIGRATION_JQ_BIN" -r '.registration.mode' "$state")" ] || { migration_die 'Rollback conflict: original registration owner or mode changed.'; return 1; }
    else
      migration_die 'Rollback conflict: architecture registration changed since prepare.'
      return 1
    fi
  elif [ "$reg_kind" = file ]; then
    if [ "$("$MIGRATION_JQ_BIN" -r '.checkpoints.caskRemoved // false' "$state")" != true ] && [ "$("$MIGRATION_JQ_BIN" -r '.phase' "$state")" != finalizing ]; then
      migration_die 'Rollback conflict: original architecture registration disappeared.'
      return 1
    fi
  elif [ "$reg_kind" = absent ] && [ "$("$MIGRATION_JQ_BIN" -r '.checkpoints.caskRemoved // false' "$state")" != true ] && [ "$("$MIGRATION_JQ_BIN" -r '.phase' "$state")" != finalizing ] && [ "$("$MIGRATION_JQ_BIN" -r '.checkpoints.registration' "$state")" = registered ]; then
    migration_die 'Rollback conflict: registered architecture path disappeared.'
    return 1
  fi
}
migration_restore_targets() {
  local state path kind backup mode
  state=$(migration_state_path)
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    [ "$("$MIGRATION_JQ_BIN" --arg p "$path" '.checkpoints.appliedTargets|index($p)!=null' "$state")" = true ] || continue
    [ "$("$MIGRATION_JQ_BIN" --arg p "$path" '.checkpoints.restoredTargets|index($p)!=null' "$state")" = true ] && continue
    kind=$("$MIGRATION_JQ_BIN" -r --arg p "$path" '.targets[]|select(.path==$p)|.kind' "$state") || return 1
    backup=$("$MIGRATION_JQ_BIN" -r --arg p "$path" '.targets[]|select(.path==$p)|.backupFile' "$state") || return 1
    mode=$("$MIGRATION_JQ_BIN" -r --arg p "$path" '.targets[]|select(.path==$p)|.mode' "$state") || return 1
    case "$kind" in
      file) mkdir -p "$(dirname "$path")" && cp "$backup" "$path" && chmod "$mode" "$path" || return 1;;
      symlink) rm -f "$path" && ln -s "$(cat "$backup")" "$path" || return 1;;
      absent) rm -f "$path" || return 1;;
      *) migration_die "Unsupported original target kind $kind: $path" || return 1;;
    esac
    migration_update_state --arg p "$path" '.checkpoints.restoredTargets += [$p] | .checkpoints.restoredTargets |= unique' || return 1
  done <<EOF
$(migration_targets)
EOF
}
migration_restore_manifest() {
  local state path kind backup mode
  state=$(migration_state_path)
  path=$("$MIGRATION_JQ_BIN" -r '.manifest.path' "$state")
  kind=$("$MIGRATION_JQ_BIN" -r '.manifest.originalKind' "$state")
  backup=$("$MIGRATION_JQ_BIN" -r '.manifest.backupFile' "$state")
  mode=$("$MIGRATION_JQ_BIN" -r '.manifest.originalMode' "$state")
  if [ "$kind" = absent ]; then
    [ ! -e "$path" ] || rm -f "$path" || return 1
  else
    [ -f "$backup" ] || migration_die 'Retained SDK manifest backup is missing.' || return 1
    [ -f "$path" ] && [ "$(migration_sha "$path")" = "$("$MIGRATION_JQ_BIN" -r '.manifest.originalSha256' "$state")" ] && [ "$(stat -f '%Lp' "$path")" = "$mode" ] && return 0
    local temp
    temp=$(mktemp "$path.rollback.XXXXXX") || return 1
    cp "$backup" "$temp" && chmod "$mode" "$temp" && mv -f "$temp" "$path" || return 1
  fi
}
migration_restore_registration() {
  local kind backup temp original_mode original_uid baseline system_sdks
  kind=$("$MIGRATION_JQ_BIN" -r '.registration.kind' "$(migration_state_path)")
  backup=$("$MIGRATION_JQ_BIN" -r '.registration.backupFile' "$(migration_state_path)")
  baseline=$("$MIGRATION_JQ_BIN" -r '.package.version' "$(migration_state_path)")
  system_sdks=''
  if [ -x "$MIGRATION_SYSTEM_ROOT/dotnet" ]; then system_sdks=$("$MIGRATION_SYSTEM_ROOT/dotnet" --list-sdks 2>/dev/null) || migration_die 'Could not inspect the system SDK host for rollback.' || return 1; fi
  if ! printf '%s\n' "$system_sdks" | grep -q "^$baseline "; then
    local package_file package_sha
    package_file=$("$MIGRATION_JQ_BIN" -r '.package.file' "$(migration_state_path)")
    package_sha=$("$MIGRATION_JQ_BIN" -r '.package.sha512' "$(migration_state_path)")
    [ -f "$package_file" ] && [ "$(migration_sha512 "$package_file")" = "$package_sha" ] || migration_die 'Verified rollback package is missing or has changed.' || return 1
    migration_verify_package_signature "$package_file" >/dev/null 2>&1 || migration_die 'Rollback package signature no longer verifies.' || return 1
    [ -n "$MIGRATION_PACKAGE_TOOL" ] && [ -n "$MIGRATION_SUDO_BIN" ] || migration_die 'installer and sudo are required for runtime rollback.' || return 1
    "$MIGRATION_SUDO_BIN" "$MIGRATION_PACKAGE_TOOL" -pkg "$package_file" -target / || migration_die 'Rollback SDK package install failed; registration not restored.' || return 1
  fi
  if [ "$kind" = file ] && [ "$(cat "$MIGRATION_REGISTRATION" 2>/dev/null || true)" = "$(cat "$backup" 2>/dev/null || true)" ]; then return 0; fi
  if [ "$kind" = absent ] && [ ! -e "$MIGRATION_REGISTRATION" ]; then return 0; fi
  if [ "$kind" = absent ]; then "$MIGRATION_SUDO_BIN" rm -f "$MIGRATION_REGISTRATION" || return 1
  else
    [ -f "$backup" ] || migration_die 'Registration backup missing.' || return 1
    if [ ! -e /etc/dotnet ]; then "$MIGRATION_SUDO_BIN" mkdir -m 0755 /etc/dotnet || return 1; fi
    [ -d /etc/dotnet ] && [ ! -L /etc/dotnet ] && [ "$(stat -f '%Su' /etc/dotnet 2>/dev/null)" = root ] || migration_die '/etc/dotnet is missing or has unexpected ownership/type.' || return 1
    temp=$("$MIGRATION_SUDO_BIN" mktemp /etc/dotnet/.install_location_XXXXXX) || return 1
    cat "$backup" | "$MIGRATION_SUDO_BIN" tee "$temp" >/dev/null || { "$MIGRATION_SUDO_BIN" rm -f "$temp"; return 1; }
    original_mode=$("$MIGRATION_JQ_BIN" -r '.registration.mode' "$(migration_state_path)")
    original_uid=$("$MIGRATION_JQ_BIN" -r '.registration.uid' "$(migration_state_path)")
    "$MIGRATION_SUDO_BIN" chown "$original_uid":wheel "$temp" && "$MIGRATION_SUDO_BIN" chmod "$original_mode" "$temp" && "$MIGRATION_SUDO_BIN" mv -f "$temp" "$MIGRATION_REGISTRATION" || { "$MIGRATION_SUDO_BIN" rm -f "$temp"; return 1; }
  fi
}
migration_rollback() {
  migration_init_defaults; migration_require_macos || return 1; migration_require_tools || return 1; migration_validate_inputs || return 1; migration_read_state || return 1; migration_reconcile_state_inputs || return 1; migration_lock || return 1
  migration_preflight_rollback_conflicts || return 1
  # Restore runtime before registration. Preflight all file conflicts before any restore.
  migration_restore_registration || return 1
  migration_restore_targets || return 1
  migration_restore_manifest || return 1
  migration_update_state '.checkpoints.registration="restored" | .checkpoints.manifestRestored=true' || return 1
  if [ "$("$MIGRATION_JQ_BIN" -r '.checkpoints.caskRemoved // false' "$(migration_state_path)")" = true ] && { [ -z "$MIGRATION_BREW_BIN" ] || ! "$MIGRATION_BREW_BIN" list --cask dotnet-sdk >/dev/null 2>&1; }; then
    migration_update_state '.phase="rollback-awaiting-homebrew"' || return 1
    migration_note 'Rollback is incomplete: the verified vendor package and dotfiles are restored, but Homebrew receipt, PATH links, and cask declaration are not synthesized. Restore Homebrew ownership, verify command -v dotnet, then rerun rollback.'
    migration_note 'Suggested user action: brew install --cask dotnet-sdk; restore the dotnet-sdk declaration in the dotfiles source before a future package apply.'
    return 0
  fi
  migration_update_state '.phase="rolled-back"' || return 1
  migration_note 'Rollback completed for runtime selection and approved configuration. Additive mise SDKs remain installed; no Homebrew receipt was synthesized.'
}
migration_usage() {
  cat <<'EOF'
Usage: bash scripts/migrate-dotnet-macos.sh [plan|prepare|switch|verify|finalize|rollback] --state-dir ABSOLUTE_PATH [--project ABSOLUTE_ROOT_OR_SOLUTION]... [--sdk X.Y.Z]... [--ide-checks-confirmed]

Default phase is plan (read-only). Each mutation requires an explicit phase.
Pass every project root/solution and additional exact SDK version to retain.
Prepare backs up approved files, downloads/verifies the old vendor package, and
installs SDKs. Switch applies only allowlisted targets and architecture registration.
Verify runs selected project builds and prints manual GUI checks. Finalize removes
only the dotnet-sdk cask after explicit attestation. Rollback checks hashes and
restores the old runtime selection without deleting additive SDKs.
Run on macOS as the regular user. Repository tests use fake tools and do not
validate real SDK installations. GUI checks are manual and never inferred.
EOF
}
migration_main() {
  migration_init_defaults
  if [ "$#" -gt 0 ] && [[ "$1" != --* ]]; then MIGRATION_PHASE=$1; shift; fi
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --state-dir) [ "$#" -ge 2 ] || { migration_die '--state-dir requires a value.'; return 2; }; MIGRATION_STATE_DIR=$2; shift 2;;
      --project) [ "$#" -ge 2 ] || { migration_die '--project requires a value.'; return 2; }; MIGRATION_PROJECTS+=("$2"); shift 2;;
      --sdk) [ "$#" -ge 2 ] || { migration_die '--sdk requires a value.'; return 2; }; MIGRATION_SDKS+=("$2"); shift 2;;
      --ide-checks-confirmed) MIGRATION_IDE_CHECKS_CONFIRMED=1; shift;;
      -h|--help) migration_usage; return 0;;
      *) migration_die "Unknown argument: $1"; migration_usage >&2; return 2;;
    esac
  done
  migration_validate_inputs || return 2
  case "$MIGRATION_PHASE" in
    plan) migration_inventory;; prepare) migration_prepare;; switch) migration_switch;; verify) migration_verify;; finalize) migration_finalize;; rollback) migration_rollback;;
    *) migration_die "Unknown phase: $MIGRATION_PHASE"; migration_usage >&2; return 2;;
  esac
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  migration_main "$@"
  exit $?
fi
