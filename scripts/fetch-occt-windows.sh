#!/usr/bin/env bash
# Fetch the official OCCT release build for Windows (MSVC x64) into Vendor/occt/windows-x64 and
# print the environment Forge needs: FORGE_OCCT_PREFIX and the DLL directories for PATH.
# Tries the newest tag first. Runs in Git Bash (CI and developer machines).
#
#   scripts/fetch-occt-windows.sh [dest]        (default dest: Vendor/occt/windows-x64)
#
# Writes <dest>/forge-env.sh, to source: `. Vendor/occt/windows-x64/forge-env.sh`.
set -euo pipefail
dest="${1:-Vendor/occt/windows-x64}"
tags=(V8_0_1 V8_0_0)
mkdir -p "$dest"
if [ ! -f "$dest/.fetched" ]; then
    for tag in "${tags[@]}"; do
        base="https://github.com/Open-Cascade-SAS/OCCT/releases/download/$tag"
        if curl -fsSL -o "$dest/occt.zip" "$base/opencascade-release-no-pch.zip"; then
            curl -fsSL -o "$dest/3rdparty.zip" "$base/3rdparty-vc14-64.zip" || true
            echo "$tag" > "$dest/.tag"
            break
        fi
        echo "no Windows release build for $tag" >&2
    done
    [ -f "$dest/occt.zip" ] || { echo "could not download OCCT" >&2; exit 1; }
    (cd "$dest" && unzip -q -o occt.zip -d occt && rm occt.zip)
    if [ -f "$dest/3rdparty.zip" ]; then (cd "$dest" && unzip -q -o 3rdparty.zip -d 3rdparty && rm 3rdparty.zip); fi
    # The release assets wrap the actual archives (opencascade-<v>-vc14-64.zip…): unpack those too.
    while read -r inner; do
        [ -n "$inner" ] || continue
        unzip -q -o "$inner" -d "$(dirname "$inner")" && rm "$inner"
    done < <(find "$dest" -name '*.zip')
    touch "$dest/.fetched"
fi

# Locate the install inside the archive (layouts differ between releases).
header="$(find "$dest/occt" -name Standard.hxx | head -1)"
[ -n "$header" ] || { echo "Standard.hxx not found in the OCCT archive" >&2; find "$dest/occt" -maxdepth 3 >&2; exit 1; }
incdir="$(dirname "$header")"
case "$incdir" in
    */include/opencascade) prefix="$(dirname "$(dirname "$incdir")")" ;;
    *) prefix="$(dirname "$incdir")" ;;
esac
libfile="$(find "$prefix" -name TKernel.lib | head -1)"
[ -n "$libfile" ] || { echo "TKernel.lib not found under $prefix" >&2; exit 1; }
libdir="$(dirname "$libfile")"
# Package.swift looks in <prefix>/lib and <prefix>/win64/vc14/lib; link anything else there.
if [ "$libdir" != "$prefix/lib" ] && [ "$libdir" != "$prefix/win64/vc14/lib" ]; then
    mkdir -p "$prefix/lib" && cp "$libdir"/*.lib "$prefix/lib/"
fi
prefix="$(cd "$prefix" && pwd)"
# DLLs the kernel toolkits load (OCCT itself, TBB, jemalloc). Not the bundled MSVC runtime
# (msvc-vc14-64: older than the system's, it breaks newer programs) nor the viewers'
# third-party libraries (Qt, VTK, Tcl/Tk…).
dlldirs="$(find "$dest" -name '*.dll' -printf '%h\n' | sort -u | grep -Ev '/(qt|vtk|tcltk|glfw|angle|openvr|gl2ps|ffmpeg|freeimage|msvc|lzma|zlib|freetype)[^/]*(/|$)|/debug/' || true)"

{
    echo "export FORGE_OCCT_PREFIX='$(cygpath -m "$prefix")'"
    for d in $dlldirs; do echo "export PATH=\"$(cd "$d" && pwd):\$PATH\""; done
} > "$dest/forge-env.sh"
echo "OCCT $(cat "$dest/.tag" 2>/dev/null): prefix $prefix, libraries $libdir"
echo "DLL directories:"; echo "$dlldirs"
