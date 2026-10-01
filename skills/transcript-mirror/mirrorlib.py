#!/usr/bin/env python3
"""Shared transcript-mirror helpers (WP 4-01).

One record identity, one meaning-line escape, one secret redaction.
A JSONL line that is not an object does not raise.
"""
from __future__ import annotations

import hashlib
import json
import re
import sys

HEADING_RE = re.compile(r"^## (user|assistant)[ \t]*$")
REF_RE = re.compile(r"^>\s*@")
_BEARER = re.compile(r"Bearer [A-Za-z0-9._~/+-]{8,}")
_SK = re.compile(r"sk-[A-Za-z0-9]{8,}")
_AKIA = re.compile(r"AKIA[0-9A-Z]{8,}")
_PASSWORD = re.compile(r"(?i)password=\S+")


def redact_text(text: str) -> str:
    if not isinstance(text, str) or not text:
        return text if isinstance(text, str) else ""
    text = _BEARER.sub("Bearer [redacted]", text)
    text = _SK.sub("sk-[redacted]", text)
    text = _AKIA.sub("AKIA[redacted]", text)
    text = _PASSWORD.sub("password=[redacted]", text)
    return text


def escape_meaning_line(line: str) -> str:
    if HEADING_RE.match(line) or REF_RE.match(line):
        return " " + line
    return line


def escape_meaning_text(text: str) -> str:
    if not text:
        return text
    nl = text.endswith("\n")
    body = text[:-1] if nl else text
    out = "\n".join(escape_meaning_line(part) for part in body.split("\n"))
    return out + ("\n" if nl else "")


def hash_raw_bytes(raw: bytes) -> str:
    body = raw.rstrip(b"\r\n")
    if not body:
        return ""
    return "h:" + hashlib.sha256(body + b"\n").hexdigest()


def record_ident(line: str) -> str:
    """uuid when present, else sha256 of the raw line bytes.

    Does not re-serialize. A list or other non-object is hashed, not rejected.
    """
    raw = line.rstrip("\r\n")
    if not raw.strip():
        return ""
    try:
        obj = json.loads(raw)
    except json.JSONDecodeError:
        return ""
    if isinstance(obj, dict):
        uuid = obj.get("uuid")
        if isinstance(uuid, str) and uuid:
            return uuid
    return hash_raw_bytes(raw.encode("utf-8"))


def grok_tool_name(tc: dict) -> str:
    """Name from a flat tool call or from function.name."""
    name = tc.get("name")
    if isinstance(name, str) and name:
        return name
    fn = tc.get("function")
    if isinstance(fn, dict):
        nested = fn.get("name")
        if isinstance(nested, str) and nested:
            return nested
    return "unknown"


def grok_tool_arguments(tc: dict):
    if "arguments" in tc and tc.get("arguments") is not None:
        return tc.get("arguments")
    fn = tc.get("function")
    if isinstance(fn, dict):
        return fn.get("arguments")
    return None


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[1] == "ident-line":
        line = sys.stdin.readline()
        if line.endswith("\n"):
            line = line[:-1]
        sys.stdout.write(record_ident(line) + "\n")
        return 0
    return 64


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as exc:
        sys.stderr.write("mirrorlib: %s\n" % exc)
        sys.exit(1)
