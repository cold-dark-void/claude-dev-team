/**
 * Council-on-Workflow tribunal driver (CDV-196).
 *
 * Opt-in path for /council and /review-and-commit when --workflow or
 * COUNCIL_WORKFLOW=1. Default remains engine.sh + Task spawns.
 *
 * Architecture (D1–D10):
 *   preflight (engine.sh) → agent() schema steps → finalize (engine.sh)
 * Shared finalize guarantees report/index parity. No JSON-repair on this path
 * (schema violation = step failure). Spawn-failure degradation: pass
 * --verification-mode self-verified to finalize (marker string lives only in
 * engine finalize — never retyped here).
 *
 * Args-as-JSON-string guard shared with CDV-197 / p0-fix-workflow.js (D7).
 *
 * Host globals (Workflow runtime): args, agent, phase, parallel, budget (opt).
 * Pure helpers exported for node unit checks.
 */

import { readFileSync, writeFileSync, mkdtempSync, existsSync, rmSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { tmpdir } from 'node:os'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'
import {
  ClaimsSchema,
  EvidenceSchema,
  RankingSchema,
  BriefSchema,
  VerdictSchema,
  FindingSchema,
} from './workflow-schemas.js'

export const meta = {
  name: 'council',
  description:
    'Adversarial council tribunal via Workflow agent() schema steps + engine.sh finalize',
  phases: [
    { title: 'Preflight', detail: 'engine.sh preflight → investigation plan' },
    { title: 'Extract', detail: 'claim extraction (skip for single claim scope)' },
    { title: 'Investigate', detail: '≥2 parallel investigators per claim, distinct flavors' },
    { title: 'Cross-review', detail: 'Borda peer ranking when ≥3 investigators' },
    { title: 'Phase4', detail: 'prosecutor + advocate (verdict[] only)' },
    { title: 'Judge', detail: 'council-judge agentType, empty tools, schema-forced' },
    { title: 'Finalize', detail: 'engine.sh finalize → report + index' },
  ],
}

const __dirname = dirname(fileURLToPath(import.meta.url))
const COUNCIL_DIR = __dirname
const PROMPTS_DIR = join(COUNCIL_DIR, 'prompts')
const FLAVORS_DIR = join(COUNCIL_DIR, 'flavors')
const ENGINE_SH = join(COUNCIL_DIR, 'engine.sh')

const PROSECUTOR_BIAS =
  "You prosecute. Your default prior is the claim is FALSE until the bundles " +
  "overwhelmingly prove otherwise. Be brutal: strike anything vague, paraphrased, " +
  "or that merely 'sounds right'. Demand receipts."

const ADVOCATE_BIAS =
  "You defend, to prevent prosecutor monoculture. Your bias is FOR the claim: " +
  "look for any defensible reading of the bundles that supports it, leaning " +
  "VERIFIED or PARTIALLY_VERIFIED. But concede when the bundles truly contradict " +
  "the claim — a dishonest advocate is worse than no advocate."

// ---- pure helpers (exported) -----------------------------------------------

/** Args-as-JSON-string guard (D7 / AC8). Shared convention with CDV-197. */
export function parseArgs(raw) {
  let t = raw
  if (typeof t === 'string') {
    try {
      t = JSON.parse(t)
    } catch {
      t = {}
    }
  }
  if (!t || typeof t !== 'object' || Array.isArray(t)) {
    return { ok: false, error: 'args not interpolated', args_type: typeof raw, args_seen: t }
  }
  return { ok: true, args: t }
}

/** Strip YAML frontmatter from a prompt/flavor markdown file. */
export function stripFrontmatter(md) {
  if (md.startsWith('---')) {
    const end = md.indexOf('\n---', 3)
    if (end !== -1) {
      return md.slice(end + 4).replace(/^\s*\n/, '')
    }
  }
  return md
}

/**
 * Extract fenced prompt body if present (``` ... ``` after "Prompt body"),
 * else return full body after frontmatter.
 */
export function extractPromptBody(md) {
  const body = stripFrontmatter(md)
  const fence = body.match(/```\n([\s\S]*?)\n```/)
  if (fence) return fence[1]
  return body
}

/**
 * Plan-extractor input. Byte-for-byte the plan file.
 * The rendered prompt starts with this string. Do not prepend a header:
 * source_locator lines are 1-based indexes into this text (L-19).
 */
export function buildPlanExtractorInput(planText) {
  return String(planText ?? '')
}

/** 1-based line of the first line that contains `claim`, else 0. */
export function planClaimLine(inputText, claim) {
  const needle = String(claim ?? '')
  if (!needle) return 0
  const lines = String(inputText ?? '').split('\n')
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].includes(needle)) return i + 1
  }
  return 0
}

/**
 * Flavor delta injected as {{FLAVOR_DELTA}}.
 * Strips YAML frontmatter, `[//]: #` authoring lines, and any authoring
 * note above the `## Delta body` marker. No marker means the whole body
 * is the delta (diff-mode flavors).
 */
export function flavorDelta(md) {
  let body = stripFrontmatter(String(md ?? ''))
  const marker = '## Delta body'
  const at = body.startsWith(marker) ? 0 : body.indexOf('\n' + marker)
  if (at !== -1) {
    const start = at === 0 ? 0 : at + 1
    const after = body.slice(start)
    const nl = after.indexOf('\n')
    body = nl === -1 ? '' : after.slice(nl + 1)
  }
  body = body.replace(/^\[\/\/\]: #.*(?:\n|$)/gm, '')
  return body.trim()
}

/** Load flavor body (system-prompt delta only). */
export function loadFlavor(name) {
  const path = join(FLAVORS_DIR, `${name}.md`)
  if (!existsSync(path)) {
    throw new Error(`council workflow: flavor not found: ${name}`)
  }
  return flavorDelta(readFileSync(path, 'utf8'))
}

/**
 * Apply {{#NAME}} ... {{/NAME}} section blocks (SPEC-013 Engine Architecture).
 * A marker is a line equal to `{{#NAME}}` or `{{/NAME}}` (NAME matches
 * [A-Z_]+). Sections do not nest. When vars[NAME] is null, undefined or ''
 * the whole block (both marker lines and the body, newlines included) is
 * removed. Otherwise only the two marker lines are removed and the body
 * stays, so a later {{VAR}} substitution can still fill placeholders in it.
 * Runs before {{VAR}} substitution.
 */
function applySections(text, vars) {
  const sectionRe = /^\{\{#([A-Z_]+)\}\}\r?\n([\s\S]*?)\r?\n\{\{\/\1\}\}\r?\n?/gm
  return text.replace(sectionRe, (_full, name, body) => {
    const v = vars[name]
    const keep = !(v == null || v === '')
    return keep ? `${body}\n` : ''
  })
}

/**
 * Load prompt template and substitute {{VARS}}.
 * Missing vars leave the placeholder (callers must supply happy-path set).
 */
export function loadPrompt(name, vars = {}) {
  const path = join(PROMPTS_DIR, `${name}.md`)
  if (!existsSync(path)) {
    throw new Error(`council workflow: prompt not found: ${name}`)
  }
  let text = extractPromptBody(readFileSync(path, 'utf8'))
  text = applySections(text, vars)
  // One pass. A value that contains {{OTHER}} must not be expanded.
  const map = {}
  for (const [k, v] of Object.entries(vars)) {
    const name = k.startsWith('{{') && k.endsWith('}}') ? k.slice(2, -2) : k
    map[name] = v == null ? '' : String(v)
  }
  return text.replace(/\{\{([A-Z0-9_]+)\}\}/g, (m, name) =>
    Object.prototype.hasOwnProperty.call(map, name) ? map[name] : m,
  )
}

/** Preflight stdout → plan. Invalid JSON is exit 1, not a throw (CDT-275). */
export function parsePreflightStdout(stdout) {
  try {
    const plan = JSON.parse(stdout)
    if (!plan || typeof plan !== 'object' || Array.isArray(plan)) {
      return { ok: false, error: 'preflight JSON is not an object', exit_code: 1 }
    }
    return { ok: true, plan }
  } catch (e) {
    const detail = e && e.message ? e.message : String(e)
    return { ok: false, error: `preflight JSON parse failed: ${detail}`, exit_code: 1 }
  }
}

/** Caller asked for Phase 3 or --external. Workflow does not run those. */
export function callerWantsTaskPath(t, plan) {
  if (t) {
    if (t.phase3 === true || t.phase_3 === true || t.domain_specialist === true) return true
    const ext = t.external
    if (ext === true || ext === 'codex' || ext === 'gemini' || ext === 'auto') return true
    if (ext && typeof ext === 'object' && ext.requested) return true
  }
  if (plan && plan.external && plan.external.requested === true) return true
  return false
}

const LIGHT_NOTICE =
  'council: council_tier=light unsupported on the Workflow path; falling back to engine.sh'
const TASK_PATH_NOTICE =
  'council: Phase 3 and --external are the Task path (commands/council.md)'

export function isUsableAgentResult(result) {
  if (result == null) return false
  if (typeof result === 'object' && result.error) return false
  if (typeof result === 'object' && result.__unusable) return false
  return true
}

function tmpHandoff(prefix) {
  const dir = mkdtempSync(join(tmpdir(), 'council-wf-'))
  return {
    dir,
    plan: join(dir, `${prefix}-plan.json`),
    evidence: join(dir, `${prefix}-evidence.json`),
    judge: join(dir, `${prefix}-judge.json`),
  }
}

function runEngine(subcmd, argv, { input, capture = true } = {}) {
  const r = spawnSync(ENGINE_SH, [subcmd, ...argv], {
    encoding: 'utf8',
    input: input || undefined,
    maxBuffer: 32 * 1024 * 1024,
  })
  return {
    status: r.status == null ? 1 : r.status,
    stdout: r.stdout || '',
    stderr: r.stderr || '',
  }
}

function briefToText(briefObj, field) {
  if (!briefObj || !Array.isArray(briefObj.briefs)) return ''
  return briefObj.briefs
    .map((b) => {
      const body = b[field] || b.evidence_against || b.evidence_for || ''
      return `claim_id=${b.claim_id} requested=${b.requested_verdict}\n${body}\nids=${(b.supporting_tool_use_ids || []).join(',')}`
    })
    .join('\n\n')
}

function formatBundlesForPrompt(bundles) {
  return bundles
    .map(
      (b, i) =>
        `### bundle_${i} claim_id=${b.claim_id || '?'} tool_use_id=${b.tool_use_id}\n` +
        `file_line: ${b.file_line}\ncmd: ${b.reproducible_command}\n\`\`\`\n${b.raw_blob}\n\`\`\``,
    )
    .join('\n\n')
}

function shuffled(items, shuffleFn) {
  const a = items.slice()
  if (typeof shuffleFn === 'function') return shuffleFn(a)
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1))
    const tmp = a[i]
    a[i] = a[j]
    a[j] = tmp
  }
  return a
}

function bordaRank(bundles, rankings) {
  // rankings: { ranking, labelToIndex, excludeIndex }
  // labelToIndex maps the labels THIS reviewer saw onto bundle indexes.
  // A missing map is the legacy global A=0 order. A present map never
  // falls through to that global index (CDT-339).
  if (!rankings.length) return { ordered: bundles, scores: [], status: 'bypassed: no valid rankings' }
  const n = bundles.length
  const scores = new Array(n).fill(0)
  for (const r of rankings) {
    const order = r.ranking || []
    const m = order.length
    const map = r.labelToIndex
    order.forEach((lab, rankIdx) => {
      let bi
      if (map && Object.prototype.hasOwnProperty.call(map, lab)) {
        bi = map[lab]
      } else if (!map) {
        bi = lab.charCodeAt(0) - 65
      } else {
        return
      }
      if (typeof r.excludeIndex === 'number' && bi === r.excludeIndex) return
      if (bi >= 0 && bi < n) scores[bi] += m - 1 - rankIdx
    })
  }
  const indexed = bundles.map((b, i) => ({ b, i, s: scores[i] }))
  indexed.sort((a, c) => c.s - a.s || a.i - c.i)
  const q = [...scores].sort((a, c) => a - c)
  const thr = q[Math.floor((q.length - 1) * 0.25)] || 0
  const ordered = indexed.map(({ b, s }) => ({
    ...b,
    borda_score: s,
    weak_evidence: s <= thr,
  }))
  return {
    ordered,
    scores: indexed.map(({ i, s }) => `bundle_${i}=${s}`),
    status: 'completed',
  }
}

// ---- main tribunal ---------------------------------------------------------

/**
 * Run the Workflow tribunal.
 * @param {object} runtime — { args, agent, phase, parallel, budget? }
 *   When called from Workflow host, pass globals. Unit tests inject fakes.
 */
export async function runCouncil(runtime) {
  const { agent, phase, parallel } = runtime
  const parsed = parseArgs(runtime.args)
  if (!parsed.ok) {
    return parsed
  }
  const t = parsed.args

  // Required: scope (claim|session|diff|plan) or claim text
  const scope =
    t.scope ||
    (t.claim ? 'claim' : t.diff ? 'diff' : t.session ? 'session' : t.plan ? 'plan' : '')
  if (!scope) {
    return { ok: false, error: 'scope required (claim|session|diff|plan) or claim string' }
  }

  // Full path only. Refuse before preflight so no handoff dir is created.
  if (t.council_tier === 'light') {
    console.error(LIGHT_NOTICE)
    return { ok: false, error: LIGHT_NOTICE, exit_code: 2, stderr: LIGHT_NOTICE }
  }
  if (callerWantsTaskPath(t, null)) {
    console.error(TASK_PATH_NOTICE)
    return { ok: false, error: TASK_PATH_NOTICE, exit_code: 2, stderr: TASK_PATH_NOTICE }
  }

  let degraded = false
  const tokenUsage = []

  const markDegraded = () => {
    degraded = true
  }

  const safeAgent = async (prompt, opts) => {
    try {
      const result = await agent(prompt, opts)
      if (!isUsableAgentResult(result)) {
        markDegraded()
        return null
      }
      if (opts && opts.phase && runtime.budget && typeof runtime.budget === 'function') {
        try {
          const b = runtime.budget()
          if (b) tokenUsage.push({ phase: opts.phase, ...b })
        } catch {
          /* budget API optional */
        }
      }
      return result
    } catch {
      markDegraded()
      return null
    }
  }

  // --- Preflight ------------------------------------------------------------
  if (typeof phase === 'function') phase('Preflight')

  const planPath = t.plan || (scope === 'plan' ? t.scope_arg || t.claim : '') || ''
  const preflightArgs = ['--scope', scope]
  if (t.claim || t.scope_arg || planPath) {
    preflightArgs.push('--scope-arg', t.claim || t.scope_arg || planPath)
  }
  if (t.last != null) preflightArgs.push('--last', String(t.last))
  if (t.task_id) preflightArgs.push('--task-id', String(t.task_id))
  if (t.preset) preflightArgs.push('--preset', String(t.preset))
  if (t.why) preflightArgs.push('--why')
  // CDT-126: forward the already-resolved tier, same as every other flag here.
  // Dropping it would re-grade a graded `full` run as "ungraded" in its report
  // and index row, breaking output parity between this path and engine.sh on
  // byte-identical input. The Workflow path is `full`-only (light falls back
  // before dispatch), so this forwards a value — it forks no tiering logic.
  if (t.council_tier) preflightArgs.push('--tier', String(t.council_tier))
  if (t.grading_reason) preflightArgs.push('--grading-reason', String(t.grading_reason))

  const pre = runEngine('preflight', preflightArgs)
  if (pre.status !== 0) {
    return {
      ok: false,
      error: 'preflight failed',
      exit_code: pre.status,
      stderr: pre.stderr,
    }
  }

  const parsedPlan = parsePreflightStdout(pre.stdout)
  if (!parsedPlan.ok) {
    console.error(`council workflow: ${parsedPlan.error}`)
    return {
      ok: false,
      error: parsedPlan.error,
      exit_code: 1,
      stderr: parsedPlan.error,
    }
  }
  const plan = parsedPlan.plan

  if (plan.council_tier === 'light') {
    console.error(LIGHT_NOTICE)
    return { ok: false, error: LIGHT_NOTICE, exit_code: 2, stderr: LIGHT_NOTICE }
  }
  if (callerWantsTaskPath(t, plan)) {
    console.error(TASK_PATH_NOTICE)
    return { ok: false, error: TASK_PATH_NOTICE, exit_code: 2, stderr: TASK_PATH_NOTICE }
  }

  let handoff = null
  try {
  handoff = tmpHandoff('run')
  writeFileSync(handoff.plan, JSON.stringify(plan, null, 2))

  const outputShape = plan.output_shape
  const flavors = Array.isArray(plan.flavors) ? plan.flavors : ['paranoid-ic', 'skeptic-ic']
  const claimBudget = plan.claim_budget || 10
  const skipExtract = plan.phases?.['1_claim_extraction']?.skip === true
  const skipPhase4 =
    plan.phases?.['4_prosecution_defense']?.skipped === true || outputShape === 'finding[]'
  // Marker the Judge sees in place of a brief that was never produced — built
  // from the plan's own reason, never a hardcoded shape sentinel (judge.md
  // § Variables; SPEC-013 Phase 5 forbids synthesizing an absent brief).
  const phase4SkipMarker = `NOT RUN — Phase 4 skipped (reason: ${
    plan.phases?.['4_prosecution_defense']?.reason || 'not recorded'
  })`

  // Resolve extract input: plan scope reads file; others use provided text
  let inputText = t.input_text || ''
  if (!inputText && plan.scope === 'plan' && plan.scope_arg && existsSync(plan.scope_arg)) {
    inputText = buildPlanExtractorInput(readFileSync(plan.scope_arg, 'utf8'))
  }
  if (!inputText) inputText = plan.scope_arg || t.claim || ''

  // --- Extract --------------------------------------------------------------
  if (typeof phase === 'function') phase('Extract')

  let claims = []
  if (skipExtract) {
    if (Array.isArray(plan.claims) && plan.claims.length) {
      // M14 per-AC split (SPEC-013 Phase 1 "M14 per-AC split"; SPEC-033
      // M14(g)): consume plan.claims[] verbatim -- same order, same claim
      // text, same source_locator, one investigation claim per array
      // element. No truncate/reorder/merge/reword/re-extract, and never
      // slice to claimBudget (preflight already enforced the M14 budget).
      // Keep claim_id/ac_id so verdicts can join back to ACs by the
      // [AC-<id>] tag (Task path parity: commands/council.md).
      claims = plan.claims.map((c) => ({
        claim: c.claim,
        source_locator: c.source_locator,
        claim_type: c.claim_type,
        claim_id: c.claim_id,
        ac_id: c.ac_id,
        verify: c.verify ?? null,
        tool_budget: c.tool_budget ?? null,
      }))
    } else {
      const retroClaim = plan.resolved_claim || ''
      const claimText =
        plan.scope === 'from-retro'
          ? retroClaim || t.claim || ''
          : plan.scope_arg || t.claim || retroClaim || ''
      claims = [
        {
          claim: claimText,
          source_locator:
            plan.scope === 'from-retro' && plan.scope_arg
              ? `retro:${plan.scope_arg}`
              : 'cli:claim',
          claim_type: 'factual',
        },
      ]
    }
  } else {
    const extractPromptName =
      plan.scope === 'plan' ||
      (plan.phases?.['1_claim_extraction']?.prompt || '').includes('plan-extractor')
        ? 'plan-extractor'
        : 'claim-extractor'
    const extractVars =
      extractPromptName === 'plan-extractor'
        ? {
            PLAN_PATH: plan.scope_arg || planPath || '',
            INPUT_TEXT: inputText,
            CLAIM_BUDGET: String(claimBudget),
          }
        : {
            SCOPE_TYPE: plan.scope,
            INPUT_TEXT: inputText,
            CLAIM_BUDGET: String(claimBudget),
          }
    const extractPrompt = loadPrompt(extractPromptName, extractVars)
    const extracted = await safeAgent(extractPrompt, {
      schema: ClaimsSchema,
      agentType: 'dev-team:council-scribe',
      phase: 'Extract',
      label: extractPromptName,
    })
    if (extracted && Array.isArray(extracted.claims)) {
      claims = extracted.claims.slice(0, claimBudget)
    } else {
      // self-verify path: orchestrator-equivalent minimal claim from input
      markDegraded()
      claims = [
        {
          claim: (inputText || plan.scope_arg || 'unparsed input').slice(0, 500),
          source_locator: 'self-verified:extract',
          claim_type: 'factual',
        },
      ]
    }
  }

  // --- Investigate ----------------------------------------------------------
  if (typeof phase === 'function') phase('Investigate')

  const invFlavors =
    outputShape === 'finding[]'
      ? flavors
      : flavors.filter((f) => f === 'paranoid-ic' || f === 'skeptic-ic').length >= 2
        ? flavors.filter((f) => f === 'paranoid-ic' || f === 'skeptic-ic')
        : flavors.slice(0, Math.max(2, flavors.length))

  const invJobs = []
  claims.forEach((c, ci) => {
    const claimId = `c${ci}`
    invFlavors.forEach((flavor) => {
      invJobs.push({ claim: c, claimId, flavor, ci })
    })
  })

  // Ensure ≥2 investigators when verdict shape and only one flavor listed
  if (outputShape === 'verdict[]' && invFlavors.length < 2) {
    ;['paranoid-ic', 'skeptic-ic'].forEach((flavor) => {
      if (!invFlavors.includes(flavor)) {
        claims.forEach((c, ci) => {
          invJobs.push({ claim: c, claimId: `c${ci}`, flavor, ci })
        })
      }
    })
  }

  const runOneInv = async ({ claim, claimId, flavor, ci }) => {
    let flavorDelta = ''
    try {
      flavorDelta = loadFlavor(flavor)
    } catch {
      flavorDelta = `(flavor ${flavor})`
    }
    const prompt = loadPrompt('investigator', {
      CLAIM_TEXT: claim.claim || claim.description || '',
      SOURCE_LOCATOR: claim.source_locator || claim.file || 'unknown',
      RAW_ARTIFACTS: t.raw_artifacts || plan.scope_arg || t.input_text || '',
      FLAVOR_DELTA: flavorDelta,
      CACHE_DIR: plan.cache_dir || '',
      TOOL_BUDGET: String(claim.tool_budget ?? 5),
      VERIFY_COMMAND: claim.verify ?? '',
    })
    const res = await safeAgent(prompt, {
      schema: EvidenceSchema,
      agentType: 'dev-team:finder',
      phase: 'Investigate',
      label: `inv:${claimId}:${flavor}`,
    })
    if (!res || !Array.isArray(res.bundles)) {
      // Fail closed (CDT-349). A failed investigator contributes no bundle.
      // Do not invent a self-verify stub: a non-empty stub makes the
      // empty-fleet exit 5 below unreachable and lets the judge rule on text
      // no tool produced. The orchestrator self-verifies with real tools on
      // the Task path; this driver only marks the run degraded.
      markDegraded()
      return []
    }
    return res.bundles.map((b) => ({ ...b, claim_id: b.claim_id || claimId, flavor }))
  }

  let bundleLists
  if (typeof parallel === 'function') {
    bundleLists = await parallel(invJobs.map((job) => () => runOneInv(job)))
  } else {
    bundleLists = []
    for (const job of invJobs) bundleLists.push(await runOneInv(job))
  }

  let bundles = bundleLists.flat().filter(Boolean)
  if (bundles.length === 0) {
    return {
      ok: false,
      error: 'zero evidence bundles after investigate+self-verify',
      exit_code: 5,
      handoff,
    }
  }

  // --- Cross-review ---------------------------------------------------------
  if (typeof phase === 'function') phase('Cross-review')

  // Per-claim cross-review (SPEC-013 Phase 2.5 "MUST run Phase 2.5 per
  // claim", WP 1-15 AC I). Bundles group by claim_id, in claim order; each
  // group runs its own Borda round against its own claim text, so a c1
  // reviewer never sees a c0 bundle or the c0 claim text. A group with
  // fewer than 3 bundles bypasses cross-review for that claim only, and the
  // bypass reason is recorded per claim, not globally.
  const groupOrder = []
  const groupMap = new Map()
  const seedGroup = (key) => {
    if (!groupMap.has(key)) {
      groupMap.set(key, [])
      groupOrder.push(key)
    }
  }
  claims.forEach((_, ci) => seedGroup(`c${ci}`))
  bundles.forEach((b) => seedGroup(b.claim_id || ''))
  bundles.forEach((b) => groupMap.get(b.claim_id || '').push(b))
  for (let i = groupOrder.length - 1; i >= 0; i--) {
    if (groupMap.get(groupOrder[i]).length === 0) {
      groupMap.delete(groupOrder[i])
      groupOrder.splice(i, 1)
    }
  }

  // A group with no matching claim (bad/absent claim_id) falls back to the
  // scope text, same fallback the single-claim path used before this change.
  const claimTextFor = (key) => {
    const m = /^c(\d+)$/.exec(key)
    if (m && claims[Number(m[1])]) return claims[Number(m[1])].claim
    return plan.scope_arg || ''
  }

  const statusLines = []
  const rankingBlocks = []
  const scoreLines = []
  let orderedBundles = []

  for (const key of groupOrder) {
    const groupBundles = groupMap.get(key)
    if (groupBundles.length < 3) {
      statusLines.push(`${key}: bypassed: fewer than 3 bundles (${groupBundles.length} found)`)
      orderedBundles = orderedBundles.concat(groupBundles)
      continue
    }
    const claimText = claimTextFor(key)
    const runReview = async (ri) => {
      // Reviewer ri submitted groupBundles[ri]. Labels cover the other
      // bundles only, shuffled per reviewer, then mapped back by identity
      // (CDT-339). A label never falls through to the global A=0 index.
      const others = groupBundles
        .map((b, i) => ({ b, i }))
        .filter((x) => x.i !== ri)
      const presented = shuffled(others, runtime.shuffle)
      const labelToIndex = {}
      const block = presented
        .map((x, j) => {
          const lab = String.fromCharCode(65 + j)
          labelToIndex[lab] = x.i
          return `### ${lab}\nclaim_id=${x.b.claim_id}\ntool_use_id=${x.b.tool_use_id}\n\`\`\`\n${x.b.raw_blob}\n\`\`\``
        })
        .join('\n\n')
      const prompt = loadPrompt('cross-reviewer', {
        CLAIM_TEXT: claimText,
        BUNDLE_BLOCK: block,
      })
      const res = await safeAgent(prompt, {
        schema: RankingSchema,
        agentType: 'dev-team:council-scribe',
        phase: 'Cross-review',
        label: `cross:${key}:${ri}`,
      })
      if (!res || !Array.isArray(res.ranking)) return res
      return { ...res, labelToIndex, excludeIndex: ri }
    }

    const reviewers = groupBundles.map((_, ri) => ri)
    let rankings
    if (typeof parallel === 'function') {
      rankings = await parallel(reviewers.map((ri) => () => runReview(ri)))
    } else {
      rankings = []
      for (const ri of reviewers) rankings.push(await runReview(ri))
    }
    const valid = rankings.filter((r) => r && Array.isArray(r.ranking) && r.ranking.length)
    if (valid.length === 0) {
      statusLines.push(`${key}: bypassed: no valid cross-review rankings collected`)
      markDegraded()
      orderedBundles = orderedBundles.concat(groupBundles)
    } else {
      const br = bordaRank(groupBundles, valid)
      orderedBundles = orderedBundles.concat(br.ordered)
      statusLines.push(`${key}: ${br.status}`)
      rankingBlocks.push(
        `${key}:\n${valid.map((r, i) => `reviewer_${i}: ${(r.ranking || []).join(' > ')}`).join('\n')}`
      )
      scoreLines.push(`${key}: ${br.scores.join(', ')}`)
    }
  }

  const crossStatus = statusLines.join('\n') || 'Phase 2.5 not run'
  const crossRankings = rankingBlocks.length
    ? rankingBlocks.join('\n\n')
    : '_Phase 2.5 not run — no cross-review rankings._'
  const crossScores = scoreLines.length
    ? scoreLines.join('\n')
    : '_Phase 2.5 not run — no Borda scores._'

  // --- Phase 4 --------------------------------------------------------------
  if (typeof phase === 'function') phase('Phase4')

  let prosecutorBrief = ''
  let advocateBrief = ''
  const struck = []

  if (!skipPhase4) {
    const bundleBlock = formatBundlesForPrompt(orderedBundles)
    const runBrief = async (role, field, flavor, bias) => {
      let flavorDelta = ''
      try {
        flavorDelta = loadFlavor(flavor)
      } catch {
        flavorDelta = ''
      }
      const prompt = loadPrompt('phase4-brief', {
        ROLE: role,
        ROLE_BIAS: bias,
        EVIDENCE_FIELD: field,
        EVIDENCE_BUNDLES: bundleBlock,
        FLAVOR_DELTA: flavorDelta,
      })
      const res = await safeAgent(prompt, {
        schema: BriefSchema,
        agentType: 'dev-team:council-scribe',
        phase: 'Phase4',
        label: role,
      })
      if (!res) {
        markDegraded()
        return {
          briefs: orderedBundles.map((b) => ({
            claim_id: b.claim_id || '?',
            [field]: `(self-verified brief) tool_use_id=${b.tool_use_id}`,
            requested_verdict: 'UNVERIFIED',
            supporting_tool_use_ids: [b.tool_use_id],
          })),
          struck_lines: [],
        }
      }
      return res
    }

    let pRes, aRes
    if (typeof parallel === 'function') {
      ;[pRes, aRes] = await parallel([
        () => runBrief('Prosecutor', 'evidence_against', 'jaded-senior', PROSECUTOR_BIAS),
        () => runBrief("Devil's Advocate", 'evidence_for', 'yolo-ic', ADVOCATE_BIAS),
      ])
    } else {
      pRes = await runBrief('Prosecutor', 'evidence_against', 'jaded-senior', PROSECUTOR_BIAS)
      aRes = await runBrief("Devil's Advocate", 'evidence_for', 'yolo-ic', ADVOCATE_BIAS)
    }
    prosecutorBrief = briefToText(pRes, 'evidence_against')
    advocateBrief = briefToText(aRes, 'evidence_for')
    if (pRes?.struck_lines) struck.push(...pRes.struck_lines)
    if (aRes?.struck_lines) struck.push(...aRes.struck_lines)
  }

  // --- Judge ----------------------------------------------------------------
  if (typeof phase === 'function') phase('Judge')

  const judgePrompt = loadPrompt('judge', {
    ORIGINAL_CLAIMS: JSON.stringify(claims, null, 2),
    EVIDENCE_BUNDLES: formatBundlesForPrompt(orderedBundles),
    PROSECUTOR_BRIEF: prosecutorBrief || phase4SkipMarker,
    ADVOCATE_BRIEF: advocateBrief || phase4SkipMarker,
    OUTPUT_SHAPE: outputShape,
  })

  const judgeSchema = outputShape === 'finding[]' ? FindingSchema : VerdictSchema
  // D4 / AC4: plugin-qualified council-judge; tools empty via agent file
  let judgeOut = await safeAgent(judgePrompt, {
    schema: judgeSchema,
    agentType: 'dev-team:council-judge',
    phase: 'Judge',
    label: 'council-judge',
  })

  // Passed to finalize only for the finding[] judge fallback (CDT-487).
  // The CDV-199 marker string stays in engine.sh; this is the reason line.
  let degradationReason = ''

  if (!judgeOut) {
    // Orchestrator emits judge JSON — never grant tools to a judge persona
    markDegraded()
    if (outputShape === 'finding[]') {
      degradationReason = 'degraded-judge: council-judge spawn failed'
      judgeOut = {
        findings: orderedBundles.map((b) => ({
          file: (b.file_line || 'unknown:0').split(':')[0],
          line: parseInt((b.file_line || '0:0').split(':')[1], 10) || 0,
          severity: 'critical',
          category: b.flavor === 'quality' || !b.flavor ? 'design' : b.flavor,
          description: `(${degradationReason}) ${b.raw_blob}`.slice(0, 500),
          suggestion: 're-run council with a live council-judge',
          confidence: 50,
          tool_use_id: b.tool_use_id,
        })),
        struck_lines: [],
      }
    } else {
      judgeOut = {
        verdicts: claims.map((c, i) => {
          const cid = `c${i}`
          const matched = orderedBundles.find((b) => b.claim_id === cid)
          const src = matched || orderedBundles[0]
          const blob = src && typeof src.raw_blob === 'string' ? src.raw_blob : ''
          return {
            claim: c.claim,
            claim_id: cid,
            verdict: 'UNVERIFIED',
            confidence: 40,
            evidence_blob: blob,
          }
        }),
        struck_lines: [],
      }
    }
  }

  // Phase-4 strikes stay on the evidence doc only. Copying them onto the
  // judge object double-counts: finalize appends judge.struck_lines to
  // evidence.struck_lines (CDT-178).

  // --- Finalize handoff -----------------------------------------------------
  if (typeof phase === 'function') phase('Finalize')

  // Omit the brief keys entirely when Phase 4 did not run — an empty string is
  // the stub SPEC-013 Phase 6 forbids. Finalize reads the skip and its reason
  // off the plan and records those in the report's brief sections.
  const evidenceDoc = {
    bundles: orderedBundles,
    ...(skipPhase4 ? {} : { prosecutor_brief: prosecutorBrief, advocate_brief: advocateBrief }),
    extracted_claims: claims,
    struck_lines: struck,
  }
  writeFileSync(handoff.evidence, JSON.stringify(evidenceDoc, null, 2))
  writeFileSync(handoff.judge, JSON.stringify(judgeOut, null, 2))

  const finArgs = [
    '--plan-file',
    handoff.plan,
    '--evidence-file',
    handoff.evidence,
    '--judge-output',
    handoff.judge,
    '--cross-review-status',
    crossStatus,
    '--cross-review-rankings',
    crossRankings,
    '--cross-review-scores',
    crossScores,
  ]
  if (t.task_id || plan.task_id) {
    finArgs.push('--task-id', String(t.task_id || plan.task_id))
  }
  // D6: marker only via finalize flag — never retype the CDV-199 string here
  if (degraded) {
    finArgs.push('--verification-mode', 'self-verified')
  }
  if (degradationReason) {
    finArgs.push('--degradation-reason', degradationReason)
  }
  // Pass a tokens file through. Do not invent one when the caller has none.
  if (typeof t.tokens_file === 'string' && t.tokens_file && existsSync(t.tokens_file)) {
    finArgs.push('--tokens-file', t.tokens_file)
  }

  const fin = runEngine('finalize', finArgs)
  if (fin.status !== 0) {
    return {
      ok: false,
      error: 'finalize failed',
      exit_code: fin.status,
      stderr: fin.stderr,
      stdout: fin.stdout,
      degraded,
      handoff,
    }
  }

  // Token summary (D10 / AC10) when budget API contributed
  if (tokenUsage.length) {
    console.log('Council Workflow token usage:', JSON.stringify(tokenUsage))
  } else if (runtime.budget && typeof runtime.budget === 'function') {
    try {
      const b = runtime.budget()
      if (b) console.log('Council Workflow token usage:', JSON.stringify(b))
    } catch {
      /* optional */
    }
  }

  if (fin.stdout) console.log(fin.stdout)

  return {
    ok: true,
    degraded,
    verification_mode: degraded ? 'self-verified' : 'full',
    stdout: fin.stdout,
    handoff,
    plan,
    claim_count: claims.length,
    bundle_count: orderedBundles.length,
  }
  } finally {
    // Trap: drop council-wf-* on every exit, including early exit 2.
    if (handoff && handoff.dir) {
      try {
        rmSync(handoff.dir, { recursive: true, force: true })
      } catch {
        /* best-effort */
      }
    }
  }
}

// Workflow host auto-run: globals args/agent/phase/parallel injected by CC Workflow
const _g = globalThis
if (typeof _g.agent === 'function' && typeof _g.args !== 'undefined') {
  const result = await runCouncil({
    args: _g.args,
    agent: _g.agent,
    phase: _g.phase,
    parallel: _g.parallel,
    budget: _g.budget,
  })
  // Hosts that honor top-level return will use this; also attach for inspection
  _g.__council_workflow_result = result
}
