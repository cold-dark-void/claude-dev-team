#!/usr/bin/env bash
# Distill lock. A holder releases only its own token. A lock older than
# 30 minutes is stale and may be taken. guard exits 1 when a fresh foreign
# lock is held, and exits 0 for the owner, an empty lock, or a stale lock.
# usage: distill-lock.sh acquire|release|guard|force-clear <db> [token]
set -euo pipefail

cmd=${1:-}
db=${2:-}
token=${3:-}
if [ -z "$cmd" ] || [ -z "$db" ]; then
  echo "usage: distill-lock.sh acquire|release|guard|force-clear <db> [token]" >&2
  exit 64
fi

exec python3 - "$cmd" "$db" "$token" <<'PY'
import os
import sqlite3
import sys
import time

cmd, db, token = sys.argv[1], sys.argv[2], sys.argv[3]
ttl = 1800
con = sqlite3.connect(db)
con.execute("PRAGMA busy_timeout=5000")

def current():
    row = con.execute(
        "SELECT value FROM config WHERE key='distilling_lock'"
    ).fetchone()
    if row is None or row[0] is None:
        return ""
    return row[0]

def is_stale(value, now):
    if value == "":
        return True
    if not value.startswith("distill-"):
        return False
    epoch = value[len("distill-"):].split("-", 1)[0]
    if not epoch.isdigit():
        return False
    return now - int(epoch) > ttl

now = int(time.time())
cur = current()

if cmd == "acquire":
    if not is_stale(cur, now):
        sys.stderr.write("distill-lock: held by %s\n" % cur)
        sys.exit(75)
    new = "distill-%d-%d" % (now, os.getpid())
    cur_row = con.execute(
        "UPDATE config SET value=? WHERE key='distilling_lock' AND value=?",
        (new, cur),
    )
    con.commit()
    if cur_row.rowcount != 1:
        sys.stderr.write("distill-lock: held by %s\n" % current())
        sys.exit(75)
    sys.stdout.write(new + "\n")
elif cmd == "release":
    con.execute(
        "UPDATE config SET value='' WHERE key='distilling_lock' AND value=?",
        (token,),
    )
    con.commit()
elif cmd == "force-clear":
    con.execute("UPDATE config SET value='' WHERE key='distilling_lock'")
    con.commit()
elif cmd == "guard":
    if is_stale(cur, now) or cur == token:
        sys.exit(0)
    sys.stderr.write("distill-lock: held by %s\n" % cur)
    sys.exit(1)
else:
    sys.stderr.write("usage: distill-lock.sh acquire|release|guard|force-clear <db> [token]\n")
    sys.exit(64)
PY
