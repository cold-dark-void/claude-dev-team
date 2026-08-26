"""Shared strip of Transcript-mirror main.md (SPEC-018 M3f / SPEC-036 M14)."""
import re

_TITLE_RE = re.compile(r"^\s*#\s*transcript mirror")
_SIDECAR_RE = re.compile(r"^>\s*@")


def _raw_line(line):
    if line.endswith("\r\n"):
        return line[:-2]
    if line.endswith("\n") or line.endswith("\r"):
        return line[:-1]
    return line


def strip_mirror_main(text):
    """Drop `# transcript mirror` title and `> @` sidecar/nest refs."""
    kept = []
    for line in text.splitlines(keepends=True):
        raw = _raw_line(line)
        if _TITLE_RE.match(raw) or _SIDECAR_RE.match(raw):
            continue
        kept.append(line)
    return "".join(kept)
