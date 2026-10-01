#!/usr/bin/env python3
"""Insert one digest, archive its sources, and write the log, in one transaction.

usage: distill-commit.py <db> <agent> <content> <id> [id...]
DISTILL_FAIL_AFTER=insert raises before commit so a test can prove rollback.
Prints the new memory id. A failure leaves the database unchanged.
"""

import json
import os
import sqlite3
import sys

ROSTER = {"pm", "tech-lead", "ic5", "ic4", "devops", "qa", "ds"}


def main(argv):
    if len(argv) < 4:
        sys.stderr.write(
            "usage: distill-commit.py <db> <agent> <content> <id> [id...]\n"
        )
        return 64
    db_path, agent, content = argv[0], argv[1], argv[2]
    if agent not in ROSTER:
        sys.stderr.write("Error: agent must match the roster\n")
        return 64
    ids = []
    for raw in argv[3:]:
        if not raw.isdigit():
            sys.stderr.write("Error: source id must be an integer\n")
            return 64
        ids.append(int(raw))
    con = sqlite3.connect(db_path)
    try:
        con.execute("PRAGMA busy_timeout=5000")
        con.execute("BEGIN IMMEDIATE")
        cur = con.execute(
            "INSERT INTO memories(agent, type, content, tier, distilled_from) "
            "VALUES (?, 'digest', ?, 1, ?)",
            (agent, content, json.dumps(ids, separators=(",", ":"))),
        )
        new_id = cur.lastrowid
        if os.environ.get("DISTILL_FAIL_AFTER") == "insert":
            raise RuntimeError("injected failure after insert")
        marks = ",".join("?" * len(ids))
        con.execute(
            "UPDATE memories SET archived=1, archive_reason='distilled' "
            "WHERE id IN (%s) AND (archive_reason IS NULL OR archive_reason='')"
            % marks,
            ids,
        )
        con.execute(
            "INSERT INTO distillation_log"
            "(agent, from_tier, to_tier, source_count, result_memory_id) "
            "VALUES (?, 0, 1, ?, ?)",
            (agent, len(ids), new_id),
        )
        con.commit()
        sys.stdout.write("%s\n" % new_id)
        return 0
    except Exception as exc:
        con.rollback()
        sys.stderr.write("distill-commit: %s\n" % exc)
        return 1
    finally:
        con.close()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
