#!/usr/bin/env bash
# test-ext-hash.sh — hash-at-load, quoted .load, and curl hardening (WP 3-08).
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SCHEMA="$HERE/schema.sql"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok  $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }

for f in "$HERE/embed-one.sh" "$HERE/migrate-md.sh" "$HERE/download-extensions.sh"; do
  if grep -nE '\.load \$' "$f" >/dev/null; then
    bad "$(basename "$f") still has an unquoted .load path"
  else
    ok "$(basename "$f") quotes every .load path"
  fi
done
if grep -nE '^\.load \$' "$ROOT/skills/memory-recall/SKILL.md" >/dev/null; then
  bad "memory-recall still has an unquoted .load path"
else
  ok "memory-recall quotes every .load path"
fi

grep -q -- '--connect-timeout' "$HERE/embed-one.sh" && grep -q -- '--max-time' "$HERE/embed-one.sh" && grep -q -- '--proto' "$HERE/embed-one.sh" \
  && ok "embed-one curl sets connect-timeout, max-time, and proto" \
  || bad "embed-one curl flags missing"
grep -q -- '--connect-timeout' "$HERE/migrate-md.sh" && grep -q -- '--proto' "$HERE/migrate-md.sh" \
  && ok "migrate-md curl sets connect-timeout and proto" \
  || bad "migrate-md curl flags missing"
grep -q -- '--proto-redir' "$HERE/download-extensions.sh" && grep -q -- '--max-time 120' "$HERE/download-extensions.sh" \
  && grep -qF '.partial.' "$HERE/download-extensions.sh" \
  && grep -qF 'vec0.$EXT' "$HERE/download-extensions.sh" \
  && ok "download-extensions uses https proto, a partial file, and requires vec0 for lembed" \
  || bad "download-extensions hardening missing"
grep -qF 'trap '"'"'rm -f -- "$CURL_CONFIG"'"'"'' "$HERE/embed-one.sh" \
  && ok "embed-one removes the key file on EXIT" \
  || bad "embed-one key trap missing"

FIX=$(mktemp -d "${TMPDIR:-/tmp}/ext-hash.XXXXXX")
SHIM="$FIX/bin"
mkdir -p "$SHIM" "$FIX/proj/.claude/memory/extensions" "$FIX/proj/.claude/memory/models"
REAL_SQLITE=$(command -v sqlite3)
cat > "$SHIM/sqlite3" <<EOF
#!/usr/bin/env bash
in=\$(cat)
if printf '%s\n' "\$in" | grep -q '^\\.load'; then
  printf '%s\n' "\$in" >> "$FIX/shim.log"
  exit 0
fi
if [ -n "\$in" ]; then printf '%s\n' "\$in" | "$REAL_SQLITE" "\$@"; else "$REAL_SQLITE" "\$@"; fi
EOF
cat > "$SHIM/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$FIX/curl.log"
exit 1
EOF
chmod +x "$SHIM/sqlite3" "$SHIM/curl"
sqlite3 "$FIX/proj/.claude/memory/memory.db" < "$SCHEMA" >/dev/null
sqlite3 "$FIX/proj/.claude/memory/memory.db" \
  "UPDATE config SET value='lembed' WHERE key='embedding_mode'; UPDATE config SET value='384' WHERE key='embedding_dimensions';"
printf 'original-vec' > "$FIX/proj/.claude/memory/extensions/vec0.so"
printf 'original-lembed' > "$FIX/proj/.claude/memory/extensions/lembed0.so"
printf 'original-model' > "$FIX/proj/.claude/memory/models/all-MiniLM-L6-v2.gguf"
sha256sum "$FIX/proj/.claude/memory/extensions/vec0.so" | awk '{print $1}' > "$FIX/proj/.claude/memory/extensions/vec0.so.sha256"
printf 'tampered-vec' > "$FIX/proj/.claude/memory/extensions/vec0.so"
: > "$FIX/shim.log"
env -u EMBEDDING_MODEL -u EMBEDDING_API_KEY PATH="$SHIM:$PATH" \
  bash "$HERE/embed-one.sh" "$FIX/proj/.claude/memory/memory.db" 1 "hello memory" >/dev/null 2>&1 || true
if grep -qF 'hash mismatch' "$FIX/proj/.claude/memory/.errors.log" && [ ! -s "$FIX/shim.log" ]; then
  ok "tampered vec0 is refused before .load"
else
  bad "tamper log=$(cat "$FIX/proj/.claude/memory/.errors.log" 2>/dev/null) shim=$(cat "$FIX/shim.log" 2>/dev/null)"
fi

rm -f "$FIX/proj/.claude/memory/extensions/vec0.so.sha256" "$FIX/proj/.claude/memory/.errors.log"
: > "$FIX/shim.log"
env -u EMBEDDING_MODEL -u EMBEDDING_API_KEY PATH="$SHIM:$PATH" \
  bash "$HERE/embed-one.sh" "$FIX/proj/.claude/memory/memory.db" 1 "hello memory" >/dev/null 2>&1 || true
if grep -q '^\.load ' "$FIX/shim.log"; then
  ok "missing sidecar still allows .load"
else
  bad "missing sidecar did not reach sqlite: $(cat "$FIX/shim.log" 2>/dev/null) err=$(cat "$FIX/proj/.claude/memory/.errors.log" 2>/dev/null)"
fi

sqlite3 "$FIX/proj/.claude/memory/memory.db" \
  "UPDATE config SET value='remote' WHERE key='embedding_mode'; INSERT OR REPLACE INTO config(key, value) VALUES ('embedding_model', 'none'); INSERT OR REPLACE INTO config(key, value) VALUES ('embedding_url', 'http://127.0.0.1:1/embeddings');"
: > "$FIX/curl.log"
rm -f "$FIX/proj/.claude/memory/.errors.log"
env -u EMBEDDING_MODEL -u EMBEDDING_API_KEY PATH="$SHIM:$PATH" \
  bash "$HERE/embed-one.sh" "$FIX/proj/.claude/memory/memory.db" 1 "hello memory" >/dev/null 2>&1 || true
if [ ! -s "$FIX/curl.log" ] && grep -qF 'placeholder' "$FIX/proj/.claude/memory/.errors.log"; then
  ok "embed-one skips a placeholder remote model"
else
  bad "placeholder model curl=$(cat "$FIX/curl.log" 2>/dev/null) err=$(cat "$FIX/proj/.claude/memory/.errors.log" 2>/dev/null)"
fi

KEYDIR=$(mktemp -d "${TMPDIR:-/tmp}/ext-key.XXXXXX")
sqlite3 "$FIX/proj/.claude/memory/memory.db" "UPDATE config SET value='stub-model' WHERE key='embedding_model';"
TMPDIR="$KEYDIR" EMBEDDING_API_KEY="super-secret" PATH="$SHIM:$PATH" \
  bash "$HERE/embed-one.sh" "$FIX/proj/.claude/memory/memory.db" 1 "hello memory" >/dev/null 2>&1 || true
left=$(find "$KEYDIR" -type f | wc -l | tr -d ' ')
[ "$left" = "0" ] && ok "embed-one key temp is gone after exit" || bad "key temp left=$left"

rm -rf "$FIX" "$KEYDIR"

if grep -nE '^[^#]*trap .*RETURN' "$HERE/download-extensions.sh" >/dev/null; then
  bad "download-extensions still uses a RETURN trap"
else
  ok "download-extensions cleans temps on EXIT, not RETURN"
fi

DL=$(mktemp -d "${TMPDIR:-/tmp}/dl-ext.XXXXXX")
mkdir -p "$DL/bin" "$DL/proj/.claude/memory"
cat > "$DL/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then out="$a"; fi
  prev="$a"
done
if [ -z "$out" ] || [ ! -d "$(dirname -- "$out")" ]; then
  echo "curl: dest dir missing: $out" >&2
  exit 22
fi
printf 'not-a-real-archive' > "$out"
exit 0
EOF
chmod +x "$DL/bin/curl"
set +e
PATH="$DL/bin:$PATH" bash "$HERE/download-extensions.sh" "$DL/proj" >"$DL/out" 2>"$DL/err"
DL_RC=$?
set -e
if [ "$DL_RC" -eq 0 ] && grep -q 'SHA-256 mismatch' "$DL/err" && ! find "$DL/proj" -name '.dl.*' -o -name '.partial.*' | grep -q .; then
  ok "failed download verifies the temp file, then leaves no partial"
else
  bad "download temp rc=$DL_RC err=$(head -n 20 "$DL/err")"
fi
rm -rf "$DL"

echo
echo "=== results: pass=$PASS fail=$FAIL ==="
[ "$FAIL" -eq 0 ]
