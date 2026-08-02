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


def scan_fences(text):
    """Return (bash_blocks, fenced_mask).

    bash_blocks: [(first_content_line_1based, [lines])] for top-level ```bash
    fences. fenced_mask: set of 1-based line numbers inside ANY fence (of any
    language), fence delimiters included — lets callers tell a markdown heading
    from a `#` shell comment.

    CommonMark rules: a closing fence has >= opener's backticks and NO info
    string. While a fence is open, a backticked line WITH an info string is
    content — so ```bash examples nested inside ````markdown templates are
    correctly treated as text, not executable blocks.

    A fence is bash iff the first whitespace-delimited token of the info string
    is exactly ``bash`` (Q5).
    """
    blocks = []
    mask = set()
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
                is_bash = bool(info) and info.split()[0] == "bash"
                buf = []
                start = i + 1
                mask.add(i)
        else:
            mask.add(i)
            if m and len(m.group(1)) >= open_ticks and not m.group(2).strip():
                if is_bash:
                    blocks.append((start, buf))
                open_ticks = 0
                is_bash = False
            elif is_bash:
                buf.append(line)
    return blocks, mask


def extract_blocks(text):
    return scan_fences(text)[0]


CHECKS = []  # list of (check_id, fn(block_lines, add)) — per-block checks
CHECKS_FILE = []  # list of fn(path, blocks, add_abs) — file-level checks (C1, C5)

# --- C4: captured inline-PRAGMA sqlite poison ---

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

# --- C2: zsh history-expansion hazard ---

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

# --- C3: zsh-fatal unguarded glob ---

# Path-like unquoted globs only. Excludes shell specials ($?), SQL COUNT(*),
# and arithmetic `*` — residual FPs waived at adoption (Q2).
GLOB_TOKEN_RE = re.compile(
    r"(?<![\"'\w])"
    r"(?:"
    r"[\w./$@{}-]*/[\w./*?$@{}-]*[*?][\w./*?$@{}-]*"  # has / and a glob metachar
    r"|"
    r"[\w.$@{}-]+\*[\w./*?$@{}-]+"  # foo*bar / prefix*.ext
    r"|"
    r"\*[\w.]+"  # *.ext
    r")"
)
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
        # Neutralize shell specials and arithmetic so $? / $((a*b)) never match
        bare = re.sub(r"\$\?", "  ", bare)
        bare = re.sub(r"\$\(\([^)]*\)\)", " ", bare)
        if GLOB_TOKEN_RE.search(bare):
            add(i, C3_MSG)


CHECKS.append(("C3", check_c3))

# --- C1: cross-block variable scope (file-level) ---

DEF_RES = [
    # assignment at line start (optional indent) or after && / || / ;
    re.compile(
        r"(?:^\s*|(?:&&|\|\||;)\s*)(?:export\s+|local\s+|readonly\s+|"
        r"declare\s+(?:-[a-zA-Z]+\s+)*)?([A-Za-z_]\w*)\+?="
    ),
    # local/declare/readonly name without assignment (Q4)
    re.compile(
        r"^\s*(?:local|readonly|declare(?:\s+-[a-zA-Z]+)*)\s+([A-Za-z_]\w*)\b"
    ),
    re.compile(r"\bfor\s+([A-Za-z_]\w*)\s+in\b"),
    re.compile(r"\bread\s+(?:-[a-zA-Z]\s+\S+\s+)*([A-Za-z_]\w*)\b"),
    re.compile(r"^\s*export\s+(?:-[a-zA-Z]+\s+)*([A-Za-z_]\w*)\b"),
    re.compile(
        r"^\s*(?:local|readonly|declare(?:\s+-[a-zA-Z]+)*)\s+"
        r"((?:[A-Za-z_]\w*(?:\s+|$))+)"
    ),
]
USE_RE = re.compile(r"\$\{?([A-Za-z_]\w*)")
# function-parameter: names bound at definition via `foo() {` aren't named;
# also match `f() {` args documented as first `local` lines. Extra pattern for
# bash `foo() (` unused. Treat `name()` body `local -` covered.
# Capture: `func() {` then later tasks. For explicit `function foo bar` no.
FUNC_PARAM_RE = re.compile(
    r"^\s*(?:function\s+)?[A-Za-z_]\w*\s*\(\s*([^)]*)\s*\)"
)


def _block_defs_uses(block_lines):
    body = heredoc_body_lines(block_lines)
    defs, uses = set(), {}  # uses: name -> first rel line
    for i, line in enumerate(block_lines):
        if i in body:
            continue
        # function params inside () if any named (rare in bash; still scan)
        fm = FUNC_PARAM_RE.match(line)
        if fm and fm.group(1).strip():
            for tok in re.findall(r"[A-Za-z_]\w*", fm.group(1)):
                defs.add(tok)
        for rx in DEF_RES:
            for m in rx.finditer(line):
                g = m.group(1)
                # multi-name local/declare/readonly capture may be space-separated
                for name in re.findall(r"[A-Za-z_]\w*", g):
                    defs.add(name)
        scan = re.sub(r"'[^']*'", "", line)  # single quotes don't expand
        for m in USE_RE.finditer(scan):
            uses.setdefault(m.group(1), i)
    return defs, uses


def check_c1_file(_path, blocks, add_abs):
    """blocks: [(start_line, lines)]. Flag uses defined only in a sibling block."""
    per_block = [(_start, _block_defs_uses(lines)) for _start, lines in blocks]
    all_defs = set().union(*[d for _s, (d, _u) in per_block]) if per_block else set()
    for _bi, (start, (defs, uses)) in enumerate(per_block):
        for name, rel in uses.items():
            if name in defs or name in ENV_ALLOW or name not in all_defs:
                continue
            add_abs(start + rel, "C1",
                    f"${name} is defined in a different bash block of this file — "
                    "blocks run as separate shells; re-resolve it in this block")


CHECKS_FILE.append(check_c1_file)

# --- C5: PDH bootstrap-stanza drift (file-level) ---
#
# The canonical stanza is READ FROM SPEC-002 AT RUNTIME. It is deliberately not
# duplicated here: a second literal copy is itself the drift class C5 exists to
# prevent. Resolution failure is never a silent pass — see VACUOUS below.

SPEC002_REL = "specs/core/SPEC-002-plugin-infrastructure.md"
# Anchor on the section HEADING, not "first fenced block in the file": SPEC-002
# holds more than one fenced bash block (the canonical stanza here, plus the
# inventory re-derivation command further down). Anchoring on the first block
# would compare every emission against the wrong text and still exit 0.
CANON_HEADING_RE = re.compile(r"^(#{1,6})\s+Locating\s+`?plugin-dir\.sh`?\s+itself\s*$")
ATX_HEADING_RE = re.compile(r"^(#{1,6})\s")
PDH_LINE_RE = re.compile(r"^\s*PDH=\$\(")
# The locator cannot bootstrap itself; the test harness holds a deliberately
# re-quoted copy for `bash -c`. Both are standalone .sh files (outside the .md
# scan set), asserted here rather than assumed.
C5_EXCLUDE_SUFFIXES = ("skills/plugin-dir.sh", "skills/plugin-dir-test.sh")

CANON_ROOTS = []  # search roots for SPEC-002, set by main()
CANON_CACHE = []  # memoized (stanza, error)
VACUOUS = []  # distinct unresolvable-canonical reasons; forces non-zero exit


def _extract_canonical(roots):
    """Return (stanza, None) or (None, reason). Never (None, None)."""
    tried = []
    for root in roots:
        path = os.path.join(root, SPEC002_REL)
        tried.append(path)
        if not os.path.isfile(path):
            continue
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError as e:
            return None, f"{path} is unreadable: {e}"
        lines = text.splitlines()
        blocks, fenced = scan_fences(text)
        heads = []
        for n, ln in enumerate(lines, 1):
            hm = CANON_HEADING_RE.match(ln)
            if hm and n not in fenced:
                heads.append((n, hm))
        if len(heads) != 1:
            return None, (f'{path} has {len(heads)} sections matching the heading '
                          '"Locating `plugin-dir.sh` itself" (expected exactly 1)')
        start, head = heads[0]
        depth = len(head.group(1))
        end = len(lines) + 1
        for n, ln in enumerate(lines[start:], start + 1):
            hm = ATX_HEADING_RE.match(ln)
            if hm and n not in fenced and len(hm.group(1)) <= depth:
                end = n
                break
        section = [b for b in blocks if start < b[0] < end]
        if not section:
            return None, (f'{path} section "Locating `plugin-dir.sh` itself" '
                          f"(lines {start}-{end - 1}) contains no fenced bash block")
        _s, body = section[0]
        stanzas = [ln for ln in body if PDH_LINE_RE.match(ln)]
        if len(stanzas) != 1:
            return None, (f"{path} canonical fenced block holds {len(stanzas)} "
                          "`PDH=$(` lines (expected exactly 1)")
        return stanzas[0].lstrip(), None
    return None, "SPEC-002 not found at any of: " + ", ".join(tried)


def canonical_stanza():
    if not CANON_CACHE:
        CANON_CACHE.append(_extract_canonical(CANON_ROOTS or [os.getcwd()]))
    return CANON_CACHE[0]


def _first_diff_col(actual, canon):
    for i, (a, b) in enumerate(zip(actual, canon)):
        if a != b:
            return i + 1
    return min(len(actual), len(canon)) + 1


def check_c5_file(path, blocks, add_abs):
    norm = path.replace(os.sep, "/")
    if any(norm.endswith(sfx) for sfx in C5_EXCLUDE_SUFFIXES):
        return
    for start, block_lines in blocks:
        for i, line in enumerate(block_lines):
            if not PDH_LINE_RE.match(line):
                continue
            canon, err = canonical_stanza()
            if err:
                # Fail loudly: a PDH stanza exists but nothing to compare it to.
                if err not in VACUOUS:
                    VACUOUS.append(err)
                return
            actual = line.lstrip()
            if actual == canon:
                continue
            add_abs(start + i, "C5",
                    "PDH bootstrap stanza is not byte-identical to the SPEC-002 "
                    f"canonical block (first difference at column {_first_diff_col(actual, canon)}) "
                    "— copy the stanza verbatim from SPEC-002 "
                    '"Locating `plugin-dir.sh` itself"')


CHECKS_FILE.append(check_c5_file)


def lint_file(path):
    """Return list of finding dicts for one .md file."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError as e:
        print(f"warn: cannot read {path}: {e}", file=sys.stderr)
        return None  # signal unreadable to caller
    findings = []
    src_lines = text.splitlines()
    blocks = extract_blocks(text)
    for start, block_lines in blocks:
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

    def add_abs(abs_line, check_id, message):
        findings.append({
            "path": path,
            "line": abs_line,
            "check": check_id,
            "message": message,
            "waived": False,
        })
    for fn in CHECKS_FILE:
        fn(path, blocks, add_abs)

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
    """No-arg scan set per SPEC-021: commands/skills/agents globs + AGENTS.md.

    Excludes skills/skill-lint/fixtures/** (Q1) so planted defects do not
    self-fail the live-tree gate.
    """
    out = []
    for pat in ("commands", "skills", "agents"):
        base = os.path.join(root, pat)
        for dirpath, _dirs, files in os.walk(base):
            norm = dirpath.replace(os.sep, "/")
            if "skill-lint/fixtures" in norm:
                continue
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
    except SystemExit as e:
        code = e.code if isinstance(e.code, int) else 64
        return 0 if code == 0 else 64

    root = args.root
    if not root:
        try:
            root = subprocess.run(
                ["git", "rev-parse", "--show-toplevel"],
                capture_output=True, text=True, check=True,
            ).stdout.strip()
        except (subprocess.CalledProcessError, OSError):
            root = os.getcwd()

    # this file lives at <checkout>/skills/skill-lint/lint.py
    own_checkout = os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))))

    CANON_CACHE.clear()
    VACUOUS.clear()
    # An explicit --root pins the search: a fallback would let a broken test
    # tree silently resolve its canonical from the real checkout.
    CANON_ROOTS[:] = [root] if args.root else [root, own_checkout, os.getcwd()]

    if args.files:
        targets = args.files
        explicit = True
    else:
        targets = discover(root)
        explicit = False

    findings = []
    readable = 0
    for path in targets:
        if explicit and not os.path.isfile(path):
            print(f"warn: cannot read {path}: missing", file=sys.stderr)
            continue
        result = lint_file(path)
        if result is None:
            # unreadable (lint_file already warned)
            continue
        readable += 1
        findings.extend(result)

    if explicit and readable == 0:
        print("usage error: no scannable targets (all paths missing/unreadable)",
              file=sys.stderr)
        return 64

    unwaived = [f for f in findings if not f["waived"]]
    waived_n = len(findings) - len(unwaived)
    if args.json:
        print(json.dumps(findings, indent=None))
    else:
        for f in unwaived:
            print(f"{f['path']}:{f['line']}: [{f['check']}] {f['message']}")
        print(f"{len(findings)} findings, {waived_n} waived")
    for reason in VACUOUS:
        # Unwaivable by construction: a waiver here would re-hide the vacuity.
        print(f"error: [C5] canonical stanza not resolvable — {reason}", file=sys.stderr)
    return 1 if (unwaived or VACUOUS) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
