#!/usr/bin/env python3
"""transcript-sync — catch-up CLI for the Transcript mirror (SPEC-036 M10–M11).

Locate via hosts.py only. Freshness via freshness.sh check (skip exit 9).
Always invoke transcript-mirror.sh --transcript FILE --sid SID.
--check prints a lag report and exits 0. Fail-open: always exit 0.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from typing import Any, Iterable, Optional

_HERE = os.path.dirname(os.path.abspath(__file__))
_PARSE = os.path.abspath(os.path.join(_HERE, "..", "transcript-parse"))
RECORDER = os.path.join(_HERE, "transcript-mirror.sh")
FRESHNESS = os.path.join(_PARSE, "freshness.sh")
CHAT_HISTORY = "chat_history.jsonl"

if _PARSE not in sys.path:
    sys.path.insert(0, _PARSE)

try:
    import hosts as _hosts  # locate only — do not call normalize
except Exception:
    _hosts = None  # type: ignore


def _warn(msg: str) -> None:
    sys.stderr.write("transcript-sync: " + msg + "\n")


def store_root() -> str:
    env = os.environ.get("TRANSCRIPT_MIRROR_ROOT")
    if env:
        return os.path.abspath(os.path.expanduser(env))
    return os.path.join(os.path.expanduser("~"), ".claude", "transcript")


def sid_from_path(path: str) -> Optional[str]:
    """Session id from a source path. Grok chat_history.jsonl uses parent dir."""
    if not path:
        return None
    abs_p = os.path.abspath(path)
    base = os.path.basename(abs_p)
    if base == CHAT_HISTORY or base == "updates.jsonl":
        parent = os.path.basename(os.path.dirname(abs_p))
        return parent or None
    if base.endswith(".jsonl"):
        return base[: -len(".jsonl")] or None
    return None


def resolve_transcript(path: str) -> str:
    """Honor Grok updates.jsonl → sibling chat_history.jsonl (M5)."""
    abs_p = os.path.abspath(os.path.expanduser(path))
    if os.path.basename(abs_p) == "updates.jsonl":
        sibling = os.path.join(os.path.dirname(abs_p), CHAT_HISTORY)
        if os.path.isfile(sibling):
            return sibling
    return abs_p


def locate_source(sid: Optional[str], cwd: str) -> Optional[str]:
    if _hosts is None:
        return None
    if not cwd:
        return None
    for host in getattr(_hosts, "HOSTS", ()):
        try:
            path = _hosts.locate(host, sid, cwd)
        except Exception as e:
            _warn(f"locate host={host} sid={sid} failed: {e}")
            continue
        if path:
            return path
    return None


def freshness_check(path: str) -> int:
    """Return freshness.sh check exit code. 9 = in-progress (skip)."""
    if not os.path.isfile(FRESHNESS):
        _warn(f"freshness.sh missing: {FRESHNESS}")
        return 1
    if not os.path.isfile(path):
        return 1
    try:
        r = subprocess.run(
            ["bash", FRESHNESS, "check", path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        return r.returncode
    except Exception as e:
        _warn(f"freshness check failed: {e}")
        return 1


def record_ident(line: str) -> str:
    raw = line.strip()
    if not raw:
        return ""
    try:
        obj = json.loads(raw)
    except json.JSONDecodeError:
        return ""
    uuid = obj.get("uuid")
    if isinstance(uuid, str) and uuid:
        return uuid
    try:
        # jq -S -c always emits a trailing newline; hash that (M6 / M11).
        canon = json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n"
    except (TypeError, ValueError):
        return ""
    return "h:" + hashlib.sha256(canon.encode("utf-8")).hexdigest()


def last_ident(path: str) -> str:
    ident = ""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                i = record_ident(line)
                if i:
                    ident = i
    except OSError:
        return ""
    return ident


def read_cursor(sid_dir: str) -> tuple[str, str]:
    cursor = os.path.join(sid_dir, "cursor")
    try:
        with open(cursor, encoding="utf-8", errors="replace") as f:
            line = f.readline()
    except OSError:
        return "", ""
    parts = line.rstrip("\n").split("\t")
    ident = parts[0] if parts else ""
    src = parts[1] if len(parts) > 1 else ""
    return ident, src


def existing_sids(root: str) -> list[str]:
    if not os.path.isdir(root):
        return []
    out: list[str] = []
    try:
        names = os.listdir(root)
    except OSError:
        return []
    for name in names:
        if not name or name.startswith("."):
            continue
        if os.path.isdir(os.path.join(root, name)):
            out.append(name)
    out.sort()
    return out


def source_for_sid(sid: str, cwd: str, root: str) -> Optional[str]:
    ident, src = read_cursor(os.path.join(root, sid))
    del ident
    if src and os.path.isfile(src):
        return src
    return locate_source(sid, cwd)


def _walk_command(obj: Any, needle: str) -> bool:
    if isinstance(obj, dict):
        cmd = obj.get("command")
        if isinstance(cmd, str) and needle in cmd:
            return True
        return any(_walk_command(v, needle) for v in obj.values())
    if isinstance(obj, list):
        return any(_walk_command(x, needle) for x in obj)
    return False


def recorder_registered(cwd: str) -> bool:
    """True if any hooks.*.command contains transcript-mirror.sh (M10)."""
    for fname in ("settings.json", "settings.local.json"):
        path = os.path.join(cwd, ".claude", fname)
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, json.JSONDecodeError, UnicodeError):
            continue
        hooks = data.get("hooks") if isinstance(data, dict) else None
        if _walk_command(hooks, "transcript-mirror.sh"):
            return True
    return False


def cwd_sessions(cwd: str) -> list[tuple[str, str]]:
    """All cwd-bucket sessions: enumerate files, locate by sid (never locate None)."""
    found: list[tuple[str, str]] = []
    seen: set[str] = set()
    if _hosts is None or not cwd:
        return found

    def add_located(host: str, sid: str) -> None:
        if not sid or sid in seen:
            return
        try:
            path = _hosts.locate(host, sid, cwd)
        except Exception as e:
            _warn(f"locate host={host} sid={sid} failed: {e}")
            return
        if not path:
            return
        seen.add(sid)
        found.append((sid, resolve_transcript(path)))

    try:
        pdir = _hosts.claude_project_dir(cwd)
    except Exception as e:
        _warn(f"claude_project_dir failed: {e}")
        pdir = ""
    if pdir and os.path.isdir(pdir):
        try:
            names = os.listdir(pdir)
        except OSError as e:
            _warn(f"cannot list {pdir}: {e}")
            names = []
        for name in sorted(names):
            if not name.endswith(".jsonl"):
                continue
            if not os.path.isfile(os.path.join(pdir, name)):
                continue
            add_located("claude", name[: -len(".jsonl")])

    try:
        bucket = _hosts.grok_cwd_bucket(cwd)
    except Exception as e:
        _warn(f"grok_cwd_bucket failed: {e}")
        bucket = ""
    if bucket and os.path.isdir(bucket):
        try:
            names = os.listdir(bucket)
        except OSError as e:
            _warn(f"cannot list {bucket}: {e}")
            names = []
        for name in sorted(names):
            if name in (".", ".."):
                continue
            hist = os.path.join(bucket, name, CHAT_HISTORY)
            if not os.path.isfile(hist):
                continue
            add_located("grok", name)

    return found


def collect_targets(
    sid: Optional[str],
    transcript: Optional[str],
    cwd: str,
    root: str,
    check: bool = False,
) -> list[tuple[str, str]]:
    """Ordered unique (sid, source) jobs."""
    jobs: dict[str, str] = {}

    def add(s: Optional[str], p: Optional[str]) -> None:
        if not s or not p:
            return
        jobs[s] = p

    if sid or transcript:
        src = None
        if transcript:
            src = resolve_transcript(transcript)
        if src is None:
            src = locate_source(sid, cwd)
        use_sid = sid or (sid_from_path(src) if src else None)
        add(use_sid, src)
        return [(k, jobs[k]) for k in jobs]

    if check:
        for s, p in cwd_sessions(cwd):
            add(s, p)
        return [(k, jobs[k]) for k in jobs]

    for s in existing_sids(root):
        add(s, source_for_sid(s, cwd, root))

    if recorder_registered(cwd):
        for s, p in cwd_sessions(cwd):
            if s not in jobs:
                add(s, p)

    return [(k, jobs[k]) for k in jobs]


def lag_status(sid: str, source: str, root: str) -> str:
    if not source or not os.path.isfile(source):
        main = os.path.join(root, sid, "main.md")
        return "missing" if not os.path.isfile(main) else "lag"
    rc = freshness_check(source)
    if rc == 9:
        return "in-progress"
    sid_dir = os.path.join(root, sid)
    if not os.path.isfile(os.path.join(sid_dir, "main.md")):
        return "missing"
    cur, _ = read_cursor(sid_dir)
    last = last_ident(source)
    if not cur:
        return "missing"
    if cur != last:
        return "lag"
    return "ok"


def invoke_recorder(sid: str, transcript: str) -> None:
    """Always pass --sid so Grok chat_history basename is not the store key."""
    if not os.path.isfile(RECORDER):
        _warn(f"recorder missing: {RECORDER}")
        return
    if not sid or not transcript:
        return
    try:
        subprocess.run(
            ["bash", RECORDER, "--transcript", transcript, "--sid", sid],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=os.environ.copy(),
        )
    except Exception as e:
        _warn(f"recorder failed sid={sid}: {e}")


def sync_one(sid: str, source: str, root: str, check: bool) -> None:
    if check:
        status = lag_status(sid, source, root)
        src = source if source else "-"
        sys.stdout.write(f"sid={sid} status={status} source={src}\n")
        return
    if not source or not os.path.isfile(source):
        return
    rc = freshness_check(source)
    if rc == 9:
        return
    if rc != 0:
        return
    invoke_recorder(sid, source)


def parse_args(argv: Optional[Iterable[str]] = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="transcript-sync",
        description="Catch-up CLI for the Transcript mirror (fail-open).",
    )
    p.add_argument("--sid", default=None, help="Session id")
    p.add_argument("--transcript", default=None, help="Source JSONL path")
    p.add_argument("--check", action="store_true", help="Lag report only; exit 0")
    p.add_argument("--cwd", default=None, help="Project directory for locate")
    args, _unknown = p.parse_known_args(list(argv) if argv is not None else None)
    return args


def main(argv: Optional[Iterable[str]] = None) -> int:
    try:
        args = parse_args(argv)
        cwd = os.path.abspath(os.path.expanduser(args.cwd or os.getcwd()))
        root = store_root()
        transcript = args.transcript
        if transcript:
            transcript = resolve_transcript(transcript)
        targets = collect_targets(args.sid, transcript, cwd, root, check=args.check)
        for sid, source in targets:
            try:
                sync_one(sid, source, root, args.check)
            except Exception as e:
                _warn(f"session {sid}: {e}")
    except Exception as e:
        _warn(f"failed: {e}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
