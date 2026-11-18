#!/usr/bin/env bash
# Build libcrispasr.so (and the ggml libraries it needs) for arm64-v8a with NDK r30, strip them,
# copy them to the app's jniLibs, and build the C ABI smoke test against them.
set -euo pipefail

APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$APP/.." && pwd)"
# The CrispASR checkout: CRISPASR_SRC, else <repo>/third_party/CrispASR (see README), else the
# development harness's copy.
SRC="${CRISPASR_SRC:-$REPO/third_party/CrispASR}"
[ -d "$SRC" ] || SRC="$REPO/harness/third_party/CrispASR"
NDK="$REPO/tools/android-ndk-r30"
TOOLCHAIN="$NDK/build/cmake/android.toolchain.cmake"
STRIP="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
CC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android28-clang"
READELF="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf"
OUT="$APP/android/app/src/main/jniLibs/arm64-v8a"
BUILD="$SRC/build-android-shared"
SMOKE_DIR="$APP/native/build"

# CrispASR v0.8.54, the version Fauxnetic's patches are written against.
COMMIT="9ddae4590d427f27e0ca04694864eed66bcb530e"
HEAD="$(git -C "$SRC" rev-parse HEAD)"
[ "$HEAD" = "$COMMIT" ] || { echo "CrispASR checkout at $HEAD, expected $COMMIT" >&2; exit 1; }

# Fauxnetic's changes to the pinned CrispASR, applied once (app/native/patches, in order).
for p in "$APP"/native/patches/*.patch; do
  if git -C "$SRC" apply --reverse --check "$p" 2>/dev/null; then
    echo "patch already applied: $(basename "$p")"
  else
    git -C "$SRC" apply "$p" || { echo "patch does not apply: $p" >&2; exit 1; }
  fi
done

export PKG_CONFIG_LIBDIR=""
export PKG_CONFIG_PATH=""

cmake -S "$SRC" -B "$BUILD" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-28 \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON -DGGML_OPENMP=OFF -DGGML_NATIVE=OFF \
  -DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16 -DCRISPASR_AMR=OFF -DCMAKE_DISABLE_FIND_PACKAGE_OpenMP=ON
cmake --build "$BUILD" --target crispasr-lib -j"$(nproc)"

rm -rf "$OUT"
mkdir -p "$OUT"
find "$BUILD" -name '*.so' -type f -exec cp {} "$OUT/" \;
for so in "$OUT"/*.so; do "$STRIP" --strip-unneeded "$so"; done

SYSTEM="libc.so libm.so libdl.so liblog.so libmediandk.so libandroid.so"
BUNDLED="$(cd "$OUT" && echo *.so)"
for so in "$OUT"/*.so; do
  for need in $("$READELF" -d "$so" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p'); do
    case " $SYSTEM $BUNDLED " in
      *" $need "*) ;;
      *) echo "$(basename "$so") needs $need, which is neither a system nor a bundled library" >&2; exit 1 ;;
    esac
  done
done
(cd "$OUT" && ls -1 *.so) > "$APP/native/LIBS.txt"
echo "bundled:"; cat "$APP/native/LIBS.txt"

mkdir -p "$SMOKE_DIR"
"$CC" -O2 -I"$SRC/include" -I"$SRC/ggml/include" "$APP/native/abi_smoke.c" -L"$OUT" -lcrispasr -o "$SMOKE_DIR/abi_smoke"
file "$SMOKE_DIR/abi_smoke"
