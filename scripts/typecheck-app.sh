#!/usr/bin/env bash
set -euo pipefail
clicky_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
clicky_stub_dir="$(mktemp -d "${TMPDIR:-/tmp}/clicky-typecheck.XXXXXX")"
trap 'rm -rf "$clicky_stub_dir"' EXIT
cat > "$clicky_stub_dir/Sparkle.swift" <<'SWIFT'
import Foundation
@MainActor public final class SPUUpdater { public func start() throws {} }
@MainActor public final class SPUStandardUpdaterController {
    public let updater = SPUUpdater()
    public init(startingUpdater: Bool, updaterDelegate: AnyObject?, userDriverDelegate: AnyObject?) {}
}
SWIFT
xcrun swiftc -emit-module -target arm64-apple-macos14.2 -module-name Sparkle -o "$clicky_stub_dir/Sparkle.swiftmodule" "$clicky_stub_dir/Sparkle.swift"
cd "$clicky_root"
clicky_sources=()
# ripgrep is optional; fall back to find so a stock macOS install can typecheck.
if command -v rg >/dev/null 2>&1; then clicky_list_sources() { rg --files leanring-buddy -g '*.swift'; }
else clicky_list_sources() { find leanring-buddy -name '*.swift' -type f; }; fi
while IFS= read -r clicky_source; do clicky_sources+=("$clicky_source"); done < <(clicky_list_sources | sort)
clicky_defines=(-D CLICKY_TYPECHECK)
if [[ "${1:-}" == "--debug" ]]; then clicky_defines+=(-D DEBUG); fi
xcrun swiftc -typecheck -module-name Clicky -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -target arm64-apple-macos14.2 -swift-version 5 -I "$clicky_stub_dir" \
  -default-isolation MainActor -enable-upcoming-feature MemberImportVisibility \
  -enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances \
  -enable-upcoming-feature InferSendableFromCaptures -enable-upcoming-feature GlobalActorIsolatedTypesUsability \
  -enable-upcoming-feature DisableOutwardActorInference "${clicky_defines[@]}" "${clicky_sources[@]}"
