#!/usr/bin/env bash
# build/build-mfem.sh — compile MFEM (FE solver) to WASM static libs.
#
# This is the swappable "solver" layer. If you ever want to evaluate a
# different FE library, add a sibling build-<solver>.sh and point the Dockerfile
# at it; OCCT and Netgen above are untouched.
set -euo pipefail

: "${MFEM_TAG:?must be set}"
: "${MFEM_WASM_ROOT:?must be set}"

SRC=/build/sources
JOBS="$(nproc)"
mkdir -p "${SRC}"

echo "==> Building MFEM ${MFEM_TAG} — ~10-20 min"
[ -f "${SRC}/mfem.tar.gz" ] || \
curl -fsSL "https://github.com/mfem/mfem/archive/refs/tags/${MFEM_TAG}.tar.gz" \
    -o "${SRC}/mfem.tar.gz"
mkdir -p "${SRC}/mfem"
tar -xzf "${SRC}/mfem.tar.gz" -C "${SRC}/mfem" --strip-components=1

# isockstream.cpp calls bind() unqualified; emcc's libc++ resolves it as
# std::bind via ADL. Qualify to avoid the collision.
sed -i 's/if (bind(sfd,/if (::bind(sfd,/g' \
    "${SRC}/mfem/general/isockstream.cpp"

mkdir -p "${SRC}/build-mfem"
cd "${SRC}/build-mfem"

emcmake cmake "${SRC}/mfem" \
    -G Ninja \
    -DCMAKE_INSTALL_PREFIX="${MFEM_WASM_ROOT}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_FLAGS="-fPIC" \
    -DCMAKE_C_FLAGS="-fPIC" \
    -DMFEM_USE_MPI=OFF \
    -DMFEM_USE_OPENMP=OFF \
    -DMFEM_USE_LAPACK=OFF \
    -DMFEM_USE_METIS=OFF \
    -DMFEM_USE_SUPERLU=OFF \
    -DMFEM_USE_SUITESPARSE=OFF \
    -DBUILD_SHARED_LIBS=OFF

ninja -j"${JOBS}" install

if [ ! -f "${MFEM_WASM_ROOT}/lib/libmfem.a" ]; then
    echo "ERROR: MFEM build failed — libmfem.a not found" >&2
    exit 1
fi

rm -rf "${SRC}/mfem" "${SRC}/build-mfem"
echo "  MFEM done."
