#!/usr/bin/env bash
set -euo pipefail
clicky_repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
clicky_cache_root="${CLICKY_CACHE_DIR:-${TMPDIR:-/tmp}/clicky-swift-cache}"
clicky_swift_command="${CLICKY_SWIFT_BIN:-swift}"
mkdir -p "$clicky_cache_root"
export CLANG_MODULE_CACHE_PATH="$clicky_cache_root/clang"
cd "$clicky_repository_root"
exec "$clicky_swift_command" test --jobs 4 \
  --cache-path "$clicky_cache_root/cache" \
  --config-path "$clicky_cache_root/config" \
  --security-path "$clicky_cache_root/security" \
  --scratch-path "$clicky_cache_root/build" "$@"
