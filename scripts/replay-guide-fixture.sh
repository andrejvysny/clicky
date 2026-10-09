#!/usr/bin/env bash
# Offline gate B replay: renders the synthetic fixture states into a scratch directory, replays them through a
# real clean provider session with the host's own messages, prints counts (and, with --show-text, the provider's
# synthetic-fixture text to stdout only), then deletes the images. Usage:
#   scripts/replay-guide-fixture.sh SCRATCH_DIR /absolute/path/to/claude [--runs=N] [--show-text]
set -euo pipefail
scratch="$1"; executable="$2"; shift 2
root="$(cd "$(dirname "$0")/.." && pwd)"
states="$scratch/fixture-states"; profile="$scratch/clicky-replay-profile"
trap 'rm -rf "$states"' EXIT
mkdir -p "$profile"
python3 "$root/scripts/render-guide-fixture.py" "$states" >/dev/null 2>&1
swift build --package-path "$root" --product clicky-guide >/dev/null
"$(swift build --package-path "$root" --show-bin-path)/clicky-guide" replay claude "$executable" "$profile" "$states/manifest.json" "$@"
