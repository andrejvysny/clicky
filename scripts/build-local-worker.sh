#!/usr/bin/env bash
# Builds the local inference worker (Tools/ClickyLocalWorker) and the MLX Metal library it needs.
#
# Output (gitignored): build/local-worker/{clicky-local-worker, mlx.metallib, VERSION}
# The worker finds mlx.metallib next to its executable (mlx-swift lookup: <exe dir>/mlx.metallib, then
# <exe dir>/Resources/mlx.metallib). SwiftPM cannot compile .metal files, so the library is built here from
# the exact mlx checkout the binary was compiled against, offline: metal-cpp, json and fmt come vendored from
# mlx-swift's Source/Cmlx. Needs the Metal Toolchain (Xcode > Settings > Components). Does not codesign.
#
# Exit codes: 0 ok, 3 Metal Toolchain missing (binary is still produced), 4 cmake/ninja missing.
set -euo pipefail
clicky_repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
clicky_cache_root="${CLICKY_CACHE_DIR:-${TMPDIR:-/tmp}/clicky-worker-build}"
clicky_swift_command="${CLICKY_SWIFT_BIN:-swift}"
# 14.0 is enough everywhere: mlx-swift builds in JIT mode (nojit_kernels.cpp excluded), so the M5 NAX matmul,
# quantized and attention kernels are compiled at runtime from source embedded in the binary, not loaded from
# this metallib (see jit_kernels.cpp get_*_nax_kernel). Untested on M5 hardware.
clicky_metallib_target="${CLICKY_METALLIB_DEPLOYMENT_TARGET:-14.0}"
package_path="$clicky_repository_root/Tools/ClickyLocalWorker"
output_dir="$clicky_repository_root/build/local-worker"
scratch_path="$clicky_cache_root/build"

mkdir -p "$clicky_cache_root" "$output_dir"
export CLANG_MODULE_CACHE_PATH="$clicky_cache_root/clang"
swift_flags=(--package-path "$package_path" -c release
  --cache-path "$clicky_cache_root/cache" --config-path "$clicky_cache_root/config"
  --security-path "$clicky_cache_root/security" --scratch-path "$scratch_path"
  --force-resolved-versions)

"$clicky_swift_command" build "${swift_flags[@]}" --jobs 4
bin_path="$("$clicky_swift_command" build "${swift_flags[@]}" --show-bin-path)"
install -m 755 "$bin_path/clicky-local-worker" "$output_dir/clicky-local-worker"
rm -f "$output_dir/mlx.metallib"

write_version() {
  local metallib_state="$1" commit dirty=""
  commit="$(git -C "$clicky_repository_root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  git -C "$clicky_repository_root" diff --quiet HEAD -- 2>/dev/null || dirty="-dirty"
  {
    echo "commit: ${commit}${dirty}"
    echo "metallib: $metallib_state (deployment target $clicky_metallib_target)"
    echo "pins (Tools/ClickyLocalWorker/Package.resolved):"
    awk -F'"' '/"identity"/ {id=$4} /"version"/ && id != "" {print "  " id " " $4; id=""}' "$package_path/Package.resolved"
  } > "$output_dir/VERSION"
}

if ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
  write_version missing
  echo "Metal Toolchain missing: install via Xcode › Settings › Components or \`xcodebuild -downloadComponent MetalToolchain\`" >&2
  echo "Built $output_dir/clicky-local-worker without mlx.metallib." >&2
  exit 3
fi
if ! command -v cmake >/dev/null 2>&1 || ! command -v ninja >/dev/null 2>&1; then
  write_version missing
  echo "cmake and ninja are required to build mlx.metallib (brew install cmake ninja)." >&2
  exit 4
fi

cmlx="$scratch_path/checkouts/mlx-swift/Source/Cmlx"
metallib_build="$clicky_cache_root/metallib"
cmake -S "$cmlx/mlx" -B "$metallib_build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET="$clicky_metallib_target" \
  -DMLX_BUILD_METAL=ON -DMLX_BUILD_TESTS=OFF -DMLX_BUILD_EXAMPLES=OFF -DMLX_BUILD_BENCHMARKS=OFF \
  -DMLX_BUILD_PYTHON_BINDINGS=OFF -DMLX_BUILD_PYTHON_STUBS=OFF -DMLX_BUILD_GGUF=OFF -DMLX_BUILD_SAFETENSORS=OFF \
  -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
  -DFETCHCONTENT_SOURCE_DIR_METAL_CPP="$cmlx/metal-cpp" \
  -DFETCHCONTENT_SOURCE_DIR_JSON="$cmlx/json" \
  -DFETCHCONTENT_SOURCE_DIR_FMT="$cmlx/fmt"
cmake --build "$metallib_build" --target mlx-metallib

metallib="$(find "$metallib_build" -name mlx.metallib -print -quit)"
if [[ -z "$metallib" ]]; then
  echo "mlx.metallib was not produced." >&2
  exit 5
fi
install -m 644 "$metallib" "$output_dir/mlx.metallib"
write_version built
echo "Built $output_dir (clicky-local-worker, mlx.metallib, VERSION)."
