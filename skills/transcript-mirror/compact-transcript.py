#!/usr/bin/env python3
"""compact-transcript — bounded Meaning-tail CLI (SPEC-036 M14).

Detect: transcript-sync.sh --check --sid <sid> (no --transcript).
Hit: atomically write <store-root>/<sid>.meaning-tail.md; stdout = abs path.
Miss: exit 1 (or 64 usage); no tail create/update. Fail-closed.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

try:
    from strip_main import strip_mirror_main
except Exception:
    sys.stderr.write("compact-transcript: strip_main.py not found\n")
    sys.exit(1)

SYNC_SH = os.path.join(_HERE, "transcript-sync.sh")
LOCK_SH = os.path.join(_HERE, "sid-lock.sh")
DISCOVER_SH = os.path.abspath(os.path.join(_HERE, "..", "handoff", "discover-warm.sh"))
CAP = 32768
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
try:
    from mirrorlib import HEADING_RE
except Exception:
    HEADING_RE = re.compile(r"^## (user|assistant)[ \t]*$")


def store_root() -> str:
    env = os.environ.get("TRANSCRIPT_MIRROR_ROOT")
    if env:
        return os.path.abspath(os.path.expanduser(env))
    return os.path.join(os.path.expanduser("~"), ".claude", "transcript")


def _raw_line(line: str) -> str:
    if line.endswith("\r\n"):
        return line[:-2]
    if line.endswith("\n") or line.endswith("\r"):
        return line[:-1]
    return line


def usage_exit(msg: str) -> None:
    sys.stderr.write("compact-transcript: " + msg + "\n")
    sys.stderr.write("usage: compact-transcript.sh [<sid>]\n")
    sys.exit(64)


def miss_exit(reason: str) -> None:
    sys.stderr.write("compact-transcript: " + reason + "\n")
    sys.exit(1)


def parse_argv(argv: list[str] | None = None) -> str | None:
    if argv is None:
        argv = sys.argv[1:]
    sid: str | None = None
    for a in argv:
        if a.startswith("-"):
            usage_exit("unknown flag: " + a)
        if sid is not None:
            usage_exit("unexpected argument: " + a)
        sid = a
    return sid


def reject_sid_shape(sid: str) -> bool:
    return not sid or sid in (".", "..") or "/" in sid


def _run_bash(args: list[str], os_err: str):
    try:
        return subprocess.run(
            ["bash"] + args,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except OSError as e:
        miss_exit(os_err + str(e))


def resolve_bare_sid() -> str:
    if not os.path.isfile(DISCOVER_SH):
        miss_exit("discover-warm.sh not found")
    proc = _run_bash([DISCOVER_SH], "discover-warm failed: ")
    err = proc.stderr or ""
    if err:
        sys.stderr.write(err)
        if not err.endswith("\n"):
            sys.stderr.write("\n")
    lines = (proc.stdout or "").splitlines()
    if proc.returncode != 0 or not lines or not lines[0]:
        miss_exit("unresolvable sid")
    return lines[0]


def mirror_check(sid: str) -> str | None:
    """Status token for sid from --check stdout, or None if no matching line."""
    if not os.path.isfile(SYNC_SH):
        miss_exit("transcript-sync.sh not found")
    proc = _run_bash([SYNC_SH, "--check", "--sid", sid], "--check failed: ")
    found: str | None = None
    for line in (proc.stdout or "").splitlines():
        got_sid = got_status = None
        for tok in line.split():
            if tok.startswith("sid="):
                got_sid = tok[4:]
            elif tok.startswith("status="):
                got_status = tok[7:]
        if got_sid != sid or got_status is None:
            continue
        if got_status == "ok":
            return "ok"
        found = got_status
    return found


def split_turn_blocks(text: str) -> list[str]:
    lines = text.splitlines(keepends=True)
    starts = [i for i, line in enumerate(lines) if HEADING_RE.match(_raw_line(line))]
    if not starts:
        return []
    starts.append(len(lines))
    return ["".join(lines[a:b]) for a, b in zip(starts, starts[1:])]


def utf8_prefix(text: str, max_bytes: int) -> str:
    if max_bytes <= 0:
        return ""
    raw = text.encode("utf-8")
    if len(raw) <= max_bytes:
        return text
    return raw[:max_bytes].decode("utf-8", errors="ignore")


def clip_newest_block(block: str, cap: int) -> str:
    lines = block.splitlines(keepends=True)
    if not lines:
        return ""
    heading = lines[0]
    body = "".join(lines[1:])
    h_b = len(heading.encode("utf-8"))
    if h_b >= cap:
        return utf8_prefix(heading, cap)
    return heading + utf8_prefix(body, cap - h_b)


def bound_tail(text: str, cap: int = CAP) -> str:
    blocks = split_turn_blocks(text)
    if not blocks:
        return ""
    for i in range(len(blocks)):
        candidate = "".join(blocks[i:])
        if len(candidate.encode("utf-8")) <= cap:
            return candidate
    return clip_newest_block(blocks[-1], cap)


def freshness_footer(root: str, sid: str, status: str) -> str:
    """E7: one HTML comment so the operator can see how fresh the tail is."""
    ident = ""
    lag_n = 0
    cursor = os.path.join(root, sid, "cursor")
    try:
        with open(cursor, encoding="utf-8") as fh:
            parts = fh.readline().rstrip("\n").split("\t")
    except OSError:
        parts = []
    if parts and parts[0]:
        ident = parts[0]
    src = parts[1] if len(parts) > 1 else ""
    line_no = 0
    if len(parts) > 3 and parts[3].isdigit():
        line_no = int(parts[3])
    if src and line_no and os.path.isfile(src):
        try:
            with open(src, encoding="utf-8", errors="replace") as fh:
                total = sum(1 for _ in fh)
            lag_n = max(total - line_no, 0)
        except OSError:
            lag_n = 0
    elif status != "ok":
        lag_n = 0
    return "<!-- mirror cursor: %s, lag: %d lines -->\n" % (ident, lag_n)


def atomic_write(path: str, data: str) -> None:
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(prefix=".meaning-tail.", suffix=".tmp", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
        tmp = None
    finally:
        if tmp is not None:
            try:
                os.unlink(tmp)
            except OSError:
                pass


def main(argv: list[str] | None = None) -> int:
    bare = False
    sid = parse_argv(argv)
    if sid is None:
        bare = True
        sid = resolve_bare_sid()
        if reject_sid_shape(sid):
            miss_exit("unresolvable sid")
    elif reject_sid_shape(sid):
        usage_exit("bad sid")

    status = mirror_check(sid)
    if status is None:
        miss_exit("no matching --check line")
    # Positional <sid> still requires status=ok. Bare/live accepts lag and
    # in-progress when main.md exists (CDT-308). The footer marks the cursor.
    if status != "ok" and not (bare and status in ("lag", "in-progress")):
        miss_exit("status=" + status)

    root = store_root()
    try:
        held = subprocess.run(["bash", LOCK_SH, "acquire", root, sid]).returncode == 0
    except Exception:
        held = False
    if not held:
        miss_exit("lock busy")
    os.environ["TM_LOCK_HELD"] = sid
    try:
        main_md = os.path.join(root, sid, "main.md")
        try:
            with open(main_md, "r", encoding="utf-8") as fh:
                raw_main = fh.read()
        except OSError:
            miss_exit("main.md missing")

        footer = freshness_footer(root, sid, status or "")
        foot_b = len(footer.encode("utf-8"))
        # One spare byte so a missing trailing newline still fits with the footer.
        room = CAP - foot_b - 1
        if room < 1:
            miss_exit("bound exceeded")
        tail = bound_tail(strip_mirror_main(raw_main), room)
        if not tail.strip():
            miss_exit("empty after strip")
        if not tail.endswith("\n"):
            tail += "\n"
        tail = tail + footer
        if len(tail.encode("utf-8")) > CAP:
            miss_exit("bound exceeded")

        dest = os.path.join(root, sid + ".meaning-tail.md")
        dest_abs = os.path.abspath(dest)
        sid_dir = os.path.abspath(os.path.join(root, sid)) + os.sep
        if dest_abs.startswith(sid_dir):
            miss_exit("refusing write inside sid dir")
        try:
            atomic_write(dest_abs, tail)
        except OSError as e:
            miss_exit("write failed: " + str(e))

        sys.stdout.write(dest_abs + "\n")
        return 0
    finally:
        os.environ.pop("TM_LOCK_HELD", None)
        subprocess.run(["bash", LOCK_SH, "release", root, sid])


if __name__ == "__main__":
    sys.exit(main())
