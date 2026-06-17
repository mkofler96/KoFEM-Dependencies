#!/usr/bin/env bash
# test/run-smoke.sh — compile & run the OCCT + Netgen + MFEM smoke test under node.
#
# Invoked at image-build time (see Dockerfile) so a broken dependency pipeline
# fails the image build instead of the downstream engine. The link line mirrors
# the consuming engine's CMakeLists so "links here" implies "links there".
set -euo pipefail

: "${OCCT_WASM_ROOT:?must be set}"
: "${NETGEN_WASM_ROOT:?must be set}"
: "${MFEM_WASM_ROOT:?must be set}"

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "${OUT}"' EXIT

# Netgen install layouts vary; add every include variant that exists.
NG_INC=()
for d in "${NETGEN_WASM_ROOT}/include" "${NETGEN_WASM_ROOT}/include/netgen"; do
    [ -d "${d}" ] && NG_INC+=("-I${d}")
done

# OCCT link set, mirroring the engine. Classic STEP/IGES/STL names resolve to the
# 7.8 TKDE* libs via the symlinks build-occt.sh creates. Unreferenced archives are
# simply not pulled, so listing the full set is free and keeps Netgen's OCC layer
# satisfied. Wrapped in a group so inter-library ordering doesn't matter.
OCCT_LIBS=(
    -lTKernel -lTKMath -lTKG2d -lTKG3d -lTKGeomBase -lTKBRep
    -lTKGeomAlgo -lTKTopAlgo -lTKMesh -lTKShHealing
    -lTKXSBase -lTKSTEP -lTKSTEP209 -lTKSTEPAttr -lTKSTEPBase
    -lTKCDF -lTKLCAF -lTKCAF -lTKXCAF -lTKVCAF -lTKService -lTKV3d -lTKHLR
    -lTKDE -lTKDEIGES -lTKDESTL -lTKPrim -lTKFillet -lTKOffset
)

# Some Netgen builds expose the OCC layer as a separate libngocc.a.
NG_OCC=()
[ -f "${NETGEN_WASM_ROOT}/lib/libngocc.a" ] && NG_OCC+=(-lngocc)

echo "==> Compiling dependency smoke test (OCCT + Netgen + MFEM)"
em++ "${HERE}/smoke.cpp" \
    -std=c++17 -O2 -fexceptions \
    -I"${OCCT_WASM_ROOT}/include/opencascade" \
    "${NG_INC[@]}" \
    -I"${MFEM_WASM_ROOT}/include" \
    -L"${OCCT_WASM_ROOT}/lib" \
    -L"${NETGEN_WASM_ROOT}/lib" \
    -L"${MFEM_WASM_ROOT}/lib" \
    -Wl,--start-group \
        "${OCCT_LIBS[@]}" \
        -lnglib -lngcore "${NG_OCC[@]}" \
        -lmfem \
    -Wl,--end-group \
    -sDISABLE_EXCEPTION_CATCHING=0 \
    -sINITIAL_MEMORY=67108864 \
    -sALLOW_MEMORY_GROWTH=1 \
    -sUSE_ZLIB=1 \
    -o "${OUT}/smoke.js"

echo "==> Running smoke test under node"
node "${OUT}/smoke.js"
echo "  smoke test passed."
