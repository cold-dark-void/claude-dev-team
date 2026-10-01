#!/usr/bin/env python3
"""One hashing pass for transcript-mirror.sh.

index: stdin is one jq -R -S -c line per source line. Writes ident rows and
a .pos sidecar (line_no, 1-based byte offset, ident) for the last identity.
next-off: print the 1-based byte after the line that starts at OFF, and
whether any bytes remain.
"""
from __future__ import annotations

import hashlib
import sys


def index_mode(src: str, dest: str) -> int:
    last_n = 0
    last_off = 0
    last_id = ""
    n = 0
    with open(src, "rb") as raw, open(dest, "w", encoding="utf-8") as out:
        for canon in sys.stdin.buffer:
            start = raw.tell()
            if not raw.readline():
                sys.stderr.write("ident-batch: jq row has no source line\n")
                return 1
            n += 1
            line = canon.rstrip(b"\r\n")
            if line.startswith(b"UUID:"):
                ident = line[5:].decode("utf-8", "replace")
            elif line == b"":
                ident = ""
            else:
                ident = "h:" + hashlib.sha256(line + b"\n").hexdigest()
            out.write(ident + "\n")
            if ident:
                last_n = n
                last_off = start + 1
                last_id = ident
    with open(dest + ".pos", "w", encoding="utf-8") as pos:
        pos.write("%s\t%s\t%s\n" % (last_n, last_off, last_id))
    return 0


def next_off(path: str, off: int) -> int:
    with open(path, "rb") as raw:
        raw.seek(max(off - 1, 0))
        raw.readline()
        nxt = raw.tell() + 1
        more = "yes" if raw.read(1) else "no"
    sys.stdout.write("%s\t%s\n" % (nxt, more))
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        return 64
    cmd = argv[1]
    if cmd == "index" and len(argv) == 4:
        return index_mode(argv[2], argv[3])
    if cmd == "next-off" and len(argv) == 4:
        return next_off(argv[2], int(argv[3]))
    return 64


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as exc:
        sys.stderr.write("ident-batch: %s\n" % exc)
        sys.exit(1)
