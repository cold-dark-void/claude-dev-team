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

# ---------------------------------------------------------------------------
# Helper: download a tar.gz and extract a single file
# ---------------------------------------------------------------------------
download_and_extract() {
  local url="$1"
  local dest_file="$2"   # full path where the extracted file should land
  local artifact_name="$3"  # human-readable name for error messages

  if [ -f "$dest_file" ]; then
    echo "  [skip] $artifact_name already present: $dest_file"
    return 0
  fi

  echo "  Downloading $artifact_name from $url ..."
  local tmpdir
  tmpdir=$(mktemp -d)
  if curl -fSL "$url" 2>/dev/null | tar -xz -C "$tmpdir" 2>/dev/null; then
    # Move the extracted file (single .so/.dylib) to the target location
    local extracted
    extracted=$(find "$tmpdir" -maxdepth 2 -type f | head -1)
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
  fi
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# Helper: download a single file (no archive)
# ---------------------------------------------------------------------------
download_file() {
  local url="$1"
  local dest_file="$2"
  local artifact_name="$3"

  if [ -f "$dest_file" ]; then
    echo "  [skip] $artifact_name already present: $dest_file"
    return 0
  fi

  echo "  Downloading $artifact_name from $url ..."
  if curl -fSL -o "$dest_file" "$url" 2>/dev/null; then
    echo "  [ok]   $artifact_name -> $dest_file"
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
  fi
}

# ---------------------------------------------------------------------------
# Download sqlite-vec
# ---------------------------------------------------------------------------
VEC_URL="https://github.com/asg017/sqlite-vec/releases/download/v${VEC_VERSION}/sqlite-vec-${VEC_VERSION}-loadable-${PLATFORM}.tar.gz"
VEC_DEST="$EXT_DIR/vec0.$EXT"

echo ""
echo "=== sqlite-vec ==="
download_and_extract "$VEC_URL" "$VEC_DEST" "sqlite-vec"

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
  download_and_extract "$LEMBED_URL" "$LEMBED_DEST" "sqlite-lembed"
fi

# ---------------------------------------------------------------------------
# Download GGUF embedding model
# ---------------------------------------------------------------------------
echo ""
echo "=== all-MiniLM-L6-v2 GGUF model ==="
MODEL_URL="https://huggingface.co/asg017/sqlite-lembed-model-examples/resolve/main/all-MiniLM-L6-v2/${MODEL_FILENAME}"
MODEL_DEST_PATH="$MODEL_DIR/$MODEL_DEST"
download_file "$MODEL_URL" "$MODEL_DEST_PATH" "all-MiniLM-L6-v2"

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
  # Store URL in config for recall/search to use
  if [ -f "$MEMDB" ]; then
    sqlite3 "$MEMDB" "INSERT OR REPLACE INTO config(key, value, updated_at) VALUES ('embedding_url', '$EMBEDDING_URL', strftime('%Y-%m-%dT%H:%M:%SZ','now'));"
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
  sqlite3 "$MEMDB" \
    "UPDATE config SET value='$MODE',  updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE key='embedding_mode';" \
    "UPDATE config SET value='$MODEL', updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE key='embedding_model';" \
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
  VEC_VER=$(sqlite3 :memory: ".load $VEC_LIB" "SELECT vec_version();" 2>/dev/null) || true
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
  sqlite3 "$MEMDB" ".load $VEC_LIB" \
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
