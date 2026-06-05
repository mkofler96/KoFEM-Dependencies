# syntax=docker/dockerfile:1
#
# KoFEM WASM dependency builder image.
#
# Produces a ready-to-use Emscripten build environment with OCCT, Netgen and
# MFEM already compiled to WASM static libraries. Downstream projects link
# their own engine against these via the OCCT_WASM_ROOT / NETGEN_WASM_ROOT /
# MFEM_WASM_ROOT environment variables, which are baked in below.
#
# First build: ~2-4 hours (OCCT dominates). Once published, consumers just
# `docker pull` — no library compilation on their side.
#
# Build:
#   docker build --platform linux/amd64 -t kofem-wasm-deps:dev .
#
# Override a version:
#   docker build --build-arg MFEM_TAG=v4.6 -t kofem-wasm-deps:mfem46 .

ARG EMSDK_VERSION=3.1.64
FROM emscripten/emsdk:${EMSDK_VERSION}

# ── Base build tools ─────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        cmake ninja-build curl git python3 xz-utils ca-certificates ccache \
    && rm -rf /var/lib/apt/lists/*

# ── Replace bundled wasm-opt ──────────────────────────────────────────────────
# emsdk's bundled wasm-opt doesn't support --enable-bulk-memory-opt, which emcc
# uses when linking with newer toolchains. Swap in a binaryen release build.
ARG BINARYEN_VERSION=124
RUN curl -fsSL "https://github.com/WebAssembly/binaryen/releases/download/version_${BINARYEN_VERSION}/binaryen-version_${BINARYEN_VERSION}-x86_64-linux.tar.gz" \
      | tar -xzf - --strip-components=1 -C /emsdk/upstream \
        "binaryen-version_${BINARYEN_VERSION}/bin/wasm-opt"

# ── Install locations for the prebuilt libraries ─────────────────────────────
ENV DEPS_PREFIX=/opt/kofem-deps
ENV OCCT_WASM_ROOT=${DEPS_PREFIX}/occt \
    NETGEN_WASM_ROOT=${DEPS_PREFIX}/netgen \
    MFEM_WASM_ROOT=${DEPS_PREFIX}/mfem

WORKDIR /build

# ── OCCT (longest build; placed first so version bumps below don't rebuild it)─
ARG OCCT_VERSION=7.8.0
COPY build/build-occt.sh /build/scripts/build-occt.sh
RUN --mount=type=cache,id=kofem-sources,target=/build/sources \
    --mount=type=cache,id=kofem-ccache,target=/root/.ccache \
    CMAKE_C_COMPILER_LAUNCHER=ccache CMAKE_CXX_COMPILER_LAUNCHER=ccache \
    OCCT_VERSION=${OCCT_VERSION} bash scripts/build-occt.sh

# ── Netgen ────────────────────────────────────────────────────────────────────
ARG NETGEN_TAG=v6.2.2401
COPY build/build-netgen.sh /build/scripts/build-netgen.sh
RUN --mount=type=cache,id=kofem-sources,target=/build/sources \
    --mount=type=cache,id=kofem-ccache,target=/root/.ccache \
    CMAKE_C_COMPILER_LAUNCHER=ccache CMAKE_CXX_COMPILER_LAUNCHER=ccache \
    NETGEN_TAG=${NETGEN_TAG} bash scripts/build-netgen.sh

# ── MFEM ──────────────────────────────────────────────────────────────────────
ARG MFEM_TAG=v4.7
COPY build/build-mfem.sh /build/scripts/build-mfem.sh
RUN --mount=type=cache,id=kofem-sources,target=/build/sources \
    --mount=type=cache,id=kofem-ccache,target=/root/.ccache \
    CMAKE_C_COMPILER_LAUNCHER=ccache CMAKE_CXX_COMPILER_LAUNCHER=ccache \
    MFEM_TAG=${MFEM_TAG} bash scripts/build-mfem.sh

# Record what we built (handy for `docker inspect` / debugging consumers).
RUN { \
      echo "OCCT_VERSION=${OCCT_VERSION}"; \
      echo "NETGEN_TAG=${NETGEN_TAG}"; \
      echo "MFEM_TAG=${MFEM_TAG}"; \
      echo "BINARYEN_VERSION=${BINARYEN_VERSION}"; \
    } > "${DEPS_PREFIX}/versions.txt"

# Consumers mount their source here and run their own build-wasm.sh.
WORKDIR /workspace

LABEL org.opencontainers.image.title="kofem-wasm-deps" \
      org.opencontainers.image.description="Emscripten builder with OCCT, Netgen and MFEM prebuilt as WASM static libs." \
      org.opencontainers.image.source="https://github.com/OWNER/kofem-wasm-deps"
