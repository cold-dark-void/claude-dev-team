#!/usr/bin/env python3
"""Require one extraction entry for every input memory id.

usage: check-extraction.py <id> [id...]
stdin: JSON {"extractions":[{"memory_id":N,"claims":[...]}]}
"""

import json
import sys


def main(argv):
    if not argv:
        sys.stderr.write("usage: check-extraction.py <id> [id...]\n")
        return 64
    try:
        ids = [int(x) for x in argv]
    except ValueError:
        sys.stderr.write("Error: memory id must be an integer\n")
        return 64
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        sys.stderr.write("extraction is not JSON: %s\n" % exc)
        return 1
    got = []
    for entry in data.get("extractions", []):
        got.append(entry.get("memory_id"))
    if len(got) != len(set(got)) or sorted(got) != sorted(ids):
        sys.stderr.write("extraction must list every input memory id once\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
