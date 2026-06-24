#!/usr/bin/env bash
#
# Build frpc as Android c-shared libraries (libfrpc.so), one per ABI.
#
# It pulls frp as a Go module dependency (latest release by default) and
# cross-compiles the thin c-shared wrapper in frplib/ against it with the
# Android NDK. Each ABI is packaged as bin_<arch>.tgz with the layout
#
#     lib/libfrpc.so
#     version
#
# ready to drop into an Android app's runtime installer (e.g. under
# assets/runtimes/frpc/).
#
# Why c-shared rather than a standalone executable: the engine is meant to live
# in the app's writable data directory and be dlopen'd by a tiny native loader
# (see loader/). Android API 29+ forbids execve from the data dir but still
# allows dlopen, and a dlopen'able .so there can be updated independently of
# the host APK.
#
# Usage:
#   ./scripts/build.sh [abi ...]
#
# Environment overrides:
#   FRP_VERSION       frp module version to build (default: latest release).
#                     Set to a tag like v0.69.1 to pin; set to "keep" to use
#                     whatever is already pinned in go.mod (reproducible build,
#                     no network update).
#   ANDROID_NDK_HOME  NDK path (default: /d/AndroidSDK/ndk/28.2.13676358).
#   ANDROID_API       min API level (default: 24).
#
# On Windows run it from Git Bash; the NDK .cmd compiler wrappers are selected
# automatically.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

FRP_VERSION="${FRP_VERSION:-latest}"
ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-/d/AndroidSDK/ndk/28.2.13676358}"
API="${ANDROID_API:-24}"

command -v go >/dev/null 2>&1 || { echo "error: go not found in PATH" >&2; exit 1; }

# Select the prebuilt NDK toolchain for this build host. Windows wrappers are .cmd.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) HOST_TAG=windows-x86_64; CC_EXT=.cmd ;;
  Linux)                HOST_TAG=linux-x86_64;   CC_EXT= ;;
  Darwin)               HOST_TAG=darwin-x86_64;  CC_EXT= ;;
  *) echo "error: unsupported build host: $(uname -s)" >&2; exit 1 ;;
esac
TOOLBIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$HOST_TAG/bin"
[ -d "$TOOLBIN" ] || { echo "error: NDK toolchain not found: $TOOLBIN" >&2; exit 1; }

# ── 1. Resolve the frp dependency ──────────────────────────────────────────
if [ "$FRP_VERSION" = "keep" ]; then
  echo ">>> using frp version already pinned in go.mod (no update)"
else
  echo ">>> resolving frp@$FRP_VERSION"
  go get "github.com/fatedier/frp@$FRP_VERSION"
fi

FRP_VER="$(go list -m github.com/fatedier/frp | awk '{print $2}')"
echo "    frp = $FRP_VER"

# Mirror frp's own `replace` directives into our go.mod. A required module's
# replaces are NOT inherited by the main module, and frp pins a patched yamux
# fork (and may add more replaces in future releases), so we copy them over
# automatically to stay correct as frp evolves.
FRPMOD="$(go env GOMODCACHE)/github.com/fatedier/frp@$FRP_VER/go.mod"
if [ -f "$FRPMOD" ]; then
  if grep -qE '^replace[[:space:]]*\(' "$FRPMOD"; then
    echo "WARNING: frp go.mod uses block-form replace(...); verify replaces manually" >&2
  fi
  while read -r line; do
    [ -z "$line" ] && continue
    old="$(echo "$line" | awk '{print $2}')"
    new="$(echo "$line" | awk '{print $4}')"
    ver="$(echo "$line" | awk '{print $5}')"
    [ -n "$old" ] && [ -n "$new" ] || continue
    if [ -n "$ver" ]; then
      go mod edit -replace="${old}=${new}@${ver}"
    else
      go mod edit -replace="${old}=${new}"
    fi
    echo "    mirrored replace: $old => $new ${ver:-}"
  done < <(grep -E '^replace[[:space:]]+[^(]' "$FRPMOD")
fi

go mod tidy

VERSION="$FRP_VER"

# ── 2. Cross-compile and package per ABI ───────────────────────────────────
DIST="$ROOT/dist"
PKGS="$DIST/packages"
mkdir -p "$PKGS"

ABIS=("$@")
[ ${#ABIS[@]} -eq 0 ] && ABIS=(arm64-v8a armeabi-v7a x86_64)

for abi in "${ABIS[@]}"; do
  armenv=""
  case "$abi" in
    arm64-v8a)   goarch=arm64; ccname=aarch64-linux-android${API};    pkgarch=arm64 ;;
    armeabi-v7a) goarch=arm;   ccname=armv7a-linux-androideabi${API}; pkgarch=arm;    armenv="GOARM=7" ;;
    x86_64)      goarch=amd64; ccname=x86_64-linux-android${API};      pkgarch=x86_64 ;;
    x86)         goarch=386;   ccname=i686-linux-android${API};        pkgarch=x86 ;;
    *) echo "skip unknown abi: $abi" >&2; continue ;;
  esac

  cc="$TOOLBIN/${ccname}-clang${CC_EXT}"
  [ -e "$cc" ] || { echo "error: compiler not found: $cc" >&2; exit 1; }
  out="$DIST/$abi"
  mkdir -p "$out"

  echo ">>> building $abi (GOARCH=$goarch) with $(basename "$cc")"
  # -checklinkname=0 is required: github.com/wlynxg/anet (the Android network
  # interface shim, compiled only for GOOS=android) uses //go:linkname against
  # net.zoneCache, which the linker rejects by default on Go 1.23+.
  env CGO_ENABLED=1 GOOS=android GOARCH="$goarch" $armenv CC="$cc" \
    go build -buildmode=c-shared -trimpath \
      -ldflags "-s -w -checklinkname=0" \
      -o "$out/libfrpc.so" ./frplib

  stage="$(mktemp -d)"
  mkdir -p "$stage/lib"
  cp "$out/libfrpc.so" "$stage/lib/libfrpc.so"
  echo "$VERSION" > "$stage/version"
  tar -C "$stage" -czf "$PKGS/bin_${pkgarch}.tgz" lib version
  rm -rf "$stage"

  echo "    -> $out/libfrpc.so"
  echo "    -> $PKGS/bin_${pkgarch}.tgz"
done

# Standalone version file, copied alongside the packages so a consumer can
# compare versions without unpacking a .tgz first.
echo "$VERSION" > "$PKGS/version"

echo ""
echo "done. frp=$VERSION  ABIs=${ABIS[*]}"
echo "packages: $PKGS"
echo "drop bin_<arch>.tgz + version into your Android app's assets/runtimes/frpc/"
