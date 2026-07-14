# SPEC-021 Skill-Bash Lint Gate — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `skills/skill-lint/` — a deterministic, LLM-free linter for fenced ```bash blocks in this plugin's `.md` files (checks C1–C4 per SPEC-021), wired into `/release` as a pre-commit gate, with fixture bite-tests proving every check bites.

**Architecture:** A thin `check-skill-bash.sh` wrapper execs `lint.py` (single-file python3 linter). `lint.py` extracts depth-0 fenced bash blocks CommonMark-correctly (info-string fences inside an open fence are content, which naturally skips template-embedded examples), runs four static checks, applies `# lint-ok:` waivers, and reports `file:line: [Cx] message`. Fixtures + `test.sh` form the bite-test harness. `/release` gains Step 4.8 mirroring the existing 4.5–4.7 gates.

**Tech Stack:** bash + python3 stdlib only (spec MUST: no LLM, no network). No new dependencies.

## Global Constraints

- Exit codes (SPEC-021 MUST): `0` = no unwaived findings, `1` = ≥1 unwaived finding, `64` = usage error.
- Static only (SPEC-021 MUST): never execute scanned code, never modify scanned files.
- Finding format (SPEC-021 MUST): `<file>:<line>: [<check-id>] <message>`, line = source `.md` line number.
- No-arg scan set (SPEC-021 MUST): `commands/**/*.md`, `skills/**/*.md`, `agents/**/*.md`, `AGENTS.md`.
- Env allowlist for C1 (SPEC-021 MUST, minimum): `HOME PATH PWD TMPDIR OLDPWD CLAUDE_PROJECT_DIR` (+ shell specials, which the `[A-Za-z_]\w*` name regex already excludes).
- Waiver (SPEC-021 MUST): `# lint-ok: <check-id>[,<check-id>...]` on the offending line or the line immediately above, same block; waived findings counted in a `N findings, M waived` summary.
- **Authoring rule (project lesson):** any file content containing `!` or `<!--` (lint.py, fixtures) MUST be authored with the Write tool — never via bash heredocs (zsh history-expansion mangles them silently).
- **Bite-test revert rule (project lesson):** revert injected defects via cp-from-backup, NEVER `git checkout` (wipes uncommitted sibling work).
- All work on branch `feat/spec-021-skill-lint`. Commit per task, plain `feat:`/`test:` subjects (no version bump — `/release` handles that later, and its version-sync gate covers CHANGELOG.md/plugin.json/marketplace.json).
- `skills/skill-lint/SKILL.md` needs YAML frontmatter `name:` + `description:` (AGENTS.md convention — required for discovery).

---

### Task 1: Scaffold — wrapper, extractor, harness, clean fixture

**Files:**
- Create: `skills/skill-lint/check-skill-bash.sh`
- Create: `skills/skill-lint/lint.py`
- Create: `skills/skill-lint/SKILL.md`
- Create: `skills/skill-lint/fixtures/clean.md`
- Test: `skills/skill-lint/test.sh`

**Interfaces:**
- Consumes: nothing (root task).
- Produces: `lint.py` CLI — `python3 lint.py [--root DIR] [--json] [FILE...]`; internal seams later tasks extend: `extract_blocks(text) -> [(first_content_line_1based, [lines])]`, `CHECKS` list of `(check_id, fn)` where `fn(block_lines, add)` and `add(block_rel_line0, check_id, message)` records a finding; `test.sh` helpers `run_lint <expected_exit> <args...>` and `expect_finding <check-id> <path-substring>`.

- [ ] **Step 1: Write the failing test harness**

Author `skills/skill-lint/test.sh` with the Write tool:

```bash
#!/usr/bin/env bash
# SPEC-021 bite-test harness. Run: bash skills/skill-lint/test.sh
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LINT="$HERE/check-skill-bash.sh"
FIX="$HERE/fixtures"
PASS=0; FAIL=0
OUT=""; RC=0

run_lint() { # run_lint <expected_exit> <args...>
  local want="$1"; shift
  OUT=$(bash "$LINT" "$@" 2>&1); RC=$?
  if [ "$RC" -eq "$want" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: exit $RC != $want for: $*"; echo "$OUT" | head -5
  fi
}

expect_finding() { # expect_finding <check-id> <path-substring> — greps last OUT
  if echo "$OUT" | grep -q "\[$1\]" && echo "$OUT" | grep -q "$2"; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: no [$1] finding for $2 in:"; echo "$OUT" | head -5
  fi
}

expect_no_finding() { # expect_no_finding <check-id>
  if echo "$OUT" | grep -q "\[$1\]"; then
    FAIL=$((FAIL+1)); echo "FAIL: unexpected [$1] finding:"; echo "$OUT" | grep "\[$1\]" | head -3
  else PASS=$((PASS+1)); fi
}

# T1: clean fixture exits 0; bad flag exits 64
run_lint 0 "$FIX/clean.md"
run_lint 64 --no-such-flag

echo "---"
echo "skill-lint tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Write the clean fixture**

Author `skills/skill-lint/fixtures/clean.md` with the Write tool:

````markdown
# Clean fixture — no findings expected

```bash
MROOT=$(pwd)
for f in $(find "$MROOT" -maxdepth 1 -name '*.json'); do
  echo "$f"
done
if [ "${HOME}" = "/" ]; then echo root; fi
```

```sql
PRAGMA busy_timeout=5000; SELECT 1;
```

Text outside blocks with $UNDEFINED and a glob *.tmp is ignored.
````

(The ```sql block and prose prove non-bash content is skipped; the `find`-based loop is the C3-safe idiom; `${HOME}` is allowlisted for C1.)

- [ ] **Step 3: Run tests to verify they fail**

Run: `bash skills/skill-lint/test.sh`
Expected: FAIL — `check-skill-bash.sh` does not exist yet (exit nonzero, "No such file").

- [ ] **Step 4: Write the wrapper and linter skeleton**

Author `skills/skill-lint/check-skill-bash.sh` with the Write tool:

```bash
#!/usr/bin/env bash
# SPEC-021: deterministic linter for fenced bash blocks in plugin .md files.
# Pure subprocess CLI — no LLM, no network. See skills/skill-lint/SKILL.md.
set -euo pipefail
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lint.py" "$@"
```

Author `skills/skill-lint/lint.py` with the Write tool (skeleton — checks land in Tasks 2–5):

```python
#!/usr/bin/env python3
"""SPEC-021 skill-bash linter: static checks over fenced bash blocks in .md files.

Exit codes: 0 = no unwaived findings, 1 = unwaived findings, 64 = usage error.
Finding format: <file>:<line>: [<check-id>] <message>
"""
import argparse
import json
import os
import re
import subprocess
import sys

ENV_ALLOW = {"HOME", "PATH", "PWD", "TMPDIR", "OLDPWD", "CLAUDE_PROJECT_DIR"}

FENCE_RE = re.compile(r"^\s*(`{3,})(.*)$")


def extract_blocks(text):
    """Yield (first_content_line_1based, [lines]) for top-level ```bash fences.

    CommonMark rules: a closing fence has >= opener's backticks and NO info
    string. While a fence is open, a backticked line WITH an info string is
    content — so ```bash examples nested inside ````markdown templates are
    correctly treated as text, not executable blocks.
    """
    blocks = []
    open_ticks = 0
    is_bash = False
    buf = []
    start = 0
    for i, line in enumerate(text.splitlines(), 1):
        m = FENCE_RE.match(line)
        if open_ticks == 0:
            if m:
                info = m.group(2).strip()
                open_ticks = len(m.group(1))
                is_bash = info.split()[0] == "bash" if info else False
                buf = []
                start = i + 1
        else:
            if m and len(m.group(1)) >= open_ticks and not m.group(2).strip():
                if is_bash:
                    blocks.append((start, buf))
                open_ticks = 0
                is_bash = False
            elif is_bash:
                buf.append(line)
    return blocks


CHECKS = []  # list of (check_id, fn(block_lines, add)) — Tasks 2-5 append here.


def lint_file(path):
    """Return list of finding dicts for one .md file."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError as e:
        print(f"warn: cannot read {path}: {e}", file=sys.stderr)
        return []
    findings = []
    src_lines = text.splitlines()
    for start, block_lines in extract_blocks(text):
        def add(rel_line0, check_id, message, _start=start):
            findings.append({
                "path": path,
                "line": _start + rel_line0,
                "check": check_id,
                "message": message,
                "waived": False,
            })
        for check_id, fn in CHECKS:
            fn(block_lines, lambda rel, msg, _c=check_id, _a=add: _a(rel, _c, msg))
    apply_waivers(findings, src_lines)
    return findings


WAIVER_RE = re.compile(r"#\s*lint-ok:\s*([A-Za-z0-9,\s]+)")


def apply_waivers(findings, src_lines):
    """Waive a finding when its line or the line above carries # lint-ok: <id>."""
    for f in findings:
        for ln in (f["line"], f["line"] - 1):
            if 1 <= ln <= len(src_lines):
                m = WAIVER_RE.search(src_lines[ln - 1])
                if m and f["check"] in [t.strip() for t in m.group(1).split(",")]:
                    f["waived"] = True
                    break


def discover(root):
    """No-arg scan set per SPEC-021: commands/skills/agents globs + AGENTS.md."""
    out = []
    for pat in ("commands", "skills", "agents"):
        base = os.path.join(root, pat)
        for dirpath, _dirs, files in os.walk(base):
            for name in sorted(files):
                if name.endswith(".md"):
                    out.append(os.path.join(dirpath, name))
    agents_md = os.path.join(root, "AGENTS.md")
    if os.path.isfile(agents_md):
        out.append(agents_md)
    return out


def main(argv):
    ap = argparse.ArgumentParser(prog="check-skill-bash.sh", add_help=True)
    ap.add_argument("--root", default=None, help="repo root for no-arg discovery")
    ap.add_argument("--json", action="store_true", help="emit findings as JSON")
    ap.add_argument("files", nargs="*", help="explicit .md files to scan")
    try:
        args = ap.parse_args(argv)
    except SystemExit:
        return 64
    if args.files:
        targets = args.files
    else:
        root = args.root
        if not root:
            try:
                root = subprocess.run(
                    ["git", "rev-parse", "--show-toplevel"],
                    capture_output=True, text=True, check=True,
                ).stdout.strip()
            except (subprocess.CalledProcessError, OSError):
                root = os.getcwd()
        targets = discover(root)
    findings = []
    for path in targets:
        findings.extend(lint_file(path))
    unwaived = [f for f in findings if not f["waived"]]
    waived_n = len(findings) - len(unwaived)
    if args.json:
        print(json.dumps(findings, indent=None))
    else:
        for f in unwaived:
            print(f"{f['path']}:{f['line']}: [{f['check']}] {f['message']}")
        print(f"{len(findings)} findings, {waived_n} waived")
    return 1 if unwaived else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

Then: `chmod +x skills/skill-lint/check-skill-bash.sh skills/skill-lint/test.sh`

- [ ] **Step 5: Write SKILL.md**

Author `skills/skill-lint/SKILL.md` with the Write tool:

```markdown
---
name: skill-lint
description: |
    Deterministic, LLM-free linter for fenced bash blocks in plugin .md files
    (SPEC-021). Checks: C1 cross-block variable scope, C2 zsh history-expansion
    hazard, C3 zsh-fatal unguarded glob, C4 captured inline-PRAGMA sqlite poison.
    Run by /release as a pre-commit gate (Step 4.8). Not user-invoked directly;
    run manually via: bash skills/skill-lint/check-skill-bash.sh [FILE...]
---

# skill-lint

Static analysis over fenced ```bash blocks in `commands/**/*.md`, `skills/**/*.md`,
`agents/**/*.md`, and `AGENTS.md`. Governing spec: `specs/core/SPEC-021-skill-bash-lint-gate.md`.

## Usage

    bash skills/skill-lint/check-skill-bash.sh              # no-arg: full repo scan
    bash skills/skill-lint/check-skill-bash.sh FILE.md ...  # explicit file list
    bash skills/skill-lint/check-skill-bash.sh --json       # machine-readable
    bash skills/skill-lint/check-skill-bash.sh --root DIR   # override discovery root

Exit codes: 0 clean, 1 unwaived findings, 64 usage error.

## Checks

| ID | Defect class | Remedy |
|----|--------------|--------|
| C1 | Variable used in one bash block, defined only in another (blocks run as separate shells) | Re-resolve the variable in the using block |
| C2 | History-expansion-hazardous `bang` sequences / HTML-comment openers in heredocs and quoted strings (zsh mangles them) | Author the content via the Write tool, or build the char as chr(33) |
| C3 | Unquoted glob that aborts the block under zsh when it matches nothing | Iterate via find -maxdepth 1 -name, or guard existence |
| C4 | Command substitution capturing sqlite3 with a leading inline PRAGMA assignment (emits a value row on sqlite >= 3.51.2) | sqlite3 -cmd ".timeout N", or drop the inline PRAGMA |

## Waivers

Add `# lint-ok: C3` (comma-separate multiple IDs) on the offending line or the
line directly above it. Waived findings are counted in the summary line — never
silent. Waive only after confirming the flagged line is genuinely safe.

## Bite-tests

    bash skills/skill-lint/test.sh

Fixtures under `fixtures/` include one defect fixture per check class and a clean
fixture; the harness asserts each defect produces exit 1 naming its check-id.
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bash skills/skill-lint/test.sh`
Expected: PASS — `skill-lint tests: 2 passed, 0 failed` (clean fixture exit 0, bad flag exit 64).

- [ ] **Step 7: Commit**

```bash
git add skills/skill-lint/
git commit -m "feat: SPEC-021 scaffold — skill-lint wrapper, block extractor, bite-test harness"
```

---

### Task 2: C4 — captured inline-PRAGMA sqlite poison

**Files:**
- Modify: `skills/skill-lint/lint.py` (add `check_c4`, register in `CHECKS`)
- Create: `skills/skill-lint/fixtures/c4-pragma.md`
- Test: `skills/skill-lint/test.sh` (append assertions)

**Interfaces:**
- Consumes: `CHECKS` registry + `add(rel_line0, message)` callback from Task 1.
- Produces: check id `C4`.

- [ ] **Step 1: Write the defect fixture**

Author `skills/skill-lint/fixtures/c4-pragma.md` with the Write tool:

````markdown
# C4 fixture

```bash
DB=/tmp/x.db
VAL=$(sqlite3 "$DB" "PRAGMA busy_timeout=5000; SELECT content FROM memories;")
echo "$VAL"
```

```bash
DB=/tmp/x.db
sqlite3 "$DB" <<'SQL'
PRAGMA busy_timeout=5000;
SELECT 1;
SQL
OK=$(sqlite3 -cmd ".timeout 5000" "$DB" "SELECT 1;")
echo "$OK"
```
````

(Block 1 = the poison pattern → must flag. Block 2 = uncaptured heredoc + the `-cmd` remedy → must NOT flag.)

- [ ] **Step 2: Append failing tests to test.sh**

Insert before the `echo "---"` summary lines:

```bash
# T2: C4 — captured inline-PRAGMA flagged; heredoc + -cmd forms not flagged
run_lint 1 "$FIX/c4-pragma.md"
expect_finding C4 "c4-pragma.md:4"
run_lint 1 "$FIX/c4-pragma.md"   # same file: exactly ONE C4 finding
[ "$(echo "$OUT" | grep -c '\[C4\]')" -eq 1 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: expected exactly 1 C4"; }
```

- [ ] **Step 3: Run tests to verify the new ones fail**

Run: `bash skills/skill-lint/test.sh`
Expected: FAIL on the C4 assertions (exit 0 observed where 1 expected — no checks registered yet).

- [ ] **Step 4: Implement check_c4**

Add to `lint.py` (below `CHECKS = []`), authored via the Edit tool on the Write-created file:

```python
C4_RE = re.compile(
    r"\$\(\s*sqlite3\b[^()]{0,200}?[\"']\s*PRAGMA\s+\w+\s*=\s*[^;]{1,60};",
    re.S,
)


def check_c4(block_lines, add):
    """Captured $(sqlite3 ... "PRAGMA x=v; ...") — the value row poisons the read."""
    text = "\n".join(block_lines)
    for m in C4_RE.finditer(text):
        rel = text.count("\n", 0, m.start())
        add(rel, "captured sqlite3 with leading inline PRAGMA assignment — emits a "
                 "value row on sqlite >= 3.51.2; use sqlite3 -cmd \".timeout N\" "
                 "or a statement without the inline PRAGMA")


CHECKS.append(("C4", check_c4))
```

(Note the registration replaces the bare `CHECKS = []` comment line's promise; keep `CHECKS = []` itself.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash skills/skill-lint/test.sh`
Expected: PASS — all assertions green, exactly one C4 at `c4-pragma.md:4`.

- [ ] **Step 6: Commit**

```bash
git add skills/skill-lint/
git commit -m "feat: SPEC-021 C4 — captured inline-PRAGMA sqlite poison check"
```

---

### Task 3: C2 — zsh history-expansion hazard

**Files:**
- Modify: `skills/skill-lint/lint.py` (add heredoc tracker + `check_c2`, register)
- Create: `skills/skill-lint/fixtures/c2-bang.md`
- Test: `skills/skill-lint/test.sh` (append assertions)

**Interfaces:**
- Consumes: `CHECKS` registry from Task 1.
- Produces: check id `C2`; helper `heredoc_body_lines(block_lines) -> set[int]` (0-based rel lines inside heredoc bodies) reused by C1 (Task 5) and C3 (Task 4).

- [ ] **Step 1: Write the defect fixture**

Author `skills/skill-lint/fixtures/c2-bang.md` with the Write tool. IMPORTANT: author with Write, never a heredoc — this file deliberately contains the hazardous sequences.

````markdown
# C2 fixture

```bash
python3 <<'PY'
print("include marker: <!-- include: x -->")
print("wow!bang")
PY
MSG="deploy failed!retry now"
echo "$MSG"
```

```bash
if ! command -v jq >/dev/null; then echo no; fi
[ ! -f /tmp/x ] && echo absent
X=1
if [ "$X" != "2" ]; then echo ok; fi
wait $!
echo "${!X}" 2>/dev/null || true
```
````

(Block 1: heredoc body has `<!--` and `wow!bang`; quoted string has `failed!retry` — 3 findings. Block 2: every legitimate `!` form — negation, test-negation, `!=`, `$!`, `${!X}` — 0 findings.)

- [ ] **Step 2: Append failing tests**

```bash
# T3: C2 — heredoc/quoted-string bang + HTML-comment opener flagged; legit forms not
run_lint 1 "$FIX/c2-bang.md"
expect_finding C2 "c2-bang.md"
[ "$(echo "$OUT" | grep -c '\[C2\]')" -eq 3 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: expected exactly 3 C2, got:"; echo "$OUT" | grep '\[C2\]'; }
```

- [ ] **Step 3: Run tests to verify the new ones fail**

Run: `bash skills/skill-lint/test.sh` — Expected: FAIL (0 C2 findings).

- [ ] **Step 4: Implement heredoc tracker + check_c2**

Add to `lint.py`:

```python
HEREDOC_OPEN_RE = re.compile(r"<<-?\s*(['\"]?)(\w+)\1")


def heredoc_body_lines(block_lines):
    """Return set of 0-based indices that are inside a heredoc body."""
    body = set()
    tag = None
    for i, line in enumerate(block_lines):
        if tag is not None:
            if line.strip() == tag:
                tag = None
            else:
                body.add(i)
            continue
        m = HEREDOC_OPEN_RE.search(line)
        if m:
            tag = m.group(2)
    return body


BANG_RE = re.compile(r"(?<![{$])!(?=\w)")
QUOTED_RE = re.compile(r"'[^']*'|\"[^\"]*\"")
C2_MSG = ("zsh history-expansion hazard in executed text — author this content "
          "via the Write tool (or build the char as chr(33))")


def check_c2(block_lines, add):
    body = heredoc_body_lines(block_lines)
    for i, line in enumerate(block_lines):
        if line.lstrip().startswith("#!"):
            continue
        if "<!--" in line:
            add(i, C2_MSG + " (HTML-comment opener)")
            continue
        if i in body:
            if BANG_RE.search(line):
                add(i, C2_MSG)
            continue
        for m in QUOTED_RE.finditer(line):
            if BANG_RE.search(m.group(0)):
                add(i, C2_MSG)
                break


CHECKS.append(("C2", check_c2))
```

(`(?<![{$])!(?=\w)` = a bang followed by a word char, not preceded by `{`/`$` — excludes `${!X}` and `$!`; `!=`, `[ ! -f ]`, `if ! cmd` never match because the next char isn't a word char, or a space follows the bang.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash skills/skill-lint/test.sh` — Expected: PASS, exactly 3 C2 findings on the fixture.

- [ ] **Step 6: Commit**

```bash
git add skills/skill-lint/
git commit -m "feat: SPEC-021 C2 — zsh history-expansion hazard check"
```

---

### Task 4: C3 — zsh-fatal unguarded glob

**Files:**
- Modify: `skills/skill-lint/lint.py` (add `check_c3`, register)
- Create: `skills/skill-lint/fixtures/c3-glob.md`
- Test: `skills/skill-lint/test.sh` (append assertions)

**Interfaces:**
- Consumes: `heredoc_body_lines` from Task 3.
- Produces: check id `C3`.

- [ ] **Step 1: Write the defect fixture**

Author `skills/skill-lint/fixtures/c3-glob.md` with the Write tool:

````markdown
# C3 fixture

```bash
for f in /tmp/data/*.json; do echo "$f"; done
FILES=$(ls "$HOME"/logs/*.jsonl)
rm .claude/tasks/CDV-1-*.json
```

```bash
for f in $(find /tmp/data -maxdepth 1 -name '*.json'); do echo "$f"; done
case "$1" in
  *.md) echo md ;;
  *) echo other ;;
esac
X="star literal *"
if [[ "$X" == *literal* ]]; then echo match; fi
grep -c '\.jsonl$' /tmp/list.txt
```
````

(Block 1: for-loop glob, `$(ls ...glob)` capture, bare `rm` glob — 3 findings. Block 2: find-based loop with QUOTED pattern, `case` arm patterns, `[[ == pattern ]]`, quoted glob in string/grep — 0 findings.)

- [ ] **Step 2: Append failing tests**

```bash
# T4: C3 — unguarded globs flagged; find/case/[[ patterns not
run_lint 1 "$FIX/c3-glob.md"
expect_finding C3 "c3-glob.md"
[ "$(echo "$OUT" | grep -c '\[C3\]')" -eq 3 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: expected exactly 3 C3, got:"; echo "$OUT" | grep '\[C3\]'; }
```

- [ ] **Step 3: Run tests to verify the new ones fail**

Run: `bash skills/skill-lint/test.sh` — Expected: FAIL (0 C3 findings).

- [ ] **Step 4: Implement check_c3**

Add to `lint.py`:

```python
GLOB_TOKEN_RE = re.compile(r"(?<![\"'\w])[\w./$@{}-]*[*?][\w./*?$@{}-]*")
C3_MSG = ("unquoted glob is fatal under zsh when it matches nothing — iterate "
          "via find -maxdepth 1 -name '<pat>', or guard existence first")


def _strip_quoted(line):
    """Blank out quoted spans so globs inside quotes are never flagged."""
    return QUOTED_RE.sub(lambda m: " " * len(m.group(0)), line)


def check_c3(block_lines, add):
    body = heredoc_body_lines(block_lines)
    in_case = 0
    for i, line in enumerate(block_lines):
        if i in body:
            continue
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        if re.match(r"^case\b", stripped):
            in_case += 1
        if re.match(r"^esac\b", stripped):
            in_case = max(0, in_case - 1)
            continue
        if in_case and re.match(r"^[^()]*\)", stripped):
            continue  # case arm pattern — bash pattern-match, not a glob expansion
        if stripped.startswith("[[") or " == " in stripped or " != " in stripped:
            continue  # [[ pattern ]] contexts don't glob-expand
        bare = _strip_quoted(line)
        if GLOB_TOKEN_RE.search(bare):
            add(i, C3_MSG)


CHECKS.append(("C3", check_c3))
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash skills/skill-lint/test.sh` — Expected: PASS, exactly 3 C3 on block 1, 0 on block 2. If the count is off, adjust `GLOB_TOKEN_RE` boundaries against the fixture lines only (do NOT weaken the block-2 negatives).

- [ ] **Step 6: Commit**

```bash
git add skills/skill-lint/
git commit -m "feat: SPEC-021 C3 — zsh-fatal unguarded glob check"
```

---

### Task 5: C1 — cross-block variable scope

**Files:**
- Modify: `skills/skill-lint/lint.py` (add file-level pass; small refactor of `lint_file`)
- Create: `skills/skill-lint/fixtures/c1-cross-block.md`
- Test: `skills/skill-lint/test.sh` (append assertions)

**Interfaces:**
- Consumes: `extract_blocks`, `heredoc_body_lines`, `ENV_ALLOW`, `_strip_quoted` (single-quote stripping) from earlier tasks.
- Produces: check id `C1`. NOTE: C1 is file-scoped (needs all blocks), so it does NOT go into the per-block `CHECKS` registry — `lint_file` calls `check_c1_file(blocks, add_abs)` after the per-block loop, where `add_abs(abs_line_1based, check_id, message)` records with an absolute line.

- [ ] **Step 1: Write the defect fixture**

Author `skills/skill-lint/fixtures/c1-cross-block.md` with the Write tool:

````markdown
# C1 fixture

```bash
PDH=$(cd "$(dirname "$0")" && pwd)
GATE="$PDH/gate.sh"
echo "$GATE"
```

```bash
bash "$PDH/other.sh"
echo "$HOME/$UNDEFINED_ANYWHERE"
for t in a b; do echo "$t"; done
```
````

(Block 2 uses `$PDH` — defined only in block 1 → 1 finding. `$HOME` allowlisted; `$UNDEFINED_ANYWHERE` defined in NO block → skipped, avoids false positives on prompt-substituted vars; `$t` defined by its own `for`.)

- [ ] **Step 2: Append failing tests**

```bash
# T5: C1 — cross-block use flagged once; allowlist + nowhere-defined + loop vars not
run_lint 1 "$FIX/c1-cross-block.md"
expect_finding C1 "c1-cross-block.md:9"
[ "$(echo "$OUT" | grep -c '\[C1\]')" -eq 1 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: expected exactly 1 C1, got:"; echo "$OUT" | grep '\[C1\]'; }
```

- [ ] **Step 3: Run tests to verify the new ones fail**

Run: `bash skills/skill-lint/test.sh` — Expected: FAIL (0 C1 findings).

- [ ] **Step 4: Implement check_c1_file + wire into lint_file**

Add to `lint.py`:

```python
DEF_RES = [
    re.compile(r"^\s*(?:export\s+|local\s+|readonly\s+)?([A-Za-z_]\w*)\+?="),
    re.compile(r"\bfor\s+([A-Za-z_]\w*)\s+in\b"),
    re.compile(r"\bread\s+(?:-[a-z]\s+\S+\s+)*-?r?\s*([A-Za-z_]\w*)\b"),
]
USE_RE = re.compile(r"\$\{?([A-Za-z_]\w*)")


def _block_defs_uses(block_lines):
    body = heredoc_body_lines(block_lines)
    defs, uses = set(), {}  # uses: name -> first rel line
    for i, line in enumerate(block_lines):
        if i in body:
            continue
        for rx in DEF_RES:
            for m in rx.finditer(line):
                defs.add(m.group(1))
        scan = re.sub(r"'[^']*'", "", line)  # single quotes don't expand
        for m in USE_RE.finditer(scan):
            uses.setdefault(m.group(1), i)
    return defs, uses


def check_c1_file(blocks, add_abs):
    """blocks: [(start_line, lines)]. Flag uses defined only in a sibling block."""
    per_block = [(_start, _block_defs_uses(lines)) for _start, lines in blocks]
    all_defs = set().union(*[d for _s, (d, _u) in per_block]) if per_block else set()
    for bi, (start, (defs, uses)) in enumerate(per_block):
        for name, rel in uses.items():
            if name in defs or name in ENV_ALLOW or name not in all_defs:
                continue
            add_abs(start + rel, "C1",
                    f"${name} is defined in a different bash block of this file — "
                    "blocks run as separate shells; re-resolve it in this block")


CHECKS_FILE = [check_c1_file]
```

In `lint_file`, after the per-block `CHECKS` loop, add:

```python
    def add_abs(abs_line, check_id, message):
        findings.append({"path": path, "line": abs_line, "check": check_id,
                         "message": message, "waived": False})
    for fn in CHECKS_FILE:
        fn(blocks, add_abs)
```

where `blocks = extract_blocks(text)` is hoisted to a variable used by both loops.

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash skills/skill-lint/test.sh` — Expected: PASS, exactly 1 C1 at `c1-cross-block.md:9`.

- [ ] **Step 6: Commit**

```bash
git add skills/skill-lint/
git commit -m "feat: SPEC-021 C1 — cross-block variable scope check"
```

---

### Task 6: Waiver semantics

**Files:**
- Create: `skills/skill-lint/fixtures/waived.md`
- Test: `skills/skill-lint/test.sh` (append assertions)

**Interfaces:**
- Consumes: `apply_waivers` (already implemented in Task 1) — this task proves it per SPEC-021's waiver MUSTs.
- Produces: verified waiver contract.

- [ ] **Step 1: Write the waiver fixture**

Author `skills/skill-lint/fixtures/waived.md` with the Write tool:

````markdown
# Waiver fixture

```bash
rm /tmp/known-nonempty/*.bak  # lint-ok: C3
# lint-ok: C3
rm /tmp/other-nonempty/*.bak
rm /tmp/unwaived/*.bak  # lint-ok: C1
```
````

(Line 4: same-line waiver → waived. Line 6: previous-line waiver → waived. Line 7: waiver names the WRONG check → C3 still fires.)

- [ ] **Step 2: Append tests**

```bash
# T6: waivers — same-line + prev-line suppress; wrong-id does not; summary counts
run_lint 1 "$FIX/waived.md"
[ "$(echo "$OUT" | grep -c '\[C3\]')" -eq 1 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: expected exactly 1 unwaived C3"; }
echo "$OUT" | grep -q "3 findings, 2 waived" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: summary line wrong: $(echo "$OUT" | tail -1)"; }
```

- [ ] **Step 3: Run tests**

Run: `bash skills/skill-lint/test.sh`
Expected: PASS if Task 1's `apply_waivers` is correct; if the prev-line case fails, fix `apply_waivers` (it must check `f["line"] - 1` within bounds) and re-run.

- [ ] **Step 4: Commit**

```bash
git add skills/skill-lint/
git commit -m "test: SPEC-021 waiver semantics — same-line, prev-line, wrong-id, summary"
```

---

### Task 7: No-arg discovery coverage bite-test

**Files:**
- Test: `skills/skill-lint/test.sh` (append the coverage bite-test)

**Interfaces:**
- Consumes: `--root` flag and `discover()` from Task 1; C4 check from Task 2.
- Produces: proof that the no-arg form covers all four SPEC-021 scan locations (the P1-5B "default_files must glob every claimed dir" lesson, mechanized).

- [ ] **Step 1: Append the coverage bite-test**

```bash
# T7: coverage — a planted defect in EACH claimed location is found by the no-arg form
T7ROOT=$(mktemp -d)
mkdir -p "$T7ROOT/commands" "$T7ROOT/skills/deep/nested" "$T7ROOT/agents"
PLANT='```bash'$'\n''V=$(sqlite3 db "PRAGMA busy_timeout=5000; SELECT 1;")'$'\n''```'
printf '%s\n' "$PLANT" > "$T7ROOT/commands/a.md"
printf '%s\n' "$PLANT" > "$T7ROOT/skills/deep/nested/b.md"
printf '%s\n' "$PLANT" > "$T7ROOT/agents/c.md"
printf '%s\n' "$PLANT" > "$T7ROOT/AGENTS.md"
run_lint 1 --root "$T7ROOT"
for loc in commands/a.md skills/deep/nested/b.md agents/c.md AGENTS.md; do
  echo "$OUT" | grep -q "$loc" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: no-arg scan missed $loc"; }
done
rm -rf "$T7ROOT"
```

(The planted block contains no `!`, so `printf` here is heredoc-safe; it deliberately trips C4.)

- [ ] **Step 2: Run tests**

Run: `bash skills/skill-lint/test.sh`
Expected: PASS — all four locations reported. If `AGENTS.md` or the nested skills path is missed, fix `discover()` (this is exactly the gate-coverage failure class the test exists to catch).

- [ ] **Step 3: Commit**

```bash
git add skills/skill-lint/
git commit -m "test: SPEC-021 no-arg discovery coverage bite-test (4 locations)"
```

---

### Task 8: Adoption pass — bring the live tree to clean

**Files:**
- Modify: any `commands/**/*.md`, `skills/**/*.md`, `agents/**/*.md`, `AGENTS.md` with genuine findings (fix), or add `# lint-ok:` waivers (false positives)

**Interfaces:**
- Consumes: the complete linter (Tasks 1–7).
- Produces: a live tree where `bash skills/skill-lint/check-skill-bash.sh` exits 0 — the SPEC-021 "gate lands green" MUST.

- [ ] **Step 1: Run the full scan and capture the finding list**

Run: `bash skills/skill-lint/check-skill-bash.sh | tee /tmp/skill-lint-adoption.txt`
Expected: exit 1 with a finding list (the live tree has never been linted).

- [ ] **Step 2: Triage every finding — fix or waive, never ignore**

Decision rules, applied per finding:
- **C1 true positive** (use genuinely depends on a sibling block): add the re-resolution stanza to the using block (copy the defining block's assignment — e.g. the PDH bootstrap stanza pattern already used across commands).
- **C2/C3/C4 true positive**: apply the check's named remedy verbatim.
- **False positive** (line is genuinely safe — e.g. a glob against a directory the same block just created): add `# lint-ok: <id>` on the line, with a brief trailing reason if space allows.
- **Ambiguous**: treat as true positive. Waivers are for *proven*-safe lines only.
- NOTE: fixture files under `skills/skill-lint/fixtures/` WILL self-report (they contain planted defects). Do not waive them inline (that would defeat the bite-tests) — instead exclude the fixtures directory in `discover()`:

```python
            if "skill-lint/fixtures" in dirpath.replace(os.sep, "/"):
                continue
```

added as the first statement of the `for dirpath ...` loop body, with a matching negative test appended to test.sh:

```bash
# T8: fixtures dir excluded from no-arg discovery
run_lint 1 --root "$(cd "$HERE/../.." && pwd)" 2>/dev/null || true
echo "$OUT" | grep -q "fixtures/c4-pragma.md" && { FAIL=$((FAIL+1)); echo "FAIL: fixtures not excluded"; } || PASS=$((PASS+1))
```

- [ ] **Step 3: Iterate to clean**

Run: `bash skills/skill-lint/check-skill-bash.sh; echo "exit=$?"`
Expected: `exit=0`, summary `N findings, N waived` (all remaining findings are reviewed waivers). Also re-run `bash skills/skill-lint/test.sh` — all bite-tests still green.

- [ ] **Step 4: Commit**

```bash
git add -A skills/ commands/ agents/ AGENTS.md
git commit -m "fix: SPEC-021 adoption pass — live tree lints clean (fixes + reviewed waivers)"
```

---

### Task 9: /release gate wiring + injected-defect dry run

**Files:**
- Modify: `skills/release/SKILL.md` (insert Step 4.8 after Step 4.7)
- Modify: `specs/core/SPEC-021-skill-bash-lint-gate.md` (Covers + Version History)
- Modify: `specs/TDD.md` (Version History row)

**Interfaces:**
- Consumes: clean live tree from Task 8.
- Produces: the release gate (SPEC-021 "Release gate wiring" MUSTs).

- [ ] **Step 1: Insert Step 4.8 into skills/release/SKILL.md**

After the Step 4.7 section (`## Step 4.7: Hook-template drift-check (pre-commit gate)` block) and before `## Step 5: Commit (one folded commit)`, insert:

```markdown
## Step 4.8: Skill-bash lint (pre-commit gate)

Run:
```bash
bash skills/skill-lint/check-skill-bash.sh
```

If it exits non-zero, a fenced bash block in a command/skill/agent .md file contains a known prompts-as-code defect (C1 cross-block variable scope, C2 zsh history-expansion hazard, C3 zsh-fatal unguarded glob, or C4 captured inline-PRAGMA sqlite poison — see `skills/skill-lint/SKILL.md`). **Do NOT commit or tag.** Fix the finding using the remedy named in its message — or, ONLY for a proven-safe line, add a `# lint-ok: <check-id>` waiver — then re-run until it exits 0. (Covered: `commands/**/*.md`, `skills/**/*.md` excluding `skill-lint/fixtures/`, `agents/**/*.md`, `AGENTS.md`; governing spec SPEC-021.)
```

- [ ] **Step 2: Injected-defect gate bite (revert via cp-from-backup, NEVER git checkout)**

```bash
cp AGENTS.md /tmp/AGENTS.md.bak
printf '\n```bash\nV=$(sqlite3 db "PRAGMA busy_timeout=5000; SELECT 1;")\n```\n' >> AGENTS.md
bash skills/skill-lint/check-skill-bash.sh; echo "exit=$?"    # MUST print exit=1 + a C4 finding in AGENTS.md
cp /tmp/AGENTS.md.bak AGENTS.md
cmp AGENTS.md /tmp/AGENTS.md.bak && echo restored-byte-identical
bash skills/skill-lint/check-skill-bash.sh; echo "exit=$?"    # MUST print exit=0
```

Expected: `exit=1` with the injected C4, then `restored-byte-identical`, then `exit=0`.

- [ ] **Step 3: Update SPEC-021 + TDD.md**

- SPEC-021 `**Covers**:` — add `skills/skill-lint/lint.py` and `skills/skill-lint/test.sh` (the implementation split the CLI into wrapper + python module).
- SPEC-021 `## Version History` — append row: `| <today> | Implemented: linter + fixtures + bite-tests + /release Step 4.8; Covers extended with lint.py/test.sh |` (append AFTER the latest date — keep the column chronologically monotonic).
- SPEC-021 `## Validation` — tick the three implementation checkboxes (bite-tests, adoption pass, gate step); leave "promoted to ACTIVE" unticked for review.
- `specs/TDD.md` `## Version History` — append: `| <today> | SPEC-021 implemented: skills/skill-lint/ linter + fixtures + /release Step 4.8 gate |` (again, append at the bottom).

- [ ] **Step 4: Run everything one last time**

```bash
bash skills/skill-lint/test.sh                      # all bite-tests green
bash skills/skill-lint/check-skill-bash.sh          # live tree exit 0
bash skills/spec-tooling/check-format.sh specs/core/SPEC-021-skill-bash-lint-gate.md   # spec format OK
```

Expected: all three exit 0.

- [ ] **Step 5: Commit**

```bash
git add skills/release/SKILL.md skills/skill-lint/ specs/core/SPEC-021-skill-bash-lint-gate.md specs/TDD.md
git commit -m "feat: SPEC-021 /release Step 4.8 skill-bash lint gate — bite-tested, tree clean"
```

---

## Completion / Handoff

After Task 9: the branch holds the complete SPEC-021 implementation. Next actions (outside this plan):
1. `/review-and-commit` or `/council --diff` on the branch for adversarial review.
2. Promote SPEC-021 DRAFT → ACTIVE (tick the final Validation box) once reviewed.
3. Merge to master via the standard squash-merge and ship with `/release minor` (this is a `feat:` line — the release exercises Step 4.8 for the first time, satisfying the last Validation criterion).

## Self-Review Notes

- Spec coverage: CLI contract → T1; C4/C2/C3/C1 → T2–T5; waivers → T1+T6; scan coverage + file-list form → T1+T7; fixtures-dir exclusion → T8; release wiring + lands-green + injected-defect proof → T8+T9; bite-tests-before-wiring MUST → T2–T7 all precede T9. SHOULD items (--json flag: T1; in-block use-before-define warning, 10s budget: deferred, SHOULD-level, revisit at review).
- Known calibration risk: C3 (`GLOB_TOKEN_RE`) is the FP-prone check — T4 Step 5 explicitly permits tightening the regex against fixtures, and T8's waiver path absorbs residual FPs without weakening the gate.
- Type consistency: `add(rel_line0, message)` (per-block, check id bound at registration) vs `add_abs(abs_line, check_id, message)` (file-scoped C1) — deliberate, documented in T5 Interfaces.
