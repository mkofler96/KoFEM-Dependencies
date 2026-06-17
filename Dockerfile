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
# Published for linux/amd64 AND linux/arm64 so Apple Silicon hosts run the
# toolchain natively instead of under Rosetta/QEMU emulation (KoFEM#176).
# The compiled output is WASM either way — only the host toolchain differs.
#
# Build (host architecture):
#   docker build -t kofem-wasm-deps:dev .
#
# Override a version:
#   docker build --build-arg MFEM_TAG=v4.6 -t kofem-wasm-deps:mfem46 .

# emsdk has no arm64 image for 3.1.64: arm64 starts at 3.1.67 as a separate
# "-arm64" tag, and single multi-arch tags only exist from 4.0.16 onwards.
# 3.1.67 is the closest version available for both architectures, selected
# per-platform via the stage aliases below. Drop the alias indirection once
# EMSDK_VERSION is bumped to >= 4.0.16.
ARG EMSDK_VERSION=3.1.67
ARG TARGETARCH
FROM emscripten/emsdk:${EMSDK_VERSION} AS emsdk-amd64
FROM emscripten/emsdk:${EMSDK_VERSION}-arm64 AS emsdk-arm64

FROM emsdk-${TARGETARCH}

# ── Base build tools ─────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        cmake ninja-build curl git python3 xz-utils ca-certificates ccache \
    && rm -rf /var/lib/apt/lists/*

# ── Replace bundled wasm-opt ──────────────────────────────────────────────────
# emsdk's bundled wasm-opt doesn't support --enable-bulk-memory-opt, which emcc
# uses when linking with newer toolchains. Swap in a binaryen release build.
ARG BINARYEN_VERSION=124
ARG TARGETARCH
RUN case "${TARGETARCH}" in \
        amd64) BINARYEN_ARCH=x86_64 ;; \
        arm64) BINARYEN_ARCH=aarch64 ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/WebAssembly/binaryen/releases/download/version_${BINARYEN_VERSION}/binaryen-version_${BINARYEN_VERSION}-${BINARYEN_ARCH}-linux.tar.gz" \
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
    --mount=type=cache,id=kofem-ccache-${TARGETARCH},target=/root/.ccache \
    CMAKE_C_COMPILER_LAUNCHER=ccache CMAKE_CXX_COMPILER_LAUNCHER=ccache \
    OCCT_VERSION=${OCCT_VERSION} bash scripts/build-occt.sh

# ── Netgen ────────────────────────────────────────────────────────────────────
ARG NETGEN_TAG=v6.2.2401
COPY build/build-netgen.sh /build/scripts/build-netgen.sh
RUN --mount=type=cache,id=kofem-sources,target=/build/sources \
    --mount=type=cache,id=kofem-ccache-${TARGETARCH},target=/root/.ccache \
    CMAKE_C_COMPILER_LAUNCHER=ccache CMAKE_CXX_COMPILER_LAUNCHER=ccache \
    NETGEN_TAG=${NETGEN_TAG} bash scripts/build-netgen.sh

# ── MFEM ──────────────────────────────────────────────────────────────────────
ARG MFEM_TAG=v4.7
COPY build/build-mfem.sh /build/scripts/build-mfem.sh
RUN --mount=type=cache,id=kofem-sources,target=/build/sources \
    --mount=type=cache,id=kofem-ccache-${TARGETARCH},target=/root/.ccache \
    CMAKE_C_COMPILER_LAUNCHER=ccache CMAKE_CXX_COMPILER_LAUNCHER=ccache \
    MFEM_TAG=${MFEM_TAG} bash scripts/build-mfem.sh

# ── Smoke test ────────────────────────────────────────────────────────────────
# Compile and run a tiny program that links OCCT + Netgen + MFEM together and
# exercises each (including MFEM virtual dispatch, KoFEM#175). Fails the image
# build if the produced libraries don't actually work together, instead of
# letting the breakage surface in the downstream engine build.
COPY test /build/test
RUN bash /build/test/run-smoke.sh

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
      org.opencontainers.image.source="https://github.com/mkofler96/KoFEM-Dependencies"
