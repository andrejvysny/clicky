#!/usr/bin/env bash
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
  echo "Mac preflight requires macOS. Cloud checks: bash scripts/test-core.sh"
  exit 1
fi
echo "macOS version:"
sw_vers -productVersion
echo "Architecture:"
uname -m
echo "Selected developer directory:"
xcode-select -p
echo "Swift toolchain:"
xcrun swift --version
for clicky_agent in claude codex; do
  if command -v "$clicky_agent" >/dev/null 2>&1; then
    echo "$clicky_agent executable: $(command -v "$clicky_agent")"
    "$clicky_agent" --version
  else
    echo "$clicky_agent not found in this terminal's PATH; configure its path in Clicky Settings."
  fi
done
echo "Preflight does not establish sign-in or GUI readiness. Follow docs/MAC_VALIDATION.md."
