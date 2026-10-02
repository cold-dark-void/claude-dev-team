#!/usr/bin/env python3
"""Apply /audit findings to instruction-stack files only (SPEC-035)."""
from __future__ import annotations

import argparse
import json
import os
import sys

STACK_NAMES = frozenset({"CLAUDE.md", "AGENTS.md", "directives.md"})
APPLYABLE = frozenset({"instruction-stack", "judgment"})
# Layers the inventory walk emits. A finding whose layer is outside this set
# is not an instruction-stack target (CDT-389 / E8).
INVENTORY_LAYERS = frozenset({"user-global", "parent", "project", "directives"})


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


def enclosing_repo(path: str) -> str | None:
    """Nearest ancestor that is a git checkout or this plugin. Ancestors
    outside that root (for example /home/skills/...) are not skills/**."""
    cur = os.path.dirname(resolve_path(path))
    while True:
        git_meta = os.path.join(cur, ".git")
        # A linked worktree has a .git file, not a .git directory.
        if os.path.isdir(git_meta) or os.path.isfile(git_meta) or os.path.isfile(
            os.path.join(cur, ".claude-plugin", "plugin.json")
        ):
            return cur
        parent = os.path.dirname(cur)
        if parent == cur:
            return None
        cur = parent


def path_gate(path: str) -> str | None:
    norm = resolve_path(path)
    if os.path.basename(norm) not in STACK_NAMES:
        return "path is not an instruction-stack file (CLAUDE.md, AGENTS.md, directives.md)"
    root = enclosing_repo(norm)
    if root is not None:
        parts = os.path.relpath(norm, root).split(os.sep)
    else:
        # No repo root: keep the old segment check so a symlink into skills/**
        # is still refused.
        parts = norm.split(os.sep)
    if "skills" in parts or "commands" in parts:
        return "refuses skills/** and commands/** (instruction-stack files only)"
    return None


def _resolve_cited(path: str, bases: list[str]) -> str:
    if os.path.isabs(path):
        return resolve_path(path)
    for base in bases:
        cand = os.path.join(base, path)
        if os.path.isfile(cand):
            return resolve_path(cand)
    return resolve_path(path)


def _read_text(path: str) -> str:
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def verify_evidence(finding: dict, bases: list[str]) -> str | None:
    """Quotes, byte size, and spec quote must match the files (CDT-389)."""
    fid = str(finding.get("id") or "?")
    ev = finding.get("evidence")
    if not isinstance(ev, dict):
        return f"rejected {fid}: missing mechanical evidence"
    target = resolve_path(str(finding.get("path") or ""))
    try:
        size = os.path.getsize(target)
    except OSError as exc:
        return f"rejected {fid}: cannot stat {target}: {exc}"
    counts = ev.get("counts") if isinstance(ev.get("counts"), dict) else {}
    if "bytes" in counts:
        try:
            claimed = int(counts["bytes"])
        except (TypeError, ValueError):
            return f"rejected {fid}: counts.bytes is not an integer"
        if claimed != size:
            return (
                f"rejected {fid}: counts.bytes {claimed} != file size {size}"
            )
    passages = ev.get("passages") or []
    for p in passages:
        if not isinstance(p, dict):
            continue
        quote = str(p.get("quote") or "")
        cited = _resolve_cited(str(p.get("path") or ""), bases)
        try:
            text = _read_text(cited)
        except OSError as exc:
            return f"rejected {fid}: cannot read passage {cited}: {exc}"
        if quote not in text:
            return f"rejected {fid}: passage quote not in {cited}"
        if p.get("line") not in (None, ""):
            try:
                lineno = int(p["line"])
            except (TypeError, ValueError):
                return f"rejected {fid}: passage line is not an integer"
            lines = text.splitlines()
            if lineno < 1 or lineno > len(lines) or quote not in lines[lineno - 1]:
                return f"rejected {fid}: passage quote not on line {lineno} of {cited}"
    spec = ev.get("spec") if isinstance(ev.get("spec"), dict) else {}
    squote = str(spec.get("quote") or "").strip()
    if squote:
        spath = str(spec.get("path") or "").strip()
        if not spath:
            return f"rejected {fid}: spec quote has no spec path"
        sfile = _resolve_cited(spath, bases)
        try:
            stext = _read_text(sfile)
        except OSError as exc:
            return f"rejected {fid}: cannot read spec {sfile}: {exc}"
        if squote not in stext:
            return f"rejected {fid}: spec quote not in {sfile}"
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
    layer = str(finding.get("layer") or "")
    if layer and layer not in INVENTORY_LAYERS:
        return f"rejected {fid}: layer {layer} is not in the inventory"
    bases = [os.getcwd()]
    repo = enclosing_repo(resolve_path(path))
    if repo:
        bases.append(repo)
    err = verify_evidence(finding, bases)
    if err:
        return err
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


def plan_batch(findings: list[dict]) -> list[tuple[str, str]]:
    """Compose every edit for one path in one buffer. No write.
    A miss dies here, before commit_plans, so no file changes."""
    order: list[str] = []
    groups: dict[str, list[dict]] = {}
    for finding in findings:
        path = resolve_path(str(finding["path"]))
        if path not in groups:
            order.append(path)
            groups[path] = []
        groups[path].append(finding)
    plans: list[tuple[str, str]] = []
    for path in order:
        rows = groups[path]
        try:
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
        except OSError as exc:
            die(2, f"rejected {rows[0].get('id')}: cannot read {path}: {exc}")
        for finding in rows:
            action = finding["action"]
            old = action["old"]
            new = action["new"]
            n = text.count(old)
            if n != 1:
                die(
                    2,
                    f"rejected {finding.get('id')}: old text occurs {n} time(s) (want 1)",
                )
            text = text.replace(old, new, 1)
        plans.append((path, text))
    return plans


def commit_plans(plans: list[tuple[str, str]]) -> None:
    """Write every temp first, then rename. A failure before rename changes nothing."""
    temps: list[tuple[str, str]] = []
    try:
        for path, new in plans:
            tmp = path + ".audit-tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                fh.write(new)
            temps.append((tmp, path))
        for tmp, path in temps:
            os.replace(tmp, path)
    except OSError as exc:
        for tmp, _path in temps:
            if os.path.exists(tmp):
                try:
                    os.remove(tmp)
                except OSError:
                    pass
        die(2, f"rejected batch: cannot write: {exc}")


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
    plans = plan_batch(picked)
    if args.dry_run:
        for row, (path, _new) in zip(picked, plans):
            print(f"audit apply: dry-run {row.get('id')} {path}")
        return 0
    commit_plans(plans)
    for row, (path, _new) in zip(picked, plans):
        print(f"audit apply: wrote {row.get('id')} {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
