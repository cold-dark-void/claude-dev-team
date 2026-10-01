#!/usr/bin/env bash
# Smoke harness for install.sh hardening (CDT-95). Re-runnable, self-contained:
# each check runs install.sh against a throwaway HOME/XDG_CONFIG_HOME and asserts
# the acceptance criteria. Exits non-zero on the first failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL="$SCRIPT_DIR/install.sh"
UNINSTALL="$SCRIPT_DIR/uninstall.sh"
pass=0
fail=0
temps=()

ok()   { printf 'PASS: %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf 'FAIL: %s\n' "$1"; fail=$((fail+1)); }

cleanup() {
  local d
  for d in "${temps[@]+"${temps[@]}"}"; do
    rm -rf "$d"
  done
}
trap cleanup EXIT

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    printf 'no-sha\n'
  fi
}

# Run a command with set +e so a non-zero status becomes $rc and a FAIL line,
# instead of aborting the harness under set -e.
capture() {
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e
}

# Snapshot a tree as "path\tsha" lines (empty string if the tree is empty).
snapshot() {
  local root="$1"
  if [ -d "$root" ]; then
    find "$root" \( -type f -o -type l \) 2>/dev/null | sort | while IFS= read -r p; do
      if [ -L "$p" ]; then printf '%s\tSYMLINK->%s\n' "$p" "$(readlink "$p")";
      else printf '%s\t%s\n' "$p" "$(sha256 "$p")"; fi
    done
  fi
}

mk_home() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/cdt95.XXXXXX")
  temps+=("$d")
  printf '%s\n' "$d"
}

# A fake opencode binary so "present" detection passes without a real install.
FAKE_BIN="$(mktemp -d "${TMPDIR:-/tmp}/cdt95bin.XXXXXX")"
temps+=("$FAKE_BIN")
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/opencode"
chmod +x "$FAKE_BIN/opencode"

# A clean bindir with the coreutils install.sh needs but NO 'opencode' — used to
# exercise the absent-opencode path deterministically regardless of the host.
CLEAN_BIN="$(mktemp -d "${TMPDIR:-/tmp}/cdt95clean.XXXXXX")"
temps+=("$CLEAN_BIN")
for t in bash sh find wc tr grep sed jq basename dirname mkdir rm ln cat cut sort readlink sha256sum mktemp chmod ls seq env; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$CLEAN_BIN/$t"
done

# ---------------------------------------------------------------------------
# AC1: --dry-run leaves an existing opencode config tree byte-for-byte unchanged
# and exits 0. Seed a config dir + opencode.json so there is state to mutate.
# ---------------------------------------------------------------------------
H="$(mk_home)"
export HOME="$H" XDG_CONFIG_HOME="$H/.config"
mkdir -p "$XDG_CONFIG_HOME/opencode/agents/dev-team"
printf '{"agent":{"ic4":{"model":"x/y"}}}\n' > "$XDG_CONFIG_HOME/opencode/opencode.json"
before="$(snapshot "$XDG_CONFIG_HOME/opencode")"
capture env PATH="$FAKE_BIN:$PATH" bash "$INSTALL" --dry-run </dev/null
after="$(snapshot "$XDG_CONFIG_HOME/opencode")"
[ "$rc" -eq 0 ] && ok "AC1 dry-run exit 0" || bad "AC1 dry-run exit ($rc)"
[ "$before" = "$after" ] && ok "AC1 dry-run left config tree unchanged" || { bad "AC1 dry-run mutated the tree"; diff <(echo "$before") <(echo "$after") || true; }
grep -q '\[dry-run\]' <<<"$out" && ok "AC1 dry-run printed planned mutations" || bad "AC1 dry-run printed no plan"
# opencode.json must be byte-identical (risk item 1).
grep -q '"ic4"' "$XDG_CONFIG_HOME/opencode/opencode.json" && ok "AC1 opencode.json pins untouched" || bad "AC1 opencode.json was rewritten in dry-run"
# ---------------------------------------------------------------------------
# AC2: opencode absent (no binary on PATH, no config dir) -> warn, skip, exit 0,
# zero writes.
# ---------------------------------------------------------------------------
H="$(mk_home)"
export HOME="$H" XDG_CONFIG_HOME="$H/.config"
before="$(snapshot "$XDG_CONFIG_HOME")"
capture env PATH="$CLEAN_BIN" bash "$INSTALL" </dev/null
after="$(snapshot "$XDG_CONFIG_HOME")"
[ "$rc" -eq 0 ] && ok "AC2 absent-opencode exit 0" || bad "AC2 absent-opencode exit ($rc)"
grep -qi 'opencode not detected' <<<"$out" && ok "AC2 printed detection warning" || bad "AC2 no warning printed"
[ "$before" = "$after" ] && ok "AC2 absent-opencode wrote nothing" || bad "AC2 absent-opencode wrote files"
# AC2b: --dry-run still prints its full plan even when opencode is absent.
H="$(mk_home)"
export HOME="$H" XDG_CONFIG_HOME="$H/.config"
capture env PATH="$CLEAN_BIN" bash "$INSTALL" --dry-run </dev/null
[ "$rc" -eq 0 ] && grep -q '\[dry-run\]' <<<"$out" && ok "AC2b dry-run prints plan when opencode absent" || bad "AC2b dry-run gave no plan when absent"
# ---------------------------------------------------------------------------
# AC3: capacity warning fires (both modes) with 100+ agent .md files, counted
# recursively across the whole agents/ tree.
# ---------------------------------------------------------------------------
H="$(mk_home)"
export HOME="$H" XDG_CONFIG_HOME="$H/.config"
mkdir -p "$XDG_CONFIG_HOME/opencode/agents/other"
for i in $(seq 1 105); do : > "$XDG_CONFIG_HOME/opencode/agents/other/a$i.md"; done
capture env PATH="$FAKE_BIN:$PATH" bash "$INSTALL" --dry-run </dev/null
grep -q '105 agent files' <<<"$out" && ok "AC3 capacity warning fires in dry-run (recursive count)" || bad "AC3 capacity warning missing/miscounted (dry-run)"
capture env PATH="$FAKE_BIN:$PATH" bash "$INSTALL" </dev/null
grep -q '105 agent files' <<<"$out" && ok "AC3 capacity warning fires in normal mode" || bad "AC3 capacity warning missing (normal)"
# AC3b: below threshold -> no warning.
H="$(mk_home)"
export HOME="$H" XDG_CONFIG_HOME="$H/.config"
mkdir -p "$XDG_CONFIG_HOME/opencode/agents"
: > "$XDG_CONFIG_HOME/opencode/agents/one.md"
capture env PATH="$FAKE_BIN:$PATH" bash "$INSTALL" --dry-run </dev/null
grep -q 'agent files under' <<<"$out" && bad "AC3b warning fired below threshold" || ok "AC3b no warning below threshold"

# ---------------------------------------------------------------------------
# AC4: an unknown flag exits 64 and writes nothing. --dryrun is not --dry-run.
# ---------------------------------------------------------------------------
H="$(mk_home)"
export HOME="$H" XDG_CONFIG_HOME="$H/.config"
mkdir -p "$XDG_CONFIG_HOME/opencode/agents/dev-team"
printf 'keep\n' > "$XDG_CONFIG_HOME/opencode/agents/dev-team/marker"
printf '{"agent":{"ic4":{"model":"keep/me"}}}\n' > "$XDG_CONFIG_HOME/opencode/opencode.json"
before="$(snapshot "$XDG_CONFIG_HOME/opencode")"
capture env PATH="$FAKE_BIN:$PATH" bash "$INSTALL" --dryrun </dev/null
after="$(snapshot "$XDG_CONFIG_HOME/opencode")"
[ "$rc" -eq 64 ] && ok "AC4 unknown flag exit 64" || bad "AC4 unknown flag exit ($rc)"
grep -q 'unknown flag' <<<"$out" && ok "AC4 unknown flag message" || bad "AC4 no unknown-flag message"
[ "$before" = "$after" ] && ok "AC4 unknown flag wrote nothing" || bad "AC4 unknown flag mutated the tree"

# ---------------------------------------------------------------------------
# AC6: --dry-run --assign-models must not block on stdin / touch the TTY.
# Run with </dev/null; a read -rp would either hang or consume EOF. Assert it
# returns promptly, exits 0, and prints the picker-skip line.
# ---------------------------------------------------------------------------
H="$(mk_home)"
export HOME="$H" XDG_CONFIG_HOME="$H/.config"
mkdir -p "$XDG_CONFIG_HOME/opencode"
printf '{"provider":{"p":{"models":{"m1":{},"m2":{}}}}}\n' > "$XDG_CONFIG_HOME/opencode/opencode.json"
before="$(snapshot "$XDG_CONFIG_HOME/opencode")"
capture env PATH="$FAKE_BIN:$PATH" bash "$INSTALL" --dry-run --assign-models </dev/null
after="$(snapshot "$XDG_CONFIG_HOME/opencode")"
[ "$rc" -eq 0 ] && ok "AC6 dry-run+assign-models exit 0 (no TTY block)" || bad "AC6 dry-run+assign-models exit ($rc)"
grep -qi 'would prompt for model tiers' <<<"$out" && ok "AC6 printed picker-skip line" || bad "AC6 no picker-skip line"
[ "$before" = "$after" ] && ok "AC6 dry-run+assign-models wrote nothing" || bad "AC6 dry-run+assign-models mutated tree"
# ---------------------------------------------------------------------------
# AC5: normal install (opencode present) still performs the real writes.
# ---------------------------------------------------------------------------
H="$(mk_home)"
export HOME="$H" XDG_CONFIG_HOME="$H/.config"
mkdir -p "$XDG_CONFIG_HOME/opencode"
capture env PATH="$FAKE_BIN:$PATH" bash "$INSTALL" </dev/null
[ "$rc" -eq 0 ] && ok "AC5 normal install exit 0" || bad "AC5 normal install exit ($rc)"
[ -d "$XDG_CONFIG_HOME/opencode/agents/dev-team" ] && [ "$(ls -A "$XDG_CONFIG_HOME/opencode/agents/dev-team")" ] && ok "AC5 agents generated" || bad "AC5 agents not generated"
[ -L "$XDG_CONFIG_HOME/opencode/commands/dev-team" ] && ok "AC5 commands symlink created" || bad "AC5 commands symlink missing"

# AC5b: a default install does not drop an existing pin.
H="$(mk_home)"
export HOME="$H" XDG_CONFIG_HOME="$H/.config"
mkdir -p "$XDG_CONFIG_HOME/opencode"
printf '{"agent":{"ic4":{"model":"keep/me"},"other":{"model":"z/z"}}}\n' > "$XDG_CONFIG_HOME/opencode/opencode.json"
capture env PATH="$FAKE_BIN:$PATH" bash "$INSTALL" </dev/null
grep -q 'keep/me' "$XDG_CONFIG_HOME/opencode/opencode.json" && ok "AC5b default install keeps pins" || bad "AC5b default install dropped pins"
grep -q '"other"' "$XDG_CONFIG_HOME/opencode/opencode.json" && ok "AC5b unrelated pin kept" || bad "AC5b unrelated pin dropped"

# AC7: --reset clears dev-team pins and leaves an unrelated pin.
capture env PATH="$FAKE_BIN:$PATH" bash "$INSTALL" --reset </dev/null
grep -q 'keep/me' "$XDG_CONFIG_HOME/opencode/opencode.json" && bad "AC7 --reset left ic4 pin" || ok "AC7 --reset cleared ic4 pin"
grep -q '"other"' "$XDG_CONFIG_HOME/opencode/opencode.json" && ok "AC7 --reset kept unrelated pin" || bad "AC7 --reset dropped unrelated pin"

# AC8: --assign-models apply from stdin writes the chosen tier pins.
H="$(mk_home)"
export HOME="$H" XDG_CONFIG_HOME="$H/.config"
mkdir -p "$XDG_CONFIG_HOME/opencode"
printf '{"provider":{"p":{"models":{"m1":{},"m2":{}}}},"agent":{"custom":{"model":"z/z"}}}\n' > "$XDG_CONFIG_HOME/opencode/opencode.json"
set +e
out="$(printf '1\n1\n2\n' | env PATH="$FAKE_BIN:$PATH" DEV_TEAM_ASSIGN_MODELS_STDIN=1 bash "$INSTALL" --assign-models 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ] && ok "AC8 assign-models apply exit 0" || bad "AC8 assign-models apply exit ($rc) out=$out"
grep -q '"ic4"' "$XDG_CONFIG_HOME/opencode/opencode.json" && grep -q 'p/m1' "$XDG_CONFIG_HOME/opencode/opencode.json" && ok "AC8 ic4 pinned to first model" || bad "AC8 ic4 pin missing"
grep -q 'p/m2' "$XDG_CONFIG_HOME/opencode/opencode.json" && ok "AC8 opus tier pinned to second model" || bad "AC8 opus pin missing"
grep -q '"custom"' "$XDG_CONFIG_HOME/opencode/opencode.json" && ok "AC8 assign kept unrelated pin" || bad "AC8 assign dropped unrelated pin"

# AC9: frontmatter tools:/model: are stripped; a body line that starts with
# those words is kept. Uses a copy of install.sh so the fixture is not a
# product agent.
FIX="$(mk_home)"
cp "$INSTALL" "$FIX/install.sh"
mkdir -p "$FIX/agents" "$FIX/commands"
printf '%s\n' '---' 'tools: Read, Write' 'model: sonnet' 'effort: medium' '---' '' 'tools: keep-body' 'model: keep-body' > "$FIX/agents/one.md"
H="$(mk_home)"
export HOME="$H" XDG_CONFIG_HOME="$H/.config"
mkdir -p "$XDG_CONFIG_HOME/opencode"
capture env PATH="$FAKE_BIN:$PATH" bash "$FIX/install.sh" </dev/null
gen="$XDG_CONFIG_HOME/opencode/agents/dev-team/one.md"
if [ -f "$gen" ] && awk 'BEGIN{n=0;fm=0} /^---[[:space:]]*$/{n++; if(n==1)fm=1; else if(n==2)fm=0; next} fm && /^(tools|model):/{bad=1} END{exit bad+0}' "$gen"; then
  ok "AC9 frontmatter tools and model stripped"
else
  bad "AC9 frontmatter still has tools or model"
fi
grep -q 'tools: keep-body' "$gen" && grep -q 'model: keep-body' "$gen" && ok "AC9 body tools/model lines kept" || bad "AC9 body lines stripped"
grep -q 'effort: medium' "$gen" && ok "AC9 effort line kept" || bad "AC9 effort line missing"

# AC10: jq failure leaves the previous install intact and prints FAIL, not an abort.
H="$(mk_home)"
export HOME="$H" XDG_CONFIG_HOME="$H/.config"
mkdir -p "$XDG_CONFIG_HOME/opencode/agents/dev-team" "$XDG_CONFIG_HOME/opencode/commands"
printf 'marker\n' > "$XDG_CONFIG_HOME/opencode/agents/dev-team/marker"
ln -s "$SCRIPT_DIR/commands" "$XDG_CONFIG_HOME/opencode/commands/dev-team"
printf '{"agent":{"ic4":{"model":"keep/me"}}}\n' > "$XDG_CONFIG_HOME/opencode/opencode.json"
JQ_BIN="$(mk_home)"
printf '#!/usr/bin/env bash\nexit 1\n' > "$JQ_BIN/jq"
chmod +x "$JQ_BIN/jq"
before="$(snapshot "$XDG_CONFIG_HOME/opencode")"
capture env PATH="$JQ_BIN:$FAKE_BIN:$PATH" bash "$INSTALL" </dev/null
after="$(snapshot "$XDG_CONFIG_HOME/opencode")"
if [ "$rc" -ne 0 ]; then
  ok "AC10 jq failure exit non-zero"
else
  bad "AC10 jq failure exit 0"
fi
[ "$before" = "$after" ] && ok "AC10 jq failure left the install intact" || bad "AC10 jq failure mutated the install"
printf '%s\n' "$out" | grep -q 'Nothing was changed' && ok "AC10 jq failure printed a FAIL-visible message" || bad "AC10 jq failure message missing"

# AC11: JSON with a comment is refused and the tree is unchanged.
H="$(mk_home)"
export HOME="$H" XDG_CONFIG_HOME="$H/.config"
mkdir -p "$XDG_CONFIG_HOME/opencode/agents/dev-team"
printf 'marker\n' > "$XDG_CONFIG_HOME/opencode/agents/dev-team/marker"
printf '{ /* comment */ "agent": {} }\n' > "$XDG_CONFIG_HOME/opencode/opencode.json"
before="$(snapshot "$XDG_CONFIG_HOME/opencode")"
capture env PATH="$FAKE_BIN:$PATH" bash "$INSTALL" </dev/null
after="$(snapshot "$XDG_CONFIG_HOME/opencode")"
[ "$rc" -ne 0 ] && ok "AC11 JSONC exit non-zero" || bad "AC11 JSONC exit ($rc)"
grep -q 'not strict JSON' <<<"$out" && ok "AC11 JSONC message" || bad "AC11 JSONC message missing"
[ "$before" = "$after" ] && ok "AC11 JSONC left the install intact" || bad "AC11 JSONC mutated the install"

# AC12: uninstall removes our symlink, the generated agents dir, and pins.
H="$(mk_home)"
export HOME="$H" XDG_CONFIG_HOME="$H/.config"
mkdir -p "$XDG_CONFIG_HOME/opencode"
printf '{"provider":{"p":{"models":{"m1":{},"m2":{}}}}}\n' > "$XDG_CONFIG_HOME/opencode/opencode.json"
capture env PATH="$FAKE_BIN:$PATH" bash "$INSTALL" </dev/null
printf '{"agent":{"ic4":{"model":"keep/me"},"custom":{"model":"z/z"}}}\n' > "$XDG_CONFIG_HOME/opencode/opencode.json"
capture env PATH="$FAKE_BIN:$PATH" bash "$UNINSTALL" </dev/null
[ "$rc" -eq 0 ] && ok "AC12 uninstall exit 0" || bad "AC12 uninstall exit ($rc)"
[ ! -e "$XDG_CONFIG_HOME/opencode/agents/dev-team" ] && ok "AC12 agents dir removed" || bad "AC12 agents dir remains"
[ ! -e "$XDG_CONFIG_HOME/opencode/commands/dev-team" ] && ok "AC12 commands symlink removed" || bad "AC12 commands symlink remains"
grep -q 'keep/me' "$XDG_CONFIG_HOME/opencode/opencode.json" && bad "AC12 pin remains" || ok "AC12 dev-team pin removed"
grep -q '"custom"' "$XDG_CONFIG_HOME/opencode/opencode.json" && ok "AC12 unrelated pin kept" || bad "AC12 unrelated pin removed"

# AC12b: a foreign commands/dev-team is kept, and the generated agents dir is
# still removed.
H="$(mk_home)"
export HOME="$H" XDG_CONFIG_HOME="$H/.config"
mkdir -p "$XDG_CONFIG_HOME/opencode/commands/dev-team" "$XDG_CONFIG_HOME/opencode/agents/dev-team"
printf 'foreign\n' > "$XDG_CONFIG_HOME/opencode/commands/dev-team/keep"
printf 'agent\n' > "$XDG_CONFIG_HOME/opencode/agents/dev-team/one.md"
capture env PATH="$FAKE_BIN:$PATH" bash "$UNINSTALL" </dev/null
[ "$rc" -ne 0 ] && ok "AC12b foreign commands dir exit non-zero" || bad "AC12b foreign commands dir exit ($rc)"
[ -f "$XDG_CONFIG_HOME/opencode/commands/dev-team/keep" ] && ok "AC12b foreign commands dir kept" || bad "AC12b foreign commands dir removed"
[ ! -e "$XDG_CONFIG_HOME/opencode/agents/dev-team" ] && ok "AC12b agents dir still removed" || bad "AC12b agents dir left after commands refusal"
grep -q 'refusing to remove' <<<"$out" && ok "AC12b refusal message" || bad "AC12b no refusal message"

# AC12c: uninstall unknown flag exits 64 and removes nothing.
H="$(mk_home)"
export HOME="$H" XDG_CONFIG_HOME="$H/.config"
mkdir -p "$XDG_CONFIG_HOME/opencode/agents/dev-team"
printf 'marker\n' > "$XDG_CONFIG_HOME/opencode/agents/dev-team/marker"
before="$(snapshot "$XDG_CONFIG_HOME/opencode")"
capture env PATH="$FAKE_BIN:$PATH" bash "$UNINSTALL" --dryrun </dev/null
after="$(snapshot "$XDG_CONFIG_HOME/opencode")"
[ "$rc" -eq 64 ] && ok "AC12c uninstall unknown flag exit 64" || bad "AC12c uninstall unknown flag exit ($rc)"
[ "$before" = "$after" ] && ok "AC12c uninstall unknown flag wrote nothing" || bad "AC12c uninstall unknown flag mutated the tree"

# AC12d: uninstall with opencode absent warns and exits 0.
H="$(mk_home)"
export HOME="$H" XDG_CONFIG_HOME="$H/.config"
capture env PATH="$CLEAN_BIN" bash "$UNINSTALL" </dev/null
[ "$rc" -eq 0 ] && grep -qi 'opencode not detected' <<<"$out" && ok "AC12d absent opencode skips uninstall" || bad "AC12d absent opencode rc=$rc out=$out"

temps+=("$FAKE_BIN" "$CLEAN_BIN")
echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
