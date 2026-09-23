#!/usr/bin/env bash
# Builds the planegcs oracle (docs/adr/0003): FreeCAD's sketch solver, compiled out of tree
# as a separate executable used only by tests. planegcs is LGPL-2.1+; it is never linked into
# Forge (docs/adr/0005). Needs git, a C++20 compiler, Eigen 3 and Boost.Graph headers.
#   tools/planegcs-oracle/build.sh [output-dir]   → <output-dir>/planegcs-oracle
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/.build}"
tag="1.1.3"
src="$out/FreeCAD-$tag"
mkdir -p "$out"
if [ ! -d "$src/src/Mod/Sketcher/App/planegcs" ]; then
  rm -rf "$src"
  git clone --quiet --depth 1 --branch "$tag" --filter=blob:none --sparse https://github.com/FreeCAD/FreeCAD.git "$src"
  git -C "$src" sparse-checkout set src/Mod/Sketcher/App/planegcs
fi
pg="$src/src/Mod/Sketcher/App/planegcs"
cp "$here/shim/SketcherGlobal.h" "$src/src/Mod/Sketcher/SketcherGlobal.h"
${CXX:-g++} -std=c++20 -O2 -w \
  -I"$here/shim" -I/usr/include/eigen3 ${EIGEN_INCLUDE:+-I"$EIGEN_INCLUDE"} ${BOOST_INCLUDE:+-I"$BOOST_INCLUDE"} -I"$pg" \
  "$here/oracle.cpp" "$pg/GCS.cpp" "$pg/Constraints.cpp" "$pg/Geo.cpp" "$pg/SubSystem.cpp" "$pg/qp_eq.cpp" \
  -o "$out/planegcs-oracle" -lpthread
echo "$out/planegcs-oracle"
