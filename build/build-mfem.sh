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

# Build in a fresh directory. ${SRC} is a persistent buildx cache mount, so a
# stale CMakeCache.txt from an earlier configure can pin a previous compiler
# (e.g. the native host toolchain) and silently produce ELF objects instead of
# WASM — which then fails the relocatable combine below. Wipe to force emcmake
# to re-detect the Emscripten toolchain every build.
rm -rf "${SRC}/build-mfem"
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

LIB="${MFEM_WASM_ROOT}/lib/libmfem.a"
if [ ! -f "${LIB}" ]; then
    echo "ERROR: MFEM build failed — libmfem.a not found" >&2
    exit 1
fi

# ── Force-include packaging (KoFEM#175) ───────────────────────────────────────
# The consuming engine links MFEM by bare name (`-lmfem`). wasm-ld therefore only
# pulls the archive members it needs to resolve already-referenced symbols. MFEM's
# element classes (Tetrahedron, H1_TetrahedronElement, IsoparametricTransformation,
# …) define ALL their virtual methods inline in headers, so they have no non-inline
# "key function" and thus no single owning translation unit for the vtable — it is
# emitted as a weak/COMDAT symbol scattered across whichever TUs reference it.
# Archive member selection can then drop the member carrying the surviving vtable
# copy, leaving the WASM indirect-call table slot null. The first virtual dispatch
# (e.g. SetIntPoint / CalcShape / CalcDShape, KoFEM#153/#164/#172) then traps with
# "null function or function signature mismatch" or an OOB access. The engine has
# been working around this with a hand-maintained _kofem_mfem_element_keepalive()
# whitelist that must be grown reactively for every new MFEM method — it does not
# scale and only surfaces after a 20+ minute WASM build.
#
# Fix it here, at the dependency level, so no engine change is needed: partial-link
# every MFEM object into ONE relocatable object and re-archive it as a single-member
# libmfem.a. A single-member archive is pulled in WHOLE the moment the engine
# references any MFEM symbol, so member selection can no longer drop a vtable. The
# vtables are then rooted by MFEM's own in-library construction sites (Mesh builds
# Tetrahedron, H1_FECollection builds H1_TetrahedronElement, …) and survive the
# engine's final -O2/--gc-sections link. This lets the engine eventually delete
# _kofem_mfem_element_keepalive() entirely.
NM="${EMSDK:-/emsdk}/upstream/bin/llvm-nm"
command -v "${NM}" >/dev/null 2>&1 || NM=llvm-nm
COMBINED="${MFEM_WASM_ROOT}/lib/mfem_combined.o"

echo "==> Combining libmfem.a members into a single relocatable object"
emcc -r -Wl,--whole-archive "${LIB}" -Wl,--no-whole-archive -o "${COMBINED}"
emar rcs "${LIB}.new" "${COMBINED}"
mv -f "${LIB}.new" "${LIB}"
rm -f "${COMBINED}"

# Sanity: the repackaged archive must be exactly one member, otherwise the
# force-include guarantee above does not hold.
MEMBERS="$(emar t "${LIB}" | grep -c .)"
if [ "${MEMBERS}" -ne 1 ]; then
    echo "ERROR: expected a single-member libmfem.a after combining, got ${MEMBERS}" >&2
    exit 1
fi

# ── Validation: the element vtables must be present in the packaged archive ───
# These are exactly the classes whose missing vtables caused the runtime traps
# above. If a future MFEM bump or a regression in the combine step drops one, fail
# the DEPENDENCY build here rather than letting it trap at runtime in the app.
# Matched via demangled names (llvm-nm -C) to stay independent of the mangling.
echo "==> Verifying MFEM element vtables survive packaging"
NM_OUT="$("${NM}" -C --defined-only "${LIB}" 2>/dev/null || true)"
MISSING=0
while IFS= read -r want; do
    [ -n "${want}" ] || continue
    if grep -qF "${want}" <<<"${NM_OUT}"; then
        echo "  ok: ${want}"
    else
        echo "  MISSING: ${want}" >&2
        MISSING=1
    fi
done <<'VTABLES'
vtable for mfem::Tetrahedron
vtable for mfem::H1_TetrahedronElement
vtable for mfem::IsoparametricTransformation
VTABLES
if [ "${MISSING}" -ne 0 ]; then
    echo "ERROR: expected MFEM vtable(s) absent from libmfem.a after packaging." >&2
    echo "       The engine would trap on the first virtual dispatch (KoFEM#175)." >&2
    exit 1
fi

rm -rf "${SRC}/mfem" "${SRC}/build-mfem"
echo "  MFEM done."
