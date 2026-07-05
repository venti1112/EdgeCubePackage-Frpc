#!/usr/bin/env bash
#
# Build frpc as Android c-shared libraries (libfrpc.so), one per ABI, and
# package them as EdgeCube .ecpkg runtime packages.
#
# It pulls frp as a Go module dependency (latest release by default) and
# cross-compiles the thin c-shared wrapper in frplib/ against it with the
# Android NDK. Each ABI is packaged as <id>-<arch>.ecpkg with the layout
#
#     edgecube-package.json
#     <arch>/lib/libfrpc.so
#
# A multi-arch package, <id>-multi.ecpkg, is also produced when more than one
# supported ABI is built.
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
#   ECPKG_VERSION     build number (integer) in manifest (default: 1).
#   ECPKG_VERSION_NAME
#                     display version string (default: auto-detected from frp).
#   ECPKG_ID          runtime id in edgecube-package.json (default: frpc).
#   ECPKG_NAME        display name in edgecube-package.json (default: FRP Client).
#   ECPKG_AUTHOR      package author (default: EdgeCube).
#   ECPKG_HOMEPAGE    homepage URL (default: https://github.com/fatedier/frp).
#   ECPKG_REPOSITORY  repository URL.
#   ECPKG_MIN_APP_VERSION
#                     minimum EdgeCube versionCode (default: 6).
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
ECPKG_ID="${ECPKG_ID:-frpc}"
ECPKG_NAME="${ECPKG_NAME:-FRP Client}"
ECPKG_AUTHOR="${ECPKG_AUTHOR:-EdgeCube}"
ECPKG_HOMEPAGE="${ECPKG_HOMEPAGE:-https://github.com/fatedier/frp}"
ECPKG_REPOSITORY="${ECPKG_REPOSITORY:-https://github.com/venti1112/EdgeCubePackage-Frpc}"
ECPKG_MIN_APP_VERSION="${ECPKG_MIN_APP_VERSION:-6}"
ECPKG_VERSION="${ECPKG_VERSION:-1}"
ECPKG_VERSION_NAME="${ECPKG_VERSION_NAME:-}"
ECPKG_UPDATE_URL="${ECPKG_UPDATE_URL:-}"

# ecpkg arch dir → lookup key mapping (must match EcPackage.pickArchDir)
declare -A ARCH_KEY_MAP
ARCH_KEY_MAP[aarch64]=aarch64
ARCH_KEY_MAP[arm]=arm
ARCH_KEY_MAP[x86_64]=x86_64

command -v go >/dev/null 2>&1 || { echo "error: go not found in PATH" >&2; exit 1; }
[[ "$ECPKG_ID" =~ ^[A-Za-z0-9._-]+$ && "$ECPKG_ID" != .* ]] || {
  echo "error: ECPKG_ID must match ^[A-Za-z0-9._-]+$ and must not start with '.'" >&2
  exit 1
}
[[ "$ECPKG_VERSION" =~ ^[0-9]+$ ]] || {
  echo "error: ECPKG_VERSION must be an integer" >&2
  exit 1
}
[[ "$ECPKG_MIN_APP_VERSION" =~ ^[0-9]+$ ]] || {
  echo "error: ECPKG_MIN_APP_VERSION must be an integer" >&2
  exit 1
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  printf '%s' "$s"
}

write_manifest() {
  local manifest="$1"
  shift
  local archs=("$@")
  local version_json version_name_json name_json author_json homepage_json repository_json update_url_json
  version_json="$(json_escape "$VERSION")"
  if [[ -n "$ECPKG_VERSION_NAME" ]]; then
    version_name_json="$(json_escape "$ECPKG_VERSION_NAME")"
  else
    version_name_json="$version_json"
  fi
  name_json="$(json_escape "$ECPKG_NAME")"
  author_json="$(json_escape "$ECPKG_AUTHOR")"
  homepage_json="$(json_escape "$ECPKG_HOMEPAGE")"
  repository_json="$(json_escape "$ECPKG_REPOSITORY")"
  update_url_json="$(json_escape "$ECPKG_UPDATE_URL")"

  cat > "$manifest" <<EOF
{
  "formatVersion": 1,
  "type": "frpc",
  "id": "$ECPKG_ID",
  "name": "$name_json",
  "version": $ECPKG_VERSION,
  "versionName": "$version_name_json",
  "description": "frp client runtime for EdgeCube.",
  "author": "$author_json",
  "homepage": "$homepage_json",
  "repository": "$repository_json",
EOF

    if [[ -n "$ECPKG_UPDATE_URL" ]]; then
      printf '  "updateUrl": "%s",\n' "$update_url_json" >> "$manifest"
    fi

    cat >> "$manifest" <<EOF
  "arch": {
EOF

  for i in "${!archs[@]}"; do
    local dir="${archs[$i]}"
    local key="${ARCH_KEY_MAP[$dir]}"
    local comma=","
    [ "$i" -eq $((${#archs[@]} - 1)) ] && comma=""
    printf '    "%s": { "dir": "%s" }%s\n' "$key" "$dir" "$comma" >> "$manifest"
  done

  cat >> "$manifest" <<EOF
  },
  "launcher": {
    "type": "frpc",
    "lib": "lib/libfrpc.so"
  },
  "minAppVersion": $ECPKG_MIN_APP_VERSION
}
EOF
}

zip_dir() {
  local src="$1"
  local dst="$2"
  rm -f "$dst"

  if command -v zip >/dev/null 2>&1; then
    (cd "$src" && zip -9qr "$dst" edgecube-package.json */)
    return
  fi

  local py=""
  if command -v python3 >/dev/null 2>&1; then
    py="$(command -v python3)"
  elif command -v python >/dev/null 2>&1; then
    py="$(command -v python)"
  fi
  [ -n "$py" ] || { echo "error: zip or python is required to create .ecpkg packages" >&2; exit 1; }

  "$py" - "$src" "$dst" <<'PY'
import os
import sys
import zipfile

src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dst, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
    for root, dirs, files in os.walk(src):
        dirs.sort()
        files.sort()
        rel_root = os.path.relpath(root, src)
        if rel_root != ".":
            zf.write(root, rel_root.replace(os.sep, "/") + "/")
        for name in files:
            path = os.path.join(root, name)
            rel = os.path.relpath(path, src).replace(os.sep, "/")
            zf.write(path, rel)
PY
}

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
MULTI_STAGE="$DIST/ecpkg-staging/multi"
mkdir -p "$PKGS"
rm -rf "$DIST/ecpkg-staging"
rm -f "$PKGS"/"${ECPKG_ID}"-*.ecpkg "$PKGS"/bin_*.tgz "$PKGS"/version

ABIS=("$@")
[ ${#ABIS[@]} -eq 0 ] && ABIS=(arm64-v8a armeabi-v7a x86_64)
built_archs=()

for abi in "${ABIS[@]}"; do
  armenv=""
  case "$abi" in
    arm64-v8a)   goarch=arm64; ccname=aarch64-linux-android${API};    pkgarch=aarch64 ;;
    armeabi-v7a) goarch=arm;   ccname=armv7a-linux-androideabi${API}; pkgarch=arm;    armenv="GOARM=7" ;;
    x86_64)      goarch=amd64; ccname=x86_64-linux-android${API};      pkgarch=x86_64 ;;
    x86) echo "skip unsupported ecpkg abi: $abi (EdgeCube package spec supports aarch64, arm, x86_64)" >&2; continue ;;
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

  single_stage="$DIST/ecpkg-staging/$pkgarch"
  mkdir -p "$single_stage/$pkgarch/lib"
  cp "$out/libfrpc.so" "$single_stage/$pkgarch/lib/libfrpc.so"
  write_manifest "$single_stage/edgecube-package.json" "$pkgarch"
  zip_dir "$single_stage" "$PKGS/${ECPKG_ID}-${pkgarch}.ecpkg"

  mkdir -p "$MULTI_STAGE/$pkgarch/lib"
  cp "$out/libfrpc.so" "$MULTI_STAGE/$pkgarch/lib/libfrpc.so"
  if [[ " ${built_archs[*]} " != *" $pkgarch "* ]]; then
    built_archs+=("$pkgarch")
  fi

  echo "    -> $out/libfrpc.so"
  echo "    -> $PKGS/${ECPKG_ID}-${pkgarch}.ecpkg"
done

if [ ${#built_archs[@]} -eq 0 ]; then
  echo "error: no supported ABIs were built" >&2
  exit 1
fi

if [ ${#built_archs[@]} -gt 1 ]; then
  write_manifest "$MULTI_STAGE/edgecube-package.json" "${built_archs[@]}"
  zip_dir "$MULTI_STAGE" "$PKGS/${ECPKG_ID}-multi.ecpkg"
  echo "    -> $PKGS/${ECPKG_ID}-multi.ecpkg"
fi

echo ""
echo "done. frp=$VERSION  ABIs=${ABIS[*]}"
echo "packages: $PKGS"
echo "import ${ECPKG_ID}-<arch>.ecpkg or ${ECPKG_ID}-multi.ecpkg from EdgeCube's runtime page."
