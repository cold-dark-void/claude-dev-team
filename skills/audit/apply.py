#!/usr/bin/env python3
"""Apply /audit findings to instruction-stack files only (SPEC-035)."""
from __future__ import annotations

import argparse
import json
import os
import sys

STACK_NAMES = frozenset({"CLAUDE.md", "AGENTS.md", "directives.md"})
APPLYABLE = frozenset({"instruction-stack", "judgment"})


def die(code: int, msg: str) -> None:
    print(f"audit apply: {msg}", file=sys.stderr)
    raise SystemExit(code)


def load_findings(path: str) -> list[dict]:
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        die(64, f"cannot read --from-json: {exc}")
    if isinstance(data, dict) and "findings" in data:
        rows = data["findings"]
    elif isinstance(data, dict):
        rows = [data]
    elif isinstance(data, list):
        rows = data
    else:
        die(64, " --from-json must be an object, array, or {findings:[]}")
    out: list[dict] = []
    for row in rows:
        if not isinstance(row, dict):
            die(64, "each finding must be a JSON object")
        out.append(row)
    return out


def pick(findings: list[dict], fid: str) -> dict:
    for row in findings:
        if str(row.get("id") or "") == fid:
            return row
    die(2, f"rejected {fid}: id not in --from-json")
    raise AssertionError


def has_mechanical_evidence(finding: dict) -> bool:
    ev = finding.get("evidence")
    if not isinstance(ev, dict):
        return False
    passages = ev.get("passages") or []
    if not isinstance(passages, list):
        return False
    good = 0
    for p in passages:
        if not isinstance(p, dict):
            continue
        if str(p.get("path") or "").strip() and str(p.get("quote") or "").strip():
            good += 1
    if good < 2:
        return False
    counts = ev.get("counts") if isinstance(ev.get("counts"), dict) else {}
    if not (counts.get("bytes") or counts.get("lines")):
        return False
    has_mtime = bool(ev.get("mtime"))
    tag = ev.get("tag") if isinstance(ev.get("tag"), dict) else {}
    has_tag = bool(tag.get("date") or tag.get("name"))
    spec = ev.get("spec") if isinstance(ev.get("spec"), dict) else {}
    has_spec = bool(
        str(spec.get("quote") or "").strip()
        and (spec.get("id") or spec.get("path"))
    )
    return bool(has_mtime or has_tag or has_spec)


def resolve_path(path: str) -> str:
    """Absolute path after symlink resolution (QA P2: do not trust abspath)."""
    return os.path.realpath(os.path.expanduser(path))


def path_gate(path: str) -> str | None:
    norm = resolve_path(path)
    parts = norm.split(os.sep)
    if "skills" in parts or "commands" in parts:
        return "refuses skills/** and commands/** (instruction-stack files only)"
    if os.path.basename(norm) not in STACK_NAMES:
        return "path is not an instruction-stack file (CLAUDE.md, AGENTS.md, directives.md)"
    return None


def under_user_config(path: str, home: str) -> bool:
    home_r = resolve_path(home)
    norm = resolve_path(path)
    for name in (".claude", ".grok"):
        root = os.path.join(home_r, name)
        if norm == root or norm.startswith(root + os.sep):
            return True
    return False


def validate(finding: dict, *, judgment: bool, yes: bool, home: str) -> str | None:
    fid = str(finding.get("id") or "?")
    klass = str(finding.get("class") or "")
    if klass not in APPLYABLE:
        return f"rejected {fid}: class {klass or 'missing'} is not applyable (instruction-stack only)"
    if klass == "judgment" and not judgment:
        return f"rejected {fid}: judgment class requires --judgment"
    if not has_mechanical_evidence(finding):
        return (
            f"rejected {fid}: missing mechanical evidence "
            "(two passages, counts, and mtime/tag or spec quote)"
        )
    path = str(finding.get("path") or "")
    if not path:
        return f"rejected {fid}: missing path"
    err = path_gate(path)
    if err:
        return f"rejected {fid}: {err}"
    if under_user_config(path, home) and not yes:
        return (
            f"rejected {fid}: extra confirm required for ~/.claude or ~/.grok "
            "write (pass --yes)"
        )
    action = finding.get("action")
    if not isinstance(action, dict) or action.get("type") != "replace-span":
        return f"rejected {fid}: action.type must be replace-span"
    old = action.get("old")
    if not isinstance(old, str) or old == "":
        return f"rejected {fid}: action.old must be a non-empty string"
    if "new" not in action or not isinstance(action.get("new"), str):
        return f"rejected {fid}: action.new must be a string"
    return None


def apply_one(finding: dict, *, dry_run: bool) -> None:
    path = resolve_path(str(finding["path"]))
    action = finding["action"]
    old = action["old"]
    new = action["new"]
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        die(2, f"rejected {finding.get('id')}: cannot read {path}: {exc}")
    n = text.count(old)
    if n != 1:
        die(2, f"rejected {finding.get('id')}: old text occurs {n} time(s) (want 1)")
    if dry_run:
        print(f"audit apply: dry-run {finding.get('id')} {path}")
        return
    try:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text.replace(old, new, 1))
    except OSError as exc:
        die(2, f"rejected {finding.get('id')}: cannot write {path}: {exc}")
    print(f"audit apply: wrote {finding.get('id')} {path}")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="apply.py")
    p.add_argument("--from-json", required=True)
    p.add_argument("--id", action="append", default=[])
    p.add_argument("--judgment", action="store_true")
    p.add_argument("--yes", action="store_true")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--home", default=os.path.expanduser("~"))
    args = p.parse_args(argv)
    ids: list[str] = []
    for raw in args.id:
        for part in raw.split(","):
            part = part.strip()
            if part:
                ids.append(part)
    if not ids:
        die(64, "apply requires at least one --id")
    findings = load_findings(args.from_json)
    picked = [pick(findings, i) for i in ids]
    for row in picked:
        err = validate(row, judgment=args.judgment, yes=args.yes, home=args.home)
        if err:
            die(2, err)
    for row in picked:
        apply_one(row, dry_run=args.dry_run)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
