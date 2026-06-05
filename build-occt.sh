#!/usr/bin/env bash
# build/build-occt.sh — compile OCCT to WASM static libs.
set -euo pipefail

: "${OCCT_VERSION:?must be set}"
: "${OCCT_WASM_ROOT:?must be set}"

SRC=/build/sources
JOBS="$(nproc)"
mkdir -p "${SRC}"

OCCT_TAG="V$(echo "${OCCT_VERSION}" | tr '.' '_')"
echo "==> Building OCCT ${OCCT_VERSION} (tag ${OCCT_TAG}) — ~60-90 min on first run"

curl -fsSL "https://github.com/Open-Cascade-SAS/OCCT/archive/refs/tags/${OCCT_TAG}.tar.gz" \
    -o "${SRC}/occt.tar.gz"
mkdir -p "${SRC}/occt"
tar -xzf "${SRC}/occt.tar.gz" -C "${SRC}/occt" --strip-components=1

mkdir -p "${SRC}/build-occt"
cd "${SRC}/build-occt"

emcmake cmake "${SRC}/occt" \
    -G Ninja \
    -DCMAKE_INSTALL_PREFIX="${OCCT_WASM_ROOT}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_MODULE_Draw=OFF \
    -DBUILD_MODULE_Visualization=OFF \
    -DBUILD_MODULE_ApplicationFramework=OFF \
    -DBUILD_MODULE_FoundationClasses=ON \
    -DBUILD_MODULE_ModelingData=ON \
    -DBUILD_MODULE_ModelingAlgorithms=ON \
    -DBUILD_MODULE_DataExchange=ON \
    -DBUILD_MODULE_Mesh=ON \
    -DUSE_FREETYPE=OFF \
    -DUSE_OPENGL=OFF \
    -DUSE_TBB=OFF \
    -DUSE_FREEIMAGE=OFF \
    -DUSE_FFMPEG=OFF \
    -DUSE_OPENVR=OFF \
    -DBUILD_SHARED_LIBS=OFF

ninja -j"${JOBS}"

# ExpToCasExe is a host-side tool Emscripten can't fully link; the install
# fails at the very last step but all .a files are already written.
ninja install 2>&1 || true

if [ ! -f "${OCCT_WASM_ROOT}/lib/libTKernel.a" ]; then
    echo "ERROR: OCCT install failed — libTKernel.a not found" >&2
    exit 1
fi

# OCCT 7.7+ consolidated TKSTEP* into TKDESTEP. Create classic-name symlinks so
# downstream CMakeLists can use the old names without version checks.
echo "==> Patching OCCT DataExchange library names..."
cd "${OCCT_WASM_ROOT}/lib"
for OLD in TKSTEP TKSTEP209 TKSTEPAttr TKSTEPBase TKXSBase; do
    if [ ! -f "lib${OLD}.a" ]; then
        if [ -f "libTKDESTEP.a" ]; then
            ln -sf libTKDESTEP.a "lib${OLD}.a"
            echo "  lib${OLD}.a -> libTKDESTEP.a"
        else
            echo "  WARNING: lib${OLD}.a missing and libTKDESTEP.a not found" >&2
        fi
    fi
done

# Drop sources/build tree so this layer only carries the installed libs.
rm -rf "${SRC}/occt" "${SRC}/build-occt" "${SRC}/occt.tar.gz"
echo "  OCCT done."
