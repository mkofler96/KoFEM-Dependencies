# kofem-wasm-deps

A dedicated builder image that compiles the C++ dependencies for the KoFEM WASM
engine — **OCCT**, **Netgen**, and **MFEM** — to WebAssembly static libraries,
once, so every downstream build (your laptop, CI, Claude Code) just pulls a
ready-to-use image instead of spending hours rebuilding libraries.

The image is `emscripten/emsdk` + a patched `wasm-opt` + the three libraries
preinstalled under `/opt/kofem-deps`, with these environment variables baked in:

| Variable           | Path                       |
|--------------------|----------------------------|
| `OCCT_WASM_ROOT`   | `/opt/kofem-deps/occt`     |
| `NETGEN_WASM_ROOT` | `/opt/kofem-deps/netgen`   |
| `MFEM_WASM_ROOT`   | `/opt/kofem-deps/mfem`     |

Your KoFEM `scripts/build-wasm.sh` already reads those, so it links against the
prebuilt libs with no extra wiring.

## Layout

```
.
├── Dockerfile                 # bakes the three libs into the emsdk image
├── build/
│   ├── build-occt.sh          # OCCT 7.8.0
│   ├── build-netgen.sh        # Netgen v6.2.2401 (+ emscripten zlib pic port)
│   └── build-mfem.sh          # MFEM v4.7  <- swappable "solver" layer
├── action.yml                 # optional: consume via `uses:`
└── .github/workflows/publish.yml
```

Versions are `ARG`s in the `Dockerfile` (single source of truth). They're
ordered OCCT → Netgen → MFEM so bumping MFEM doesn't invalidate the OCCT layer.

## Build locally

```bash
docker build --platform linux/amd64 -t kofem-wasm-deps:dev .
```

First build is ~2-4 hours (OCCT dominates). Override a version without editing
files:

```bash
docker build --build-arg MFEM_TAG=v4.6 -t kofem-wasm-deps:mfem46 .
```

## Publishing

Push a tag and the workflow builds and pushes to GHCR:

```bash
git tag v1.0.0 && git push origin v1.0.0
# -> ghcr.io/OWNER/kofem-wasm-deps:1.0.0, :1.0, :latest
```

A registry-backed build cache (`:buildcache`) means only the first publish is
slow; later ones reuse the OCCT/Netgen/MFEM layers and finish in minutes. Make
the package public (or grant pull access) under the repo's Packages settings if
you want anonymous pulls.

## Consuming the image

### Your dev workflow

```bash
docker pull ghcr.io/OWNER/kofem-wasm-deps:latest
docker run --rm -v "$PWD":/workspace ghcr.io/OWNER/kofem-wasm-deps:latest \
    bash scripts/build-wasm.sh
# output lands in web/src/wasm/pkg/
```

This replaces the old `scripts/docker-build-wasm.sh` in the KoFEM repo: there's
no library cache to manage anymore because the libraries live in the image.

### CI — option A: `container:` (recommended)

Run all your steps *inside* the image. Note `uses:` does not take a Docker
image directly; the job-level `container:` key is the idiomatic way to do this:

```yaml
jobs:
  build-wasm:
    runs-on: ubuntu-latest
    container:
      image: ghcr.io/OWNER/kofem-wasm-deps:latest
      credentials:                       # omit if the package is public
        username: ${{ github.actor }}
        password: ${{ secrets.GITHUB_TOKEN }}
    steps:
      - uses: actions/checkout@v4
      - run: bash scripts/build-wasm.sh
      - uses: actions/upload-artifact@v4
        with:
          name: kofem-wasm
          path: web/src/wasm/pkg/
```

### CI — option B: `uses:` (the literal `uses:` you wanted)

If you specifically want a `uses:` step, this repo's `action.yml` wraps the
image as a Docker container action:

```yaml
steps:
  - uses: actions/checkout@v4
  - uses: OWNER/kofem-wasm-deps@v1
    with:
      run: bash scripts/build-wasm.sh
```

Tradeoff: a container action pins one image tag, so you keep the action release
tag and the image tag in sync. `container:` avoids that coupling, which is why
it's the recommended option.

## Why MFEM and not NGSolve

Netgen (mesher) and NGSolve (FE library) are the same project, so switching to
NGSolve means replacing the solver while staying tied to Netgen. For a WASM
target, MFEM is the better fit: it's a lean, dependency-light C++ library
designed to be embedded, which is why it links cleanly here with MPI / OpenMP /
LAPACK / METIS / SuiteSparse all off. NGSolve is large and Python-frontend
centric (heavy pybind11, expects LAPACK) with no maintained Emscripten build,
so a static WASM build would be a substantial porting effort and a much bigger
binary.

If you still want to evaluate it, the solver is isolated in
`build/build-mfem.sh`. Add a sibling `build/build-ngsolve.sh`, point the
Dockerfile's last build stage at it behind a build arg, and OCCT + Netgen above
stay untouched.
