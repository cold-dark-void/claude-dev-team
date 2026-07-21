#!/usr/bin/env python3
"""SPEC-030 smoke harness: load-only static verification of plugin Surfaces.

A "Surface" is a user-invocable markdown file with YAML frontmatter
(commands/*.md, skills/*/SKILL.md) whose executable logic lives in fenced
```bash blocks; engine scripts are the non-test skills/**/*.sh files. This gate
asserts each still *loads* — frontmatter parses with name+description, every
top-level bash fence passes `bash -n`, every engine script parses (plus an
opt-in --help/--check where the script declares it). It is static: bash fences
and mutating script bodies are never executed.

Exit codes: 0 = all pass, 1 = at least one fail, 64 = usage error.
Output: one `PASS <path>` / `FAIL <path>: <reason>` line per target, then a
final `N checked, M failed` summary. python3 stdlib only — no pyyaml, no network.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

FENCE_RE = re.compile(r"^\s*(`{3,})(.*)$")

# Test-script basenames excluded from engine-script discovery (SPEC-030):
# `test`-prefixed, `test-*.sh`, and `*-test.sh`.
TEST_SH_RE = re.compile(r"^(test\.sh|test-.*\.sh|.*-test\.sh)$")

# Literal flag tokens that, when present in a script's text, opt it in to an
# explicit --help/--check invocation (its non-zero exit becomes a FAIL).
FLAG_RE = re.compile(r"--help|--check")


# --- Vendored from SPEC-021 skills/skill-lint/lint.py extract_blocks() ---
# Source of truth for fence semantics is lint.py; kept in lockstep with it.
# Cross-dir import (tools/ <-> skills/) needs a path hack, so the ~30-line
# extractor is re-implemented here per the SPEC-030 design decision. If fence
# rules change in lint.py, mirror the change here.
def extract_blocks(text):
    """Yield (first_content_line_1based, [lines], info_string) per top-level
    ```bash fence.

    CommonMark rules: a closing fence has >= opener's backticks and NO info
    string. While a fence is open, a backticked line WITH an info string is
    content — so ```bash nested inside a ````markdown template is treated as
    text. A fence is bash iff the FIRST token of the info string is `bash`.

    Delta from lint.py: this returns the fence's full info string as a third
    tuple element so the caller can honor the `bash template` opt-out marker
    (SPEC-030). The fence-classification rules above are byte-identical to
    lint.py's — only the returned arity differs.
    """
    blocks = []
    open_ticks = 0
    is_bash = False
    buf = []
    start = 0
    info = ""
    for i, line in enumerate(text.splitlines(), 1):
        m = FENCE_RE.match(line)
        if open_ticks == 0:
            if m:
                info = m.group(2).strip()
                open_ticks = len(m.group(1))
                is_bash = bool(info) and info.split()[0] == "bash"
                buf = []
                start = i + 1
        else:
            if m and len(m.group(1)) >= open_ticks and not m.group(2).strip():
                if is_bash:
                    blocks.append((start, buf, info))
                open_ticks = 0
                is_bash = False
            elif is_bash:
                buf.append(line)
    return blocks
# --- end vendored region ---


def is_template_fence(info):
    """A bash fence opts out of the `bash -n` syntax check (SPEC-030) when its
    info string is `bash template` — i.e. the second whitespace-delimited token
    is exactly `template`. Documentation-shape fences (angle-bracket placeholders,
    elided pseudocode) carry this marker; they are still `bash`-classified, so
    skill-lint's defect-class coverage is unaffected."""
    toks = info.split()
    return len(toks) >= 2 and toks[1] == "template"


def parse_frontmatter(text):
    """Parse a leading `---`-delimited YAML frontmatter block.

    Returns (mapping, error). `mapping` maps top-level keys to a truthiness
    proxy: "" for an empty scalar, else a non-empty marker string. Handles flat
    `key: value`, block scalars (`key: |` / `key: >` with indented continuation),
    and quoted values — the subset of YAML the plugin's frontmatter actually
    uses (verified: no nested mappings, no flow collections). On a structural
    problem (no opening `---`, unterminated block, a non-`key:` top-level line)
    returns (None, reason). stdlib only — no pyyaml dependency.
    """
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return None, "no opening --- frontmatter delimiter"
    # Find the closing delimiter.
    end = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end = i
            break
    if end is None:
        return None, "unterminated frontmatter (no closing ---)"

    mapping = {}
    i = 1
    top_key_re = re.compile(r"^([A-Za-z0-9_-]+):(.*)$")
    while i < end:
        raw = lines[i]
        # Blank and comment lines between top-level keys are inert.
        if not raw.strip() or raw.lstrip().startswith("#"):
            i += 1
            continue
        # Top-level keys start in column 0 (no leading whitespace).
        if raw[0] in (" ", "\t"):
            return None, f"unexpected indented line in frontmatter (line {i + 1})"
        m = top_key_re.match(raw)
        if not m:
            return None, f"unparseable frontmatter line {i + 1}: {raw.strip()!r}"
        key = m.group(1)
        rest = m.group(2).strip()
        if rest and rest[0] in ("|", ">"):
            # Block scalar (`key: |` / `key: >`): value is the indented lines
            # that follow. Non-empty iff at least one such line has content.
            i += 1
            body_has_content = False
            while i < end:
                nxt = lines[i]
                if nxt.strip() and not (nxt[0] in (" ", "\t")):
                    break  # dedent to column 0 ends the block scalar
                if nxt.strip():
                    body_has_content = True
                i += 1
            mapping[key] = "x" if body_has_content else ""
        elif rest:
            # Inline scalar, possibly a plain multi-line scalar: YAML folds any
            # subsequent more-indented non-blank lines into this value. Consume
            # (and ignore) that continuation so it is not misread as an
            # unexpected indented top-level line.
            val = rest
            if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
                val = val[1:-1]
            mapping[key] = val.strip()
            i += 1
            while i < end and lines[i][:1] in (" ", "\t") and lines[i].strip():
                i += 1
        else:
            # `key:` with no inline value and no block indicator — empty scalar.
            mapping[key] = ""
            i += 1
    return mapping, None


def bash_n(path=None, source=None, cwd=None):
    """Run `bash -n` (parse-only) on a file path or on source via stdin.

    Returns (ok, stderr). Never executes the script body. Uses `bash` (not
    `zsh`) so results match the CI Ubuntu-bash runner and the other /release
    gates, even though fences are authored with zsh idioms.
    """
    if source is not None:
        proc = subprocess.run(
            ["bash", "-n", "-"], input=source,
            capture_output=True, text=True, cwd=cwd,
        )
    else:
        proc = subprocess.run(
            ["bash", "-n", path], capture_output=True, text=True, cwd=cwd,
        )
    return proc.returncode == 0, proc.stderr.strip()


def check_md(path):
    """Check set for a .md Surface. Returns (ok, reason)."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError as e:
        return None, f"cannot read: {e}"

    mapping, err = parse_frontmatter(text)
    if mapping is None:
        return False, err
    for field in ("name", "description"):
        if field not in mapping:
            return False, f"frontmatter missing `{field}`"
        if not mapping[field]:
            return False, f"frontmatter `{field}` is empty"

    for start, block_lines, info in extract_blocks(text):
        # `bash template` fences are documentation-shape (angle-bracket
        # placeholders / elided pseudocode) — skip the syntax check for them.
        if is_template_fence(info):
            continue
        ok, stderr = bash_n(source="\n".join(block_lines) + "\n")
        if not ok:
            end = start + len(block_lines) - 1
            detail = stderr.splitlines()[-1] if stderr else "bash -n failed"
            return False, f"bash fence at lines {start}-{end} fails bash -n: {detail}"
    return True, ""


def check_sh(path, invoke_flags=False):
    """Check set for an engine .sh script. Returns (ok, reason).

    The MUST-level check is `bash -n` (parse-only). The SPEC-030 `--help`/
    `--check` invocation is a MAY, and is gated behind `invoke_flags` (the
    harness `--invoke-flags` opt-in), OFF by default. Rationale: this repo's
    dominant help convention routes `--help` to a `usage()` that prints to
    stderr and exits non-zero (a usage-error exit, not a help-success exit),
    and `--check` on some scripts (e.g. local-agent/run.sh) is a value-taking
    argument, not a boolean self-test. Auto-invoking those as a pass/fail gate
    would fail the live tree and make the gate un-landable, contradicting the
    "gate lands green" mandate (SPEC-030 MUST, release-gate wiring). Keeping
    the capability behind an explicit opt-in preserves it for scripts that do
    implement a zero-exit `--help`/`--check`, and for the bite-test.
    """
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError as e:
        return None, f"cannot read: {e}"

    ok, stderr = bash_n(path=path)
    if not ok:
        detail = stderr.splitlines()[-1] if stderr else "bash -n failed"
        return False, f"bash -n: {detail}"

    # Opt-in --help/--check invocation ONLY when enabled AND the script declares
    # the flag (bodies of non-declaring scripts mutate state — never invoke
    # those). Run under a timeout in an isolated mktemp -d cwd so an errant
    # script can't touch the repo tree.
    if invoke_flags:
        m = FLAG_RE.search(text)
        if m:
            flag = m.group(0)
            with tempfile.TemporaryDirectory() as td:
                try:
                    proc = subprocess.run(
                        ["bash", os.path.abspath(path), flag],
                        capture_output=True, text=True, cwd=td, timeout=30,
                    )
                except subprocess.TimeoutExpired:
                    return False, f"{flag} did not exit within 30s"
                except OSError as e:
                    return False, f"{flag} invocation failed: {e}"
            if proc.returncode != 0:
                tail = (proc.stderr.strip().splitlines() or ["no stderr"])[-1]
                return False, f"{flag} exited {proc.returncode}: {tail}"
    return True, ""


def _excluded(relparts):
    """A path is excluded from discovery iff any segment is `fixtures`, or it
    lives under tools/smoke/ (the harness's own material must not self-fail)."""
    if "fixtures" in relparts:
        return True
    if len(relparts) >= 2 and relparts[0] == "tools" and relparts[1] == "smoke":
        return True
    return False


def discover(root):
    """No-arg Surface + engine-script set (SPEC-030).

    Surfaces: every commands/*.md and every skills/*/SKILL.md. Engine scripts:
    every non-test skills/**/*.sh. Excludes any path under a `fixtures/` dir and
    all of tools/smoke/ itself.
    """
    out = []

    cmd_dir = os.path.join(root, "commands")
    if os.path.isdir(cmd_dir):
        for name in sorted(os.listdir(cmd_dir)):
            if name.endswith(".md"):
                out.append(os.path.join(cmd_dir, name))

    skills_dir = os.path.join(root, "skills")
    for dirpath, dirs, files in os.walk(skills_dir):
        dirs.sort()
        rel = os.path.relpath(dirpath, root)
        relparts = [] if rel == "." else rel.replace(os.sep, "/").split("/")
        if _excluded(relparts):
            dirs[:] = []  # prune the subtree
            continue
        # SKILL.md lives one level under skills/ (skills/<name>/SKILL.md).
        if len(relparts) == 2 and relparts[0] == "skills" and "SKILL.md" in files:
            out.append(os.path.join(dirpath, "SKILL.md"))
        for name in sorted(files):
            if name.endswith(".sh") and not TEST_SH_RE.match(name):
                out.append(os.path.join(dirpath, name))
    return out


def check_path(path, invoke_flags=False):
    """Dispatch one target to its check set by extension. Returns (ok, reason);
    ok is None when the file is unreadable/unsupported."""
    if path.endswith(".md"):
        return check_md(path)
    if path.endswith(".sh"):
        return check_sh(path, invoke_flags=invoke_flags)
    return None, "unsupported target type (expected .md or .sh)"


def resolve_root(explicit_root):
    if explicit_root:
        return explicit_root
    try:
        return subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    except (subprocess.CalledProcessError, OSError):
        return os.getcwd()


def main(argv):
    ap = argparse.ArgumentParser(prog="run.sh", add_help=True)
    ap.add_argument("--root", default=None, help="repo root for no-arg discovery")
    ap.add_argument("--json", action="store_true", help="emit results as JSON")
    ap.add_argument("--invoke-flags", action="store_true",
                    help="also invoke declared --help/--check on engine scripts "
                         "(opt-in; off by default — see check_sh docstring)")
    ap.add_argument("paths", nargs="*", help="explicit paths to check")
    try:
        args = ap.parse_args(argv)
    except SystemExit as e:
        code = e.code if isinstance(e.code, int) else 64
        return 0 if code == 0 else 64

    if args.paths:
        targets = args.paths
        explicit = True
    else:
        targets = discover(resolve_root(args.root))
        explicit = False

    results = []
    failed = 0
    checked = 0
    for path in targets:
        if not os.path.isfile(path) or not os.access(path, os.R_OK):
            print(f"warn: skipping unreadable path: {path}", file=sys.stderr)
            continue
        ok, reason = check_path(path, invoke_flags=args.invoke_flags)
        if ok is None:
            print(f"warn: skipping unreadable path: {path} ({reason})",
                  file=sys.stderr)
            continue
        checked += 1
        results.append({"path": path, "ok": bool(ok), "reason": reason})
        if not ok:
            failed += 1

    if explicit and checked == 0:
        print("usage error: no checkable targets (all paths missing/unreadable)",
              file=sys.stderr)
        return 64

    if args.json:
        print(json.dumps(results))
    else:
        for r in results:
            if r["ok"]:
                print(f"PASS {r['path']}")
            else:
                print(f"FAIL {r['path']}: {r['reason']}")
        print(f"{checked} checked, {failed} failed")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
