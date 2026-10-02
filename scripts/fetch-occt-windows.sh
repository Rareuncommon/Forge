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
    downloaded=0
    for tag in "${tags[@]}"; do
        base="https://github.com/Open-Cascade-SAS/OCCT/releases/download/$tag"
        if curl -fsSL -o "$dest/occt.zip.download" "$base/opencascade-release-no-pch.zip"; then
            mv "$dest/occt.zip.download" "$dest/occt.zip"
            # Failed curl downloads can leave partial files; never unpack or cache those.
            rm -f "$dest/3rdparty.zip"
            if curl -fsSL -o "$dest/3rdparty.zip.download" "$base/3rdparty-vc14-64.zip"; then
                mv "$dest/3rdparty.zip.download" "$dest/3rdparty.zip"
            else
                rm -f "$dest/3rdparty.zip.download"
            fi
            downloaded=1
            echo "$tag" > "$dest/.tag"
            break
        fi
        rm -f "$dest/occt.zip.download"
        echo "no Windows release build for $tag" >&2
    done
    [ "$downloaded" -eq 1 ] || { echo "could not download OCCT" >&2; exit 1; }
    (cd "$dest" && unzip -q -o occt.zip -d occt && rm occt.zip)
    if [ -f "$dest/3rdparty.zip" ]; then (cd "$dest" && unzip -q -o 3rdparty.zip -d 3rdparty && rm 3rdparty.zip); fi
    # The release assets wrap the actual archives (opencascade-<v>-vc14-64.zip…): unpack those too.
    while read -r inner; do
        [ -n "$inner" ] || continue
        unzip -q -o "$inner" -d "$(dirname "$inner")" && rm "$inner"
    done < <(find "$dest" -name '*.zip')
fi

# Locate the install inside the archive (layouts differ between releases).
header="$(find "$dest/occt" -name Standard.hxx -print -quit)"
[ -n "$header" ] || { echo "Standard.hxx not found in the OCCT archive" >&2; find "$dest/occt" -maxdepth 3 >&2; exit 1; }
incdir="$(dirname "$header")"
case "$incdir" in
    */include/opencascade) prefix="$(dirname "$(dirname "$incdir")")" ;;
    *) prefix="$(dirname "$incdir")" ;;
esac
libfile="$(find "$prefix" -name TKernel.lib -print -quit)"
[ -n "$libfile" ] || { echo "TKernel.lib not found under $prefix" >&2; exit 1; }
libdir="$(dirname "$libfile")"
# Package.swift looks in <prefix>/lib and <prefix>/win64/vc14/lib; link anything else there.
if [ "$libdir" != "$prefix/lib" ] && [ "$libdir" != "$prefix/win64/vc14/lib" ]; then
    mkdir -p "$prefix/lib" && cp "$libdir"/*.lib "$prefix/lib/"
fi
prefix="$(cd "$prefix" && pwd)"
# DLLs the toolkits load: OCCT, TBB, jemalloc, and what TKService (pulled in by the STEP/STL
# exchange through XCAF) imports: FreeImage, FreeType, FFmpeg, OpenVR. Not the bundled MSVC
# runtime (msvc-vc14-64: older than the system's, it shadows it) nor the viewers' Qt, VTK or
# Tcl/Tk.
# Batch directory extraction in POSIX sh: BSD find has no GNU -printf, while
# passing filenames as arguments preserves spaces and quotes on every host.
dlldirs="$(find "$dest" -name '*.dll' -exec sh -c 'for dll do printf "%s\n" "${dll%/*}"; done' sh {} + | sort -u | grep -Ev '/(qt|vtk|tcltk|glfw|angle|gl2ps|msvc)[^/]*(/|$)|/(debug|plugins)(/|$)' || true)"

{
    printf 'export FORGE_OCCT_PREFIX=%q\n' "$(cygpath -m "$prefix")"
    while IFS= read -r d; do
        [[ -n "$d" ]] || continue
        printf 'export PATH=%q:"$PATH"\n' "$(cd "$d" && pwd)"
    done <<< "$dlldirs"
} > "$dest/forge-env.sh"
# Only cache a complete, validated installation and its generated environment.
touch "$dest/.fetched"
echo "OCCT $(cat "$dest/.tag" 2>/dev/null): prefix $prefix, libraries $libdir"
echo "DLL directories:"; echo "$dlldirs"
