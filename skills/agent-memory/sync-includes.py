#!/usr/bin/env python3
"""Expand and verify managed <!-- include --> regions for shared markdown partials.

A managed region looks like:

    <!-- include: <partial-relpath> agent=<X> -->
    ...region body (generated)...
    <!-- /include -->

The region body MUST equal the partial expanded for agent <X>:
  * strip the partial's leading HTML-comment block (everything up to and including
    the first line that is exactly `-->`),
  * strip surrounding blank lines,
  * replace every literal `<AGENT>` with <X>.

This is the single mechanism that keeps the agent-memory protocol (and, later, the
AGENTS.md rule-body partials) byte-identical across all their copies — drift becomes
impossible because `/release` runs `check` and fails the release on any mismatch.

Usage:
  sync-includes.py apply [files...]   # rewrite every managed region from its partial
  sync-includes.py check [files...]   # verify; exit 1 (and print a diff) on any drift

With no files, scans the repo's agents/ and skills/ for markdown carrying markers.
Run from the repo root (or pass --root). The partial path in each marker is resolved
relative to the repo root and MUST stay under it (`../` and absolute paths are
rejected). A missing partial and an open/close pairing mismatch are hard errors:
apply aborts before writing anything (rv-w3-25).
"""
import os
import re
import sys
import glob
import difflib

OPEN_RE = re.compile(r'<!-- include: (?P<partial>\S+) agent=(?P<agent>\S+) -->')
CLOSE_MARKER = '<!-- /include -->'


class IncludeError(Exception):
    """A marker, pairing, or partial problem that must abort the run."""


def expand(root, partial_rel, agent):
    if partial_rel.startswith('~'):
        raise IncludeError(f"partial path must stay under the repo root: {partial_rel}")
    if os.path.isabs(partial_rel):
        raise IncludeError(f"absolute partial path is not allowed: {partial_rel}")
    if '..' in partial_rel.replace('\\', '/').split('/'):
        raise IncludeError(f"partial path must not contain '..': {partial_rel}")
    root_real = os.path.realpath(root)
    path = os.path.join(root, *partial_rel.replace('\\', '/').split('/'))
    if not os.path.isfile(path):
        raise IncludeError(f"partial not found: {partial_rel} (looked for {path})")
    path_real = os.path.realpath(path)
    if path_real != root_real and not path_real.startswith(root_real + os.sep):
        raise IncludeError(f"partial resolves outside the repo root: {partial_rel}")
    text = open(path, encoding='utf-8').read()
    lines = text.split('\n')
    start = 0
    for i, line in enumerate(lines):
        if line.strip() == '-->':
            start = i + 1
            break
    body = '\n'.join(lines[start:]).strip('\n')
    return body.replace('<AGENT>', agent)


def parse_regions(src, filename):
    """Return [(open_lineno, close_lineno, partial, agent, body_lines)].

    A line opens a region only when the open marker ends the line, and closes
    only when the line is exactly the close marker (modulo indentation) — the
    same shapes the managed-region grammar accepts. Prose mentions of the
    markers (backticked, mid-sentence, or with trailing text) are ignored.
    """
    regions = []
    open_lineno = open_partial = open_agent = None
    body_lines = []
    for idx, line in enumerate(src.split('\n')):
        m = OPEN_RE.search(line)
        if m is not None and m.end() == len(line):
            if open_lineno is not None:
                raise IncludeError(
                    f"{filename}:{idx + 1}: unclosed region '{open_partial}' opened at "
                    f"line {open_lineno} — every '<!-- include:' needs its own "
                    f"'<!-- /include -->' before the next open"
                )
            open_lineno, open_partial, open_agent = idx + 1, m.group('partial'), m.group('agent')
            body_lines = []
            continue
        if line.strip() == CLOSE_MARKER:
            if open_lineno is None:
                raise IncludeError(
                    f"{filename}:{idx + 1}: '{CLOSE_MARKER}' without a matching open marker"
                )
            regions.append((open_lineno, idx + 1, open_partial, open_agent, body_lines))
            open_lineno = open_partial = open_agent = None
            body_lines = []
            continue
        if open_lineno is not None:
            body_lines.append(line)
    if open_lineno is not None:
        raise IncludeError(
            f"{filename}: unclosed region '{open_partial}' opened at line {open_lineno} "
            f"— missing '{CLOSE_MARKER}'"
        )
    return regions


def default_files(root):
    out = []
    for pat in ('agents/*.md', 'skills/**/*.md', 'commands/**/*.md', 'AGENTS.md'):
        out += glob.glob(os.path.join(root, pat), recursive=True)
    return [f for f in sorted(set(out)) if '<!-- include:' in open(f, encoding='utf-8').read()]


USAGE = """Usage: sync-includes.py [check|apply] [--root ROOT] [files...]

  check  verify managed include regions match their partials (default); exit 1 on drift
  apply  rewrite every managed region from its partial

With no files, scans the repo's agents/ and skills/ for markdown carrying markers.
Exit 64 on an unrecognised mode or bad usage; exit 1 on drift or a marker/partial
error (missing partial, path escape, unclosed region)."""


def main():
    args = sys.argv[1:]
    root = '.'
    if '--root' in args:
        i = args.index('--root')
        if i + 1 >= len(args):
            print("sync-includes.py: --root requires a value", file=sys.stderr)
            print(USAGE, file=sys.stderr)
            sys.exit(64)
        root = args[i + 1]
        del args[i:i + 2]

    if args and args[0] in ('-h', '--help'):
        print(USAGE)
        sys.exit(0)

    mode = args[0] if args else 'check'
    if mode not in ('check', 'apply'):
        print(f"sync-includes.py: unrecognised mode: {mode}", file=sys.stderr)
        print(USAGE, file=sys.stderr)
        sys.exit(64)

    files = args[1:] if len(args) > 1 else default_files(root)

    drift = 0
    changed = 0
    rewrites = []  # (path, new_text) — collected first so an error aborts before any write
    for f in files:
        src = open(f, encoding='utf-8').read()
        try:
            regions = parse_regions(src, f)
            expansions = [
                (r[0], r[1], expand(root, r[2], r[3]), r[2], r[3]) for r in regions
            ]
        except IncludeError as e:
            print(f"sync-includes.py: error: {e}", file=sys.stderr)
            sys.exit(1)

        lines = src.split('\n')
        # Reverse order: an apply mutation shifts later line numbers, so rewrite
        # each region from the bottom up while `have` slices still see the
        # original bytes of the not-yet-rewritten regions above.
        for open_ln, close_ln, want, partial, agent in sorted(
                expansions, key=lambda r: r[0], reverse=True):
            have = '\n'.join(lines[open_ln:close_ln - 1]).strip('\n')
            if have != want:
                if mode == 'check':
                    drift += 1
                    print(f"DRIFT: {f} (agent={agent}, partial={partial})")
                    for line in difflib.unified_diff(
                            have.split('\n'), want.split('\n'),
                            fromfile='in-file', tofile='partial-expanded', lineterm=''):
                        print('  ' + line)
                else:
                    changed += 1
            if mode == 'apply':
                lines[open_ln:close_ln - 1] = want.split('\n') if want else []
        if mode == 'apply':
            new = '\n'.join(lines)
            if new != src:
                rewrites.append((f, new))

    if mode == 'apply':
        for f, new in rewrites:
            open(f, 'w', encoding='utf-8').write(new)
        print(f"apply: rewrote {changed} region(s).")
    else:
        if drift:
            print(f"\n{drift} managed include region(s) drifted from their partial.", file=sys.stderr)
            sys.exit(1)
        print("All managed include regions match their partials.")


if __name__ == '__main__':
    main()
