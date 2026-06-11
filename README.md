# kofem-wasm-deps

Builds **OCCT**, **Netgen**, and **MFEM** as WebAssembly static libraries inside
an Emscripten image and publishes it to GHCR. Downstream repos pull the image
instead of spending hours compiling C++.

The image is `emscripten/emsdk` + a patched `wasm-opt` + the three libraries
under `/opt/kofem-deps`, with these env vars baked in:

| Variable           | Path                     |
|--------------------|--------------------------|
| `OCCT_WASM_ROOT`   | `/opt/kofem-deps/occt`   |
| `NETGEN_WASM_ROOT` | `/opt/kofem-deps/netgen` |
| `MFEM_WASM_ROOT`   | `/opt/kofem-deps/mfem`   |

## Layout

```
.
├── Dockerfile           # bakes the three libs into the emsdk image
├── build/
│   ├── build-occt.sh    # OCCT 7.8.0        — slowest, first layer
│   ├── build-netgen.sh  # Netgen v6.2.2401
│   └── build-mfem.sh    # MFEM v4.7         — most likely to change, last layer
└── publish.sh           # build + push to GHCR (always run locally)
```

Versions are `ARG`s in the `Dockerfile` and the single source of truth.
Layer order (OCCT → Netgen → MFEM) means bumping MFEM never invalidates the
OCCT layer.

## Building and publishing

The compile takes 2-4 hours on first run (OCCT dominates), so this repo is
**always built and published locally** — there is no CI here.

```bash
./publish.sh
```

This builds for `linux/amd64` **and** `linux/arm64`, pushes a multi-arch
manifest to GHCR, and keeps a registry-backed layer cache (`:buildcache`) so
subsequent publishes only recompile what changed. The arm64 variant exists so
Apple Silicon machines run the Emscripten toolchain natively instead of under
Rosetta/QEMU emulation — the compiled WASM output is identical.

Override the platform set via `PLATFORM` (but never push a single-arch tag
over a multi-arch one — that breaks consumers on the other architecture):

```bash
PLATFORM=linux/amd64,linux/arm64 ./publish.sh
```

On an Apple Silicon Mac the arm64 half builds natively while the amd64 half
runs under Rosetta, so the first publish after a Dockerfile change is slow.
Prefer publishing from an x86_64 Linux box when the amd64 layers need a full
rebuild.

Tag derivation matches what GitHub Actions' metadata-action would produce:

| Git state              | Tags pushed                         |
|------------------------|-------------------------------------|
| branch `main`          | `:main`                             |
| tag `v1.2.3`           | `:1.2.3`, `:1.2`, `:latest`         |

```bash
git tag v1.0.0
./publish.sh          # pushes :1.0.0, :1.0, :latest
```

To build without pushing (local smoke-test):

```bash
./publish.sh --no-push
```

### Build cache

Two BuildKit cache mounts persist across rebuilds on your machine:

- **`kofem-sources`** — downloaded source tarballs. Tarballs are never
  re-downloaded even when a layer is invalidated.
- **`kofem-ccache-<arch>`** — ccache object files, one cache per target
  architecture. If a layer is re-run (e.g. you changed an MFEM flag which also
  forces Netgen to re-run), ccache skips recompiling any object files that
  didn't actually change.

Both caches are managed by BuildKit (inside Docker Desktop) and persist between
`./publish.sh` runs.

## Consuming the image in another repo

Reference the image directly with the `docker://` prefix — no action file needed:

```yaml
steps:
  - uses: actions/checkout@v4
  - uses: docker://ghcr.io/michaelkofler/dependencies-kofem:latest
  - run: bash scripts/build-wasm.sh
```

The env vars (`OCCT_WASM_ROOT` etc.) are inherited automatically by every
`run:` step that follows.

## Why MFEM and not NGSolve

Netgen (mesher) and NGSolve (FE solver) are the same project. For a WASM target
MFEM is the better fit: it's a lean, dependency-light C++ library designed to be
embedded, and it links cleanly with MPI / OpenMP / LAPACK / METIS / SuiteSparse
all disabled. NGSolve is large and Python-centric (heavy pybind11, expects
LAPACK) with no maintained Emscripten build path.

If you want to evaluate an alternative solver, it's isolated in
`build/build-mfem.sh`. Add a sibling script, point the Dockerfile's last build
stage at it via a build arg, and OCCT + Netgen stay untouched.
