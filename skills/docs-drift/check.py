#!/usr/bin/env python3
"""SPEC-010 docs-drift checker: structural docs consistency (D1–D8).

Exit codes: 0 = no unwaived findings, 1 = unwaived findings, 64 = usage error.
Finding format: <file>: [<check-id>] <message>
Check-ids: cmd-index | agent-roster | docs-hub | manifest-desc
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

UNWAIVABLE = frozenset({"manifest-desc"})

# <!-- drift-ok: cmd-index -->  (comma-separated multi-ids allowed)
WAIVER_RE = re.compile(
    r"<!--\s*drift-ok:\s*([a-z0-9_,\s-]+)\s*-->", re.I
)

# README ## Commands table rows: | `/name` | ... | or | [`/name`](url) | ...
CMD_ROW_RE = re.compile(
    r"^\|\s*(?:\[)?`/([a-z0-9-]+)`(?:\])?(?:\([^)]*\))?\s*\|"
)

# AGENTS.md / README agent roster table: | `name` | Model | ...
AGENT_ROW_RE = re.compile(r"^\|\s*`([a-z0-9-]+)`\s*\|")

# Backtick token `name` (agent basenames)
BT_TOKEN_RE = re.compile(r"`([a-z0-9-]+)`")

# Markdown links: [text](path) — capture path, strip anchors
MD_LINK_RE = re.compile(r"\[[^\]]*\]\(([^)]+)\)")


def resolve_root(explicit: str | None) -> str:
    if explicit:
        return os.path.abspath(explicit)
    try:
        return subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    except (subprocess.CalledProcessError, OSError):
        return os.getcwd()


def read_text(path: str) -> str | None:
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError as e:
        print(f"warn: cannot read {path}: {e}", file=sys.stderr)
        return None


def rel(root: str, path: str) -> str:
    try:
        return os.path.relpath(path, root).replace(os.sep, "/")
    except ValueError:
        return path.replace(os.sep, "/")


def section_lines(text: str, heading: str) -> list[tuple[int, str]]:
    """Lines (1-based, content) from a heading until next same-or-higher heading.

    heading is matched as a line starting with that exact string (e.g. '## Commands').
    Higher = fewer '#'. Stops at any heading with level <= opener level.
    """
    lines = text.splitlines()
    start = None
    level = None
    for i, line in enumerate(lines):
        if line.startswith(heading) and (
            len(line) == len(heading) or line[len(heading)] in " \t\r\n"
            or line == heading
        ):
            # accept exact or with trailing space/content after heading word
            # but require the heading prefix at start
            m = re.match(r"^(#+)\s", line)
            if m and line.rstrip().startswith(heading.rstrip()):
                start = i + 1  # content starts on next line
                level = len(m.group(1))
                # if heading line itself is the match
                if line.startswith(heading):
                    start = i + 1
                    break
    if start is None:
        # fallback: exact line match
        for i, line in enumerate(lines):
            if line.strip() == heading.strip() or line.startswith(heading):
                m = re.match(r"^(#+)", line)
                level = len(m.group(1)) if m else 2
                start = i + 1
                break
    if start is None:
        return []
    out: list[tuple[int, str]] = []
    for i in range(start, len(lines)):
        line = lines[i]
        m = re.match(r"^(#+)\s", line)
        if m and len(m.group(1)) <= level:
            break
        out.append((i + 1, line))
    return out


def find_heading_section(text: str, *candidates: str) -> list[tuple[int, str]]:
    for h in candidates:
        sec = section_lines(text, h)
        if sec:
            return sec
    return []


def parse_cmd_index(readme: str) -> list[tuple[int, str]]:
    """Return (line, name) for each /name in README ## Commands tables."""
    sec = find_heading_section(readme, "## Commands")
    found: list[tuple[int, str]] = []
    for ln, line in sec:
        m = CMD_ROW_RE.match(line)
        if m:
            found.append((ln, m.group(1)))
    return found


def parse_agent_roster_table(text: str, *headings: str) -> list[tuple[int, str]]:
    sec = find_heading_section(text, *headings)
    # If heading not found, try scanning for a table with Agent | Model header
    if not sec:
        lines = text.splitlines()
        sec = list(enumerate(lines, 1))
    found: list[tuple[int, str]] = []
    in_table = False
    for ln, line in sec:
        if re.match(r"^\|\s*Agent\s*\|", line, re.I):
            in_table = True
            continue
        if in_table:
            if not line.startswith("|"):
                # end of this table; keep scanning for more tables in section
                in_table = False
                continue
            if re.match(r"^\|\s*[-:]+", line):
                continue
            m = AGENT_ROW_RE.match(line)
            if m:
                found.append((ln, m.group(1)))
    return found


def list_md_basenames(dirpath: str) -> set[str]:
    if not os.path.isdir(dirpath):
        return set()
    return {
        name[:-3]
        for name in os.listdir(dirpath)
        if name.endswith(".md") and os.path.isfile(os.path.join(dirpath, name))
    }


def skill_exists(root: str, name: str) -> bool:
    return os.path.isfile(os.path.join(root, "skills", name, "SKILL.md"))


def waiver_ids_on_line(line: str) -> set[str]:
    ids: set[str] = set()
    for m in WAIVER_RE.finditer(line):
        for tok in m.group(1).split(","):
            t = tok.strip().lower()
            if t:
                ids.add(t)
    return ids


def is_waived(src_lines: list[str], line: int, check_id: str) -> bool:
    """D6: offending line or immediately adjacent carries matching drift-ok."""
    if check_id in UNWAIVABLE:
        return False
    for ln in (line - 1, line, line + 1):
        if 1 <= ln <= len(src_lines):
            if check_id in waiver_ids_on_line(src_lines[ln - 1]):
                return True
    return False


class Findings:
    def __init__(self, root: str):
        self.root = root
        self.items: list[dict] = []

    def add(
        self,
        path: str,
        check: str,
        message: str,
        line: int = 1,
        src_lines: list[str] | None = None,
    ) -> None:
        waived = False
        if src_lines is not None:
            waived = is_waived(src_lines, line, check)
        elif check not in UNWAIVABLE:
            # try reading file for waiver scan around line
            text = read_text(path)
            if text is not None:
                waived = is_waived(text.splitlines(), line, check)
        self.items.append({
            "path": rel(self.root, path),
            "line": line,
            "check": check,
            "message": message,
            "waived": waived,
        })


def check_cmd_index(root: str, f: Findings) -> None:
    readme_path = os.path.join(root, "README.md")
    text = read_text(readme_path)
    if text is None:
        f.add(readme_path, "cmd-index", "README.md missing or unreadable")
        return
    src = text.splitlines()
    indexed = parse_cmd_index(text)
    index_names = {n for _, n in indexed}
    index_lines = {n: ln for ln, n in indexed}  # last wins

    cmd_dir = os.path.join(root, "commands")
    cmd_names = list_md_basenames(cmd_dir)

    # (a) every commands/*.md is indexed
    for name in sorted(cmd_names):
        if name not in index_names:
            path = os.path.join(cmd_dir, f"{name}.md")
            f.add(
                path,
                "cmd-index",
                f"commands/{name}.md not listed in README ## Commands index",
                line=1,
            )

    # (b) every index entry resolves to commands/<name>.md OR skills/<name>/SKILL.md
    for name in sorted(index_names):
        cmd_ok = name in cmd_names
        skill_ok = skill_exists(root, name)
        if not cmd_ok and not skill_ok:
            ln = index_lines.get(name, 1)
            f.add(
                readme_path,
                "cmd-index",
                f"/{name} in README ## Commands has no commands/{name}.md "
                f"or skills/{name}/SKILL.md",
                line=ln,
                src_lines=src,
            )


def check_agent_roster(root: str, f: Findings) -> None:
    agents_dir = os.path.join(root, "agents")
    agent_files = list_md_basenames(agents_dir)

    agents_md_path = os.path.join(root, "AGENTS.md")
    agents_md = read_text(agents_md_path)
    if agents_md is None:
        f.add(agents_md_path, "agent-roster", "AGENTS.md missing or unreadable")
        roster: list[tuple[int, str]] = []
        roster_names: set[str] = set()
        agents_src: list[str] = []
    else:
        agents_src = agents_md.splitlines()
        roster = parse_agent_roster_table(
            agents_md, "## Agent Roster", "### Agents", "## Agents"
        )
        roster_names = {n for _, n in roster}

    # (a) AGENTS.md ↔ agents/*.md bidirectional
    for name in sorted(agent_files - roster_names):
        f.add(
            os.path.join(agents_dir, f"{name}.md"),
            "agent-roster",
            f"agents/{name}.md missing from AGENTS.md roster table",
            line=1,
        )
    for ln, name in roster:
        if name not in agent_files:
            f.add(
                agents_md_path,
                "agent-roster",
                f"AGENTS.md roster lists `{name}` but agents/{name}.md does not exist",
                line=ln,
                src_lines=agents_src,
            )

    # (b) README Agents section
    readme_path = os.path.join(root, "README.md")
    readme = read_text(readme_path)
    if readme is None:
        f.add(readme_path, "agent-roster", "README.md missing or unreadable")
        return
    readme_src = readme.splitlines()
    # Prefer ### Agents under What You Get; fall back to ## Agents
    agents_sec = find_heading_section(readme, "### Agents", "## Agents")
    if not agents_sec:
        # whole file fallback for tiny fixtures
        agents_sec = list(enumerate(readme_src, 1))

    # roster-table rows in README
    readme_table: list[tuple[int, str]] = []
    in_table = False
    for ln, line in agents_sec:
        if re.match(r"^\|\s*Agent\s*\|", line, re.I):
            in_table = True
            continue
        if in_table:
            if not line.startswith("|"):
                in_table = False
                continue
            if re.match(r"^\|\s*[-:]+", line):
                continue
            m = AGENT_ROW_RE.match(line)
            if m:
                readme_table.append((ln, m.group(1)))

    for ln, name in readme_table:
        if name not in agent_files:
            f.add(
                readme_path,
                "agent-roster",
                f"README Agents table lists `{name}` but agents/{name}.md does not exist",
                line=ln,
                src_lines=readme_src,
            )

    # every agents/*.md basename appears as `name` token in Agents section
    sec_tokens: set[str] = set()
    token_lines: dict[str, int] = {}
    for ln, line in agents_sec:
        for m in BT_TOKEN_RE.finditer(line):
            tok = m.group(1)
            sec_tokens.add(tok)
            token_lines.setdefault(tok, ln)

    for name in sorted(agent_files):
        if name not in sec_tokens:
            f.add(
                readme_path,
                "agent-roster",
                f"agents/{name}.md not mentioned as `{name}` in README Agents section",
                line=agents_sec[0][0] if agents_sec else 1,
                src_lines=readme_src,
            )


def _normalize_link(href: str) -> str | None:
    """Return path without anchor/query, or None if external/non-path."""
    href = href.strip()
    if not href or href.startswith(("#", "http://", "https://", "mailto:")):
        return None
    # drop anchor / query
    href = href.split("#", 1)[0].split("?", 1)[0]
    if not href:
        return None
    return href


def _is_docs_commands_path(path: str, *, from_docs_readme: bool) -> bool:
    """True if path points at a docs/commands/*.md page."""
    norm = path.replace("\\", "/")
    if from_docs_readme:
        return (
            norm.startswith("commands/") and norm.endswith(".md")
        ) or (
            "/commands/" in norm and norm.endswith(".md") and "docs/" in norm
        )
    return "docs/commands/" in norm and norm.endswith(".md")


def check_docs_hub(root: str, f: Findings) -> None:
    docs_cmd_dir = os.path.join(root, "docs", "commands")
    page_files = list_md_basenames(docs_cmd_dir)

    docs_readme_path = os.path.join(root, "docs", "README.md")
    readme_path = os.path.join(root, "README.md")

    # Collect links from README.md and docs/README.md
    sources = [
        (readme_path, False),
        (docs_readme_path, True),
    ]

    linked_from_docs_readme: set[str] = set()  # basenames
    dead_checked: set[tuple[str, str]] = set()

    for src_path, from_docs in sources:
        text = read_text(src_path)
        if text is None:
            continue
        src_lines = text.splitlines()
        for ln, line in enumerate(src_lines, 1):
            for m in MD_LINK_RE.finditer(line):
                href = _normalize_link(m.group(1))
                if href is None:
                    continue
                if not _is_docs_commands_path(href, from_docs_readme=from_docs):
                    continue
                # resolve relative to source file's directory
                abs_target = os.path.normpath(
                    os.path.join(os.path.dirname(src_path), href)
                )
                base = os.path.basename(abs_target)
                if base.endswith(".md"):
                    if from_docs and (
                        href.startswith("commands/")
                        or href.endswith("/" + base)
                    ):
                        linked_from_docs_readme.add(base[:-3])
                    # also count docs/README links that use ../docs/commands
                    if from_docs:
                        # any link resolving into docs/commands/
                        try:
                            rel_to_docs = os.path.relpath(abs_target, docs_cmd_dir)
                            if not rel_to_docs.startswith("..") and rel_to_docs.endswith(".md"):
                                linked_from_docs_readme.add(base[:-3])
                        except ValueError:
                            pass

                key = (rel(root, src_path), href)
                if key in dead_checked:
                    continue
                dead_checked.add(key)
                if not os.path.isfile(abs_target):
                    f.add(
                        src_path,
                        "docs-hub",
                        f"dead link to docs command page: {href}",
                        line=ln,
                        src_lines=src_lines,
                    )

    # Re-scan docs/README specifically for linked basenames (robust)
    docs_text = read_text(docs_readme_path)
    if docs_text is not None:
        for m in MD_LINK_RE.finditer(docs_text):
            href = _normalize_link(m.group(1))
            if href is None:
                continue
            if href.startswith("commands/") and href.endswith(".md"):
                linked_from_docs_readme.add(os.path.basename(href)[:-3])
            abs_target = os.path.normpath(
                os.path.join(os.path.dirname(docs_readme_path), href or ".")
            )
            try:
                if os.path.commonpath(
                    [os.path.realpath(docs_cmd_dir), os.path.realpath(abs_target)]
                ) == os.path.realpath(docs_cmd_dir) and abs_target.endswith(".md"):
                    linked_from_docs_readme.add(os.path.basename(abs_target)[:-3])
            except ValueError:
                pass

    # (b) every docs/commands/*.md linked from docs/README.md
    for name in sorted(page_files - linked_from_docs_readme):
        f.add(
            os.path.join(docs_cmd_dir, f"{name}.md"),
            "docs-hub",
            f"docs/commands/{name}.md not linked from docs/README.md (orphan page)",
            line=1,
        )


def check_manifest_desc(root: str, f: Findings) -> None:
    plugin_path = os.path.join(root, ".claude-plugin", "plugin.json")
    market_path = os.path.join(root, ".claude-plugin", "marketplace.json")
    plugin_text = read_text(plugin_path)
    market_text = read_text(market_path)
    if plugin_text is None or market_text is None:
        if plugin_text is None:
            f.add(plugin_path, "manifest-desc", "plugin.json missing or unreadable")
        if market_text is None:
            f.add(market_path, "manifest-desc", "marketplace.json missing or unreadable")
        return
    try:
        plugin = json.loads(plugin_text)
    except json.JSONDecodeError as e:
        f.add(plugin_path, "manifest-desc", f"plugin.json invalid JSON: {e}")
        return
    try:
        market = json.loads(market_text)
    except json.JSONDecodeError as e:
        f.add(market_path, "manifest-desc", f"marketplace.json invalid JSON: {e}")
        return

    pdesc = plugin.get("description")
    plugins = market.get("plugins")
    if not isinstance(plugins, list) or not plugins:
        f.add(
            market_path,
            "manifest-desc",
            "marketplace.json has no plugins[] entries to compare description",
        )
        return
    for i, entry in enumerate(plugins):
        if not isinstance(entry, dict):
            continue
        mdesc = entry.get("description")
        if pdesc != mdesc:
            name = entry.get("name", f"plugins[{i}]")
            f.add(
                market_path,
                "manifest-desc",
                f"description mismatch vs plugin.json for {name!r} "
                f"(plugin.json and marketplace.json must be byte-identical)",
            )


def run_checks(root: str) -> list[dict]:
    f = Findings(root)
    check_cmd_index(root, f)
    check_agent_roster(root, f)
    check_docs_hub(root, f)
    check_manifest_desc(root, f)
    return f.items


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(
        prog="check-docs-drift.sh",
        description="SPEC-010 docs-drift structural consistency checker",
        add_help=True,
    )
    ap.add_argument("--root", default=None, help="repo root (default: git toplevel)")
    try:
        args = ap.parse_args(argv)
    except SystemExit as e:
        code = e.code if isinstance(e.code, int) else 64
        return 0 if code == 0 else 64

    # Reject unknown positionals — argparse already does; extra safety for empty root
    root = resolve_root(args.root)
    if args.root and not os.path.isdir(root):
        print(f"usage error: --root is not a directory: {root}", file=sys.stderr)
        return 64

    findings = run_checks(root)
    unwaived = [x for x in findings if not x["waived"]]
    waived_n = len(findings) - len(unwaived)

    for item in unwaived:
        # D1 format: <file>: [<check-id>] <message>  (no line number)
        print(f"{item['path']}: [{item['check']}] {item['message']}")
    print(f"{len(findings)} findings, {waived_n} waived")
    return 1 if unwaived else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
