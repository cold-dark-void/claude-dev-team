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
relative to the repo root.
"""
import os
import re
import sys
import glob
import difflib

MARKER_RE = re.compile(
    r'(?P<head><!-- include: (?P<partial>\S+) agent=(?P<agent>\S+) -->\n)'
    r'(?P<body>.*?)'
    r'(?P<tail>\n?<!-- /include -->)',
    re.S,
)


def expand(root, partial_rel, agent):
    path = os.path.join(root, partial_rel)
    text = open(path, encoding='utf-8').read()
    lines = text.split('\n')
    start = 0
    for i, line in enumerate(lines):
        if line.strip() == '-->':
            start = i + 1
            break
    body = '\n'.join(lines[start:]).strip('\n')
    return body.replace('<AGENT>', agent)


def default_files(root):
    out = []
    for pat in ('agents/*.md', 'skills/**/*.md', 'commands/**/*.md', 'AGENTS.md'):
        out += glob.glob(os.path.join(root, pat), recursive=True)
    return [f for f in sorted(set(out)) if '<!-- include:' in open(f, encoding='utf-8').read()]


USAGE = """Usage: sync-includes.py [check|apply] [--root ROOT] [files...]

  check  verify managed include regions match their partials (default); exit 1 on drift
  apply  rewrite every managed region from its partial

With no files, scans the repo's agents/ and skills/ for markdown carrying markers.
Exit 64 on an unrecognised mode or bad usage."""


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
    for f in files:
        src = open(f, encoding='utf-8').read()

        def repl(m):
            nonlocal drift, changed
            want = expand(root, m.group('partial'), m.group('agent'))
            have = m.group('body').strip('\n')
            if have != want:
                if mode == 'check':
                    drift += 1
                    print(f"DRIFT: {f} (agent={m.group('agent')}, partial={m.group('partial')})")
                    for line in difflib.unified_diff(
                            have.split('\n'), want.split('\n'),
                            fromfile='in-file', tofile='partial-expanded', lineterm=''):
                        print('  ' + line)
                else:
                    changed += 1
            new_body = want if mode == 'apply' else m.group('body').strip('\n')
            return f"{m.group('head')}{new_body}\n<!-- /include -->"

        new = MARKER_RE.sub(repl, src)
        if mode == 'apply' and new != src:
            open(f, 'w', encoding='utf-8').write(new)

    if mode == 'check':
        if drift:
            print(f"\n{drift} managed include region(s) drifted from their partial.", file=sys.stderr)
            sys.exit(1)
        print("All managed include regions match their partials.")
    else:
        print(f"apply: rewrote {changed} region(s).")


if __name__ == '__main__':
    main()
