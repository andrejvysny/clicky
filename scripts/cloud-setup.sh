#!/usr/bin/env bash
set -euo pipefail
clicky_repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
clicky_cache_root="${CLICKY_CACHE_DIR:-/workspace/.cache/clicky-swift}"
clicky_swift_version=6.2.3
clicky_toolchain_root="$clicky_cache_root/toolchain"
if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
  echo "Use your installed Swift 6+ toolchain and run bash scripts/test-core.sh."
  exit 1
fi
mkdir -p "$clicky_cache_root/downloads" "$clicky_cache_root/gnupg"
chmod 700 "$clicky_cache_root/gnupg"
if [[ ! -x "$clicky_toolchain_root/usr/bin/swift" ]]; then
  clicky_archive="$clicky_cache_root/downloads/swift.tar.gz"
  clicky_download_url="https://download.swift.org/swift-${clicky_swift_version}-release/debian12/swift-${clicky_swift_version}-RELEASE/swift-${clicky_swift_version}-RELEASE-debian12.tar.gz"
  curl --fail --location --silent --show-error "$clicky_download_url" --output "$clicky_archive"
  curl --fail --location --silent --show-error "$clicky_download_url.sig" --output "$clicky_archive.sig"
  curl --fail --location --silent --show-error \
    https://raw.githubusercontent.com/swiftlang/swift-org-website/c9b6d647ce3e30adbfe7e97f1c460d503adc6c0b/keys/all-keys.asc \
    --output "$clicky_cache_root/downloads/swift-keys.asc"
  gpg --homedir "$clicky_cache_root/gnupg" --import "$clicky_cache_root/downloads/swift-keys.asc"
  gpg --homedir "$clicky_cache_root/gnupg" --status-fd 1 --verify "$clicky_archive.sig" "$clicky_archive" > "$clicky_cache_root/downloads/signature-status.txt"
  rg -q '^\[GNUPG:\] VALIDSIG 52BB7E3DE28A71BE22EC05FFEF80A866B47A981F ' "$clicky_cache_root/downloads/signature-status.txt"
  mkdir -p "$clicky_toolchain_root"
  tar -xzf "$clicky_archive" -C "$clicky_toolchain_root" --strip-components=1
fi
"$clicky_toolchain_root/usr/bin/swift" --version
CLICKY_SWIFT_BIN="$clicky_toolchain_root/usr/bin/swift" CLICKY_CACHE_DIR="$clicky_cache_root" bash "$clicky_repository_root/scripts/test-core.sh"
