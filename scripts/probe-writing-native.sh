#!/usr/bin/env bash
# Native writing adapter probe (CLICKY-42 support). Compiles the production adapter sources with a small
# driver and runs it against real applications. Requires Accessibility for the terminal running this script
# and Automation (Terminal). The HARNESS (never Clicky) opens a scratch Terminal window with
# `do script ""` and simulates the tester's Return (only into that tab, after the focus gate) to prove the execution counter only changes then.
# Usage: scripts/probe-writing-native.sh chrome|chrome-rich|terminal|vscode|vscode-terminal
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="${CLICKY_PROBE_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/clicky-writing-probe.XXXXXX")}"
cd "$root"
xcrun swiftc -O -module-name ClickyProbe -sdk "$(xcrun --show-sdk-path --sdk macosx)" -target arm64-apple-macos14.2 \
  -swift-version 5 -default-isolation MainActor -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -enable-upcoming-feature InferIsolatedConformances -enable-upcoming-feature InferSendableFromCaptures \
  -enable-upcoming-feature GlobalActorIsolatedTypesUsability -enable-upcoming-feature DisableOutwardActorInference \
  leanring-buddy/TextInput/Core/*.swift \
  leanring-buddy/TextInput/{WritingNativeTargets,WritingAXField,WritingTerminalAdapter,WritingVSCodeAdapter,WritingClipboard,WritingEnvironment,WindowSnapshotCapture,ScopedAccessibility}.swift \
  Tools/ClickyWritingProbe/main.swift -o "$work/probe"
case "${1:-}" in
  chrome)
    open -a "Google Chrome" "$root/Tests/NativeFixtures/writing.html"; sleep 3
    "$work/probe" chrome ;;
  chrome-rich)
    open -a "Google Chrome" "file://$root/Tests/NativeFixtures/writing.html#rich"; sleep 3
    "$work/probe" chrome-rich ;;
  terminal)
    marker="$work/executed-marker"; rm -f "$marker"
    window=$(osascript -e 'tell application "Terminal"' -e 'do script ""' -e 'return id of front window' -e 'end tell'); sleep 2
    tty=$(osascript -e "tell application \"Terminal\" to get tty of selected tab of window id $window")
    "$work/probe" terminal "$marker" "$tty"; sleep 1
    [[ -e "$marker" ]] && echo "FAIL executed before tester Enter" || echo "PASS execution counter 0 before tester Enter"
    "$work/probe" tester-enter "$tty"; sleep 1.5
    [[ -e "$marker" ]] && echo "PASS execution counter 1 only after tester Enter" || echo "FAIL tester Enter did not execute"
    osascript -e "tell application \"Terminal\" to do script \"sleep 6\" in window id $window" >/dev/null; sleep 1
    "$work/probe" terminal-busy; sleep 6
    osascript -e "tell application \"Terminal\" to close window id $window" ;;
  vscode|vscode-terminal)
    "$work/probe" "$1" "$work/vscode-marker"
    [[ "$1" == vscode-terminal ]] && { [[ -e "$work/vscode-marker" ]] && echo "FAIL executed" || echo "PASS execution counter 0"; } ;;
  *) echo "usage: $0 chrome|chrome-rich|terminal|vscode|vscode-terminal" >&2; exit 2 ;;
esac
