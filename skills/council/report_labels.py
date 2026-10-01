"""Report claim labeling (SPEC-033 M14(g); WP 1-15 AC H, interface contract C6).

Resolves which claim a judge verdict belongs to, and renders the claim id
alongside its text in the finalize report. Imported by engine.sh's finalize
heredoc via COUNCIL_SKILL_DIR on sys.path. label_verdict never returns "?"
for a claim id.
"""


def resolve_claims(plan, evidence_raw, judge_items):
    """Return list of dict(claim_id, claim, source_locator, claim_type).

    Source order (first non-empty wins):
      1. plan.claims[] (M14 per-AC claims).
      2. single-claim scope ("claim" / "from-retro"): one c0 from
         plan.resolved_claim (from-retro) or plan.scope_arg (claim).
      3. evidence extracted_claims / claims, with c<i> given where the
         item carries no id.
      4. judge items.
    """
    if not isinstance(plan, dict):
        plan = {}

    plan_claims = plan.get("claims")
    if isinstance(plan_claims, list) and plan_claims:
        out = []
        for c in plan_claims:
            if not isinstance(c, dict):
                continue
            out.append({
                "claim_id": c.get("claim_id", ""),
                "claim": c.get("claim", ""),
                "source_locator": c.get("source_locator", ""),
                "claim_type": c.get("claim_type", "factual"),
            })
        if out:
            return out

    scope = plan.get("scope")
    single_text = ""
    if scope == "from-retro":
        single_text = plan.get("resolved_claim") or ""
    elif scope == "claim":
        single_text = plan.get("scope_arg") or ""
    if single_text:
        return [{
            "claim_id": "c0",
            "claim": single_text,
            "source_locator": "",
            "claim_type": "factual",
        }]

    if isinstance(evidence_raw, dict):
        extracted = evidence_raw.get("extracted_claims", evidence_raw.get("claims", []))
    else:
        extracted = []
    if isinstance(extracted, list) and extracted:
        out = []
        for i, c in enumerate(extracted):
            if isinstance(c, dict):
                cid = c.get("claim_id") or f"c{i}"
                ctext = c.get("claim_text", c.get("claim", c.get("text", "")))
                src = c.get("source_locator", c.get("source", ""))
                ctype = c.get("claim_type", c.get("type", "factual"))
            else:
                cid = f"c{i}"
                ctext = str(c)
                src = ""
                ctype = "factual"
            out.append({
                "claim_id": cid,
                "claim": ctext,
                "source_locator": src,
                "claim_type": ctype,
            })
        return out

    if isinstance(judge_items, list) and judge_items:
        out = []
        for i, v in enumerate(judge_items):
            if not isinstance(v, dict):
                continue
            cid = v.get("claim_id") or f"c{i}"
            ctext = v.get("claim", v.get("description", ""))
            out.append({
                "claim_id": cid,
                "claim": ctext,
                "source_locator": "",
                "claim_type": "factual",
            })
        return out

    return []


def label_verdict(v, claims):
    """Return (claim_id, claim_text) for one judge verdict. Never "?".

    Order:
      1. v.claim_id (text from the matching claim, else v.claim).
      2. an exact v.claim text match.
      3. the only claim when len(claims) == 1.
      4. ("unmatched", v.claim).
    """
    if not isinstance(v, dict):
        v = {}
    if not isinstance(claims, list):
        claims = []
    vclaim = v.get("claim", "")

    vcid = v.get("claim_id")
    if isinstance(vcid, str) and vcid.strip() in ("", "?"):
        # A degraded brief (e.g. workflow.js) can emit claim_id "?" for an
        # unresolved claim, and a judge can echo it verbatim. Treat that
        # the same as no id at all, so it falls through to the text /
        # sole-claim rules instead of rendering "### Claim ?:".
        vcid = None
    if vcid:
        for c in claims:
            if c.get("claim_id") == vcid:
                return vcid, (c.get("claim") or vclaim)
        return vcid, vclaim

    if vclaim:
        for c in claims:
            if c.get("claim") == vclaim:
                return (c.get("claim_id") or "unmatched"), vclaim

    if len(claims) == 1:
        c = claims[0]
        return (c.get("claim_id") or "c0"), (c.get("claim") or vclaim)

    return "unmatched", vclaim


def load_usable_tokens(path):
    """CDV-204 tokens file → dict or None. Shared by finalize render and stdout.

    Never invents 0. source "unavailable", non-dict, or no positive ints → None.
    """
    import json
    import os

    if not path or not os.path.isfile(path):
        return None
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError, TypeError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    source = data.get("source") or ""
    if source == "unavailable":
        return None
    raw_phases = data.get("phases") or {}
    if not isinstance(raw_phases, dict):
        raw_phases = {}
    clean = {}
    for k, v in raw_phases.items():
        if v is None:
            continue
        try:
            n = int(v)
        except (TypeError, ValueError):
            continue
        if n > 0:
            clean[str(k)] = n
    total = data.get("total")
    total_n = None
    if total is not None:
        try:
            t = int(total)
            if t > 0:
                total_n = t
        except (TypeError, ValueError):
            total_n = None
    if total_n is None and clean:
        total_n = sum(clean.values())
    if not clean and total_n is None:
        return None
    partial = source == "partial" or bool(data.get("partial"))
    return {"phases": clean, "total": total_n, "partial": partial, "source": source}
