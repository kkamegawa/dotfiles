#!/bin/sh
# run_once_after_35-install-apple-container.sh
# Install Apple Container from Apple's signed package on supported macOS hosts.

set -eu

skip() {
  printf '%s\n' "==> Skipping Apple Container installation: $1"
  exit 0
}

fail() {
  printf '%s\n' "Apple Container installation failed: $1" >&2
  exit 1
}

if [ "$(uname -s)" != "Darwin" ]; then
  skip "this is not macOS."
fi

if [ "$(uname -m)" != "arm64" ]; then
  skip "Apple Container requires Apple silicon."
fi

macos_version=$(sw_vers -productVersion) || fail "could not determine the macOS version."
macos_major=${macos_version%%.*}
case "$macos_major" in
  ''|*[!0-9]*) fail "could not parse macOS version '$macos_version'." ;;
esac
if [ "$macos_major" -lt 26 ]; then
  skip "Apple Container requires macOS 26 or later (found $macos_version)."
fi

package_id=com.apple.container-installer
if pkgutil --pkg-info "$package_id" >/dev/null 2>&1; then
  printf '%s\n' "==> Apple Container is already installed; leaving it unchanged."
  exit 0
fi

if command -v container >/dev/null 2>&1; then
  container_path=$(command -v container)
  skip "found '$container_path' without the $package_id package receipt; refusing to overwrite another installation."
fi

command -v curl >/dev/null 2>&1 || fail "curl is not available."
command -v mise >/dev/null 2>&1 || fail "mise is required to read the configured jq tool."

jq_path=$(MISE_CONFIG_FILE="$HOME/.config/mise/config.toml" mise -C "$HOME" which jq) || fail "mise could not locate jq."
[ -x "$jq_path" ] || fail "jq executable was not found at '$jq_path'."

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/apple-container-install.XXXXXX") || fail "could not create a temporary directory."
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

release_json=$tmp_dir/release.json
api_url=https://api.github.com/repos/apple/container/releases/latest
if ! curl --fail --location --silent --show-error \
  --header 'Accept: application/vnd.github+json' \
  --header 'X-GitHub-Api-Version: 2022-11-28' \
  --header 'User-Agent: dotfiles-apple-container-bootstrap' \
  --output "$release_json" "$api_url"; then
  fail "could not retrieve Apple's latest release metadata."
fi

asset_metadata=$(
  "$jq_path" -er '
    .tag_name as $tag
    | ($tag | ltrimstr("v")) as $version
    | [ .assets[] | select(.name == ("container-" + $version + "-installer-signed.pkg")) ]
    | if length == 1 then
        .[0] | [.name, .browser_download_url, .digest] | @tsv
      else
        error("expected exactly one versioned signed installer package")
      end
  ' "$release_json"
) || fail "the latest release has no unique versioned signed installer package."

tab=$(printf '\t')
old_ifs=$IFS
IFS=$tab
read -r asset_name download_url digest <<EOF
$asset_metadata
EOF
IFS=$old_ifs

case "$asset_name" in
  container-*-installer-signed.pkg) ;;
  *) fail "release asset name is not a signed installer package." ;;
esac
case "$download_url" in
  https://github.com/apple/container/releases/download/*/container-*-installer-signed.pkg) ;;
  *) fail "release asset URL is not an official Apple Container signed package URL." ;;
esac
case "$digest" in
  sha256:*) expected_sha256=${digest#sha256:} ;;
  *) fail "the release does not publish a SHA-256 digest for the signed package." ;;
esac
if [ "${#expected_sha256}" -ne 64 ] || ! printf '%s\n' "$expected_sha256" | grep -Eq '^[[:xdigit:]]{64}$'; then
  fail "the release published an invalid SHA-256 digest."
fi

pkg_path=$tmp_dir/$asset_name
printf '%s\n' "==> Downloading Apple's signed Apple Container package..."
if ! curl --fail --location --silent --show-error --output "$pkg_path" "$download_url"; then
  fail "could not download the signed package."
fi

actual_sha256=$(shasum -a 256 "$pkg_path" | awk '{print $1}') || fail "could not calculate the package checksum."
if [ "$actual_sha256" != "$expected_sha256" ]; then
  fail "the package SHA-256 does not match the release digest."
fi

signature_output=$tmp_dir/signature.txt
if ! pkgutil --check-signature "$pkg_path" >"$signature_output" 2>&1; then
  cat "$signature_output" >&2
  fail "the installer signature check failed."
fi
if ! grep -Fq 'Status: signed by a certificate trusted by Mac OS X' "$signature_output"; then
  cat "$signature_output" >&2
  fail "the package is not signed by a certificate trusted by macOS."
fi

printf '%s\n' "==> Installing Apple Container from the verified signed package..."
sudo installer -pkg "$pkg_path" -target / || fail "the macOS installer command failed."
printf '%s\n' "==> Apple Container installation complete. Start it manually with 'container system start' when ready."
