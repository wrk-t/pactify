#!/bin/bash
if [ -n "${BASH_VERSION:-}" ]; then
	set -euo pipefail
else
	set -eu
fi

# ── Configuration ───────────────────────────────────────────
GIT_CLIFF_VERSION="2.8.0"
GIT_CLIFF_URL="https://github.com/orhun/git-cliff/releases/download/v${GIT_CLIFF_VERSION}/git-cliff-${GIT_CLIFF_VERSION}-x86_64-unknown-linux-musl.tar.gz"
GIT_CLIFF_DIR="/tmp/git-cliff-local"

# ── Flags ───────────────────────────────────────────────────
DRY_RUN=false
CREATE_TAG=false

# ── Parse arguments ─────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --dry-run|--preview) DRY_RUN=true ;;
    --apply)             ;; # backward-compatible no-op (default)
    --tag)               CREATE_TAG=true ;;
    --help|-h)
      sed -n '3,14p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg"
      echo "Usage: $0 [--dry-run] [--tag]"
      exit 1
      ;;
  esac
done

# ── Helper functions ────────────────────────────────────────
info()  { echo -e "\033[36m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[33m[WARN]\033[0m  $*"; }
dry()   { echo -e "\033[35m[DRY-RUN]\033[0m $*"; }

# Run a command. In dry-run mode, only print it (do NOT execute).
# Use for side-effect commands (fetch, tag, commit, package.json update, file moves).
run() {
  if [ "$DRY_RUN" = true ]; then
    dry "$*"
  else
    info "$*"
    eval "$@"
  fi
}

# ── Sanity checks ───────────────────────────────────────────
cd "$(git rev-parse --show-toplevel)"

if ! command -v jq &>/dev/null; then
  echo "ERROR: 'jq' is required. Install it with: brew install jq (macOS) / apt install jq (Linux)"
  exit 1
fi

if ! git rev-parse --git-dir &>/dev/null; then
  echo "ERROR: Not inside a git repository."
  exit 1
fi

# Prevent SSH passphrase prompts during local git operations
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}"

# ── Ensure git-cliff is available ───────────────────────────
GIT_CLIFF_BIN=""
if command -v git-cliff &>/dev/null; then
  GIT_CLIFF_BIN="git-cliff"
  ok "git-cliff found on system PATH: $(command -v git-cliff)"
else
  info "git-cliff not found on PATH. Downloading v${GIT_CLIFF_VERSION}..."
  mkdir -p "$GIT_CLIFF_DIR"
  curl -sL "$GIT_CLIFF_URL" -o /tmp/git-cliff-local.tar.gz
  tar xf /tmp/git-cliff-local.tar.gz --strip 1 -C "$GIT_CLIFF_DIR"
  rm -f /tmp/git-cliff-local.tar.gz
  chmod +x "${GIT_CLIFF_DIR}/git-cliff"
  GIT_CLIFF_BIN="${GIT_CLIFF_DIR}/git-cliff"
  ok "git-cliff downloaded to ${GIT_CLIFF_BIN}"
fi

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║     LOCAL RELEASE SIMULATION                 ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ── Step 1: Show repository state ──────────────────────────
info "Repository: $(basename "$(pwd)")"
info "Branch:     $(git branch --show-current)"
info "Last tag:   $(git describe --tags --abbrev=0 2>/dev/null || echo '(none)')"
echo ""

# ── Step 2: Fetch tags (silent, non-blocking) ──────────────
if [ -f "$(git rev-parse --git-dir)/shallow" ]; then
  run "git fetch --unshallow --tags 2>/dev/null || git fetch --tags 2>/dev/null || true"
else
  run "git fetch --tags 2>/dev/null || true"
fi

# ── Step 3: Show commits since last tag ─────────────────────
last_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
if [ -n "$last_tag" ]; then
  commit_count=$(git log "${last_tag}..HEAD" --oneline 2>/dev/null | wc -l)
  info "Commits since ${last_tag}: ${commit_count}"
  echo ""
  git log "${last_tag}..HEAD" --oneline --no-decorate 2>/dev/null | head -20 || true
  echo ""
else
  info "No previous tag found. git-cliff will process all reachable commits."
  echo ""
fi

# ── Step 4: Determine next version ─────────────────────────
info "Determining next version from conventional commits..."
NEXT_VERSION=$("${GIT_CLIFF_BIN}" --unreleased --bump --context 2>/dev/null | jq -r '.[0].version' 2>/dev/null || echo "")
NEXT_VERSION="${NEXT_VERSION##v}"

if [ -z "$NEXT_VERSION" ]; then
  warn "Could not determine next version. Is there anything new to release?"
  exit 1
fi
ok "Next version: ${NEXT_VERSION}"

CURRENT_VERSION=$(jq -r '.version' package.json)
info "Current version in package.json: ${CURRENT_VERSION}"

# Extract task ID from branch name (e.g. feature/foo_CCD-1234 → CCD-1234)
BRANCH_NAME=$(git branch --show-current 2>/dev/null || echo "")
TASK_ID=$(echo "${BRANCH_NAME}" | grep -oP 'CCD-\d+' | head -1 || echo "")
if [ -n "$TASK_ID" ]; then
  info "Task ID from branch: ${TASK_ID}"
fi
echo ""

# ── Step 5: ALWAYS generate changelog (unreleased only) ────
# Uses --unreleased to avoid pulling in old v1.x.x tags.
TEMP_FILE=$(mktemp /tmp/local-changelog-XXXXXX.md)
trap 'rm -f /tmp/local-changelog-*.md' EXIT

info "Generating changelog (unreleased commits only)..."
"${GIT_CLIFF_BIN}" --unreleased -o "$TEMP_FILE" 2>/dev/null || true

if [ ! -s "$TEMP_FILE" ]; then
  warn "git-cliff produced no output. No new conventional commits to release."
  exit 0
fi

# Strip the "## [unreleased]" header (first 2 lines) from git-cliff output
tail -n +3 "$TEMP_FILE" > "${TEMP_FILE}.stripped"

# Check if there's actual content (not just blank lines)
if ! grep -q '[a-zA-Z0-9]' "${TEMP_FILE}.stripped" 2>/dev/null; then
  rm -f "$TEMP_FILE" "${TEMP_FILE}.stripped"
  warn "No new conventional commits to release."
  exit 0
fi

# Build temp file: version heading + new content, then prepend existing CHANGELOG.md
{
  echo "# ${NEXT_VERSION}"
  echo ""
  if [ -n "$TASK_ID" ]; then
    echo "[${TASK_ID}](https://jira.smartpath.ir/browse/${TASK_ID})"
    echo ""
  fi
  cat "${TEMP_FILE}.stripped"
  echo ""
  if [ -f CHANGELOG.md ] && [ -s CHANGELOG.md ]; then
    cat CHANGELOG.md
  fi
} > "${TEMP_FILE}.combined"

mv "${TEMP_FILE}.combined" "$TEMP_FILE"
rm -f "${TEMP_FILE}.stripped"

CHANGELOG_LINES=$(wc -l < "$TEMP_FILE")
ok "Changelog generated ($CHANGELOG_LINES lines)."
echo ""

# Show preview
echo "────── Preview ─────────────────────────────────"
head -30 "$TEMP_FILE" || true
echo "────────────────────────────────────────────────"
echo ""

# ── Step 6: Apply changes (only in apply mode) ─────────────
if [ "$DRY_RUN" = false ]; then
  # 6a. Move temp file to CHANGELOG.md (preserving accumulated history)
  info "Writing CHANGELOG.md..."
  mv "$TEMP_FILE" CHANGELOG.md
  # Reset trap so we don't delete the file we just moved
  trap - EXIT

  # 6b. Update package.json and package-lock.json
  info "Updating package.json version: ${CURRENT_VERSION} → ${NEXT_VERSION}"
  jq --arg v "${NEXT_VERSION}" '.version=$v' package.json > package.json.tmp && mv package.json.tmp package.json
  jq --arg v "${NEXT_VERSION}" '.version = $v | .packages[""].version = $v' package-lock.json > package-lock.json.tmp && mv package-lock.json.tmp package-lock.json

  # 6c. Create git tag (optional)
  if [ "$CREATE_TAG" = true ]; then
    TAG="v${NEXT_VERSION}"
    if git rev-parse "$TAG" &>/dev/null; then
      warn "Tag ${TAG} already exists. Skipping."
    else
      info "Creating git tag: ${TAG}"
      git tag -a "${TAG}" -m "Release ${TAG}"
      ok "Tag ${TAG} created locally."
    fi
  fi

  echo ""
else
  # Dry-run — delete temp file (trap handles this, but be explicit)
  rm -f "$TEMP_FILE"
fi

# ── Summary ─────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║     SUMMARY                                  ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "  Version:      ${CURRENT_VERSION} → ${NEXT_VERSION}"
echo "  CHANGELOG.md: ${CHANGELOG_LINES:-0} lines"
echo "  Tags created: ${CREATE_TAG}"

if [ "$DRY_RUN" = true ]; then
  echo ""
  echo "  ┌─────────────────────────────────────────────┐"
  echo "  │  DRY RUN — no files were modified.          │"
  echo "  │  Run without --dry-run to apply changes.    │"
  echo "  └─────────────────────────────────────────────┘"
else
  echo ""
  ok "All changes applied locally."
  echo ""
  echo "  To commit and push:"
  echo "    git add CHANGELOG.md package.json package-lock.json"
  echo "    git commit -m 'chore(release): prepare for v${NEXT_VERSION}'"
  echo "    git push origin HEAD"
  if [ "$CREATE_TAG" = true ]; then
    echo "    git push origin v${NEXT_VERSION}"
  fi
fi
echo ""
