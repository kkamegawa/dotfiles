#!/bin/sh
# run_after_20-mise-upgrade.sh
# Keep mise-managed tools up to date on every chezmoi apply/update.

set -e

update_dotnet_global_tools() {
  if ! command -v dotnet >/dev/null 2>&1; then
    echo "⚠️  dotnet が見つかりません。dotnet global tool 更新をスキップします" >&2
    return 0
  fi

  managed_tools="dotnet-ef
csharpier
docfx
dotnet-counters
git-credential-manager
ilspycmd
microsoft.dotnet-scaffold
microsoft.dataapibuilder
microsoft.openapi.kiota
microsoft.sqlpackage
microsoft.web.librarymanager.cli
nbgv
terminalguidesigner
upgrade-assistant
dotnet-outdated-tool"

  echo "==> Ensuring managed dotnet global tools..."
  for tool_name in $managed_tools; do
    if dotnet tool list -g 2>/dev/null | awk 'NR > 2 {print $1}' | grep -Fxq "$tool_name"; then
      echo "==> Updating dotnet global tool: $tool_name"
      dotnet tool update --global "$tool_name"
    else
      echo "==> Installing dotnet global tool: $tool_name"
      dotnet tool install --global "$tool_name"
    fi
  done
}

update_dotnet_global_tools

if ! command -v mise >/dev/null 2>&1; then
  echo "⚠️  mise が見つかりません。mise upgrade をスキップします" >&2
  exit 0
fi

echo "==> mise install を実行します..."
mise install

echo "==> mise upgrade を実行します..."
mise upgrade

echo "==> mise install/upgrade 完了"
