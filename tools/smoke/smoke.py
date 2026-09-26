#!/usr/bin/env python3
"""SPEC-030 smoke harness: load-only static verification of plugin Surfaces.

Four target kinds, classified by path shape (classify()), not extension:
Surface (commands/*.md, skills/<name>/SKILL.md), Agent (agents/*.md), Sub-doc
(every other skills/**/*.md) and Script (every *.sh anywhere, test scripts
included, plus every file under githooks/). This gate asserts each still
*loads*: frontmatter parses (Surface/Agent require name+description; Agent
also requires tools/model/effort with model/effort value-domain checks), every
top-level ```bash fence passes `bash -n` (Surface/Agent/Sub-doc), every script
parses (plus an opt-in --help/--check where a non-test, non-githook script
declares it). It is static: bash fences and mutating script bodies are never
executed.

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

# Test-script basenames: `test.sh`, `test-*.sh`, `*-test.sh`. Discovery now
# includes test scripts as ordinary Script targets (SPEC-030); this pattern is
# used only to keep a test script's mutating body from ever being invoked via
# --invoke-flags.
TEST_SH_RE = re.compile(r"^(test\.sh|test-.*\.sh|.*-test\.sh)$")

# Literal flag tokens that, when present in a script's text, opt it in to an
# explicit --help/--check invocation (its non-zero exit becomes a FAIL).
FLAG_RE = re.compile(r"--help|--check")

# SPEC-030 Check set — Agent: model/effort value-domain checks (value domain
# only — not the SPEC-003 Tier table, which is SPEC-003's to enforce).
AGENT_MODELS = {"opus", "sonnet", "haiku"}
AGENT_EFFORTS = {"low", "medium", "high", "xhigh"}


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
    quoted values, and YAML block sequences (`key:` followed by `- item` lines,
    at column 0 or indented; non-empty iff at least one item has content) — the
    subset of YAML the plugin's frontmatter actually uses (verified: no nested
    mappings, no flow collections). On a structural problem (no opening `---`,
    unterminated block, a non-`key:` top-level line) returns (None, reason).
    stdlib only — no pyyaml dependency.
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
            # `key:` with no inline value and no block indicator: either an
            # empty scalar or a YAML block sequence (`- item` lines, at column
            # 0 or indented). Non-empty iff at least one sequence item has
            # content; a plain indented continuation with no `- ` marker also
            # counts as content (SPEC-030 parser subset).
            i += 1
            seq_has_content = False
            while i < end:
                nxt = lines[i]
                if not nxt.strip():
                    i += 1
                    continue
                stripped = nxt.lstrip()
                if nxt[0] in (" ", "\t") or stripped.startswith("- "):
                    item = stripped[2:].strip() if stripped.startswith("- ") else stripped
                    if item:
                        seq_has_content = True
                    i += 1
                    continue
                break  # column-0, not a sequence item -- ends the block
            mapping[key] = "x" if seq_has_content else ""
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


def check_fences(text):
    """Shared bash-fence check (Surface/Agent/Sub-doc): every top-level
    ```bash fence must pass `bash -n`, unless tagged `bash template`. Returns
    (ok, reason)."""
    for start, block_lines, info in extract_blocks(text):
        # `bash template` fences are documentation-shape (angle-bracket
        # placeholders / elided pseudocode) -- skip the syntax check for them.
        if is_template_fence(info):
            continue
        ok, stderr = bash_n(source="\n".join(block_lines) + "\n")
        if not ok:
            end = start + len(block_lines) - 1
            detail = stderr.splitlines()[-1] if stderr else "bash -n failed"
            return False, f"bash fence at lines {start}-{end} fails bash -n: {detail}"
    return True, ""


def _read_text(path):
    """Read a target file's text. Returns (text, None) or (None, reason)."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read(), None
    except OSError as e:
        return None, f"cannot read: {e}"


def _base_frontmatter(text):
    """Parse frontmatter and enforce the Surface-level name/description
    check shared by check_md and check_agent (SPEC-003: one copy, not two).

    Returns (mapping, error). `mapping` is None on any defect -- unparseable
    structure (see parse_frontmatter) or a missing/empty `name`/`description`
    -- with `error` naming the reason. On success, `mapping` is the parsed
    frontmatter and `error` is None.
    """
    mapping, err = parse_frontmatter(text)
    if mapping is None:
        return None, err
    for field in ("name", "description"):
        if field not in mapping:
            return None, f"frontmatter missing `{field}`"
        if not mapping[field]:
            return None, f"frontmatter `{field}` is empty"
    return mapping, None


def check_md(path):
    """Check set for a Surface .md. Returns (ok, reason)."""
    text, err = _read_text(path)
    if text is None:
        return None, err

    mapping, err = _base_frontmatter(text)
    if mapping is None:
        return False, err

    return check_fences(text)


def check_agent(path):
    """Check set for an Agent `agents/*.md`. Returns (ok, reason).

    Applies the Surface frontmatter parse + fence check, plus the five
    SPEC-003 agent fields: name/description (non-empty), tools (key present,
    value MAY be empty), model and effort (value-domain checked; MUST NOT be
    compared against the SPEC-003 Tier table -- value domain only).
    """
    text, err = _read_text(path)
    if text is None:
        return None, err

    mapping, err = _base_frontmatter(text)
    if mapping is None:
        return False, err

    if "tools" not in mapping:
        return False, "frontmatter missing `tools`"

    if "model" not in mapping:
        return False, "frontmatter missing `model`"
    if mapping["model"] not in AGENT_MODELS:
        return False, (
            f"frontmatter `model` is {mapping['model']!r} "
            "(want opus|sonnet|haiku)"
        )

    if "effort" not in mapping:
        return False, "frontmatter missing `effort`"
    if mapping["effort"] not in AGENT_EFFORTS:
        return False, (
            f"frontmatter `effort` is {mapping['effort']!r} "
            "(want low|medium|high|xhigh)"
        )

    return check_fences(text)


def check_subdoc(path):
    """Check set for a Sub-doc (`skills/**/*.md`, not `SKILL.md`). Fence check
    only -- a sub-doc is loaded by reference, not directly, so it carries no
    frontmatter requirement. Returns (ok, reason)."""
    text, err = _read_text(path)
    if text is None:
        return None, err
    return check_fences(text)


def check_sh(path, invoke_flags=False):
    """Check set for a Script (`*.sh`, `githooks/*`). Returns (ok, reason).

    The MUST-level check is `bash -n` (parse-only). The SPEC-030 `--help`/
    `--check` invocation is a MAY, and is gated behind `invoke_flags` (the
    harness `--invoke-flags` opt-in), OFF by default, and never applies to a
    test script or a githook (their bodies mutate state -- never invoke those).
    Rationale for the default-off gate: this repo's dominant help convention
    routes `--help` to a `usage()` that prints to stderr and exits non-zero (a
    usage-error exit, not a help-success exit), and `--check` on some scripts
    (e.g. local-agent/run.sh) is a value-taking argument, not a boolean
    self-test. Auto-invoking those as a pass/fail gate would fail the live tree
    and make the gate un-landable, contradicting the "gate lands green"
    mandate (SPEC-030 MUST, release-gate wiring). Keeping the capability behind
    an explicit opt-in preserves it for scripts that do implement a zero-exit
    `--help`/`--check`, and for the bite-test.
    """
    text, err = _read_text(path)
    if text is None:
        return None, err

    ok, stderr = bash_n(path=path)
    if not ok:
        detail = stderr.splitlines()[-1] if stderr else "bash -n failed"
        return False, f"bash -n: {detail}"

    # Opt-in --help/--check invocation ONLY when enabled, the script declares
    # the flag, and it is neither a test script nor a githook. Run under a
    # timeout in an isolated mktemp -d cwd so an errant script can't touch the
    # repo tree.
    if invoke_flags:
        base = os.path.basename(path)
        parent = os.path.basename(os.path.dirname(path))
        is_test = bool(TEST_SH_RE.match(base))
        is_githook = parent == "githooks"
        if not is_test and not is_githook:
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


def classify(path):
    """Classify a path by shape into a target kind (SPEC-030 Discovery). Both
    no-arg discovery and the explicit target-list form use this single
    classifier so their behavior can never diverge.

    `path` MUST be repo-relative (see check_path/resolve_root). Classification
    is shape-based (a `skills` segment, an `agents`/`githooks` parent) so an
    absolute path would false-match whenever some *ancestor* of the repo root
    happens to be named `skills`, `agents` or `githooks` (for example a
    scratch tree at `$TMP/skills/repo`) -- repo-relative is the only path form
    that can't carry that ancestry.

    - a `.sh` file, or any file whose parent directory is `githooks` -> Script
    - a `.md` whose parent directory is `agents` -> Agent
    - a `.md` below a `skills` segment that is not `skills/<name>/SKILL.md` ->
      Sub-doc
    - any other `.md` -> Surface

    Returns "surface" | "agent" | "subdoc" | "script" | None (unsupported).
    """
    parts = path.replace(os.sep, "/").split("/")
    base = parts[-1]
    parent = parts[-2] if len(parts) >= 2 else ""
    if base.endswith(".sh") or parent == "githooks":
        return "script"
    if not base.endswith(".md"):
        return None
    if parent == "agents":
        return "agent"
    if "skills" in parts[:-1]:
        si = parts.index("skills")
        if base == "SKILL.md" and len(parts) - si == 3:
            return "surface"
        return "subdoc"
    return "surface"


def check_path(path, root, invoke_flags=False):
    """Dispatch one target to its check set via classify() (SPEC-030
    Discovery classifier) -- not by extension.

    `root` anchors classification: `path` is made repo-relative before it
    reaches classify(), so an ancestor directory that happens to share a name
    with a classified shape (`skills`, `agents`, `githooks`) can never leak
    in -- this applies identically to no-arg-discovered paths and to an
    explicit target list (both come through here). Returns (ok, reason); ok
    is None when the file is unreadable/unsupported.
    """
    kind = classify(os.path.relpath(path, root))
    if kind == "surface":
        return check_md(path)
    if kind == "agent":
        return check_agent(path)
    if kind == "subdoc":
        return check_subdoc(path)
    if kind == "script":
        return check_sh(path, invoke_flags=invoke_flags)
    return None, "unsupported target type (expected .md or .sh)"


def _excluded(relparts):
    """A path is excluded from no-arg discovery iff any segment is `fixtures`,
    `.worktrees` or `node_modules` (SPEC-030 DD7) -- the harness's own fixtures
    under tools/smoke/fixtures/ included; narrowed from the earlier blanket
    tools/smoke/** exclusion so tools/smoke/run.sh, tools/smoke/test.sh and the
    runner itself get checked like every other file."""
    return any(seg in ("fixtures", ".worktrees", "node_modules") for seg in relparts)


def _relparts(root, path):
    rel = os.path.relpath(path, root)
    return [] if rel == "." else rel.replace(os.sep, "/").split("/")


def _is_git_worktree(root):
    try:
        proc = subprocess.run(
            ["git", "-C", root, "rev-parse", "--is-inside-work-tree"],
            capture_output=True, text=True,
        )
    except OSError:
        return False
    return proc.returncode == 0 and proc.stdout.strip() == "true"


def _git_scripts(root):
    """Script set via `git ls-files` (tracked plus untracked-not-ignored, so a
    new script runs before it is staged): every path classify()'d "script",
    excluding fixtures/.worktrees/node_modules, skipping index entries absent
    on disk (SPEC-030 Discovery)."""
    proc = subprocess.run(
        ["git", "-C", root, "ls-files", "-z", "--cached", "--others",
         "--exclude-standard"],
        capture_output=True, text=True, check=True,
    )
    found = []
    for rel in proc.stdout.split("\0"):
        if not rel:
            continue
        relparts = rel.split("/")
        if _excluded(relparts):
            continue
        if classify(rel) != "script":
            continue
        p = os.path.join(root, rel)
        if os.path.isfile(p):
            found.append(p)
    return found


def _walk_scripts(root):
    """Sorted filesystem walk fallback for Script discovery when root is not a
    git work tree (SPEC-030 Discovery fallback; mktemp `--root` fixture
    trees)."""
    found = []
    for dirpath, dirs, files in os.walk(root):
        dirs.sort()
        relparts = _relparts(root, dirpath)
        if _excluded(relparts):
            dirs[:] = []  # prune the subtree
            continue
        for name in sorted(files):
            rel = "/".join(relparts + [name]) if relparts else name
            if classify(rel) == "script":
                found.append(os.path.join(dirpath, name))
    return found


def discover(root):
    """No-arg discovery of all four target kinds (SPEC-030 Discovery).

    Surface: commands/*.md + skills/<name>/SKILL.md. Agent: agents/*.md.
    Sub-doc: every other skills/**/*.md. Script: git ls-files (tracked plus
    untracked-not-ignored) filtered to *.sh or a githooks/ parent, or a sorted
    filesystem-walk fallback when root is not a git work tree. Excludes any
    path with a fixtures/.worktrees/node_modules segment. Returns a flat list
    of paths, sorted within each kind, in kind order Surface/Agent/Sub-doc/
    Script.
    """
    surfaces = []
    agents = []
    subdocs = []

    cmd_dir = os.path.join(root, "commands")
    if os.path.isdir(cmd_dir):
        for name in sorted(os.listdir(cmd_dir)):
            if name.endswith(".md"):
                surfaces.append(os.path.join(cmd_dir, name))

    agents_dir = os.path.join(root, "agents")
    if os.path.isdir(agents_dir):
        for name in sorted(os.listdir(agents_dir)):
            if name.endswith(".md"):
                agents.append(os.path.join(agents_dir, name))

    skills_dir = os.path.join(root, "skills")
    for dirpath, dirs, files in os.walk(skills_dir):
        dirs.sort()
        relparts = _relparts(root, dirpath)
        if _excluded(relparts):
            dirs[:] = []  # prune the subtree
            continue
        for name in sorted(files):
            if not name.endswith(".md"):
                continue
            p = os.path.join(dirpath, name)
            if classify(os.path.relpath(p, root)) == "surface":
                surfaces.append(p)
            else:
                subdocs.append(p)

    if _is_git_worktree(root):
        scripts = _git_scripts(root)
    else:
        scripts = _walk_scripts(root)

    return sorted(surfaces) + sorted(agents) + sorted(subdocs) + sorted(scripts)


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
                         "(opt-in; off by default -- see check_sh docstring)")
    ap.add_argument("paths", nargs="*", help="explicit paths to check")
    try:
        args = ap.parse_args(argv)
    except SystemExit as e:
        code = e.code if isinstance(e.code, int) else 64
        return 0 if code == 0 else 64

    # Resolved once and reused as the classification anchor for both the
    # no-arg and explicit-target forms (see check_path).
    root = resolve_root(args.root)

    if args.paths:
        targets = args.paths
        explicit = True
    else:
        targets = discover(root)
        explicit = False

    results = []
    failed = 0
    checked = 0
    for path in targets:
        if not os.path.isfile(path) or not os.access(path, os.R_OK):
            print(f"warn: skipping unreadable path: {path}", file=sys.stderr)
            continue
        ok, reason = check_path(path, root, invoke_flags=args.invoke_flags)
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
