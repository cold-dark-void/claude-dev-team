#!/usr/bin/env python3
"""Sanitize retro TSV fields and recompute fabrication anchor ids.

The command fence imports these helpers. A newline or tab in proposed text
must not split a row. anchor_id is computed here, not taken from the model.
"""
from __future__ import annotations

import hashlib
import re
import sys

_WS = re.compile(r"[\t\r\n]+")


def sanitize(value: object) -> str:
    if value is None:
        return ""
    text = value if isinstance(value, str) else str(value)
    return _WS.sub(" ", text).strip()


def anchor_id(turn_id: str, claim: str, source: str) -> str:
    raw = "\n".join((sanitize(turn_id), sanitize(claim), sanitize(source)))
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:16]


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[1] == "sanitize":
        sys.stdout.write(sanitize(sys.stdin.read()) + "\n")
        return 0
    if len(argv) >= 5 and argv[1] == "anchor":
        sys.stdout.write(anchor_id(argv[2], argv[3], argv[4]) + "\n")
        return 0
    sys.stderr.write("usage: parse_results.py sanitize | anchor TURN CLAIM SOURCE\n")
    return 64


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
