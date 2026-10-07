# observability.sh — sourced by doctor.sh (WP 8-B / CDT-300); pure definitions,
# no top-level side effects. CDT-300 R0.3/R0.4/R2.3 + lint-waiver trend +
# test-quarantine scoped-entry model (SPEC-030 ### CDT-502-C4). The embed-error count is NOT here: memory.embed_errors
# (checks/memory.sh) already owns it.

# Effective memory mode (CDT-300: ".md fallback must never be silent again").
check_memory_mode() {
  if [ -f "$MEMDB" ] && have_cmd sqlite3; then
    record "memory.mode" "memory" "PASS" "SQLite mode ($MEMDB)" ""
  elif [ -f "$MEMDB" ]; then
    record "memory.mode" "memory" "WARN" \
      ".md fallback — memory.db exists but sqlite3 is not installed; tiered and semantic reads are unavailable" \
      "install sqlite3 (or re-run /setup team)"
  else
    record "memory.mode" "memory" "WARN" \
      ".md fallback — memory.db absent; agents read and write .claude/memory/<agent>/*.md files with per-file line caps" \
      "/setup team"
  fi
}

# Live vec0 insert+MATCH round-trip on a :memory: database. memory.ext.vec only
# proves the extension LOADS; this proves a vector can actually be stored and
# queried. Never touches $MEMDB (CDT-300 R0.3).
check_memory_embed_roundtrip() {
  if ! have_cmd sqlite3; then
    record "memory.embed_roundtrip" "memory" "SKIP" "sqlite3 absent" ""
    return 0
  fi
  local probe out rc=0
  local SQL='CREATE VIRTUAL TABLE rt_probe USING vec0(embedding float[4]);
INSERT INTO rt_probe(rowid, embedding) VALUES (1, '"'"'[0.1, 0.2, 0.3, 0.4]'"'"');
SELECT rowid FROM rt_probe WHERE embedding MATCH '"'"'[0.1, 0.2, 0.3, 0.4]'"'"' AND k = 1;'
  if have_cmd timeout; then
    probe=$(printf '%s\n' "$SQL" | timeout 10 sqlite3 ':memory:' 2>&1) || rc=$?
  else
    probe=$(printf '%s\n' "$SQL" | sqlite3 ':memory:' 2>&1) || rc=$?
  fi
  if [ "$rc" -eq 0 ] && [ "$probe" = "1" ]; then
    record "memory.embed_roundtrip" "memory" "PASS" \
      "vec0 insert+MATCH round-trip ok on :memory: (synthetic 4-dim vector)" ""
  else
    record "memory.embed_roundtrip" "memory" "WARN" \
      "vec0 round-trip failed on :memory: (rc=$rc): ${probe:-no output}" \
      "install/rebuild the sqlite-vec loadable (skills/memory-store/download-extensions.sh)"
  fi
}

# Transcript size vs the Stop-hook timeout budget (CDT-300 R2.3). Budget model:
# the hook must chew the transcript at >= 1 MB/s (jq + python passes), so
# budget_mb == the hook's configured timeout seconds.
check_transcript_budget() {
  local id="transcript.budget" group="transcript"
  local tval
  tval=$(_transcript_mirror_hook_timeout)
  if [ -z "$tval" ]; then
    record "$id" "$group" "SKIP" "transcript-mirror not opted-in — no hook timeout budget to compare" ""
    return 0
  fi
  local tdir size_max=0 f sz sz_max_file=""
  tdir="${HOME:-}/.claude/projects/$(printf '%s' "$MROOT" | tr '/._' '-')"
  if [ -d "$tdir" ]; then
    for f in "$tdir"/*.jsonl; do
      [ -f "$f" ] || continue
      sz=$(_file_size "$f") || sz=0
      [ -n "$sz" ] || sz=0
      if [ "$sz" -gt "$size_max" ]; then
        size_max=$sz
        sz_max_file=$f
      fi
    done
  fi
  if [ -z "$sz_max_file" ]; then
    record "$id" "$group" "PASS" \
      "no session transcripts for this project (budget: ${tval}s hook timeout)" ""
    return 0
  fi
  local budget size_mb
  budget=$((tval * 1048576))
  size_mb=$((size_max / 1048576))
  if [ "$size_max" -gt "$budget" ]; then
    record "$id" "$group" "WARN" \
      "largest transcript is ${size_mb} MB ($sz_max_file); the mirror hook timeout is ${tval}s — budget ~${tval} MB at >=1 MB/s; the next full index can blow the Stop-hook timeout" \
      "/compact-transcript (or raise the transcript-mirror hook timeout)"
  else
    record "$id" "$group" "PASS" \
      "largest transcript ${size_mb} MB fits the ${tval}s hook timeout budget (~${tval} MB)" ""
  fi
}

# Prints the configured timeout of the transcript-mirror.sh hook registration
# (empty when not opted in). Walks the same settings files as mirror-lag.
_transcript_mirror_hook_timeout() {
  have_cmd python3 || { printf ''; return 0; }
  python3 -c '
import json, os, sys

def find(obj):
    if isinstance(obj, dict):
        for ent in obj.get("hooks", {}).values() if isinstance(obj.get("hooks"), dict) else []:
            if not isinstance(ent, list):
                continue
            for e in ent:
                for h in (e.get("hooks") or []) if isinstance(e, dict) else []:
                    cmd = h.get("command") if isinstance(h, dict) else None
                    if isinstance(cmd, str) and "transcript-mirror.sh" in cmd:
                        t = h.get("timeout")
                        if isinstance(t, int) and t > 0:
                            return t
        return None
    return None

for p in sys.argv[1:]:
    if not p or not os.path.isfile(p):
        continue
    try:
        d = json.load(open(p))
    except Exception:
        continue
    if isinstance(d, dict):
        t = find(d)
        if t:
            print(t)
            raise SystemExit(0)
' \
    "$MROOT/.claude/settings.json" \
    "$MROOT/.claude/settings.local.json" \
    "$WTROOT/.claude/settings.json" \
    "$WTROOT/.claude/settings.local.json" 2>/dev/null || true
}

# File size (GNU/BSD stat).
_file_size() {
  stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1" 2>/dev/null
}

# Skill-lint waiver count (`# lint-ok:` lines) across the shipped plugin tree.
# Shared with do_fix (the baseline writer) — single definition.
_lint_waiver_count() {
  local d total=0 out
  for d in skills commands agents githooks hooks tools; do
    [ -d "$PLUGIN_ROOT/$d" ] || continue
    out=$(grep -rn -F '# lint-ok:' "$PLUGIN_ROOT/$d" 2>/dev/null | wc -l | tr -d ' ')
    case "$out" in
      ''|*[!0-9]*) out=0 ;;
    esac
    total=$((total + out))
  done
  printf '%s' "$total"
}

# Skill-lint waiver count + trend (CDT-300). Trend compares against the
# baseline recorded by `doctor --fix --only lint.waivers`.
check_lint_waivers() {
  local id="lint.waivers" group="lint"
  local n baseline base_n base_date
  n=$(_lint_waiver_count)
  baseline="$MROOT/.claude/metrics/lint-waiver-baseline.txt"
  if [ ! -f "$baseline" ]; then
    record "$id" "$group" "PASS" \
      "$n skill-lint waivers in the plugin tree; no baseline recorded yet (trend unknown) — run doctor --fix --only lint.waivers to record one" \
      ""
    return 0
  fi
  base_n=$(awk '{print $1}' "$baseline" 2>/dev/null | head -1)
  base_date=$(awk '{print $2}' "$baseline" 2>/dev/null | head -1)
  case "$base_n" in
    ''|*[!0-9]*)
      record "$id" "$group" "WARN" \
        "baseline file unparseable ($baseline) — re-record it" \
        "doctor --fix --only lint.waivers"
      return 0
      ;;
  esac
  if [ "$n" -gt "$base_n" ]; then
    record "$id" "$group" "WARN" \
      "$n skill-lint waivers — grew by $((n - base_n)) since the $base_date baseline ($base_n)" \
      "review the new # lint-ok: waivers, then doctor --fix --only lint.waivers"
  else
    record "$id" "$group" "PASS" \
      "$n skill-lint waivers (not grown since the $base_date baseline of $base_n)" ""
  fi
}

# Test-quarantine scoped-entry model (SPEC-030 ### CDT-502-C4, R11-R13):
# entries are `<path> <scope> <reason>`; macos-scoped entries with a reason are
# sanctioned (they quarantine only the --platform macos lane); all-scoped,
# reason-less, or unknown-scope entries quarantine every lane and are policed.
check_test_quarantine() {
  local id="test.quarantine" group="tests"
  local qf="$PLUGIN_ROOT/tools/test-quarantine.txt" stats total ok bad
  if [ ! -f "$qf" ]; then
    record "$id" "$group" "SKIP" "no tools/test-quarantine.txt (quarantine mechanism absent)" ""
    return 0
  fi
  # One pass: total = data lines, ok = macos+reason entries, bad = offending NRs.
  stats=$(awk '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
      total++
      reason = ""
      for (i = 3; i <= NF; i++) reason = reason (i > 3 ? " " : "") $i
      if ($2 == "macos" && reason != "") ok++
      else bad = bad (bad != "" ? "," : "") NR
    }
    END { printf "%d %d %s\n", total + 0, ok + 0, bad }
  ' "$qf" 2>/dev/null)
  total=$(printf '%s' "$stats" | cut -d' ' -f1)
  ok=$(printf '%s' "$stats" | cut -d' ' -f2)
  bad=$(printf '%s' "$stats" | cut -d' ' -f3)
  case "$total" in ''|*[!0-9]*) total=0 ;; esac
  case "$ok" in ''|*[!0-9]*) ok=0 ;; esac
  if [ -n "$bad" ]; then
    record "$id" "$group" "WARN" \
      "tools/test-quarantine.txt line(s) $bad violate the scoped-entry model (all-scoped, reason-less, or unknown scope) — an all-scoped entry quarantines every lane" \
      "re-scope or repair line(s) $bad in tools/test-quarantine.txt to '<path> macos <reason>' (SPEC-030 R11-R13)"
  elif [ "$total" -eq 0 ]; then
    record "$id" "$group" "PASS" "0 quarantined suites (tools/test-quarantine.txt)" ""
  else
    record "$id" "$group" "PASS" \
      "$total macos-scoped quarantined suites (all-scoped: 0)" ""
  fi
}
