#!/usr/bin/env bash
# publish.sh — build and push the kofem-wasm-deps image to GHCR.
#
# Usage:
#   ./publish.sh              # auto-detects branch/tag, derives Docker tags
#   ./publish.sh --no-push    # build only, skip push (useful for local smoke-test)
#
# Prerequisites:
#   docker buildx, gh (GitHub CLI) or a GHCR_TOKEN env var, git
#
# Authentication:
#   The script logs in to ghcr.io.  Provide credentials via one of:
#     1. GHCR_TOKEN env var   (a classic PAT or fine-grained token with
#                              "write:packages" scope)
#     2. `gh auth token`      (if you're already logged into the GitHub CLI)

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────

REMOTE_URL=$(git remote get-url origin 2>/dev/null || true)

# Convert SSH or HTTPS remote to owner/repo form, then lower-case it.
# git@github.com:Owner/Repo.git  →  owner/repo
# https://github.com/Owner/Repo  →  owner/repo
GH_REPO=$(echo "$REMOTE_URL" \
  | sed -E 's|.*github\.com[:/]||; s|\.git$||' \
  | tr '[:upper:]' '[:lower:]')

if [[ -z "$GH_REPO" ]]; then
  echo "ERROR: Could not derive GitHub repo from remote '$REMOTE_URL'." >&2
  echo "       Set GHCR_IMAGE explicitly, e.g.:" >&2
  echo "       GHCR_IMAGE=ghcr.io/yourname/yourrepo ./publish.sh" >&2
  exit 1
fi

IMAGE="${GHCR_IMAGE:-ghcr.io/${GH_REPO}}"
CACHE_REF="${IMAGE}:buildcache"
PLATFORM="linux/amd64"
PUSH=true

# ── Flags ─────────────────────────────────────────────────────────────────────

for arg in "$@"; do
  case "$arg" in
    --no-push) PUSH=false ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

# ── Derive tags (mirrors docker/metadata-action logic) ────────────────────────

GIT_TAG=$(git tag --points-at HEAD 2>/dev/null | grep -E '^v[0-9]' | head -1 || true)
GIT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || true)

TAGS=()

if [[ -n "$GIT_TAG" ]]; then
  # semver tag: v1.2.3 → :1.2.3, :1.2, :latest
  VERSION="${GIT_TAG#v}"                     # strip leading v
  MINOR="${VERSION%.*}"                      # e.g. 1.2
  TAGS+=("${IMAGE}:${VERSION}")
  TAGS+=("${IMAGE}:${MINOR}")
  TAGS+=("${IMAGE}:latest")
elif [[ -n "$GIT_BRANCH" ]]; then
  # branch push: sanitise (/ → -)
  SAFE_BRANCH=$(echo "$GIT_BRANCH" | tr '/' '-')
  TAGS+=("${IMAGE}:${SAFE_BRANCH}")
else
  echo "ERROR: HEAD is detached and has no semver tag. Cannot derive a tag." >&2
  exit 1
fi

# ── Login ─────────────────────────────────────────────────────────────────────

if $PUSH; then
  GHCR_USER=$(echo "$GH_REPO" | cut -d/ -f1)

  if [[ -n "${GHCR_TOKEN:-}" ]]; then
    TOKEN="$GHCR_TOKEN"
  elif command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
    TOKEN=$(gh auth token)
  else
    echo "ERROR: No GHCR credentials found." >&2
    echo "  Set GHCR_TOKEN, or log in with 'gh auth login'." >&2
    exit 1
  fi

  echo "$TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin
fi

# ── Build ─────────────────────────────────────────────────────────────────────

TAG_ARGS=()
for t in "${TAGS[@]}"; do
  TAG_ARGS+=(-t "$t")
done

echo ""
echo "Image   : $IMAGE"
echo "Tags    : ${TAGS[*]}"
echo "Platform: $PLATFORM"
echo "Push    : $PUSH"
echo ""

BUILDX_ARGS=(
  buildx build
  --platform "$PLATFORM"
  "${TAG_ARGS[@]}"
  --cache-from "type=registry,ref=${CACHE_REF}"
)

if $PUSH; then
  BUILDX_ARGS+=(
    --cache-to "type=registry,ref=${CACHE_REF},mode=max"
    --push
  )
else
  BUILDX_ARGS+=(--load)
fi

BUILDX_ARGS+=(.)

docker "${BUILDX_ARGS[@]}"

echo ""
echo "Done."
if $PUSH; then
  echo "Pushed tags:"
  for t in "${TAGS[@]}"; do echo "  $t"; done
fi
