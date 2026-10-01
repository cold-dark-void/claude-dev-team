#!/usr/bin/env python3
"""Run one parameterized SQL statement.

Usage: python3 skills/lib/sqlq.py <db> <sql> [arg ...]
Placeholders are `?`. Values are bound, never pasted into the statement.
"""

import sqlite3
import sys


def _cell(value):
    if value is None:
        return ""
    return str(value)


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: sqlq.py <db> <sql> [arg ...]\n")
        return 64
    db_path, sql = argv[0], argv[1]
    params = argv[2:]
    try:
        con = sqlite3.connect(db_path)
    except sqlite3.Error as exc:
        sys.stderr.write("sqlq: %s\n" % exc)
        return 1
    try:
        con.execute("PRAGMA busy_timeout=5000")
        con.execute("PRAGMA foreign_keys=ON")
        cur = con.execute(sql, params)
        if cur.description:
            for row in cur:
                sys.stdout.write("|".join(_cell(col) for col in row) + "\n")
        elif sql.lstrip()[:6].upper() == "INSERT":
            sys.stdout.write("%s\n" % cur.lastrowid)
        con.commit()
    except sqlite3.Error as exc:
        try:
            con.rollback()
        except sqlite3.Error:
            pass
        sys.stderr.write("sqlq: %s\n" % exc)
        return 1
    finally:
        con.close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
