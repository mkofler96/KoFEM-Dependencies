#!/usr/bin/env bash
# build/build-netgen.sh — compile Netgen (mesher) to WASM static libs.
set -euo pipefail

: "${NETGEN_TAG:?must be set}"
: "${NETGEN_WASM_ROOT:?must be set}"
: "${OCCT_WASM_ROOT:?must be set}"
: "${EMSDK:?must be set (provided by emscripten/emsdk base image)}"

SRC=/build/sources
JOBS="$(nproc)"
mkdir -p "${SRC}"

# Netgen and MFEM don't add -fPIC themselves; the SIDE_MODULE linker rejects
# non-PIC objects, so everything below is built with -fPIC.
echo "==> Building Emscripten zlib port (pic)..."
embuilder --pic build zlib
EM_SYSROOT="${EMSDK}/upstream/emscripten/cache/sysroot"
ZLIB_LIB="${EM_SYSROOT}/lib/wasm32-emscripten/pic/libz.a"
ZLIB_INC="${EM_SYSROOT}/include"

echo "==> Building Netgen ${NETGEN_TAG} — ~10-20 min"
[ -f "${SRC}/netgen.tar.gz" ] || \
curl -fsSL "https://github.com/NGSolve/netgen/archive/refs/tags/${NETGEN_TAG}.tar.gz" \
    -o "${SRC}/netgen.tar.gz"
mkdir -p "${SRC}/netgen"
tar -xzf "${SRC}/netgen.tar.gz" -C "${SRC}/netgen" --strip-components=1

# OCCT 7.8 removed TopoDS_Shape::HashCode(int); replace all call sites in
# Netgen's OCC layer with std::hash<TopoDS_Shape>{} before building.
# Uses Python to handle nested parens (e.g. std::numeric_limits<...>::max()).
python3 - "${SRC}/netgen/libsrc/occ/" << 'PYEOF'
import re, sys, os

def replace_hashcode(content):
    out, i = [], 0
    pat = re.compile(r'([A-Za-z_]\w*)\.HashCode\(')
    while True:
        m = pat.search(content, i)
        if not m:
            out.append(content[i:])
            break
        out.append(content[i:m.start()])
        depth, j = 1, m.end()
        while j < len(content) and depth:
            if   content[j] == '(': depth += 1
            elif content[j] == ')': depth -= 1
            j += 1
        out.append(f'std::hash<TopoDS_Shape>{{}}({m.group(1)})')
        i = j
    return ''.join(out)

root = sys.argv[1]
for dirpath, _, files in os.walk(root):
    for fname in files:
        if not fname.endswith(('.cpp', '.cxx', '.hpp', '.hxx', '.ixx', '.jxx')):
            continue
        path = os.path.join(dirpath, fname)
        original = open(path).read()
        patched  = replace_hashcode(original)
        if patched != original:
            print(f'  patched {fname}')
            open(path, 'w').write(patched)
PYEOF

mkdir -p "${SRC}/build-netgen"
cd "${SRC}/build-netgen"

emcmake cmake "${SRC}/netgen" \
    -G Ninja \
    -DCMAKE_INSTALL_PREFIX="${NETGEN_WASM_ROOT}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_FLAGS="-fPIC" \
    -DCMAKE_C_FLAGS="-fPIC" \
    -DUSE_SUPERBUILD=OFF \
    -DUSE_GUI=OFF \
    -DUSE_PYTHON=OFF \
    -DUSE_MPI=OFF \
    -DUSE_OCC=ON \
    -DOpenCascade_DIR="${OCCT_WASM_ROOT}/lib/cmake/opencascade" \
    -DUSE_NUMA=OFF \
    -DUSE_NATIVE_ARCH=OFF \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTS=OFF \
    -DENABLE_UNIT_TESTS=OFF \
    -DZLIB_LIBRARY="${ZLIB_LIB}" \
    -DZLIB_INCLUDE_DIR="${ZLIB_INC}"

ninja -j"${JOBS}" install

if [ ! -f "${NETGEN_WASM_ROOT}/lib/libnglib.a" ]; then
    echo "ERROR: Netgen build failed — libnglib.a not found" >&2
    exit 1
fi

rm -rf "${SRC}/netgen" "${SRC}/build-netgen"
echo "  Netgen done."
