#!/usr/bin/env python3
"""SPEC-010 docs-drift checker: structural docs consistency (D1–D10).

Exit codes: 0 = no unwaived findings, 1 = unwaived findings, 64 = usage error.
Finding format: <file>: [<check-id>] <message>
Check-ids: cmd-index | cmd-flags | agent-roster | docs-hub | manifest-desc | skill-ref | skill-name | docs-page-links | md-anchor | spec-example | security-versions
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

# Literal skills/<name>/<file> path mentions (prose or embedded in bash),
# e.g. `skills/validate-memory/SKILL.md` or "$PLUGIN_ROOT/skills/x/y.sh"
SKILL_PATH_RE = re.compile(
    r"skills/([a-z0-9][a-z0-9_-]*)/([A-Za-z0-9_./-]+\.(?:md|sh|py))"
)


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
    in_fence = False
    for i in range(start, len(lines)):
        line = lines[i]
        # A `# comment` inside a fence is not a heading (W1-60).
        stripped = line.lstrip()
        if stripped.startswith("```"):
            in_fence = not in_fence
            out.append((i + 1, line))
            continue
        if not in_fence:
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
    in_migration = False
    for ln, line in sec:
        # A `### Migration (historical)` subsection maps deleted stubs to
        # live hubs — those rows are history, not an invocable index
        # (W3-01: user-invocable set == README index, historical rows excluded).
        if re.match(r"^#{1,3}\s+.*migration", line, re.I):
            in_migration = True
            continue
        if re.match(r"^#{1,3}\s+\S", line):
            in_migration = False
        if in_migration:
            continue
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


def skill_is_user_invocable(root: str, name: str) -> bool:
    """True when skills/<name>/SKILL.md exists and does NOT set
    `user-invocable: false` (CDT-295 / 10 E5: flagged skills are internal
    engines behind command doors and are not Surfaces)."""
    path = os.path.join(root, "skills", name, "SKILL.md")
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        return False
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return False
    for line in lines[1:]:
        if line.strip() == "---":
            break
        if re.match(r"^user-invocable:\s*false\s*$", line.strip()):
            return False
    return True


def list_surfaces(root: str) -> set[str]:
    """All user-invocable Surface names: commands/*.md plus unflagged skills."""
    names = set(list_md_basenames(os.path.join(root, "commands")))
    skills_dir = os.path.join(root, "skills")
    if os.path.isdir(skills_dir):
        for entry in sorted(os.listdir(skills_dir)):
            if skill_exists(root, entry) and skill_is_user_invocable(root, entry):
                names.add(entry)
    return names


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

    # (b) every index entry resolves to commands/<name>.md OR a user-invocable
    # skills/<name>/SKILL.md (a `user-invocable: false` skill is an internal
    # engine — indexing it advertises a non-Surface; CDT-295 [01 F21]/[10 E5])
    for name in sorted(index_names):
        cmd_ok = name in cmd_names
        skill_ok = skill_exists(root, name) and skill_is_user_invocable(root, name)
        if not cmd_ok and not skill_ok:
            ln = index_lines.get(name, 1)
            if skill_exists(root, name):
                msg = (
                    f"/{name} in README ## Commands points at skills/{name}/ "
                    "which sets user-invocable: false — index the command door "
                    "or drop the row"
                )
            else:
                msg = (
                    f"/{name} in README ## Commands has no commands/{name}.md "
                    f"or skills/{name}/SKILL.md"
                )
            f.add(
                readme_path,
                "cmd-index",
                msg,
                line=ln,
                src_lines=src,
            )

    # (c) the user-invocable skill set equals the README index: every
    # unflagged skill is indexed (CDT-295 Goal)
    for name in sorted(list_surfaces(root) - cmd_names):
        if name not in index_names:
            f.add(
                os.path.join(root, "skills", name, "SKILL.md"),
                "cmd-index",
                f"user-invocable skill skills/{name}/ is not listed in the "
                "README ## Commands index",
                line=1,
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

    # (c) every user-invocable Surface (command or unflagged skill) has a
    # docs/commands/<name>.md page (W3-01: docs-drift fails if a surface
    # lacks a page)
    for name in sorted(list_surfaces(root)):
        page = os.path.join(docs_cmd_dir, f"{name}.md")
        if not os.path.isfile(page):
            src = (
                os.path.join(root, "commands", f"{name}.md")
                if name in list_md_basenames(os.path.join(root, "commands"))
                else os.path.join(root, "skills", name, "SKILL.md")
            )
            f.add(
                src,
                "docs-hub",
                f"surface {name} has no docs/commands/{name}.md page",
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


def _skill_ref_files(root: str) -> list[str]:
    """commands, skills, agents, AGENTS.md, and spec files (Covers lines only)."""
    found: list[str] = []
    cmd_dir = os.path.join(root, "commands")
    if os.path.isdir(cmd_dir):
        for name in sorted(os.listdir(cmd_dir)):
            if name.endswith(".md"):
                found.append(os.path.join(cmd_dir, name))
    skills = os.path.join(root, "skills")
    if os.path.isdir(skills):
        for dirpath, _dirs, filenames in os.walk(skills):
            # Fixture markdown names paths that were never shipped.
            if f"{os.sep}fixtures{os.sep}" in dirpath + os.sep:
                continue
            for name in sorted(filenames):
                if name.endswith(".md"):
                    found.append(os.path.join(dirpath, name))
    agents = os.path.join(root, "agents")
    if os.path.isdir(agents):
        for name in sorted(os.listdir(agents)):
            if name.endswith(".md"):
                found.append(os.path.join(agents, name))
    agents_md = os.path.join(root, "AGENTS.md")
    if os.path.isfile(agents_md):
        found.append(agents_md)
    specs = os.path.join(root, "specs")
    if os.path.isdir(specs):
        for dirpath, _dirs, filenames in os.walk(specs):
            for name in sorted(filenames):
                if name.endswith(".md"):
                    found.append(os.path.join(dirpath, name))
    return found


def _line_in_skill_ref_scope(path: str, line: str, in_covers: bool) -> bool:
    """Spec files contribute only **Covers** lines and the ## Covers section."""
    norm = path.replace(os.sep, "/")
    if "/specs/" not in f"/{norm}/" and not norm.endswith("/specs") :
        # path is absolute; detect a /specs/ segment
        pass
    if f"{os.sep}specs{os.sep}" not in path and not path.endswith(f"{os.sep}specs"):
        return True
    if line.startswith("**Covers**") or in_covers:
        return True
    return False


def check_skill_ref(root: str, f: Findings) -> None:
    """D9: every skills/<name>/<file> literal must exist.

    Scans commands/*.md, skills/**/*.md, agents/*.md, AGENTS.md, and spec
    **Covers** lines (W1-60). A `<!-- drift-ok: skill-ref -->` on the line
    or the line next to it waives one historical mention.
    """
    for path in _skill_ref_files(root):
        text = read_text(path)
        if text is None:
            continue
        src_lines = text.splitlines()
        seen: dict[str, int] = {}
        in_covers = False
        for ln, line in enumerate(src_lines, 1):
            if line.startswith("## Covers"):
                in_covers = True
                continue
            if in_covers and line.startswith("## "):
                in_covers = False
            if not _line_in_skill_ref_scope(path, line, in_covers):
                continue
            for m in SKILL_PATH_RE.finditer(line):
                skill_name, filename = m.group(1), m.group(2)
                rel_path = f"skills/{skill_name}/{filename}"
                if rel_path not in seen:
                    seen[rel_path] = ln
        for rel_path, ln in sorted(seen.items()):
            if not os.path.isfile(os.path.join(root, rel_path)):
                f.add(
                    path,
                    "skill-ref",
                    f"references {rel_path} which does not exist",
                    line=ln,
                    src_lines=src_lines,
                )


_SKILL_NAME_RE = re.compile(r"^name:\s*[\"']?([A-Za-z0-9_-]+)")


def check_skill_name(root: str, f: Findings) -> None:
    """skill-name: SKILL.md frontmatter name equals the parent directory."""
    skills = os.path.join(root, "skills")
    if not os.path.isdir(skills):
        return
    for dirpath, _dirs, filenames in os.walk(skills):
        if f"{os.sep}fixtures{os.sep}" in dirpath + os.sep:
            continue
        if "SKILL.md" not in filenames:
            continue
        path = os.path.join(dirpath, "SKILL.md")
        text = read_text(path)
        if text is None:
            continue
        lines = text.splitlines()
        if not lines or lines[0].strip() != "---":
            continue
        name = ""
        for line in lines[1:]:
            if line.strip() == "---":
                break
            m = _SKILL_NAME_RE.match(line)
            if m:
                name = m.group(1)
                break
        dirname = os.path.basename(dirpath)
        if name and name != dirname:
            f.add(
                path,
                "skill-name",
                f"frontmatter name {name!r} does not match directory {dirname!r}",
                line=1,
                src_lines=lines,
            )


def check_docs_page_links(root: str, f: Findings) -> None:
    """D10: relative *.md links in docs/commands/**/*.md must resolve on disk.

    Path-only (fragment/query stripped). Out of scope: http(s), mailto, bare
    #anchor, non-.md paths, absolute /... paths. D6 waivers apply.
    """
    docs_cmd_dir = os.path.join(root, "docs", "commands")
    if not os.path.isdir(docs_cmd_dir):
        return
    pages: list[str] = []
    for dirpath, _dirnames, filenames in os.walk(docs_cmd_dir):
        for name in filenames:
            if name.endswith(".md") and os.path.isfile(os.path.join(dirpath, name)):
                pages.append(os.path.join(dirpath, name))
    for page_path in sorted(pages):
        text = read_text(page_path)
        if text is None:
            continue
        src_lines = text.splitlines()
        for ln, line in enumerate(src_lines, 1):
            for m in MD_LINK_RE.finditer(line):
                href = _normalize_link(m.group(1))
                if href is None:
                    continue
                # Absolute site/path links are out of scope
                if href.startswith("/"):
                    continue
                if not href.endswith(".md"):
                    continue
                abs_target = os.path.normpath(
                    os.path.join(os.path.dirname(page_path), href)
                )
                if not os.path.isfile(abs_target):
                    f.add(
                        page_path,
                        "docs-page-links",
                        f"dead relative md link: {href}",
                        line=ln,
                        src_lines=src_lines,
                    )


ARG_HINT_RE = re.compile(r"^argument-hint:\s*[\"']?(.*?)[\"']?\s*$")
FLAG_TOKEN_RE = re.compile(r"--[a-z][a-z0-9-]*")


def check_cmd_flags(root: str, f: Findings) -> None:
    """cmd-flags (W3-01): every --flag in a command's argument-hint appears
    on its docs/commands/<name>.md page. Skipped when the page is missing
    (docs-hub owns that finding)."""
    cmd_dir = os.path.join(root, "commands")
    docs_cmd_dir = os.path.join(root, "docs", "commands")
    if not os.path.isdir(cmd_dir):
        return
    for name in sorted(list_md_basenames(cmd_dir)):
        page = os.path.join(docs_cmd_dir, f"{name}.md")
        if not os.path.isfile(page):
            continue
        text = read_text(os.path.join(cmd_dir, f"{name}.md"))
        if text is None:
            continue
        src_lines = text.splitlines()
        if not src_lines or src_lines[0].strip() != "---":
            continue
        hint = ""
        for line in src_lines[1:]:
            if line.strip() == "---":
                break
            m = ARG_HINT_RE.match(line)
            if m:
                hint = m.group(1)
                break
        if not hint:
            continue
        page_text = read_text(page) or ""
        page_lines = page_text.splitlines()
        for token in sorted(set(FLAG_TOKEN_RE.findall(hint))):
            if re.search(rf"{re.escape(token)}\b", page_text):
                continue
            f.add(
                page,
                "cmd-flags",
                f"argument-hint flag {token} of commands/{name}.md is not "
                "documented on this page",
                line=1,
                src_lines=page_lines,
            )


def _docs_scan_files(root: str) -> list[str]:
    """docs/**.md (recursive) plus the root README.md."""
    files: list[str] = []
    docs_dir = os.path.join(root, "docs")
    if os.path.isdir(docs_dir):
        for dirpath, _dirs, filenames in os.walk(docs_dir):
            for name in sorted(filenames):
                if name.endswith(".md"):
                    files.append(os.path.join(dirpath, name))
    readme = os.path.join(root, "README.md")
    if os.path.isfile(readme):
        files.append(readme)
    return files


HEADING_RE = re.compile(r"^(#{1,6})\s+(.*?)\s*$")


def github_slug(heading: str) -> str:
    """GitHub-style anchor slug: lowercase, drop non-word chars except space
    and hyphen and underscore, spaces -> hyphens. Backticks are formatting
    and are stripped first."""
    text = heading.strip().lower().replace("`", "")
    kept = [ch for ch in text if ch.isalnum() or ch in " -_"]
    return "".join(kept).replace(" ", "-")


def heading_anchors(target_text: str) -> set[str]:
    anchors: set[str] = set()
    seen: dict[str, int] = {}
    for line in target_text.splitlines():
        m = HEADING_RE.match(line)
        if not m:
            continue
        heading = re.sub(r"\s+#+\s*$", "", m.group(2))
        slug = github_slug(heading)
        if not slug:
            continue
        n = seen.get(slug, 0)
        seen[slug] = n + 1
        anchors.add(slug if n == 0 else f"{slug}-{n}")
    return anchors


def check_md_anchors(root: str, f: Findings) -> None:
    """md-anchor (10 E9): every `path.md#anchor` or same-file `#anchor`
    markdown link under docs/ (and README.md) must resolve to a heading
    slug in the target file. Relative path-only links in docs/commands are
    docs-page-links' job; this check adds the anchor half everywhere."""
    for path in _docs_scan_files(root):
        text = read_text(path)
        if text is None:
            continue
        src_lines = text.splitlines()
        base_dir = os.path.dirname(path)
        seen: set[tuple[str, str]] = set()
        for ln, line in enumerate(src_lines, 1):
            for m in MD_LINK_RE.finditer(line):
                href = m.group(1).strip()
                if href.startswith(("http://", "https://", "mailto:")):
                    continue
                if "#" not in href:
                    continue
                target_rel, anchor = href.split("#", 1)
                if not anchor:
                    continue  # path-only link: other checks own it
                if target_rel:
                    target = os.path.normpath(os.path.join(base_dir, target_rel))
                else:
                    target = path
                if not target.endswith(".md"):
                    continue
                key = (rel(root, path), href)
                if key in seen:
                    continue
                seen.add(key)
                if not os.path.isfile(target):
                    f.add(
                        path,
                        "md-anchor",
                        f"dead link target: {target_rel}",
                        line=ln,
                        src_lines=src_lines,
                    )
                    continue
                target_text = read_text(target)
                if target_text is None:
                    continue
                if anchor not in heading_anchors(target_text):
                    f.add(
                        path,
                        "md-anchor",
                        f"anchor #{anchor} not found in {rel(root, target)}",
                        line=ln,
                        src_lines=src_lines,
                    )


def _existing_spec_numbers(root: str) -> set[int]:
    numbers: set[int] = set()
    specs_dir = os.path.join(root, "specs")
    if not os.path.isdir(specs_dir):
        return numbers
    for dirpath, _dirs, filenames in os.walk(specs_dir):
        for name in filenames:
            m = re.match(r"SPEC-(\d+)-.*\.md$", name)
            if m:
                numbers.add(int(m.group(1)))
    return numbers


def check_spec_examples(root: str, f: Findings) -> None:
    """spec-example (W3-43): a SPEC-<n> id in docs must exist as
    specs/**/SPEC-<n>-*.md unless n >= 900 (obviously-fake example range)."""
    existing = _existing_spec_numbers(root)
    if not existing and not os.path.isdir(os.path.join(root, "specs")):
        return
    for path in _docs_scan_files(root):
        text = read_text(path)
        if text is None:
            continue
        src_lines = text.splitlines()
        seen: dict[str, int] = {}
        for ln, line in enumerate(src_lines, 1):
            for m in re.finditer(r"\bSPEC-(\d+)\b", line):
                n = int(m.group(1))
                if n >= 900 or n in existing:
                    continue
                token = f"SPEC-{n}"
                if token in seen:
                    continue
                seen[token] = ln
                f.add(
                    path,
                    "spec-example",
                    f"{token} has no specs/ file — real ids (< 900) must exist; "
                    "use a SPEC-9xx id for made-up examples",
                    line=ln,
                    src_lines=src_lines,
                )


def check_security_versions(root: str, f: Findings) -> None:
    """security-versions (CDT-296 / 10 E9 / W3-22): SECURITY.md's
    supported-versions table must match the generator's output for the
    current plugin.json version. Skips fixture trees without the generator."""
    plugin_path = os.path.join(root, ".claude-plugin", "plugin.json")
    sec_path = os.path.join(root, "SECURITY.md")
    gen_path = os.path.join(root, "skills", "release", "gen-supported-versions.sh")
    if not (os.path.isfile(plugin_path) and os.path.isfile(sec_path)
            and os.path.isfile(gen_path)):
        return
    try:
        version = json.loads(read_text(plugin_path) or "{}").get("version")
    except json.JSONDecodeError:
        return
    if not version:
        return
    try:
        proc = subprocess.run(
            ["bash", gen_path, str(version)],
            capture_output=True, text=True, check=True,
        )
    except (subprocess.CalledProcessError, OSError) as e:
        f.add(sec_path, "security-versions",
              f"gen-supported-versions.sh failed: {e}", line=1)
        return
    want = [ln for ln in proc.stdout.splitlines() if ln.strip()]

    src_lines = (read_text(sec_path) or "").splitlines()
    section: list[str] = []
    in_sec = False
    for line in src_lines:
        if line.strip() == "## Supported Versions":
            in_sec = True
            continue
        if in_sec and re.match(r"^##\s", line):
            break
        if in_sec:
            section.append(line)
    got = [ln for ln in section if ln.strip()]
    if got != want:
        f.add(
            sec_path,
            "security-versions",
            f"supported-versions table does not match generated output for "
            f"plugin.json {version} — run skills/release/gen-supported-versions.sh --write",
            line=1,
            src_lines=src_lines,
        )


def run_checks(root: str) -> list[dict]:
    f = Findings(root)
    check_cmd_index(root, f)
    check_agent_roster(root, f)
    check_docs_hub(root, f)
    check_manifest_desc(root, f)
    check_skill_ref(root, f)
    check_skill_name(root, f)
    check_docs_page_links(root, f)
    check_cmd_flags(root, f)
    check_md_anchors(root, f)
    check_spec_examples(root, f)
    check_security_versions(root, f)
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
