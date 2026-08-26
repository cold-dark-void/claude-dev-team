#!/usr/bin/env python3
"""summarize-transcript — Meaning-channel overlay CLI (SPEC-036 M15).

Detect: transcript-sync.sh --check --sid <sid> only (no --transcript).
Hit: overlay oversized parent main.md turns, or restore one turn.
Miss: exit 1 (or 64 usage); no write. Fail-closed.
MUST NOT import/run the recorder. MUST NOT write meaning-tail / Channel sidecars / agents / meta.
"""
from __future__ import annotations

import hashlib
import os
import re
import shlex
import subprocess
import sys
import tempfile

_HERE = os.path.dirname(os.path.abspath(__file__))
SYNC_SH = os.path.join(_HERE, "transcript-sync.sh")
REAPPLY_SH = os.path.join(_HERE, "reapply-overlay.sh")

THRESHOLD = 8192
HEADING_RE = re.compile(r"^## (user|assistant)[ \t]*$")
REF_RE = re.compile(r"^>\s*@")
VREF_RE = re.compile(r"^>\s*@verbatim/")
TURN_ID_RE = re.compile(r"^T[0-9]{6}$")


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
    sys.stderr.write("summarize-transcript: " + msg + "\n")
    sys.stderr.write("usage: summarize-transcript.sh --sid <sid> [--restore <turn-id>]\n")
    sys.exit(64)


def miss_exit(reason: str) -> None:
    sys.stderr.write("summarize-transcript: " + reason + "\n")
    sys.exit(1)


def reject_sid_shape(sid: str) -> bool:
    return not sid or sid in (".", "..") or "/" in sid


def _flag_value(
    argv: list[str], i: int, n: int, current: str | None, need: str
) -> tuple[str, int]:
    flag = argv[i]
    if i + 1 >= n:
        usage_exit(flag + " requires a " + need)
    if current is not None:
        usage_exit("duplicate " + flag)
    return argv[i + 1], i + 2


def parse_argv(argv: list[str] | None = None) -> tuple[str, str | None]:
    if argv is None:
        argv = sys.argv[1:]
    sid: str | None = None
    restore: str | None = None
    i = 0
    n = len(argv)
    while i < n:
        a = argv[i]
        if a == "--sid":
            sid, i = _flag_value(argv, i, n, sid, "value")
            continue
        if a == "--restore":
            restore, i = _flag_value(argv, i, n, restore, "turn-id")
            continue
        if a.startswith("-"):
            usage_exit("unknown flag: " + a)
        usage_exit("unexpected argument: " + a)
    if sid is None:
        usage_exit("--sid is required")
    if reject_sid_shape(sid):
        usage_exit("bad sid")
    if restore is not None and not TURN_ID_RE.fullmatch(restore):
        usage_exit("bad turn-id")
    return sid, restore


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


def require_ok(sid: str) -> None:
    status = mirror_check(sid)
    if status is None:
        miss_exit("no matching --check line")
    if status != "ok":
        miss_exit("status=" + status)


def split_file(text: str) -> tuple[str, list[str]]:
    lines = text.splitlines(keepends=True)
    starts = [i for i, line in enumerate(lines) if HEADING_RE.match(_raw_line(line))]
    if not starts:
        return "".join(lines), []
    preamble = "".join(lines[: starts[0]])
    bounds = starts + [len(lines)]
    blocks = ["".join(lines[a:b]) for a, b in zip(bounds, bounds[1:])]
    return preamble, blocks


def meaning_payload(block: str) -> str:
    lines = block.splitlines(keepends=True)
    if not lines:
        return ""
    return "".join(s for s in lines[1:] if not REF_RE.match(_raw_line(s)))


def has_verbatim_ref(block: str) -> bool:
    return any(VREF_RE.match(s) for s in block.splitlines())


def turn_id_for(n: int) -> str:
    return f"T{n:06d}"


def ordinal_from_turn_id(tid: str) -> int:
    return int(tid[1:], 10)


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _unlink_quiet(path: str) -> None:
    try:
        os.unlink(path)
    except OSError:
        pass


def atomic_write_bytes(path: str, data: bytes) -> None:
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".", suffix=".tmp", dir=d)
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
        tmp = None
    finally:
        if tmp is not None:
            _unlink_quiet(tmp)


def atomic_write_text(path: str, data: str) -> None:
    atomic_write_bytes(path, data.encode("utf-8"))


def update_cursor_field3(cursor_path: str, sha: str) -> None:
    try:
        with open(cursor_path, "r", encoding="utf-8", newline="") as fh:
            line = fh.readline()
    except OSError as e:
        miss_exit("cursor read failed: " + str(e))
    parts = _raw_line(line).split("\t")
    if len(parts) < 2:
        miss_exit("cursor malformed")
    atomic_write_text(cursor_path, "\t".join([parts[0], parts[1], sha] + parts[3:]) + "\n")


def run_summarizer(payload_bytes: bytes) -> bytes | None:
    cmd = (os.environ.get("SUMMARIZE_TRANSCRIPT_CMD") or "").strip()
    if not cmd:
        return None
    try:
        args = shlex.split(cmd)
    except ValueError:
        return None
    if not args:
        return None
    try:
        proc = subprocess.run(
            args,
            shell=False,
            input=payload_bytes,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except OSError:
        return None
    out = proc.stdout or b""
    if proc.returncode != 0 or not out or len(out) >= len(payload_bytes):
        return None
    return out


def reapply(sid_dir: str) -> None:
    if not os.path.isfile(REAPPLY_SH):
        miss_exit("reapply-overlay.sh not found")
    proc = _run_bash([REAPPLY_SH, sid_dir], "reapply-overlay failed: ")
    if proc.returncode != 0:
        err = (proc.stderr or "").strip()
        miss_exit("reapply-overlay failed" + (": " + err if err else ""))


def _self_vref_re(turn_id: str) -> re.Pattern[str]:
    return re.compile(r"^>\s*@verbatim/" + re.escape(turn_id) + r"\.txt[ \t]*$")


def restore_block(block: str, turn_id: str, payload: str) -> str:
    lines = block.splitlines(keepends=True)
    if not lines:
        return payload
    heading = lines[0]
    self_re = _self_vref_re(turn_id)
    out: list[str] = [heading]
    inserted = False
    for s in lines[1:]:
        raw = _raw_line(s)
        if self_re.match(raw):
            continue
        if REF_RE.match(raw):
            out.append(s)
            continue
        if not inserted:
            out.append(payload)
            inserted = True
    if not inserted:
        out.append(payload)
    return "".join(out)


def overlay(sid: str, sid_dir: str, main_md: str, text: str) -> int:
    blocks = split_file(text)[1]
    replacements: list[tuple[str, bytes, bytes]] = []
    for n, block in enumerate(blocks, start=1):
        if has_verbatim_ref(block):
            continue
        payload = meaning_payload(block)
        payload_bytes = payload.encode("utf-8")
        if len(payload_bytes) <= THRESHOLD:
            continue
        summary = run_summarizer(payload_bytes)
        if summary is None:
            continue
        replacements.append((turn_id_for(n), payload_bytes, summary))
    if not replacements:
        sys.stdout.write("sid=" + sid + " replaced=0\n")
        return 0
    vdir = os.path.join(sid_dir, "verbatim")
    os.makedirs(vdir, exist_ok=True)
    try:
        for tid, payload_bytes, summary in replacements:
            atomic_write_bytes(os.path.join(vdir, tid + ".txt"), payload_bytes)
            atomic_write_bytes(os.path.join(vdir, tid + ".sum"), summary)
        reapply(sid_dir)
        update_cursor_field3(os.path.join(sid_dir, "cursor"), sha256_file(main_md))
    except OSError as e:
        miss_exit("write failed: " + str(e))
    sys.stdout.write("sid=" + sid + " replaced=" + str(len(replacements)) + "\n")
    return 0


def restore(sid: str, sid_dir: str, main_md: str, text: str, turn_id: str) -> int:
    n = ordinal_from_turn_id(turn_id)
    txt_path = os.path.join(sid_dir, "verbatim", turn_id + ".txt")
    sum_path = os.path.join(sid_dir, "verbatim", turn_id + ".sum")
    preamble, blocks = split_file(text)
    if n < 1 or n > len(blocks):
        miss_exit("turn-id not found")
    if not os.path.isfile(txt_path):
        miss_exit("turn-id not overlaid")
    try:
        with open(txt_path, "rb") as fh:
            payload_bytes = fh.read()
    except OSError as e:
        miss_exit("verbatim read failed: " + str(e))
    try:
        payload = payload_bytes.decode("utf-8")
    except UnicodeDecodeError:
        miss_exit("verbatim not utf-8")
    new_blocks = list(blocks)
    new_blocks[n - 1] = restore_block(blocks[n - 1], turn_id, payload)
    new_text = preamble + "".join(new_blocks)
    try:
        atomic_write_text(main_md, new_text)
        _unlink_quiet(txt_path)
        _unlink_quiet(sum_path)
        update_cursor_field3(os.path.join(sid_dir, "cursor"), sha256_file(main_md))
    except OSError as e:
        miss_exit("write failed: " + str(e))
    sys.stdout.write("sid=" + sid + " restored=" + turn_id + "\n")
    return 0


def main(argv: list[str] | None = None) -> int:
    sid, restore_id = parse_argv(argv)
    require_ok(sid)
    root = store_root()
    sid_dir = os.path.join(root, sid)
    main_md = os.path.join(sid_dir, "main.md")
    try:
        with open(main_md, "r", encoding="utf-8", newline="") as fh:
            text = fh.read()
    except OSError:
        miss_exit("main.md missing")
    if restore_id is not None:
        return restore(sid, sid_dir, main_md, text, restore_id)
    return overlay(sid, sid_dir, main_md, text)


if __name__ == "__main__":
    sys.exit(main())
