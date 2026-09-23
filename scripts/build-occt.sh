#!/usr/bin/env bash
# Reproducible build of Open CASCADE Technology (OCCT) for Forge.
#
# Builds OCCT as SHARED libraries (LGPL 2.1 + OCCT exception: we link dynamically,
# see docs/adr/0005-gpl-process-boundary.md and docs/LICENSES.md).
#
# Usage:
#   scripts/build-occt.sh [--version V8_0_1] [--prefix Vendor/occt/<os>-<arch>] [--jobs N]
#
# On macOS it additionally wraps each toolkit dylib into an .xcframework under
# Vendor/occt/xcframeworks (requires xcodebuild). On Linux the install prefix is
# used directly by Package.swift via FORGE_OCCT_PREFIX.
set -euo pipefail

OCCT_TAG="V8_0_1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
PREFIX="$ROOT/Vendor/occt/${OS}-${ARCH}"
SRC_DIR="${OCCT_SRC_DIR:-$ROOT/Vendor/src/occt-${OCCT_TAG}}"
JOBS="$( (command -v nproc >/dev/null && nproc) || sysctl -n hw.ncpu)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) OCCT_TAG="$2"; SRC_DIR="$ROOT/Vendor/src/occt-${OCCT_TAG}"; shift 2 ;;
    --prefix)  PREFIX="$2"; shift 2 ;;
    --src)     SRC_DIR="$2"; shift 2 ;;
    --jobs)    JOBS="$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done

if [[ ! -d "$SRC_DIR" ]]; then
  git clone --depth 1 --branch "$OCCT_TAG" https://github.com/Open-Cascade-SAS/OCCT.git "$SRC_DIR"
fi

BUILD_DIR="$SRC_DIR/build-forge-${OS}-${ARCH}"
CMAKE_EXTRA=()
# Installed toolkits must find each other (e.g. TKDESTEP -> TKXCAF) without relying on the
# host executable's rpath, which is not transitive on Linux (DT_RUNPATH).
if [[ "$OS" == "darwin" ]]; then
  CMAKE_EXTRA+=(-DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
                -DCMAKE_INSTALL_NAME_DIR=@rpath -DCMAKE_MACOSX_RPATH=ON
                "-DCMAKE_INSTALL_RPATH=@loader_path")
else
  CMAKE_EXTRA+=('-DCMAKE_INSTALL_RPATH=$ORIGIN')
fi

# Headless kernel only: no Visualization (we render with Metal), no Draw (Tcl), no Tk/X11/OpenGL.
cmake -S "$SRC_DIR" -B "$BUILD_DIR" -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DBUILD_LIBRARY_TYPE=Shared \
  -DBUILD_MODULE_FoundationClasses=ON \
  -DBUILD_MODULE_ModelingData=ON \
  -DBUILD_MODULE_ModelingAlgorithms=ON \
  -DBUILD_MODULE_ApplicationFramework=ON \
  -DBUILD_MODULE_DataExchange=ON \
  -DBUILD_MODULE_Visualization=OFF \
  -DBUILD_MODULE_Draw=OFF \
  -DBUILD_MODULE_DETools=OFF \
  -DBUILD_DOC_Overview=OFF \
  -DUSE_TK=OFF -DUSE_TCL=OFF -DUSE_XLIB=OFF -DUSE_OPENGL=OFF -DUSE_GLES2=OFF \
  -DUSE_FREETYPE=OFF -DUSE_FREEIMAGE=OFF -DUSE_RAPIDJSON=OFF -DUSE_DRACO=OFF \
  -DUSE_TBB=OFF -DUSE_VTK=OFF -DUSE_OPENVR=OFF -DUSE_FFMPEG=OFF \
  "${CMAKE_EXTRA[@]}"

cmake --build "$BUILD_DIR" --parallel "$JOBS"
cmake --install "$BUILD_DIR"

# Normalise include dir: OCCT installs headers under include/opencascade.
echo "OCCT ${OCCT_TAG} installed to ${PREFIX}"

if [[ "$OS" == "darwin" ]] && command -v xcodebuild >/dev/null; then
  XC="$ROOT/Vendor/occt/xcframeworks"
  rm -rf "$XC"; mkdir -p "$XC"
  for lib in "$PREFIX"/lib/libTK*.dylib; do
    [[ -L "$lib" ]] && continue
    name="$(basename "$lib" .dylib)"; name="${name#lib}"; name="${name%%.*}"
    xcodebuild -create-xcframework -library "$lib" -headers "$PREFIX/include/opencascade" \
      -output "$XC/${name}.xcframework" >/dev/null
  done
  echo "xcframeworks written to $XC"
fi

cat <<MSG
Next: export FORGE_OCCT_PREFIX="$PREFIX" and run 'swift build'.
MSG
