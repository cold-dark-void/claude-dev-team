#!/usr/bin/env bash
# Smoke harness for install.sh hardening (CDT-95). Re-runnable, self-contained:
# each check runs install.sh against a throwaway HOME/XDG_CONFIG_HOME and asserts
# the acceptance criteria. Exits non-zero on the first failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL="$SCRIPT_DIR/install.sh"
pass=0
fail=0

ok()   { printf 'PASS: %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf 'FAIL: %s\n' "$1"; fail=$((fail+1)); }

# Snapshot a tree as "path\tsha" lines (empty string if the tree is empty).
snapshot() {
  local root="$1"
  if [ -d "$root" ]; then
    find "$root" \( -type f -o -type l \) 2>/dev/null | sort | while IFS= read -r p; do
      if [ -L "$p" ]; then printf '%s\tSYMLINK->%s\n' "$p" "$(readlink "$p")";
      else printf '%s\t%s\n' "$p" "$(sha256sum "$p" | cut -d" " -f1)"; fi
    done
  fi
}

mk_home() { mktemp -d "${TMPDIR:-/tmp}/cdt95.XXXXXX"; }

# A fake opencode binary so "present" detection passes without a real install.
FAKE_BIN="$(mktemp -d "${TMPDIR:-/tmp}/cdt95bin.XXXXXX")"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/opencode"
chmod +x "$FAKE_BIN/opencode"

# A clean bindir with the coreutils install.sh needs but NO 'opencode' — used to
# exercise the absent-opencode path deterministically regardless of the host.
CLEAN_BIN="$(mktemp -d "${TMPDIR:-/tmp}/cdt95clean.XXXXXX")"
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
out="$(PATH="$FAKE_BIN:$PATH" bash "$INSTALL" --dry-run </dev/null)"; rc=$?
after="$(snapshot "$XDG_CONFIG_HOME/opencode")"
[ "$rc" -eq 0 ] && ok "AC1 dry-run exit 0" || bad "AC1 dry-run exit ($rc)"
[ "$before" = "$after" ] && ok "AC1 dry-run left config tree unchanged" || { bad "AC1 dry-run mutated the tree"; diff <(echo "$before") <(echo "$after") || true; }
grep -q '\[dry-run\]' <<<"$out" && ok "AC1 dry-run printed planned mutations" || bad "AC1 dry-run printed no plan"
# opencode.json must be byte-identical (risk item 1).
grep -q '"ic4"' "$XDG_CONFIG_HOME/opencode/opencode.json" && ok "AC1 opencode.json pins untouched" || bad "AC1 opencode.json was rewritten in dry-run"
rm -rf "$H"

# ---------------------------------------------------------------------------
# AC2: opencode absent (no binary on PATH, no config dir) -> warn, skip, exit 0,
# zero writes.
# ---------------------------------------------------------------------------
H="$(mk_home)"
export HOME="$H" XDG_CONFIG_HOME="$H/.config"
before="$(snapshot "$XDG_CONFIG_HOME")"
set +e
out="$(PATH="$CLEAN_BIN" bash "$INSTALL" </dev/null 2>&1)"; rc=$?
set -e
after="$(snapshot "$XDG_CONFIG_HOME")"
[ "$rc" -eq 0 ] && ok "AC2 absent-opencode exit 0" || bad "AC2 absent-opencode exit ($rc)"
grep -qi 'opencode not detected' <<<"$out" && ok "AC2 printed detection warning" || bad "AC2 no warning printed"
[ "$before" = "$after" ] && ok "AC2 absent-opencode wrote nothing" || bad "AC2 absent-opencode wrote files"
rm -rf "$H"

# AC2b: --dry-run still prints its full plan even when opencode is absent.
H="$(mk_home)"
export HOME="$H" XDG_CONFIG_HOME="$H/.config"
set +e
out="$(PATH="$CLEAN_BIN" bash "$INSTALL" --dry-run </dev/null 2>&1)"; rc=$?
set -e
[ "$rc" -eq 0 ] && grep -q '\[dry-run\]' <<<"$out" && ok "AC2b dry-run prints plan when opencode absent" || bad "AC2b dry-run gave no plan when absent"
rm -rf "$H"

# ---------------------------------------------------------------------------
# AC3: capacity warning fires (both modes) with 100+ agent .md files, counted
# recursively across the whole agents/ tree.
# ---------------------------------------------------------------------------
H="$(mk_home)"
export HOME="$H" XDG_CONFIG_HOME="$H/.config"
mkdir -p "$XDG_CONFIG_HOME/opencode/agents/other"
for i in $(seq 1 105); do : > "$XDG_CONFIG_HOME/opencode/agents/other/a$i.md"; done
out="$(PATH="$FAKE_BIN:$PATH" bash "$INSTALL" --dry-run </dev/null 2>&1)"
grep -q '105 agent files' <<<"$out" && ok "AC3 capacity warning fires in dry-run (recursive count)" || bad "AC3 capacity warning missing/miscounted (dry-run)"
out="$(PATH="$FAKE_BIN:$PATH" bash "$INSTALL" </dev/null 2>&1)"
grep -q '105 agent files' <<<"$out" && ok "AC3 capacity warning fires in normal mode" || bad "AC3 capacity warning missing (normal)"
rm -rf "$H"

# AC3b: below threshold -> no warning.
H="$(mk_home)"
export HOME="$H" XDG_CONFIG_HOME="$H/.config"
mkdir -p "$XDG_CONFIG_HOME/opencode/agents"
: > "$XDG_CONFIG_HOME/opencode/agents/one.md"
out="$(PATH="$FAKE_BIN:$PATH" bash "$INSTALL" --dry-run </dev/null 2>&1)"
grep -q 'agent files under' <<<"$out" && bad "AC3b warning fired below threshold" || ok "AC3b no warning below threshold"
rm -rf "$H"

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
set +e
out="$(PATH="$FAKE_BIN:$PATH" bash "$INSTALL" --dry-run --assign-models </dev/null 2>&1)"; rc=$?
set -e
after="$(snapshot "$XDG_CONFIG_HOME/opencode")"
[ "$rc" -eq 0 ] && ok "AC6 dry-run+assign-models exit 0 (no TTY block)" || bad "AC6 dry-run+assign-models exit ($rc)"
grep -qi 'would prompt for model tiers' <<<"$out" && ok "AC6 printed picker-skip line" || bad "AC6 no picker-skip line"
[ "$before" = "$after" ] && ok "AC6 dry-run+assign-models wrote nothing" || bad "AC6 dry-run+assign-models mutated tree"
rm -rf "$H"

# ---------------------------------------------------------------------------
# AC5: normal install (opencode present) still performs the real writes.
# ---------------------------------------------------------------------------
H="$(mk_home)"
export HOME="$H" XDG_CONFIG_HOME="$H/.config"
mkdir -p "$XDG_CONFIG_HOME/opencode"
out="$(PATH="$FAKE_BIN:$PATH" bash "$INSTALL" </dev/null 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "AC5 normal install exit 0" || bad "AC5 normal install exit ($rc)"
[ -d "$XDG_CONFIG_HOME/opencode/agents/dev-team" ] && [ "$(ls -A "$XDG_CONFIG_HOME/opencode/agents/dev-team")" ] && ok "AC5 agents generated" || bad "AC5 agents not generated"
[ -L "$XDG_CONFIG_HOME/opencode/commands/dev-team" ] && ok "AC5 commands symlink created" || bad "AC5 commands symlink missing"
rm -rf "$H"

rm -rf "$FAKE_BIN" "$CLEAN_BIN"
echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
