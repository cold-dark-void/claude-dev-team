# council/engine-finalize.sh — cmd_finalize (render + atomic write), sourced by engine.sh (L-10).

# ---- finalize ---------------------------------------------------------------
# Consume plan + evidence + judge output, render report, write index row.
# Inputs: --plan-file, --evidence-file, --judge-output. Does not interpret
# semantics beyond branching on output_shape and computing max_confidence.
cmd_finalize() {
  require_jq
  require_python3

  local plan_file="" evidence_file="" judge_output="" task_id="" report_out=""
  local cross_review_status="" cross_review_rankings="" cross_review_scores=""
  local verification_mode="" tokens_file="" degradation_reason=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --plan-file)     need_val "$1" $#; plan_file="$2"; shift 2 ;;
      --evidence-file) need_val "$1" $#; evidence_file="$2"; shift 2 ;;
      --judge-output)  need_val "$1" $#; judge_output="$2"; shift 2 ;;
      --task-id)       need_val "$1" $#; task_id="$2"; shift 2 ;;
      --report-out)    need_val "$1" $#; report_out="$2"; shift 2 ;;
      --cross-review-status)    need_val "$1" $#; cross_review_status="$2"; shift 2 ;;
      --cross-review-rankings)  need_val "$1" $#; cross_review_rankings="$2"; shift 2 ;;
      --cross-review-scores)    need_val "$1" $#; cross_review_scores="$2"; shift 2 ;;
      --verification-mode)      need_val "$1" $#; verification_mode="$2"; shift 2 ;;
      --degradation-reason)     need_val "$1" $#; degradation_reason="$2"; shift 2 ;;
      --tokens-file)            need_val "$1" $#; tokens_file="$2"; shift 2 ;;
      *)
        echo "engine.sh: unknown finalize flag: $1" >&2
        exit 2
        ;;
    esac
  done

  # Default full (happy path). Accept only full|self-verified (CDV-199).
  if [ -z "$verification_mode" ]; then
    verification_mode="full"
  fi
  case "$verification_mode" in
    full|self-verified) ;;
    *)
      echo "engine.sh: --verification-mode must be full|self-verified (got: $verification_mode)" >&2
      exit 2
      ;;
  esac

  if [ -z "$plan_file" ] || [ ! -f "$plan_file" ]; then
    echo "engine.sh: finalize requires --plan-file <path> (existing file)" >&2
    exit 2
  fi
  if [ -z "$evidence_file" ] || [ ! -f "$evidence_file" ]; then
    echo "engine.sh: finalize requires --evidence-file <path> (existing file)" >&2
    exit 2
  fi
  if [ -z "$judge_output" ] || [ ! -f "$judge_output" ]; then
    echo "engine.sh: finalize requires --judge-output <path> (existing file)" >&2
    exit 2
  fi

  # Extract plan metadata
  local output_shape scope preset slug plan_task_id plan_report_path
  output_shape=$(jq -r '.output_shape' "$plan_file")
  scope=$(jq -r '.scope' "$plan_file")
  preset=$(jq -r '.preset' "$plan_file")
  slug=$(jq -r '.slug' "$plan_file")
  plan_task_id=$(jq -r '.task_id // ""' "$plan_file")
  plan_report_path=$(jq -r '.report_path' "$plan_file")
  # Original on-disk value — used below to decide whether the plan file needs
  # rewriting after reservation (SPEC-013 Phase 6 "one path everywhere").
  local plan_report_path_orig="$plan_report_path"

  # CDT-126: the plan is the sole carrier of the tier — preflight resolved it,
  # finalize only records it (frontmatter + index row). Plans written before
  # tiering landed have neither key; those runs are `full` by definition.
  local council_tier grading_reason
  council_tier=$(jq -r '.council_tier // "full"' "$plan_file")
  grading_reason=$(jq -r '.grading_reason // ""' "$plan_file")
  # Coerce here, once, so the report and the index row cannot disagree: the
  # renderer used to fail closed to "full" on its own while index-writer.sh
  # hard-rejected the same raw value, which wrote a report claiming "full" and
  # then aborted the run with exit 6 and no index row.
  case "$council_tier" in
    light|full) ;;
    *)
      echo "engine.sh: plan carries an invalid council_tier ($council_tier) — failing closed to full" >&2
      council_tier="full"
      ;;
  esac

  # task-id on finalize overrides plan's task-id if given
  if [ -z "$task_id" ]; then
    task_id="$plan_task_id"
  fi

  # Reject a bad id before any report reservation, plan rewrite, or index
  # write. Empty task_id is unbound (no index row), not an error.
  if [ -n "$task_id" ]; then
    validate_path_component "task-id" "$task_id"
  fi
  if [ -n "$slug" ] && [ "$slug" != "null" ]; then
    validate_path_component "slug" "$slug"
  fi

  # Recompute report path if task_id changed (the plan's recorded path was
  # built for the old task-id suffix and names the wrong file entirely).
  if [ -n "$report_out" ]; then
    plan_report_path="$report_out"
  elif [ "$task_id" != "$plan_task_id" ]; then
    plan_report_path=$(cmd_report_path "$slug" --task-id "$task_id")
  fi

  # Report no-overwrite (SPEC-013 Phase 6, WP 1-14): reserve the path again
  # at write time, right before rendering. `--report-out` is exempt — it
  # reserves nothing and can overwrite; the caller that passes it owns that
  # risk (unchanged from before WP 1-14).
  if [ -z "$report_out" ]; then
    local reserved_path
    if ! reserved_path=$(finalize_reserve_report_path "$slug" "$task_id" "$plan_report_path"); then
      echo "engine.sh: report no-overwrite: every candidate up to -99 is taken for slug '$slug' — writing no report (SPEC-013 Phase 6)" >&2
      exit 9
    fi
    plan_report_path="$reserved_path"
    # One path everywhere: when the reserved path differs from what the plan
    # already recorded (a collision, or a task-id-driven recompute), rewrite
    # plan.report_path (tmp + rename) so plan / rendered report / sidecar /
    # `Council report:` line / index row all agree, and say so once on stderr.
    if [ "$plan_report_path" != "$plan_report_path_orig" ]; then
      local plan_tmp
      plan_tmp=$(mktemp "${plan_file}.XXXXXX")
      jq --arg rp "$plan_report_path" '.report_path = $rp' "$plan_file" > "$plan_tmp"
      mv -- "$plan_tmp" "$plan_file"
      echo "engine.sh: report_path reserved at $plan_report_path (plan recorded $plan_report_path_orig) — rewrote plan.report_path (SPEC-013 Phase 6 report no-overwrite)" >&2
    fi
  fi

  # Validate output_shape and select template
  local template_file
  case "$output_shape" in
    "verdict[]") template_file="$TEMPLATE_DIR/report-verdict.md" ;;
    "finding[]") template_file="$TEMPLATE_DIR/report-finding.md" ;;
    *)
      echo "engine.sh: invalid output_shape in plan: $output_shape" >&2
      exit 7
      ;;
  esac

  if [ ! -f "$template_file" ]; then
    echo "engine.sh: report template missing: $template_file" >&2
    exit 7
  fi

  # Validate evidence file is parseable JSON. Investigator raw_blob fields
  # may contain code with backslashes (regex, paths) that the LLM fails to
  # escape properly. Attempt repair before any jq calls.
  if ! jq empty "$evidence_file" 2>/dev/null; then
    repair_json_file "$evidence_file" evidence "evidence file" 5
  fi

  # Validate evidence file is non-empty JSON array. An empty bundle set is
  # exit 5 per SKILL.md failure-mode table.
  local evidence_count
  evidence_count=$(jq 'if type == "array" then length elif type == "object" then (.bundles // .evidence_bundles // []) | length else 0 end' "$evidence_file")
  if [ "$evidence_count" = "0" ]; then
    echo "engine.sh: Phase 2 produced zero evidence bundles — aborting" >&2
    exit 5
  fi

  # Validate judge output is parseable JSON. The judge is an LLM agent and
  # may emit malformed JSON (markdown fences, trailing text, unescaped chars).
  # Apply the same backslash repair as evidence, then validate.
  if ! jq empty "$judge_output" 2>/dev/null; then
    repair_json_file "$judge_output" judge "judge output" 7
  fi

  # CDT-390: a top-level JSON array has no .verdicts / .findings. Wrap it
  # before render and before the stdout counters so those jq paths stay object
  # form. Verdict shape → {"verdicts":[...]} ; finding shape → {"findings":[...]}.
  if ! normalize_judge_shape "$judge_output" "$output_shape"; then
    echo "engine.sh: failed to normalize judge output shape" >&2
    exit 7
  fi

  # max_*_confidence + struck_count come from finalize-meta.json after render
  # (unstruck-only; CDT-178). Pre-python all-items max would desync the index.
  # Confidence ints via Python int() (floor-compatible with CDT-181 index-writer).

  # Ensure parent dir exists
  mkdir -p "$(dirname "$plan_report_path")"

  # Render report: python3 reads the template + all JSON inputs, substitutes
  # every {{VAR}} placeholder, and writes the fully-rendered report.
  local created_at
  created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  export COUNCIL_SKILL_DIR="$SCRIPT_DIR"
  python3 - "$template_file" "$plan_file" "$evidence_file" "$judge_output" \
    "$plan_report_path" "$scope" "$preset" "$output_shape" "$created_at" \
    "$task_id" "$cross_review_status" "$cross_review_rankings" \
    "$cross_review_scores" "$verification_mode" "${tokens_file:-}" \
    "$council_tier" "$grading_reason" "$degradation_reason" <<'PYEOF'
import json, sys, os, re, math
from collections import Counter

# WP 1-15 C6: report_labels.py resolves claim ids/text for the report (AC H).
# COUNCIL_SKILL_DIR is engine.sh's own SCRIPT_DIR, set on the invocation.
sys.path.insert(0, os.environ["COUNCIL_SKILL_DIR"])
from report_labels import resolve_claims, label_verdict, load_usable_tokens

template_file  = sys.argv[1]
plan_file      = sys.argv[2]
evidence_file  = sys.argv[3]
judge_file     = sys.argv[4]
output_path    = sys.argv[5]
scope          = sys.argv[6]
preset         = sys.argv[7]
output_shape   = sys.argv[8]
created_at     = sys.argv[9]
task_id        = sys.argv[10] if len(sys.argv) > 10 else ""
cross_review_status   = sys.argv[11]
cross_review_rankings = sys.argv[12]
cross_review_scores   = sys.argv[13]
verification_mode     = sys.argv[14] if len(sys.argv) > 14 else "full"
tokens_file           = sys.argv[15] if len(sys.argv) > 15 else ""
council_tier          = sys.argv[16] if len(sys.argv) > 16 else "full"
grading_reason        = sys.argv[17] if len(sys.argv) > 17 else ""
degradation_reason    = sys.argv[18] if len(sys.argv) > 18 else ""
if verification_mode not in ("full", "self-verified"):
    verification_mode = "full"

def yaml_dq(s):
    """Escape a value for a double-quoted YAML scalar. grading_reason can carry
    LLM-authored triage text, so quotes and newlines must not escape the field."""
    return (s.replace("\\", "\\\\").replace('"', '\\"')
             .replace("\r", " ").replace("\n", " "))

# CDV-204: optional per-phase tokens (orchestrator-owned file). Never invent 0.
# Parser lives in report_labels.load_usable_tokens — one copy for render and stdout.
tokens_data = load_usable_tokens(tokens_file)

# CDV-199: banner only when orchestrator self-verified after spawn failure
if verification_mode == "self-verified":
    _deg = degradation_reason.strip() if isinstance(degradation_reason, str) else ""
    _detail = (
        _deg
        if _deg
        else "Orchestrator performed adversarial checks after refuter/investigator spawn failure."
    )
    verification_banner = (
        "> **self-verified — refuters unavailable**\n"
        f"> {_detail}\n"
    )
else:
    verification_banner = ""

# Phase 2.5 fallbacks when flags absent
if not cross_review_status:
    cross_review_status = "Phase 2.5 not run"
if not cross_review_rankings:
    cross_review_rankings = "_Phase 2.5 not run — no cross-review rankings._"
if not cross_review_scores:
    cross_review_scores = "_Phase 2.5 not run — no Borda scores._"

# --- Load JSON inputs ---
with open(plan_file) as f:
    plan = json.load(f)
with open(evidence_file) as f:
    evidence_raw = json.load(f)
with open(judge_file) as f:
    judge_raw = json.load(f)

# Evidence file may be a flat array of bundles or an object with sub-keys
if isinstance(evidence_raw, list):
    bundles = evidence_raw
    prosecutor_brief = ""
    advocate_brief = ""
    extracted_claims_raw = []
    struck_lines_raw = []
else:
    bundles = evidence_raw.get("bundles", evidence_raw.get("evidence_bundles", []))
    prosecutor_brief = evidence_raw.get("prosecutor_brief", "")
    advocate_brief = evidence_raw.get("advocate_brief", "")
    extracted_claims_raw = evidence_raw.get("extracted_claims", evidence_raw.get("claims", []))
    struck_lines_raw = evidence_raw.get("struck_lines", [])

# Judge emits {verdicts: [...], struck_lines: [...]} or {findings: [...], struck_lines: [...]}
if isinstance(judge_raw, dict):
    judge_items = judge_raw.get("verdicts", judge_raw.get("findings", []))
    # Append judge struck_lines to evidence trail (never replace; CDT-178)
    judge_struck = judge_raw.get("struck_lines", [])
    if judge_struck:
        if not isinstance(struck_lines_raw, list):
            struck_lines_raw = []
        if isinstance(judge_struck, list):
            struck_lines_raw = list(struck_lines_raw) + list(judge_struck)
        else:
            struck_lines_raw = list(struck_lines_raw) + [judge_struck]
elif isinstance(judge_raw, list):
    judge_items = judge_raw
else:
    judge_items = []

if not isinstance(struck_lines_raw, list):
    struck_lines_raw = []

# CDT-178: absent/null/non-string/whitespace-only tool_use_id → missing.
# Literal "unknown", external:…, self-verify-… with non-empty strip → valid.
def missing_tool_use_id(obj):
    if not isinstance(obj, dict):
        return True
    v = obj.get("tool_use_id", None)
    if v is None:
        return True
    if not isinstance(v, str):
        return True
    return v.strip() == ""

engine_strikes = []

# --- Plan metadata ---
flavors = plan.get("flavors", [])
if isinstance(flavors, list):
    flavors_str = ", ".join(flavors)
else:
    flavors_str = str(flavors)
claim_budget = str(plan.get("claim_budget", 10))
# Duration is not measured in this process. Use plan.completion_time when the
# orchestrator set it. Otherwise the finalize timestamp (created_at) — do not
# emit the literal N/A while that clock value exists.
raw_ct = plan.get("completion_time")
if isinstance(raw_ct, str) and raw_ct.strip():
    completion_time = raw_ct.strip()
else:
    completion_time = created_at

# --- Format extracted claims (WP 1-15 C6: claim id + text; AC H) ---
claims_resolved = resolve_claims(plan, evidence_raw, judge_items)
if claims_resolved:
    claims_lines = []
    for i, c in enumerate(claims_resolved, 1):
        ctype = c.get("claim_type", "factual")
        cid = c.get("claim_id", "")
        ctext = c.get("claim", "")
        src = c.get("source_locator", "")
        claims_lines.append(f"{i}. **{ctype}** — {cid}: {ctext} (source: {src})")
    extracted_claims_md = "\n".join(claims_lines)
else:
    extracted_claims_md = "_No claims extracted._"

# --- Format evidence bundles (unstruck only; missing tid → engine strike) ---
bundle_lines = []
raw_blobs = []
bundle_ids = set()
for b in bundles:
    if isinstance(b, dict):
        rb = b.get("raw_blob")
        if isinstance(rb, str):
            raw_blobs.append(rb)
    if missing_tool_use_id(b):
        fl = b.get("file_line", "") if isinstance(b, dict) else ""
        engine_strikes.append(
            f"evidence bundle missing tool_use_id (file_line={fl})"
        )
        continue
    tid = b.get("tool_use_id")
    bundle_ids.add(tid)
    raw = b.get("raw_blob", "")
    fl = b.get("file_line", "")
    cmd = b.get("reproducible_command", "")
    bundle_lines.append(f"### `{tid}` — {fl}\n")
    bundle_lines.append(f"```\n{raw}\n```\n")
    if cmd:
        bundle_lines.append(f"Reproducible: `{cmd}`\n")
evidence_bundles_md = "\n".join(bundle_lines) if bundle_lines else "_No evidence bundles._"

# --- Format briefs ---
# Phase-4-conditional (SPEC-013 Phases 5/6): when Phase 4 did not run there is
# no brief to render, and an empty or synthesized one is forbidden — the report
# records the skip and its reason in its place.
def brief_item_text(b):
    # Match workflow.js briefToText, plus argument/text fields (CDT-401).
    if not isinstance(b, dict):
        return str(b) if b else ""
    body = b.get("argument") or b.get("text") or b.get("evidence_against") or b.get("evidence_for") or ""
    if not isinstance(body, str):
        body = "" if body is None else str(body)
    ids = b.get("supporting_tool_use_ids") or []
    if not isinstance(ids, list):
        ids = []
    return (
        "claim_id=%s requested=%s\n%s\nids=%s"
        % (b.get("claim_id", ""), b.get("requested_verdict", ""), body, ",".join(str(x) for x in ids))
    )

def briefs_to_text(value):
    if isinstance(value, dict):
        briefs = value.get("briefs")
        if not isinstance(briefs, list):
            return ""
        return "\n\n".join(brief_item_text(b) for b in briefs)
    if isinstance(value, list):
        return "\n\n".join(brief_item_text(b) for b in value)
    if isinstance(value, str):
        return value
    return ""

def format_brief(text):
    # str keeps quote rendering. dict/list render brief text, then the same quotes.
    rendered = text if isinstance(text, str) else briefs_to_text(text)
    if not isinstance(rendered, str) or not rendered.strip():
        return "_Brief not provided._"
    lines = rendered.strip().splitlines()
    return "\n".join("> %s" % ln for ln in lines)

phase4_plan = (plan.get("phases") or {}).get("4_prosecution_defense") or {}
phase4_skipped = bool(phase4_plan.get("skipped"))
phase4_skip_reason = phase4_plan.get("reason") or "not recorded"

# Phase 3's skip needs the same visible audit trail as Phase 2.5's bypass note
# (SPEC-013 Council tiering), so it gets its own rendered status line. Finalize
# only knows whether the phase was eligible — whether a specialist was actually
# pulled is a runtime decision, so an eligible run says exactly that.
phase3_plan = (plan.get("phases") or {}).get("3_domain_specialist") or {}
if phase3_plan.get("skipped"):
    phase3_status_md = f"SKIPPED (reason: {phase3_plan.get('reason') or 'not recorded'})"
else:
    phase3_status_md = "ELIGIBLE (runtime classify)"

if phase4_skipped:
    brief_skip_md = (
        f"_Phase 4 skipped, reason: {phase4_skip_reason} — no brief was "
        "produced and none was synthesized._"
    )
    prosecutor_brief_md = brief_skip_md
    advocate_brief_md = brief_skip_md
else:
    prosecutor_brief_md = format_brief(prosecutor_brief)
    advocate_brief_md = format_brief(advocate_brief)

# CDT-181 floor (toward -inf). Bool is not a JSON number. None = not in 0..100.
def floor_conf(v):
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    if isinstance(v, float) and (math.isnan(v) or math.isinf(v)):
        return None
    n = math.floor(v)
    if n < 0 or n > 100:
        return None
    return int(n)

# CDT-178 / WP 1-14 C3: floor-to-int confidence helper, used both by the
# verdict/finding formatting below and by the finalize-meta sidecar block.
def _as_int_conf(v):
    n = floor_conf(v)
    return 0 if n is None else n

VERDICT_OK = {"VERIFIED", "PARTIALLY_VERIFIED", "UNVERIFIED", "CONTRADICTED", "FABRICATED"}
SEVERITY_OK = {"critical", "warning", "nitpick"}

def verdict_strike_reason(v, blobs, ids):
    cid = v.get("claim_id") or v.get("claim") or "?"
    verd = v.get("verdict")
    if verd not in VERDICT_OK:
        return "verdict %s outside taxonomy (claim=%s)" % (verd, cid)
    blob = v.get("evidence_blob", None)
    if not isinstance(blob, str) or blob.strip() == "":
        return "verdict evidence_blob empty (claim=%s)" % cid
    if floor_conf(v.get("confidence")) is None:
        return "verdict confidence not in 0..100 after floor (claim=%s)" % cid
    if not any(isinstance(rb, str) and blob in rb for rb in blobs):
        return "verdict evidence_blob is not a substring of a bundle raw_blob (claim=%s)" % cid
    tid = v.get("tool_use_id", None)
    if isinstance(tid, str) and tid.strip() and tid.strip() not in ids:
        return "verdict tool_use_id not in evidence bundles (claim=%s)" % cid
    return None

def finding_strike_reason(f, ids, threshold):
    fl = f.get("file", "")
    ln = f.get("line", "")
    if missing_tool_use_id(f):
        return "finding missing tool_use_id (file=%s line=%s)" % (fl, ln)
    sev = f.get("severity")
    if sev not in SEVERITY_OK:
        return "finding severity %s outside taxonomy (file=%s line=%s)" % (sev, fl, ln)
    tid = f.get("tool_use_id")
    tid_s = tid.strip() if isinstance(tid, str) else ""
    if tid_s not in ids:
        return "finding tool_use_id not in evidence bundles (file=%s line=%s)" % (fl, ln)
    conf = floor_conf(f.get("confidence"))
    if conf is None:
        return "finding confidence not in 0..100 after floor (file=%s line=%s)" % (fl, ln)
    # A failed council-judge stays critical at confidence 50 so the commit
    # gate still blocks and a task gate at 80 still fails. Do not filter it.
    desc = f.get("description")
    degraded = isinstance(desc, str) and desc.startswith("(degraded-judge:")
    if threshold is not None and conf < threshold and not degraded:
        return "finding confidence %s below confidence_filter_threshold %s (file=%s line=%s)" % (conf, threshold, fl, ln)
    return None

def validate_judge(items, shape, blobs, ids, threshold):
    # CDT-303: strike before render and before max-confidence. Continue (exit 0).
    kept = []
    strikes = []
    if not isinstance(items, list):
        strikes.append("judge items are not a list")
        return kept, strikes
    for item in items:
        if not isinstance(item, dict):
            strikes.append("judge item is not an object")
            continue
        if shape == "verdict[]":
            reason = verdict_strike_reason(item, blobs, ids)
        else:
            reason = finding_strike_reason(item, ids, threshold)
        if reason:
            strikes.append(reason)
        else:
            kept.append(item)
    return kept, strikes

# Findings only. Verdict[] is not filtered by confidence_filter_threshold.
conf_threshold = None
if output_shape == "finding[]":
    raw_th = plan.get("confidence_filter_threshold", None)
    if not isinstance(raw_th, bool) and isinstance(raw_th, (int, float)):
        th = math.floor(raw_th)
        if 0 <= th <= 100:
            conf_threshold = int(th)

unstruck_items, judge_strikes = validate_judge(
    judge_items, output_shape, raw_blobs, bundle_ids, conf_threshold
)
engine_strikes.extend(judge_strikes)

# --- Format verdicts / findings (unstruck only) ---
max_verified_confidence = None
worst_verdict_value = None
finding_counts = None
finding_attention = None
if output_shape == "verdict[]":
    verdict_lines = []
    for v in unstruck_items:
        cid, claim = label_verdict(v, claims_resolved)
        verd = v.get("verdict", "UNVERIFIED")
        conf = v.get("confidence", 0)
        blob = v.get("evidence_blob", "")
        badge = {"VERIFIED": "VERIFIED", "PARTIALLY_VERIFIED": "PARTIALLY_VERIFIED",
                 "UNVERIFIED": "UNVERIFIED", "CONTRADICTED": "CONTRADICTED",
                 "FABRICATED": "FABRICATED"}.get(verd, verd)
        verdict_lines.append(f"### Claim {cid}: {claim}\n")
        verdict_lines.append(f"**{badge}** — confidence: {conf}/100\n")
        verdict_lines.append(f"```\n{blob}\n```\n")
    verdicts_md = "\n".join(verdict_lines) if verdict_lines else "_No verdicts._"

    # Verdict summary table
    counts = Counter(v.get("verdict", "UNVERIFIED") for v in unstruck_items)
    # verdict taxonomy authority: SPEC-013 (Output Shapes)
    taxonomy = ["VERIFIED", "PARTIALLY_VERIFIED", "UNVERIFIED", "CONTRADICTED", "FABRICATED"]
    table_lines = ["| Taxonomy | Count |", "|---|---|"]
    for t in taxonomy:
        table_lines.append(f"| {t} | {counts.get(t, 0)} |")
    verdict_summary_table_md = "\n".join(table_lines)

    # WP 1-14 C3 (SPEC-013 Phase 6 "Finalize-meta sidecar"): sidecar fields
    # computed over the SAME unstruck_items / counts / taxonomy this branch
    # already built for the report body -- never a second pass over judge_raw.
    # `confs` is reused below (CDT-178 sidecar meta) for
    # max_verdict_confidence -- ONE list comprehension over unstruck_items,
    # not two (tech-lead review r1, B6).
    confs = [_as_int_conf(v.get("confidence")) for v in unstruck_items]
    min_verdict_confidence = min(confs) if confs else None
    verdict_counts = {t: counts.get(t, 0) for t in taxonomy}
    unstruck_verdicts = []
    for v in unstruck_items:
        blob = v.get("evidence_blob", "")
        if not isinstance(blob, str):
            blob = ""
        unstruck_verdicts.append({
            "claim": v.get("claim", ""),
            "verdict": v.get("verdict", "UNVERIFIED"),
            "confidence": _as_int_conf(v.get("confidence")),
            "evidence_blob": blob,
        })
    # CDT-317: verified confidence ignores UNVERIFIED/CONTRADICTED/FABRICATED.
    # worst_verdict is the worst unstruck taxonomy term (FABRICATED worst).
    verified_confs = [
        _as_int_conf(v.get("confidence"))
        for v in unstruck_items
        if v.get("verdict") in ("VERIFIED", "PARTIALLY_VERIFIED")
    ]
    max_verified_confidence = max(verified_confs) if verified_confs else None
    _worst_rank = {
        "FABRICATED": 0, "CONTRADICTED": 1, "UNVERIFIED": 2,
        "PARTIALLY_VERIFIED": 3, "VERIFIED": 4,
    }
    _best = 99
    for v in unstruck_items:
        _r = _worst_rank.get(v.get("verdict"))
        if _r is not None and _r < _best:
            _best = _r
            worst_verdict_value = v.get("verdict")
else:
    # finding[] — validate_judge already struck missing tid, bad severity,
    # foreign tid, OOB confidence, and below-threshold confidence.
    finding_lines = []
    for f in unstruck_items:
        fl = f.get("file", "")
        ln = f.get("line", "")
        sev = f.get("severity", "warning")
        cat = f.get("category", "")
        desc = f.get("description", "")
        sugg = f.get("suggestion", "")
        conf = f.get("confidence", 0)
        tid = f.get("tool_use_id", "")
        loc = f"{fl}:{ln}" if fl else ""
        finding_lines.append(f"### [{sev.upper()}] {loc} ({cat})\n")
        finding_lines.append(f"{desc}\n")
        if sugg:
            finding_lines.append(f"**Suggestion:** {sugg}\n")
        finding_lines.append(f"Confidence: {conf}/100 | tool_use_id: `{tid}`\n")
    verdicts_md = "\n".join(finding_lines) if finding_lines else "_No findings._"

    # Severity summary table (unstruck only)
    counts = Counter(f.get("severity", "warning") for f in unstruck_items)
    sev_taxonomy = ["critical", "warning", "nitpick"]
    table_lines = ["| Severity | Count |", "|---|---|"]
    for s in sev_taxonomy:
        table_lines.append(f"| {s} | {counts.get(s, 0)} |")
    verdict_summary_table_md = "\n".join(table_lines)

    # WP 1-14 C3: these three sidecar fields are null for finding[] runs
    # (SPEC-013 Phase 6 "Finalize-meta sidecar").
    min_verdict_confidence = None
    verdict_counts = None
    unstruck_verdicts = None
    finding_counts = {s: counts.get(s, 0) for s in sev_taxonomy}
    finding_attention = []
    for f in unstruck_items:
        sev = f.get("severity") or ""
        if sev not in ("critical", "warning"):
            continue
        desc = f.get("description", "")
        if not isinstance(desc, str):
            desc = ""
        fl = f.get("file", "")
        if not isinstance(fl, str):
            fl = ""
        finding_attention.append({
            "confidence": f.get("confidence", "?"),
            "severity": sev,
            "file": fl,
            "line": f.get("line", ""),
            "description": desc.strip(),
        })

# User-facing diff review reads this list. Struck rows stay out.
unstruck_findings = []
if output_shape == "finding[]":
    for f in unstruck_items:
        if not isinstance(f, dict):
            continue
        desc = f.get("description", "")
        if not isinstance(desc, str):
            desc = ""
        fl = f.get("file", "")
        if not isinstance(fl, str):
            fl = ""
        sugg = f.get("suggestion", "")
        if not isinstance(sugg, str):
            sugg = ""
        cat = f.get("category", "")
        if not isinstance(cat, str):
            cat = ""
        tid = f.get("tool_use_id", "")
        if not isinstance(tid, str):
            tid = ""
        unstruck_findings.append({
            "file": fl,
            "line": f.get("line", 0),
            "severity": f.get("severity") or "",
            "category": cat,
            "description": desc.strip(),
            "suggestion": sugg,
            "confidence": f.get("confidence", 0),
            "tool_use_id": tid,
        })

# CLAIMS_AUDITED over unstruck body only (finding[] after tid strike)
claims_audited = str(len(unstruck_items))

# Merge: pre_existing (evidence + judge) + engine_strikes (append, never replace)
struck_lines_raw = list(struck_lines_raw) + engine_strikes

# --- Format struck lines ---
# Objects are claim/line/reason records (workflow schemas). Rendering a dict
# with an f-string prints Python repr (`{'claim': ...}`), which is not a line.
def format_struck_line(ln):
    if isinstance(ln, str):
        return ln
    if isinstance(ln, dict):
        who = ln.get("claim_id") or ln.get("claim") or ""
        line = ln.get("line") or ""
        reason = ln.get("reason") or ""
        parts = [str(p) for p in (who, line, reason) if p]
        if parts:
            return " — ".join(parts)
        return json.dumps(ln, sort_keys=True, ensure_ascii=True)
    return str(ln)

if struck_lines_raw:
    struck_md = "\n".join(f"- {format_struck_line(ln)}" for ln in struck_lines_raw)
else:
    struck_md = "No lines struck."

# --- Diff-mode specific placeholders ---
# Missing or empty string is absent. Do not render an empty DIFF_SUMMARY.
def _nonempty_text(v):
    return v if isinstance(v, str) and v.strip() else None

diff_summary = _nonempty_text(plan.get("diff_summary")) or _nonempty_text(plan.get("scope_arg")) or "_Not available._"
applicable_raw = plan.get("applicable_specs", None)
if isinstance(applicable_raw, list) and applicable_raw:
    applicable_specs = "\n".join("- `%s`" % s for s in applicable_raw)
elif isinstance(applicable_raw, str) and applicable_raw.strip():
    applicable_specs = applicable_raw
else:
    # No file list on the plan — do not claim a spec-grep ran.
    applicable_specs = "_None matched._"

# Commit gate status for finding[] shape (unstruck only)
commit_gate = "PASSED"
if output_shape == "finding[]":
    for f in unstruck_items:
        if f.get("severity") == "critical" or f.get("category") == "compliance":
            commit_gate = "BLOCKED"
            break

# Action items for finding[] shape (unstruck only).
# Label + sort order is category-then-severity to match review-and-commit/SKILL.md
# (Step 8): BLOCKER -> COMPLIANCE -> DESIGN -> NITPICK. A compliance finding
# (any severity) gets the COMPLIANCE label and sorts to rank 1, EXCEPT a
# critical one which is a BLOCKER first (rank 0) — critical always blocks.
sev_order = {"critical": 0, "warning": 1, "nitpick": 2}
label_map = {"critical": "BLOCKER", "warning": "DESIGN", "nitpick": "NITPICK"}

def action_rank(f):
    sev = f.get("severity", "warning")
    if sev == "critical":
        return 0
    if f.get("category") == "compliance":
        return 1
    # warning -> 2, nitpick -> 3 (sev_order is 1/2 here, +1 to leave room for COMPLIANCE)
    return sev_order.get(sev, 8) + 1

def action_label(f):
    # critical always BLOCKER (label matches rank 0); a non-critical compliance
    # finding is COMPLIANCE; otherwise map by severity.
    if f.get("severity") == "critical":
        return "BLOCKER"
    if f.get("category") == "compliance":
        return "COMPLIANCE"
    return label_map.get(f.get("severity", "warning"), "NITPICK")

action_lines = []
for f in sorted(unstruck_items, key=action_rank):
    fl = f.get("file", "")
    ln = f.get("line", "")
    desc = f.get("description", "")
    sugg = f.get("suggestion", desc)
    if not isinstance(sugg, str):
        sugg = "" if sugg is None else str(sugg)
    sugg = sugg.strip()
    conf = f.get("confidence", 0)
    loc = f"`{fl}:{ln}`" if fl else ""
    label = action_label(f)
    if sugg:
        action_lines.append(f"- [ ] {label} {loc} — {desc} — {sugg} [confidence: {conf}]")
    else:
        action_lines.append(f"- [ ] {label} {loc} — {desc} [confidence: {conf}]")
action_items_md = "\n".join(action_lines) if action_lines else "_No action items._"

# --- Read template and strip comment block ---
with open(template_file) as f:
    template = f.read()

# Strip [//]: # comment lines (authoring notes)
template = re.sub(r'^\[//\]: #.*\n?', '', template, flags=re.MULTILINE)

# --- Substitution map ---
# Report templates own YAML frontmatter (CDV-203); finalize substitutes {{…}}
# in-place and does not dual-write a synthetic FM block.
subs = {
    "{{SCOPE}}": scope,
    "{{PRESET}}": preset,
    "{{TIMESTAMP}}": created_at,
    "{{INVESTIGATOR_FLAVORS}}": flavors_str,
    "{{CLAIM_BUDGET}}": claim_budget,
    "{{CLAIMS_AUDITED}}": claims_audited,
    "{{EXTRACTED_CLAIMS}}": extracted_claims_md,
    "{{EVIDENCE_BUNDLES}}": evidence_bundles_md,
    "{{PROSECUTOR_BRIEF}}": prosecutor_brief_md,
    "{{ADVOCATE_BRIEF}}": advocate_brief_md,
    "{{VERDICTS}}": verdicts_md,
    "{{FINDINGS}}": verdicts_md,
    "{{STRUCK_LINES}}": struck_md,
    "{{STRUCK_FINDINGS}}": struck_md,
    "{{VERDICT_SUMMARY_TABLE}}": verdict_summary_table_md,
    "{{SEVERITY_SUMMARY_TABLE}}": verdict_summary_table_md,
    "{{COMPLETION_TIME}}": completion_time,
    "{{DIFF_SUMMARY}}": str(diff_summary),
    "{{APPLICABLE_SPECS}}": str(applicable_specs),
    "{{COMMIT_GATE_STATUS}}": commit_gate,
    "{{ACTION_ITEMS}}": action_items_md,
    "{{TASK_ID}}": task_id,
    "{{VERIFICATION_MODE}}": verification_mode,
    "{{COUNCIL_TIER}}": council_tier,
    "{{GRADING_REASON}}": yaml_dq(grading_reason),
    "{{PHASE3_SPECIALIST_STATUS}}": phase3_status_md,
    "{{CROSS_REVIEW_STATUS}}": cross_review_status,
    "{{CROSS_REVIEW_RANKINGS}}": cross_review_rankings,
    "{{CROSS_REVIEW_SCORES}}": cross_review_scores,
    "{{VERIFICATION_BANNER}}": verification_banner,
}

# --- Apply substitutions ---
# The templates are placeholders-only (each section holds a single {{VAR}} plus
# legitimate prose/headings). The dynamic value rendered into {{VERDICT_SUMMARY_TABLE}}
# / {{SEVERITY_SUMMARY_TABLE}} / {{STRUCK_*}} fully replaces what the section needs,
# so there is no static example/fallback content left to strip post-substitution.
#
# ONE non-recursive pass, never a per-var chain of str.replace: substituted text
# is scanned once and its output is never re-scanned. A sequential chain lets a
# value substituted early carry a literal `{{LATER_VAR}}` that a later iteration
# then expands — with untrusted values (grading_reason is free text from the
# tier-triage model) that is a template-injection primitive, and it landed raw,
# multi-line and unescaped inside the YAML frontmatter fences. Unknown
# placeholders resolve to "" here, which also folds in the old safety-net strip.
# The class carries digits: the pre-existing [A-Z_]+ silently skipped names like
# {{PHASE3_SPECIALIST_STATUS}}, leaking them into the report verbatim.
rendered = re.sub(r'\{\{[A-Z0-9_]+\}\}', lambda m: subs.get(m.group(0), ''), template)

# Unbound runs: remove empty task_id key entirely (not null, not "")
# Template carries `task_id: "{{TASK_ID}}"`; after empty sub it is `task_id: ""`.
if not task_id:
    rendered = re.sub(r'^task_id:\s*(?:""|\'\'|)\s*\n', '', rendered, count=1, flags=re.MULTILINE)

# CDV-204: optional tokens_total / tokens_by_phase in frontmatter (omit when unavailable)
if tokens_data is not None:
    fm_lines = []
    if tokens_data.get("total") is not None:
        fm_lines.append(f'tokens_total: {tokens_data["total"]}')
    if tokens_data.get("phases"):
        fm_lines.append("tokens_by_phase:")
        for pk, pv in tokens_data["phases"].items():
            fm_lines.append(f"  {pk}: {pv}")
    if fm_lines:
        inject = "\n".join(fm_lines) + "\n"
        # Insert after verification_mode line (always present in templates)
        rendered, n_sub = re.subn(
            r'(^verification_mode:\s*.+\n)',
            r'\1' + inject,
            rendered,
            count=1,
            flags=re.MULTILINE,
        )
        if n_sub == 0:
            # Fallback: insert before closing --- of YAML frontmatter
            rendered = re.sub(
                r'(^---\n(?:.*\n)*?)(^---\n)',
                r'\1' + inject + r'\2',
                rendered,
                count=1,
                flags=re.MULTILINE,
            )

# --- Write output (atomic: tmp + rename) ---
import tempfile
output = rendered.strip() + "\n"
dir_name = os.path.dirname(output_path) or '.'
fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    f.write(output)
os.rename(tmp_path, output_path)
# mkstemp creates the report mode 0600. A normal create is 0644 masked by umask.
_saved_umask = os.umask(0)
os.umask(_saved_umask)
os.chmod(output_path, 0o644 & ~_saved_umask)

# CDT-178: sidecar meta for bash index/stdout (unstruck conf + merged struck)
if output_shape == "verdict[]":
    unstruck_verdict_count = len(unstruck_items)
    unstruck_finding_count = 0
    # `confs` already computed above (WP 1-14 C3 min_verdict_confidence) --
    # reused here, not recomputed (tech-lead review r1, B6).
    max_verdict_confidence = max(confs) if confs else None
    max_finding_confidence = None
else:
    unstruck_finding_count = len(unstruck_items)
    unstruck_verdict_count = 0
    confs = [_as_int_conf(f.get("confidence")) for f in unstruck_items]
    max_finding_confidence = max(confs) if confs else None
    max_verdict_confidence = None

meta = {
    "struck_count": len(struck_lines_raw),
    "max_verdict_confidence": max_verdict_confidence,
    "max_finding_confidence": max_finding_confidence,
    "unstruck_finding_count": unstruck_finding_count,
    "unstruck_verdict_count": unstruck_verdict_count,
    # WP 1-14 C3 (SPEC-013 Phase 6 "Finalize-meta sidecar"): min_verdict_confidence,
    # verdict_counts and unstruck_verdicts are null for finding[] runs (set above);
    # verification_mode is always "full" or "self-verified", never null.
    "min_verdict_confidence": min_verdict_confidence,
    "verdict_counts": verdict_counts,
    "verification_mode": verification_mode,
    "unstruck_verdicts": unstruck_verdicts,
    # CDT-317: null when no VERIFIED/PARTIALLY_VERIFIED remains; null worst for finding[].
    "max_verified_confidence": max_verified_confidence,
    "worst_verdict": worst_verdict_value,
    # Stdout counts. Null on the other shape. Attention rows are unstruck only.
    "finding_counts": finding_counts,
    "finding_attention": finding_attention,
    "unstruck_findings": unstruck_findings,
}

# M14 per-AC split (WP 1-14; SPEC-013 Phase 6 "Finalize-meta sidecar"): only
# when the plan carries AC-bound claims (an M14 split ran at preflight).
# Finalize copies these from the plan verbatim -- it never matches verdicts
# to ACs itself; SPEC-033 M14(b)/(i) own that mapping, implemented only in
# skills/autopilot/ship-gate-verdict.sh.
m14_plan_claims = plan.get("claims")
if isinstance(m14_plan_claims, list) and m14_plan_claims and all(
    isinstance(c, dict) and "ac_id" in c for c in m14_plan_claims
):
    meta["ac_source"] = plan.get("ac_source")
    meta["ac_claims"] = [
        {"claim_id": c.get("claim_id"), "ac_id": c.get("ac_id")}
        for c in m14_plan_claims
    ]
    meta["process_acs"] = plan.get("process_acs", [])

meta_path = output_path + ".finalize-meta.json"
with open(meta_path, "w") as mf:
    json.dump(meta, mf)
    mf.write("\n")
PYEOF

  # Read finalize-meta for index conf + struck count (unstruck-only; CDT-178)
  local max_verdict_confidence="null" max_finding_confidence="null"
  local max_verified_confidence="null" worst_verdict="null"
  local struck_count=0
  local meta_path="${plan_report_path}.finalize-meta.json"
  if [ -f "$meta_path" ]; then
    max_verdict_confidence=$(jq -r 'if .max_verdict_confidence == null then "null" else .max_verdict_confidence end' "$meta_path")
    max_finding_confidence=$(jq -r 'if .max_finding_confidence == null then "null" else .max_finding_confidence end' "$meta_path")
    max_verified_confidence=$(jq -r 'if .max_verified_confidence == null then "null" else .max_verified_confidence end' "$meta_path")
    worst_verdict=$(jq -r 'if .worst_verdict == null then "null" else .worst_verdict end' "$meta_path")
    struck_count=$(jq -r '.struck_count // 0' "$meta_path")
  fi

  # Call index-writer.sh ONLY when task-bound
  if [ -n "$task_id" ]; then
    if [ ! -x "$INDEX_WRITER" ]; then
      echo "engine.sh: index-writer.sh not executable at $INDEX_WRITER" >&2
      exit 6
    fi
    if ! "$INDEX_WRITER" "$task_id" "$plan_report_path" "$max_verdict_confidence" "$max_finding_confidence" "$council_tier" "$grading_reason" "$max_verified_confidence" "$worst_verdict" >&2; then
      echo "engine.sh: failed to update .claude/council/index.json" >&2
      exit 6
    fi
  fi

  # Stdout summary (contract from SKILL.md Phase 6)
  local rel_path="${plan_report_path#"$MROOT"/}"
  printf 'Council report: %s\n' "$rel_path"
  printf 'Scope: %s\n' "$scope"
  printf 'Preset: %s (%s)\n' "$preset" "$output_shape"
  # Tier line only when the run was NOT full: `full` keeps today's stdout
  # byte-identical (SPEC-013 § Council tiering), and a light run is exactly the
  # case a reader needs told about.
  if [ "$council_tier" != "full" ]; then
    printf 'council_tier=%s (%s)\n' "$council_tier" "$grading_reason"
  fi
  printf 'verification_mode=%s\n' "$verification_mode"

  if [ "$output_shape" = "verdict[]" ]; then
    # Unstruck counts from the sidecar. Do not rescan the raw judge file.
    local v_verified v_partial v_unverified v_contradicted v_fabricated
    v_verified=$(jq -r '.verdict_counts.VERIFIED // 0' "$meta_path")
    v_partial=$(jq -r '.verdict_counts.PARTIALLY_VERIFIED // 0' "$meta_path")
    v_unverified=$(jq -r '.verdict_counts.UNVERIFIED // 0' "$meta_path")
    v_contradicted=$(jq -r '.verdict_counts.CONTRADICTED // 0' "$meta_path")
    v_fabricated=$(jq -r '.verdict_counts.FABRICATED // 0' "$meta_path")
    printf 'VERIFIED: %d  PARTIALLY_VERIFIED: %d  UNVERIFIED: %d  CONTRADICTED: %d  FABRICATED: %d\n' \
      "$v_verified" "$v_partial" "$v_unverified" "$v_contradicted" "$v_fabricated"

    # Needs-attention block: any non-VERIFIED unstruck verdict
    local attention_count=$(( v_partial + v_unverified + v_contradicted + v_fabricated ))
    if [ "$attention_count" -gt 0 ]; then
      printf '\n\xe2\x9a\xa0 Needs attention (%d):\n' "$attention_count"
      python3 - "$meta_path" <<'PYEOF'
import json, sys
meta = json.load(open(sys.argv[1]))
for v in meta.get("unstruck_verdicts") or []:
    if not isinstance(v, dict):
        continue
    vt = v.get("verdict", "")
    if vt == "VERIFIED":
        continue
    conf = v.get("confidence", "?")
    claim = v.get("claim", "")
    if not isinstance(claim, str):
        claim = ""
    claim = claim.strip()
    blob = v.get("evidence_blob", "")
    if not isinstance(blob, str):
        blob = ""
    snippet = next((ln.strip() for ln in blob.splitlines() if ln.strip()), "")
    if snippet:
        print("  [%s] %s \u2014 %s (%s)" % (conf, vt, claim, snippet))
    else:
        print("  [%s] %s \u2014 %s" % (conf, vt, claim))
PYEOF
    fi
  else
    # Unstruck severity counts from the sidecar.
    local f_critical f_warning f_nitpick
    f_critical=$(jq -r '.finding_counts.critical // 0' "$meta_path")
    f_warning=$(jq -r '.finding_counts.warning // 0' "$meta_path")
    f_nitpick=$(jq -r '.finding_counts.nitpick // 0' "$meta_path")
    printf 'critical: %d  warning: %d  nitpick: %d\n' \
      "$f_critical" "$f_warning" "$f_nitpick"

    # Needs-attention block: unstruck critical and warning findings
    local attention_count=$(( f_critical + f_warning ))
    if [ "$attention_count" -gt 0 ]; then
      printf '\n\xe2\x9a\xa0 Needs attention (%d):\n' "$attention_count"
      python3 - "$meta_path" <<'PYEOF'
import json, sys
meta = json.load(open(sys.argv[1]))
for f in meta.get("finding_attention") or []:
    if not isinstance(f, dict):
        continue
    sev = f.get("severity", "")
    conf = f.get("confidence", "?")
    fname = f.get("file", "")
    if not isinstance(fname, str):
        fname = ""
    line = f.get("line", "")
    desc = f.get("description", "")
    if not isinstance(desc, str):
        desc = ""
    loc = "%s:%s" % (fname, line) if fname else ""
    if loc:
        print("  [%s] %s \u2014 %s: %s" % (conf, sev.upper(), loc, desc))
    else:
        print("  [%s] %s \u2014 %s" % (conf, sev.upper(), desc))
PYEOF
    fi
  fi

  # Struck lines count from finalize-meta (merged trail incl engine strikes)
  printf '\nStruck lines: %d\n' "$struck_count"

  # CDV-204: optional Tokens block (graceful omit when missing/unavailable)
  if [ -n "$tokens_file" ] && [ -f "$tokens_file" ]; then
    python3 - "$tokens_file" <<'PYEOF'
import os, sys
sys.path.insert(0, os.environ["COUNCIL_SKILL_DIR"])
from report_labels import load_usable_tokens

data = load_usable_tokens(sys.argv[1])
if not data:
    sys.exit(0)
label = "Tokens (partial):" if data.get("partial") else "Tokens:"
print("\n%s" % label)
for k, v in data["phases"].items():
    print("  %s: %s" % (k, v))
if data.get("total") is not None:
    print("  Total: %s" % data["total"])
PYEOF
  fi

  # WP 3-05: diff user-facing review. Printed before this function returns.
  # The command fence deletes JUDGE_FILE on exit, so a later shell cannot
  # read it. Struck rows are already absent from unstruck_findings.
  if [ "$scope" = "diff" ]; then
    printf '\n'
    if ! (
      set -o pipefail
      jq -c '.unstruck_findings // []' "$meta_path" \
        | bash "$SCRIPT_DIR/../review-and-commit/bucket.sh"
    ); then
      echo "engine.sh: legacy review render failed" >&2
      exit 1
    fi
  fi

  # CDV-211: best-effort discard of per-run investigator tool-call cache.
  # Only remove dirs whose basename matches council-cache-* (preflight layout).
  local cache_dir_cleanup
  cache_dir_cleanup=$(jq -r '.cache_dir // empty' "$plan_file" 2>/dev/null || true)
  if [ -n "$cache_dir_cleanup" ] && [ -d "$cache_dir_cleanup" ]; then
    case "$(basename -- "$cache_dir_cleanup")" in
      council-cache-*)
        case "$cache_dir_cleanup" in
          *..*) ;;  # refuse path traversal
          *) rm -rf -- "$cache_dir_cleanup" 2>/dev/null || true ;;
        esac
        ;;
    esac
  fi
}

