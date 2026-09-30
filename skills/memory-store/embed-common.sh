#!/usr/bin/env bash
# embed-common.sh — shared helpers for the lembed embedding write path and its
# error log (SPEC-004, CDT-262). Source only (never execute as a CLI):
#   EMBED_DIR=...; # shellcheck source=embed-common.sh
#   . "$EMBED_DIR/embed-common.sh"
# Sourced by embed-one.sh (per-write embedding) and migrate-md.sh (bulk
# migration). Sets no shell option, so the sourcing script keeps its own.
#
# sqlite-lembed takes a REGISTERED MODEL NAME, not a file path:
#   INSERT INTO temp.lembed_models(name, model)
#     SELECT '<name>', lembed_model_from_file('<gguf path>');
#   SELECT lembed('<name>', '<text>');
# temp.lembed_models is per connection. Every sqlite3 invocation is its own
# connection, so the registration statement MUST sit in the same sqlite3 call
# (same batch) as the lembed() call that uses the name, after the .load lines.
# Calling lembed('<path>', ...) fails with "Unknown model name" (the model is
# not registered), which is why local semantic search never stored a vector.
#
# Functions:
#   EMBED_LEMBED_NAME                  the registered model name ("mini")
#   embed_lembed_register_sql <gguf>   prints the registration statement for <gguf>
#   embed_log_error <memdir> <site> <detail>
#       appends one line  "<UTC ISO-8601> embed <site> <detail>"  to
#       <memdir>/.errors.log. Fail-open: it never returns non-zero, because an
#       embedding failure MUST NOT break the caller's write. /memory stats and
#       /doctor count the lines whose second field is "embed".
#   embed_error_count <memdir>         prints the number of embed lines in <memdir>/.errors.log
#   embed_error_last <memdir>          prints the timestamp of the last embed line (or nothing)

EMBED_LEMBED_NAME="mini"

embed_lembed_register_sql() {
  local gguf="${1-}" esc
  esc=$(printf '%s' "$gguf" | sed "s/'/''/g") || return 1
  printf "INSERT INTO temp.lembed_models(name, model) SELECT '%s', lembed_model_from_file('%s');\n" \
    "$EMBED_LEMBED_NAME" "$esc"
}

embed_log_error() {
  local memdir="${1-}" site="${2-}" detail ts
  [ -n "$memdir" ] || return 0
  # One line, bounded: newlines/tabs become spaces, the detail is cut at 300 chars.
  detail=$(printf '%s' "${3-}" | tr '\n\r\t' '   ' | cut -c1-300) || detail="(unreadable detail)"
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || ts="unknown-time"
  printf '%s embed %s %s\n' "$ts" "$site" "$detail" >> "$memdir/.errors.log" 2>/dev/null || true
  return 0
}

# embed_error_count <memdir> — prints how many embed lines <memdir>/.errors.log
# holds (lines whose second field is "embed"); 0 when the log is absent. The one
# reader for /memory stats and /doctor, so the line format lives in this file only.
embed_error_count() {
  local log="${1-}/.errors.log"
  if [ -z "${1-}" ] || [ ! -f "$log" ]; then
    echo 0
    return 0
  fi
  awk '$2 == "embed" { n++ } END { print n + 0 }' "$log" 2>/dev/null || echo 0
}

# embed_error_last <memdir> — prints the timestamp (first field) of the last
# embed line in <memdir>/.errors.log; prints nothing when there is none.
embed_error_last() {
  local log="${1-}/.errors.log"
  if [ -z "${1-}" ] || [ ! -f "$log" ]; then
    return 0
  fi
  awk '$2 == "embed" { t = $1 } END { print t }' "$log" 2>/dev/null || true
}
