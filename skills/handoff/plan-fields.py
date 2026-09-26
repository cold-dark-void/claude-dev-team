#!/usr/bin/env python3
"""plan-fields.py — jq-free plan.json + live-session.json field extraction.

SPEC-018 M19.11 (CDT-266, W1-27, E5): replaces the 4 `jq` calls in
commands/handoff.md Step 1 with one python3 helper (python3 is already a
/handoff dependency via prepass.sh).

Usage:
  plan-fields.py <plan.json> <live-session.json>

Stdout: exactly 5 lines, in order:
  MODE   plan.mode, or "" when absent/not a string
  SLA    "true" iff plan.stats.since_leaf_applied is JSON true, else "false"
  ET     plan.stats.est_tokens when a non-negative int, else ""
  HOST   live-session.json .host when a non-empty string, else "claude"
         (missing/unreadable/invalid live-session.json also falls back to "claude")
  SPINE  plan.spine, or "" when absent/not a string

Exit 0 on success. plan.json missing/unreadable/invalid JSON/not an object ->
"plan-fields: <reason>" on stderr, exit 1. live-session.json problems never
fail the call (HOST just falls back to "claude").
"""
import json
import sys


def _str_or_empty(value):
    return value if isinstance(value, str) else ""


def _non_negative_int_or_empty(value):
    # bool is an int subclass in Python -- exclude it explicitly.
    if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
        return str(value)
    return ""


def _host(live_path):
    try:
        with open(live_path, encoding="utf-8") as fh:
            live = json.load(fh)
    except (OSError, ValueError):
        return "claude"
    if not isinstance(live, dict):
        return "claude"
    host = live.get("host")
    return host if isinstance(host, str) and host.strip() else "claude"


def main(argv):
    if len(argv) != 3:
        print("plan-fields: usage: plan-fields.py <plan.json> <live-session.json>",
              file=sys.stderr)
        return 1
    plan_path, live_path = argv[1], argv[2]

    try:
        with open(plan_path, encoding="utf-8") as fh:
            plan = json.load(fh)
    except (OSError, ValueError) as exc:
        print(f"plan-fields: {exc}", file=sys.stderr)
        return 1
    if not isinstance(plan, dict):
        print("plan-fields: plan.json is not a JSON object", file=sys.stderr)
        return 1

    stats = plan.get("stats")
    stats = stats if isinstance(stats, dict) else {}

    mode = _str_or_empty(plan.get("mode"))
    sla = "true" if stats.get("since_leaf_applied") is True else "false"
    est_tokens = _non_negative_int_or_empty(stats.get("est_tokens"))
    host = _host(live_path)
    spine = _str_or_empty(plan.get("spine"))

    print(mode)
    print(sla)
    print(est_tokens)
    print(host)
    print(spine)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
