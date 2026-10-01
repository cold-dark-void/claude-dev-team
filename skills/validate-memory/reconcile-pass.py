#!/usr/bin/env python3
"""Parameterized reconcile candidate and resolve pass. Subprocess only.

Invoked by reconcile-lib.sh. Reads and writes the memory DB with bound
parameters so memory text never becomes SQL. Keyword pairs use an inverted
index. Embed KNN uses k=5 after a larger pre-filter, and falls back to
keyword when vec0 cannot be loaded or the vector table is empty.
"""

import datetime
import heapq
import json
import os
import re
import sqlite3
import sys

AGENTS = ("pm", "tech-lead", "ic5", "ic4", "devops", "qa", "ds")
JACCARD_MIN = 0.15
EMBED_SIM_MIN = 0.55
SAMPLE_PER_AGENT = 200
EMBED_PRE_K = 32
EMBED_K = 5
TOKEN_RE = re.compile(r"[a-z0-9]+")
VEC_TABLE_RE = re.compile(r"vec_memories_[0-9]+$")


def die(msg, code=1):
    sys.stderr.write("reconcile-pass.py: %s\n" % msg)
    sys.exit(code)


def connect(path):
    if not os.path.isfile(path):
        die("database not found at %s" % path)
    con = sqlite3.connect(path)
    con.execute("PRAGMA busy_timeout=5000")
    return con


def tokenize(text):
    return [tok for tok in TOKEN_RE.findall((text or "").lower()) if len(tok) >= 4]


def config_value(con, key, default):
    row = con.execute("SELECT value FROM config WHERE key = ?", (key,)).fetchone()
    if not row or row[0] is None or row[0] == "":
        return default
    return row[0]


def clamp_cap(raw):
    try:
        cap = int(raw)
    except (TypeError, ValueError):
        cap = 50
    if cap < 1:
        return 1
    if cap > 500:
        return 500
    return cap


def sample_rows(con):
    rows = con.execute(
        "SELECT id, agent, tier, created_at, content FROM memories "
        "WHERE archived = 0 AND agent IN (?,?,?,?,?,?,?) "
        "ORDER BY agent, tier DESC, created_at DESC",
        AGENTS,
    ).fetchall()
    kept = []
    current = None
    count = 0
    for mid, agent, tier, created, content in rows:
        if agent != current:
            current = agent
            count = 0
        if count >= SAMPLE_PER_AGENT:
            continue
        kept.append(
            {
                "id": int(mid),
                "agent": agent,
                "tier": tier,
                "created_at": created,
                "content": content if content is not None else "",
            }
        )
        count += 1
    return kept


def resolved_pairs(con):
    found = set()
    query = (
        "SELECT memory_id_a, memory_id_b FROM reconcile_log "
        "WHERE action IN ('pick-survivor','merge','both-stale')"
    )
    for a, b in con.execute(query):
        ia, ib = int(a), int(b)
        if ia > ib:
            ia, ib = ib, ia
        found.add((ia, ib))
    return found


def keyword_scores(rows):
    """Inverted-index Jaccard. Yields (score, i, j) with i < j and different agents."""
    token_sets = []
    postings = {}
    for index, row in enumerate(rows):
        toks = set(tokenize(row["content"]))
        token_sets.append(toks)
        for tok in toks:
            postings.setdefault(tok, []).append(index)
    inter = {}
    for ids in postings.values():
        if len(ids) < 2:
            continue
        for left in range(len(ids)):
            i = ids[left]
            agent_i = rows[i]["agent"]
            for right in range(left + 1, len(ids)):
                j = ids[right]
                if agent_i == rows[j]["agent"]:
                    continue
                a, b = (i, j) if i < j else (j, i)
                inter[(a, b)] = inter.get((a, b), 0) + 1
    for (i, j), shared in inter.items():
        union = len(token_sets[i]) + len(token_sets[j]) - shared
        if union <= 0:
            continue
        score = shared / float(union)
        if score + 1e-12 >= JACCARD_MIN:
            yield score, i, j


def vec_extension(memdb):
    ext_dir = os.path.join(os.path.dirname(memdb), "extensions")
    suffix = "dylib" if sys.platform == "darwin" else "so"
    return os.path.join(ext_dir, "vec0." + suffix)


def load_vec_extension(con, memdb):
    """Load vec0 before any query against a virtual vec table. False if it cannot."""
    ext = vec_extension(memdb)
    if not os.path.isfile(ext) or os.path.getsize(ext) == 0:
        return False
    try:
        con.enable_load_extension(True)
        con.load_extension(ext)
    except (AttributeError, sqlite3.Error):
        return False
    return True


def try_embed(con, rows, memdb):
    """Return a list of (score, i, j) or None when keyword must run."""
    mode = str(config_value(con, "embedding_mode", "fallback"))
    dims = str(config_value(con, "embedding_dimensions", "0"))
    if mode == "fallback" or not dims.isdigit() or int(dims) <= 0:
        return None
    table = "vec_memories_%s" % dims
    if not VEC_TABLE_RE.fullmatch(table):
        return None
    present = con.execute(
        "SELECT 1 FROM sqlite_master WHERE type IN ('table','virtual') AND name = ? LIMIT 1",
        (table,),
    ).fetchone()
    if not present:
        return None
    # A sqlite-vec virtual table cannot be counted until the module is loaded.
    if not load_vec_extension(con, memdb):
        return None
    try:
        count = con.execute("SELECT COUNT(*) FROM %s" % table).fetchone()[0]
    except sqlite3.Error:
        return None
    if not count:
        return None
    by_id = {row["id"]: idx for idx, row in enumerate(rows)}
    best = {}
    knn = (
        "SELECT e.memory_id, m.agent, e.distance FROM %s e "
        "JOIN memories m ON m.id = e.memory_id "
        "WHERE e.embedding MATCH (SELECT embedding FROM %s WHERE memory_id = ?) "
        "AND k = %d AND m.archived = 0 AND m.agent != ? AND e.memory_id != ?"
        % (table, table, EMBED_PRE_K)
    )
    try:
        for row in rows:
            neighbors = []
            for oid, oagent, dist in con.execute(knn, (row["id"], row["agent"], row["id"])):
                try:
                    # vec0 tables use distance_metric=cosine, so this is cosine similarity.
                    sim = 1.0 - float(dist)
                except (TypeError, ValueError):
                    continue
                if sim + 1e-12 < EMBED_SIM_MIN:
                    continue
                if oagent == row["agent"]:
                    continue
                neighbors.append((sim, int(oid)))
            neighbors.sort(reverse=True)
            for sim, oid in neighbors[:EMBED_K]:
                other = by_id.get(oid)
                if other is None:
                    continue
                i, j = (by_id[row["id"]], other) if by_id[row["id"]] < other else (other, by_id[row["id"]])
                prev = best.get((i, j))
                if prev is None or sim > prev:
                    best[(i, j)] = sim
    except sqlite3.Error:
        return None
    return [(score, i, j) for (i, j), score in best.items()]


def emit_candidates(con, memdb, agent_filter, cap, out_path):
    rows = sample_rows(con)
    embed = try_embed(con, rows, memdb)
    if embed is None:
        method = "keyword"
        scored = keyword_scores(rows)
    else:
        method = "embed"
        scored = embed
    done = resolved_pairs(con)
    heap = []
    qualified = 0
    seq = 0
    for score, i, j in scored:
        left, right = rows[i], rows[j]
        if left["agent"] == right["agent"]:
            continue
        if agent_filter and agent_filter not in (left["agent"], right["agent"]):
            continue
        ia, ib = left["id"], right["id"]
        if ia > ib:
            ia, ib = ib, ia
            left, right = right, left
        if (ia, ib) in done:
            continue
        qualified += 1
        seq += 1
        item = (score, seq, ia, left, ib, right)
        if len(heap) < cap:
            heapq.heappush(heap, item)
        elif score > heap[0][0]:
            heapq.heapreplace(heap, item)
    chosen = sorted(heap, key=lambda item: (-item[0], item[2], item[4]))
    lines = []
    for score, _seq, ia, left, ib, right in chosen:
        lines.append(
            json.dumps(
                {
                    "id_a": ia,
                    "agent_a": left["agent"],
                    "content_a": left["content"],
                    "id_b": ib,
                    "agent_b": right["agent"],
                    "content_b": right["content"],
                    "score": float(score),
                    "method": method,
                },
                ensure_ascii=False,
            )
        )
    payload = ("\n".join(lines) + ("\n" if lines else ""))
    if out_path:
        with open(out_path, "w", encoding="utf-8") as handle:
            handle.write(payload)
    else:
        sys.stdout.write(payload)
    cap_hit = "true" if qualified > cap else "false"
    sys.stderr.write(
        "RECONCILE_META candidates=%d cap=%d cap_hit=%s method=%s\n"
        % (len(chosen), cap, cap_hit, method)
    )


def require_pair(con, id_a, id_b):
    if id_a == id_b:
        die("winner and loser are the same id")
    for mid in (id_a, id_b):
        row = con.execute(
            "SELECT archived FROM memories WHERE id = ?", (mid,)
        ).fetchone()
        if row is None:
            die("memory id %s does not exist" % mid)
        if row[0]:
            die("memory id %s is archived" % mid)


def insert_log(con, id_a, id_b, agent_a, agent_b, claim_a, claim_b, conf, action, winner, loser, reason):
    con.execute(
        "INSERT INTO reconcile_log("
        "memory_id_a, memory_id_b, agent_a, agent_b, verdict, claim_a, claim_b, "
        "confidence, action, winner_id, loser_id, reason) "
        "VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
        (
            id_a,
            id_b,
            agent_a,
            agent_b,
            "contradictory",
            claim_a,
            claim_b,
            conf,
            action,
            winner,
            loser,
            reason,
        ),
    )


def drop_winner_vectors(con, winner):
    names = con.execute(
        "SELECT name FROM sqlite_master WHERE type IN ('table','virtual') AND name LIKE 'vec_memories_%'"
    ).fetchall()
    for (name,) in names:
        if not VEC_TABLE_RE.fullmatch(name):
            continue
        try:
            con.execute("DELETE FROM %s WHERE memory_id = ?" % name, (winner,))
        except sqlite3.OperationalError as exc:
            # Virtual table whose module did not load. Do not abort the merge.
            if "no such module" in str(exc).lower():
                continue
            raise


def in_txn(con, body):
    con.execute("BEGIN IMMEDIATE")
    try:
        body()
    except Exception:
        con.execute("ROLLBACK")
        raise
    else:
        con.execute("COMMIT")


def cmd_resolve_pick(con, winner, loser, agent_a, agent_b, claim_a, claim_b, conf, reason):
    def body():
        require_pair(con, winner, loser)
        con.execute(
            "UPDATE memories SET archived = 1, archive_reason = 'reconciled' WHERE id = ?",
            (loser,),
        )
        insert_log(
            con, winner, loser, agent_a, agent_b, claim_a, claim_b, conf,
            "pick-survivor", winner, loser, reason,
        )

    in_txn(con, body)


def cmd_resolve_both(con, id_a, id_b, agent_a, agent_b, claim_a, claim_b, conf, reason):
    def body():
        require_pair(con, id_a, id_b)
        con.execute(
            "UPDATE memories SET archived = 1, archive_reason = 'reconciled' WHERE id IN (?,?)",
            (id_a, id_b),
        )
        insert_log(
            con, id_a, id_b, agent_a, agent_b, claim_a, claim_b, conf,
            "both-stale", None, None, reason,
        )

    in_txn(con, body)


def cmd_resolve_merge(con, memdb, winner, loser, agent_a, agent_b, claim_a, claim_b, conf, merged, reason):
    cleaned = re.sub(r"\[reconciled: [0-9-]*\]", "", merged or "")
    today = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    tagged = cleaned.rstrip() + "\n\n[reconciled: %s]" % today
    # Load vec0 before the transaction. A virtual table DELETE needs the module.
    load_vec_extension(con, memdb)

    def body():
        require_pair(con, winner, loser)
        con.execute(
            "UPDATE memories SET content = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') "
            "WHERE id = ?",
            (tagged, winner),
        )
        con.execute(
            "UPDATE memories SET archived = 1, archive_reason = 'reconciled' WHERE id = ?",
            (loser,),
        )
        drop_winner_vectors(con, winner)
        insert_log(
            con, winner, loser, agent_a, agent_b, claim_a, claim_b, conf,
            "merge", winner, loser, reason,
        )

    in_txn(con, body)


def cmd_resolve_skip(con, id_a, id_b, agent_a, agent_b, claim_a, claim_b, conf, reason, action):
    def body():
        require_pair(con, id_a, id_b)
        insert_log(
            con, id_a, id_b, agent_a, agent_b, claim_a, claim_b, conf,
            action, None, None, reason,
        )

    in_txn(con, body)


def council_line(claim_a, claim_b):
    def esc(text):
        return (
            (text or "")
            .replace("\\", "\\\\")
            .replace('"', '\\"')
            .replace("`", "\\`")
            .replace("$", "\\$")
        )

    sys.stdout.write('/council "%s vs %s"\n' % (esc(claim_a), esc(claim_b)))


def as_int(label, raw):
    if raw is None or not str(raw).isdigit():
        die("%s must be an integer, got '%s'" % (label, raw), 64)
    return int(raw)


def parse_candidates(argv):
    if not argv:
        die("candidates requires a database path", 64)
    memdb = argv[0]
    agent = None
    cap = None
    out_path = None
    index = 1
    while index < len(argv):
        flag = argv[index]
        if flag in ("--agent", "--cap", "--out"):
            if index + 1 >= len(argv):
                die("%s requires a value" % flag, 64)
            value = argv[index + 1]
            if flag == "--agent":
                agent = value
            elif flag == "--cap":
                cap = value
            else:
                out_path = value
            index += 2
            continue
        die("unknown argument: %s" % flag, 64)
    con = connect(memdb)
    try:
        if cap is None:
            cap = config_value(con, "reconcile_pair_cap", "50")
        emit_candidates(con, memdb, agent, clamp_cap(cap), out_path)
    finally:
        con.close()


def resolve_args(argv, count):
    if len(argv) < count:
        die("resolve requires %d arguments" % count, 64)
    return argv[:count]


def main(argv):
    if not argv:
        die("missing command", 64)
    cmd = argv[0]
    rest = argv[1:]
    if cmd == "candidates":
        parse_candidates(rest)
        return
    if cmd == "resolve-pick":
        memdb, winner, loser, agent_a, agent_b, claim_a, claim_b, conf, reason = resolve_args(rest, 9)
        con = connect(memdb)
        try:
            cmd_resolve_pick(
                con, as_int("winner", winner), as_int("loser", loser),
                agent_a, agent_b, claim_a, claim_b, as_int("confidence", conf), reason,
            )
        finally:
            con.close()
        return
    if cmd == "resolve-both-stale":
        memdb, id_a, id_b, agent_a, agent_b, claim_a, claim_b, conf, reason = resolve_args(rest, 9)
        con = connect(memdb)
        try:
            cmd_resolve_both(
                con, as_int("id_a", id_a), as_int("id_b", id_b),
                agent_a, agent_b, claim_a, claim_b, as_int("confidence", conf), reason,
            )
        finally:
            con.close()
        return
    if cmd == "resolve-merge":
        memdb, winner, loser, agent_a, agent_b, claim_a, claim_b, conf, merged, reason = resolve_args(rest, 10)
        con = connect(memdb)
        try:
            cmd_resolve_merge(
                con, memdb, as_int("winner", winner), as_int("loser", loser),
                agent_a, agent_b, claim_a, claim_b, as_int("confidence", conf), merged, reason,
            )
        finally:
            con.close()
        return
    if cmd in ("resolve-skip", "resolve-deep-audit"):
        memdb, id_a, id_b, agent_a, agent_b, claim_a, claim_b, conf, reason = resolve_args(rest, 9)
        action = "skip" if cmd == "resolve-skip" else "deep-audit"
        con = connect(memdb)
        try:
            cmd_resolve_skip(
                con, as_int("id_a", id_a), as_int("id_b", id_b),
                agent_a, agent_b, claim_a, claim_b, as_int("confidence", conf), reason, action,
            )
        finally:
            con.close()
        if cmd == "resolve-deep-audit":
            council_line(claim_a, claim_b)
        return
    die("unknown command: %s" % cmd, 64)


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except SystemExit:
        raise
    except Exception as exc:
        die(str(exc), 1)
