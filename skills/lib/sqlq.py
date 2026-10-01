#!/usr/bin/env python3
"""Run one parameterized SQL statement.

Usage: python3 skills/lib/sqlq.py <db> <sql> [arg ...]
Placeholders are `?`. Values are bound, never pasted into the statement.
"""

import sqlite3
import sys


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: sqlq.py <db> <sql> [arg ...]\n")
        return 64
    db_path, sql = argv[0], argv[1]
    params = argv[2:]
    con = sqlite3.connect(db_path)
    try:
        con.execute("PRAGMA busy_timeout=5000")
        cur = con.execute(sql, params)
        con.commit()
        if sql.lstrip()[:6].upper() == "INSERT":
            sys.stdout.write("%s\n" % cur.lastrowid)
    finally:
        con.close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
