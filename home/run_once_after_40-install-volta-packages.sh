#!/usr/bin/env bash
# Install Volta-managed global npm packages listed in apm.yml
set -euo pipefail

if ! command -v volta &>/dev/null; then
  echo "volta not found, skipping global npm package install"
  exit 0
fi

volta install @microsoft/workiq
