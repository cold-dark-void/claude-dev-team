#!/usr/bin/env python3
"""Rank, filter, and classify retro proposals.

RAW TSV on stdin (rank, target, confidence, citation_count, pattern_summary,
proposed_text, source_jsonl, citations_json).

--mode all drops patterns that occur in only one distinct session, using a
token-jaccard cluster so a reworded summary still counts, then caps.
Other modes cap first. TIGHTEN rows get a deterministic merged proposed_text.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

STOP = {
    "a", "an", "the", "to", "of", "for", "is", "are", "be", "was", "were",
    "in", "on", "at", "by", "with", "and", "or", "not", "no", "must",
    "should", "will", "can", "do", "does", "did", "it", "its", "this",
    "that", "these", "those", "as", "if",
}
_WS = re.compile(r"[\t\r\n]+")


def sanitize(value: str) -> str:
    return _WS.sub(" ", value or "").strip()


def tokens(text: str) -> set[str]:
    return {
        t
        for t in re.split(r"[^a-z0-9]+", (text or "").lower())
        if t and t not in STOP
    }


def jaccard(a: set[str], b: set[str]) -> float:
    if not a or not b:
        return 0.0
    inter = len(a & b)
    union = len(a | b)
    return inter / union if union else 0.0


def parse_raw(text: str) -> list[dict]:
    rows = []
    for line in text.splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        while len(parts) < 8:
            parts.append("")
        try:
            rank = float(parts[0])
        except ValueError:
            rank = 0.0
        rows.append(
            {
                "rank": rank,
                "target": sanitize(parts[1]),
                "confidence": sanitize(parts[2]),
                "citation_count": sanitize(parts[3]),
                "pattern": sanitize(parts[4]),
                "proposed": sanitize(parts[5]),
                "source": sanitize(parts[6]),
                "citations": parts[7].strip(),
                "ptoks": tokens(parts[4]),
            }
        )
    return rows


def cluster_keep(rows: list[dict]) -> list[dict]:
    clusters: list[dict] = []
    for row in rows:
        placed = False
        for cluster in clusters:
            if jaccard(row["ptoks"], cluster["toks"]) >= 0.5:
                cluster["rows"].append(row)
                cluster["sessions"].add(row["source"])
                placed = True
                break
        if not placed:
            clusters.append(
                {"toks": set(row["ptoks"]), "rows": [row], "sessions": {row["source"]}}
            )
    kept = []
    for cluster in clusters:
        sessions = {s for s in cluster["sessions"] if s}
        if len(sessions) >= 2:
            kept.extend(cluster["rows"])
    return kept


def rules_for(mroot: Path, target: str) -> str:
    if target == "plugin":
        return ""
    if target == "claude":
        path = mroot / ".claude/memory/claude/lessons.md"
    else:
        path = mroot / ".claude/memory" / target / "directives.md"
    try:
        return path.read_text(encoding="utf-8")
    except OSError:
        return ""


def classify_one(row: dict, rules_text: str) -> tuple[str, str, float]:
    lines = [ln.strip() for ln in rules_text.splitlines() if ln.strip()]
    if not lines:
        return "NEW", "", 0.0
    pat_toks = row["ptoks"]
    prop_toks = tokens(row["proposed"])
    candidates = []
    seen = set()
    for ln in lines:
        ln_toks = tokens(ln)
        score = jaccard(ln_toks, prop_toks)
        overlap = len(ln_toks & pat_toks)
        if (overlap >= 2 or score >= 0.35) and ln not in seen:
            seen.add(ln)
            candidates.append((ln, score))
    if not candidates:
        return "NEW", "", 0.0
    candidates.sort(key=lambda item: item[1], reverse=True)
    best_line, best_j = candidates[0]
    action = "DUPLICATE" if best_j >= 0.65 else "TIGHTEN"
    return action, sanitize(best_line), best_j


def merge_tighten(existing: str, proposed: str) -> str:
    base = existing.strip().rstrip(".")
    text = f"{base}; additionally, {proposed}"
    return text[:200]


def emit(rows: list[dict]) -> str:
    out = []
    for row in rows:
        out.append(
            "\t".join(
                [
                    row["target"],
                    row["action"],
                    row["pattern"],
                    row["proposed"],
                    row["citation_count"],
                    row["existing"],
                    f"{row['jaccard']:.3f}",
                    row["source"],
                    row["citations"],
                ]
            )
        )
    return "\n".join(out) + ("\n" if out else "")


def run(raw: str, mode: str, mroot: Path, cap: int) -> str:
    rows = parse_raw(raw)
    if mode == "all":
        rows = cluster_keep(rows)
    rows.sort(key=lambda row: row["rank"], reverse=True)
    rows = rows[:cap]
    classified = []
    for row in rows:
        action, existing, score = classify_one(row, rules_for(mroot, row["target"]))
        proposed = row["proposed"]
        if action == "TIGHTEN":
            proposed = merge_tighten(existing, proposed)
        classified.append(
            {
                **row,
                "action": action,
                "existing": existing,
                "jaccard": score,
                "proposed": proposed,
            }
        )
    tighten_keys = {row["pattern"] for row in classified if row["action"] == "TIGHTEN"}
    kept = [
        row
        for row in classified
        if not (row["action"] == "NEW" and row["pattern"] in tighten_keys)
    ]
    return emit(kept)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", default="single")
    parser.add_argument("--mroot", default=".")
    parser.add_argument("--cap", type=int, default=5)
    args = parser.parse_args(argv[1:])
    raw = sys.stdin.read()
    sys.stdout.write(run(raw, args.mode, Path(args.mroot), args.cap))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
