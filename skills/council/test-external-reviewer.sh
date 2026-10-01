#!/usr/bin/env bash
# F-25 / W3-17: normalize keeps a finding with no file:line; severity, confidence,
# staged diff, sandbox flag, flavor load, sha256 fallback, CLI timeout.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EXT="$ROOT/skills/council/external-reviewer.sh"
fail=0

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ext-rev.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

ok() { echo "OK: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

printf '%s\n' '- missing unit tests in the parser' > "$TMP/nofile.txt"
printf '%s\n' '- skills/council/engine.sh:10 real defect here' > "$TMP/withfile.txt"

out="$(bash "$EXT" normalize --tool mock --raw-file "$TMP/nofile.txt" --output-shape 'finding[]')"
if printf '%s' "$out" | jq -e '(.findings|length)==1 and .findings[0].file=="unknown" and .findings[0].line==0 and (.findings[0].description|test("missing unit tests")) and .findings[0].severity!="nitpick" and .findings[0].confidence==81' >/dev/null; then
  ok "finding with no file:line is kept, not a nit, confidence 81"
else
  bad "no file:line finding: $out"
fi

out="$(bash "$EXT" normalize --tool mock --raw-file "$TMP/withfile.txt" --output-shape 'finding[]')"
if printf '%s' "$out" | jq -e '.findings[0].file=="skills/council/engine.sh" and .findings[0].line==10' >/dev/null; then
  ok "file:line finding still extracts"
else
  bad "file:line extract: $out"
fi

# sha256sum missing must not abort.
BIN="$TMP/bin"
mkdir -p "$BIN"
BASH_BIN="$(command -v bash)"
for c in jq head awk grep cat sed dirname; do
  src="$(command -v "$c" 2>/dev/null || true)"
  [ -n "$src" ] && ln -s "$src" "$BIN/$c"
done
out="$(PATH="$BIN" "$BASH_BIN" "$EXT" normalize --tool mock --raw-file "$TMP/nofile.txt" --output-shape 'finding[]' 2>"$TMP/sha.err")"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | jq -e '.evidence_bundle.tool_use_id|test("unavailable")' >/dev/null; then
  ok "missing sha256sum falls back and still emits"
else
  bad "sha256 fallback rc=$rc err=$(cat "$TMP/sha.err") out=$out"
fi

# Stubs record argv and stdin. Sleep proves the timeout.
cat > "$BIN/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${STUB_ARGV:?}"
cat > "${STUB_STDIN:?}"
if [ "${STUB_MODE:-}" = sleep ]; then sleep 30; fi
printf '%s\n' '- skills/council/engine.sh:3 warning staged'
EOF
cat > "$BIN/gemini" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${STUB_ARGV:?}"
printf '%s\n' '- ok'
EOF
chmod +x "$BIN/codex" "$BIN/gemini"

export STUB_ARGV="$TMP/argv" STUB_STDIN="$TMP/stdin"
# Real timeout(1) and git stay on PATH after the stubs.
FULLPATH="$BIN:$PATH"

STUB_MODE= \
PATH="$FULLPATH" bash "$EXT" run --tool codex --output-shape 'finding[]' --claim 'staged claim' \
  >"$TMP/run-codex.json" 2>"$TMP/run-codex.err"
if grep -q -- '--uncommitted' "$STUB_ARGV"; then
  bad "codex argv still has --uncommitted: $(cat "$STUB_ARGV")"
elif grep -q 'review -' "$STUB_ARGV" && grep -q 'STAGED DIFF' "$STUB_STDIN" && grep -q 'EXTERNAL investigator' "$STUB_STDIN"; then
  ok "codex review is staged diff and loads external.md"
else
  bad "codex argv=$(cat "$STUB_ARGV") stdin-head=$(head -c 200 "$STUB_STDIN")"
fi

PATH="$FULLPATH" bash "$EXT" run --tool gemini --claim 'g claim' >"$TMP/run-gem.json" 2>"$TMP/run-gem.err"
if grep -q -- '-s' "$STUB_ARGV" && grep -q -- '-p' "$STUB_ARGV"; then
  ok "gemini argv contains the sandbox flag"
else
  bad "gemini argv=$(cat "$STUB_ARGV")"
fi

start=$(date +%s)
STUB_MODE=sleep PATH="$FULLPATH" COUNCIL_EXT_TIMEOUT=1 bash "$EXT" run --tool codex --output-shape 'finding[]' --claim 'slow' \
  >"$TMP/slow.json" 2>"$TMP/slow.err"
rc=$?
end=$(date +%s)
elapsed=$((end - start))
if [ "$rc" -eq 0 ] && [ "$elapsed" -lt 15 ] && printf '%s' "$(cat "$TMP/slow.json")" | jq -e '.status=="error"' >/dev/null; then
  ok "codex timeout emits error and returns (${elapsed}s)"
else
  bad "timeout rc=$rc elapsed=$elapsed json=$(cat "$TMP/slow.json") err=$(cat "$TMP/slow.err")"
fi

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "FAILURES PRESENT"; fi
exit "$fail"
