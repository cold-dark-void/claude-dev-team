#!/usr/bin/env bash
set -euo pipefail

# Usage: download-extensions.sh <MROOT>
# Where MROOT is the project root (resolved via git-common-dir)
#
# Downloads sqlite-vec, sqlite-lembed, and the all-MiniLM-L6-v2 GGUF model.
# Resolves embedding mode (remote/lembed/fallback) and stores it in the SQLite config table.

MROOT="${1:?Usage: download-extensions.sh <project-root>}"
MEMDB="$MROOT/.claude/memory/memory.db"
EXT_DIR="$MROOT/.claude/memory/extensions"
MODEL_DIR="$MROOT/.claude/memory/models"

mkdir -p "$EXT_DIR" "$MODEL_DIR"

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
[ "$ARCH" = "arm64" ] && ARCH="aarch64"

case "${OS}-${ARCH}" in
  linux-x86_64)   PLATFORM="linux-x86_64"  ; EXT="so"    ;;
  linux-aarch64)  PLATFORM="linux-aarch64" ; EXT="so"    ;;
  darwin-x86_64)  PLATFORM="macos-x86_64"  ; EXT="dylib" ;;
  darwin-aarch64) PLATFORM="macos-aarch64" ; EXT="dylib" ;;
  *)
    echo "ERROR: Platform ${OS}/${ARCH} is not supported."
    echo "Windows users: run Claude Code inside WSL2 (treated as Linux)."
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Version pins (update these when bumping)
# ---------------------------------------------------------------------------
VEC_VERSION="0.1.6"
LEMBED_VERSION="0.0.1-alpha.8"
MODEL_FILENAME="all-MiniLM-L6-v2.e4ce9877.q8_0.gguf"
MODEL_DEST="all-MiniLM-L6-v2.gguf"
# Pin the model to an immutable commit instead of the floating `main` branch.
MODEL_REF="7a7bac37782986fe1d4f213de771a8a3d9170b35"

# ---------------------------------------------------------------------------
# Pinned SHA-256 of each downloaded artifact (fail-closed integrity check).
# These hash the artifact AS DOWNLOADED — for extensions that is the .tar.gz
# tarball (verified BEFORE extraction); for the model it is the .gguf file.
# Native code is `.load`ed from these, so an unverified/mismatched artifact
# MUST never be extracted or loaded.
#
# To regenerate after a version/ref bump: curl the asset and sha256sum it,
# e.g.  curl -fSL "$URL" | sha256sum   (model: download to a file, then sha256sum).
# Note: sqlite-lembed v0.0.1-alpha.8 publishes no linux-aarch64 build, so that
# (artifact,platform) combo is intentionally absent and skipped upstream.
# ---------------------------------------------------------------------------
expected_sha256() {
  # $1 = artifact (vec0|lembed0|model), $2 = platform (ignored for model)
  case "$1:$2" in
    vec0:linux-x86_64)    echo "438e0df29f3f8db3525b3aa0dcc0a199869c0bcec9d7abc5b51850469caf867f" ;;
    vec0:linux-aarch64)   echo "d6e4ba12c5c0186eaab42fb4449b311008d86ffd943e6377d7d88018cffab3aa" ;;
    vec0:macos-x86_64)    echo "35d014e5f7bcac52645a97f1f1ca34fdb51dcd61d81ac6e6ba1c712393fbf8fd" ;;
    vec0:macos-aarch64)   echo "142e195b654092632fecfadbad2825f3140026257a70842778637597f6b8c827" ;;
    lembed0:linux-x86_64) echo "934bea893d4e112fb2aa8e3bfac2fa216d0e67a1b4f143c79ed6528408406f0a" ;;
    lembed0:macos-x86_64) echo "8e0669d772aca64e4ad5fc18ecbdb4afe95976a7a6fa0ca8d12f294eab72eb02" ;;
    lembed0:macos-aarch64) echo "1ba6a2b5cc06e9f664bfdc01310ae0de3f3f9112015b694c9e035b2e840f0b87" ;;
    model:*)              echo "71f1d177171468fb5f186c07019e303015aea17af275a67767760bba7be8d2e6" ;;
    *)                    echo "" ;;  # no pinned hash → caller must fail closed
  esac
}

# ---------------------------------------------------------------------------
# Integrity verification (fail-closed)
# ---------------------------------------------------------------------------
# Print the SHA-256 hex of a file, cross-platform. If neither sha256sum nor
# `shasum -a 256` exists we cannot verify native code → return non-zero so the
# caller aborts (never proceed to extract/.load unverified artifacts).
sha256_of() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    echo "ERROR: no sha256 tool found (need sha256sum or shasum) — cannot verify integrity." >&2
    return 1
  fi
}

# Verify <file> matches <expected_hex> (case-insensitive). On a missing tool,
# missing/empty expected hash, or mismatch: print expected-vs-actual to stderr
# and return non-zero so the caller fails closed.
verify_sha256() {
  local file="$1" expected="$2" label="$3" actual
  if [ -z "$expected" ]; then
    echo "ERROR: no pinned SHA-256 for $label — refusing to use unverified artifact." >&2
    return 1
  fi
  if ! actual=$(sha256_of "$file"); then
    echo "ERROR: cannot verify $label (no sha256 tool available)." >&2
    return 1
  fi
  # lowercase both sides for a case-insensitive compare
  if [ "$(printf '%s' "$actual" | tr 'A-F' 'a-f')" != "$(printf '%s' "$expected" | tr 'A-F' 'a-f')" ]; then
    echo "ERROR: SHA-256 mismatch for $label — refusing to use this artifact." >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Helper: download a tar.gz and extract a single file
# ---------------------------------------------------------------------------
download_and_extract() {
  local url="$1"
  local dest_file="$2"   # full path where the extracted file should land
  local artifact_name="$3"  # human-readable name for error messages
  local expected_hash="$4"  # pinned SHA-256 of the .tar.gz (verified before extract)

  if [ -f "$dest_file" ]; then
    echo "  [skip] $artifact_name already present: $dest_file"
    return 0
  fi

  echo "  Downloading $artifact_name from $url ..."
  local tmpdir tarball
  tmpdir=$(mktemp -d)
  tarball="$tmpdir/archive.tar.gz"
  # Download to a file first so we can verify the tarball BEFORE extraction.
  # Native code is loaded from the result, so we never pipe straight into tar.
  if curl -fSL -o "$tarball" "$url" 2>/dev/null; then
    if ! verify_sha256 "$tarball" "$expected_hash" "$artifact_name tarball"; then
      echo "Fallback mode (keyword search only) will be used until this is resolved." >&2
      rm -rf "$tmpdir"
      return 1
    fi
    if tar -xz -C "$tmpdir" -f "$tarball" 2>/dev/null; then
      # Move the extracted file (single .so/.dylib) to the target location
      local extracted
      extracted=$(find "$tmpdir" -maxdepth 2 -type f ! -name 'archive.tar.gz' | head -1)
      if [ -n "$extracted" ]; then
        mv "$extracted" "$dest_file"
        echo "  [ok]   $artifact_name -> $dest_file"
      else
        echo "ERROR: Failed to extract $artifact_name from $url" >&2
        echo "Fallback mode (keyword search only) will be used until this is resolved." >&2
        echo "" >&2
        echo "To install manually:" >&2
        echo "  1. Download the archive from $url" >&2
        echo "  2. Extract the .${EXT} file" >&2
        echo "  3. Place it at $dest_file" >&2
        echo "  4. Re-run /init-team" >&2
        rm -rf "$tmpdir"
        return 1
      fi
    else
      echo "ERROR: Failed to extract $artifact_name from $url" >&2
      echo "Fallback mode (keyword search only) will be used until this is resolved." >&2
      rm -rf "$tmpdir"
      return 1
    fi
  else
    echo "" >&2
    echo "ERROR: Failed to download $artifact_name from $url" >&2
    echo "Fallback mode (keyword search only) will be used until this is resolved." >&2
    echo "" >&2
    echo "To install manually:" >&2
    local base_file
    base_file=$(basename "$dest_file")
    echo "  1. Download $(basename "$url") from $url" >&2
    echo "  2. Extract $base_file from the archive" >&2
    echo "  3. Place it at $dest_file" >&2
    echo "  4. Re-run /init-team" >&2
    rm -rf "$tmpdir"
    return 1
  fi
  rm -rf "$tmpdir"
  return 0
}

# ---------------------------------------------------------------------------
# Helper: download a single file (no archive)
# ---------------------------------------------------------------------------
download_file() {
  local url="$1"
  local dest_file="$2"
  local artifact_name="$3"
  local expected_hash="$4"  # pinned SHA-256 of the downloaded file (verified before use)

  if [ -f "$dest_file" ]; then
    echo "  [skip] $artifact_name already present: $dest_file"
    return 0
  fi

  echo "  Downloading $artifact_name from $url ..."
  if curl -fSL -o "$dest_file" "$url" 2>/dev/null; then
    if ! verify_sha256 "$dest_file" "$expected_hash" "$artifact_name"; then
      rm -f "$dest_file"  # never leave an unverified artifact on disk
      echo "Fallback mode (keyword search only) will be used until this is resolved." >&2
      return 1
    fi
    echo "  [ok]   $artifact_name -> $dest_file"
    return 0
  else
    rm -f "$dest_file"  # remove partial download
    echo "" >&2
    echo "ERROR: Failed to download $artifact_name from $url" >&2
    echo "Fallback mode (keyword search only) will be used until this is resolved." >&2
    echo "" >&2
    echo "To install manually:" >&2
    local base_file
    base_file=$(basename "$dest_file")
    echo "  1. Download $base_file from $url" >&2
    echo "  2. Place it at $dest_file" >&2
    echo "  3. Re-run /init-team" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Download sqlite-vec
# ---------------------------------------------------------------------------
VEC_URL="https://github.com/asg017/sqlite-vec/releases/download/v${VEC_VERSION}/sqlite-vec-${VEC_VERSION}-loadable-${PLATFORM}.tar.gz"
VEC_DEST="$EXT_DIR/vec0.$EXT"

echo ""
echo "=== sqlite-vec ==="
# Download failures (network/hash) must not abort under set -e — fall through to
# embedding_mode=fallback resolution below.
download_and_extract "$VEC_URL" "$VEC_DEST" "sqlite-vec" "$(expected_sha256 vec0 "$PLATFORM")" || true

# ---------------------------------------------------------------------------
# Download sqlite-lembed
# ---------------------------------------------------------------------------
echo ""
echo "=== sqlite-lembed ==="

# sqlite-lembed v0.0.1-alpha.8 does not publish a linux-aarch64 build.
if [ "${OS}-${ARCH}" = "linux-aarch64" ]; then
  echo "  WARNING: sqlite-lembed has no linux-aarch64 binary in release v${LEMBED_VERSION}."
  echo "  Skipping lembed download. Embedding mode will fall back to remote or keyword search."
else
  LEMBED_URL="https://github.com/asg017/sqlite-lembed/releases/download/v${LEMBED_VERSION}/sqlite-lembed-${LEMBED_VERSION}-loadable-${PLATFORM}.tar.gz"
  LEMBED_DEST="$EXT_DIR/lembed0.$EXT"
  download_and_extract "$LEMBED_URL" "$LEMBED_DEST" "sqlite-lembed" "$(expected_sha256 lembed0 "$PLATFORM")" || true
fi

# ---------------------------------------------------------------------------
# Download GGUF embedding model
# ---------------------------------------------------------------------------
echo ""
echo "=== all-MiniLM-L6-v2 GGUF model ==="
MODEL_URL="https://huggingface.co/asg017/sqlite-lembed-model-examples/resolve/${MODEL_REF}/all-MiniLM-L6-v2/${MODEL_FILENAME}"
MODEL_DEST_PATH="$MODEL_DIR/$MODEL_DEST"
download_file "$MODEL_URL" "$MODEL_DEST_PATH" "all-MiniLM-L6-v2" "$(expected_sha256 model "$PLATFORM")" || true

# ---------------------------------------------------------------------------
# Migrate legacy ollama mode from v0.12.0/v0.12.1
# ---------------------------------------------------------------------------
if [ -f "$MEMDB" ]; then
  OLD_MODE=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='embedding_mode';" 2>/dev/null)
  if [ "$OLD_MODE" = "ollama" ]; then
    sqlite3 "$MEMDB" "UPDATE config SET value='fallback', updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE key='embedding_mode';"
    echo "  Migrated legacy ollama mode -> fallback"
    echo "  To re-enable: export EMBEDDING_URL=http://localhost:11434/api/embed"
  fi
fi

# ---------------------------------------------------------------------------
# Resolve embedding mode
# ---------------------------------------------------------------------------
if [ -n "${EMBEDDING_URL:-}" ]; then
  MODE="remote"
  MODEL="${EMBEDDING_MODEL:-remote}"
  # Auto-detect dimensions on first use, default to 0 until then
  DIMS="${EMBEDDING_DIMENSIONS:-0}"
  # Store URL in config for recall/search to use (escape SQL single quotes)
  if [ -f "$MEMDB" ]; then
    EMBEDDING_URL_ESC=$(printf '%s' "$EMBEDDING_URL" | sed "s/'/''/g")
    sqlite3 "$MEMDB" "INSERT OR REPLACE INTO config(key, value, updated_at) VALUES ('embedding_url', '$EMBEDDING_URL_ESC', strftime('%Y-%m-%dT%H:%M:%SZ','now'));"
  fi
elif [ -f "$EXT_DIR/lembed0.$EXT" ] && [ -f "$MODEL_DIR/all-MiniLM-L6-v2.gguf" ]; then
  MODE="lembed"
  MODEL="all-MiniLM-L6-v2"
  DIMS=384
else
  MODE="fallback"
  MODEL="none"
  DIMS=0
fi

# ---------------------------------------------------------------------------
# Store config in DB
# ---------------------------------------------------------------------------
if [ -f "$MEMDB" ]; then
  MODEL_ESC=$(printf '%s' "$MODEL" | sed "s/'/''/g")
  sqlite3 "$MEMDB" \
    "UPDATE config SET value='$MODE',  updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE key='embedding_mode';" \
    "UPDATE config SET value='$MODEL_ESC', updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE key='embedding_model';" \
    "UPDATE config SET value='$DIMS',  updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE key='embedding_dimensions';"
  if [ "$MODE" != "remote" ]; then
    sqlite3 "$MEMDB" "DELETE FROM config WHERE key='embedding_url';" 2>/dev/null || true
  fi
else
  echo "  WARNING: $MEMDB not found — skipping config update (run /init-team to create it first)."
fi

# ---------------------------------------------------------------------------
# Verify sqlite-vec loads and create virtual tables
# ---------------------------------------------------------------------------
VEC_VER=""
if [ -f "$EXT_DIR/vec0.$EXT" ]; then
  # Strip the .so/.dylib extension — SQLite .load appends it automatically
  VEC_LIB="$EXT_DIR/vec0"
  VEC_VER=$(sqlite3 :memory: ".load \"$VEC_LIB\"" "SELECT vec_version();" 2>/dev/null) || true
  if [ -n "$VEC_VER" ]; then
    echo ""
    echo "sqlite-vec $VEC_VER loaded successfully"
  else
    echo ""
    echo "WARNING: sqlite-vec failed to load. Extension may be incompatible with this system."
  fi
fi

# Create virtual tables if vec0 loads and the DB exists
if [ -n "$VEC_VER" ] && [ -f "$MEMDB" ]; then
  VEC_LIB="$EXT_DIR/vec0"
  sqlite3 "$MEMDB" ".load \"$VEC_LIB\"" \
    "CREATE VIRTUAL TABLE IF NOT EXISTS vec_memories_384 USING vec0(memory_id INTEGER, embedding FLOAT[384]);" \
    "CREATE VIRTUAL TABLE IF NOT EXISTS vec_memories_768 USING vec0(memory_id INTEGER, embedding FLOAT[768]);" \
    2>/dev/null || echo "WARNING: Failed to create vec virtual tables in $MEMDB"
fi

# ---------------------------------------------------------------------------
# Update .gitignore
# ---------------------------------------------------------------------------
GITIGNORE="$MROOT/.gitignore"
IGNORE_BLOCK=".claude/memory/extensions/
.claude/memory/models/
.claude/memory/memory.db
.claude/memory/memory.db-wal
.claude/memory/memory.db-shm"

if [ -f "$GITIGNORE" ]; then
  # Only append if not already present
  if ! grep -qF ".claude/memory/extensions/" "$GITIGNORE" 2>/dev/null; then
    printf "\n# Memory store binaries and database (auto-generated)\n%s\n" "$IGNORE_BLOCK" >> "$GITIGNORE"
    echo ""
    echo "Updated $GITIGNORE"
  fi
else
  printf "# Memory store binaries and database (auto-generated)\n%s\n" "$IGNORE_BLOCK" > "$GITIGNORE"
  echo ""
  echo "Created $GITIGNORE"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Memory Extensions Setup ==="
echo "Platform:   ${OS}/${ARCH}"
echo "Mode:       ${MODE}"
[ "$MODE" = "remote" ] && echo "URL:        ${EMBEDDING_URL}"
echo "Model:      ${MODEL}"
echo "Dimensions: ${DIMS}"
echo "Extensions: ${EXT_DIR}"
echo "==============================="
