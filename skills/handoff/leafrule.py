"""Single source of the /handoff M8 "leaf-uuid" rule (SPEC-018 M8).

The leaf-uuid is the cache key: the uuid of the last surviving message in the
assembled, timestamp-ordered timeline. Both `prepass.sh prepare` (over its
already-buffered records) and `prepass.sh compute_leaf` (streaming assemble.py
for cache-check / a stand-alone finalize) apply THIS one rule, so a brief built
by prepare/finalize and a later cache-check agree on the key by construction.

Importing this module (rather than re-implementing the loop) is what keeps the
two call sites from drifting apart.
"""


def keep_last_uuid(objs):
    """Return the last non-null "uuid" over objs in timeline order, or None.

    objs is any iterable of message objects (dicts). Non-dicts and entries
    without a truthy "uuid" are skipped; the final surviving uuid wins
    (the timeline is already ordered, so "keep-last" == "the leaf").
    """
    leaf = None
    for obj in objs:
        if isinstance(obj, dict):
            u = obj.get("uuid")
            if u:
                leaf = u
    return leaf
