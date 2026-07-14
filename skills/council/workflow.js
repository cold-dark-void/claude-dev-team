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

import { readFileSync, writeFileSync, mkdtempSync, existsSync } from 'node:fs'
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

/** Load flavor body (system-prompt delta only). */
export function loadFlavor(name) {
  const path = join(FLAVORS_DIR, `${name}.md`)
  if (!existsSync(path)) {
    throw new Error(`council workflow: flavor not found: ${name}`)
  }
  return stripFrontmatter(readFileSync(path, 'utf8')).trim()
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
  for (const [k, v] of Object.entries(vars)) {
    const key = k.startsWith('{{') ? k : `{{${k}}}`
    text = text.split(key).join(v == null ? '' : String(v))
  }
  return text
}

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

function labelsFor(n) {
  return Array.from({ length: n }, (_, i) => String.fromCharCode(65 + i))
}

function bordaRank(bundles, rankings) {
  // rankings: array of { ranking: ['B','A',...] } with shared label→index map
  if (!rankings.length) return { ordered: bundles, scores: [], status: 'bypassed: no valid rankings' }
  const n = bundles.length
  const scores = new Array(n).fill(0)
  // Each ranking uses labels A.. over the presented set; map label→index 0..n-1
  // For simplicity labels are global A=0,B=1,... matching submission order
  for (const r of rankings) {
    const order = r.ranking || []
    const m = order.length
    order.forEach((lab, rankIdx) => {
      const bi = lab.charCodeAt(0) - 65
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

  // Required: scope (claim|session|diff) or claim text
  const scope = t.scope || (t.claim ? 'claim' : t.diff ? 'diff' : t.session ? 'session' : '')
  if (!scope) {
    return { ok: false, error: 'scope required (claim|session|diff) or claim string' }
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

  const preflightArgs = ['--scope', scope]
  if (t.claim || t.scope_arg) preflightArgs.push('--scope-arg', t.claim || t.scope_arg)
  if (t.last != null) preflightArgs.push('--last', String(t.last))
  if (t.task_id) preflightArgs.push('--task-id', String(t.task_id))
  if (t.preset) preflightArgs.push('--preset', String(t.preset))
  if (t.why) preflightArgs.push('--why')

  const pre = runEngine('preflight', preflightArgs)
  if (pre.status !== 0) {
    return {
      ok: false,
      error: 'preflight failed',
      exit_code: pre.status,
      stderr: pre.stderr,
    }
  }

  const plan = JSON.parse(pre.stdout)
  const handoff = tmpHandoff('run')
  writeFileSync(handoff.plan, JSON.stringify(plan, null, 2))

  const outputShape = plan.output_shape
  const flavors = Array.isArray(plan.flavors) ? plan.flavors : ['paranoid-ic', 'jaded-senior']
  const claimBudget = plan.claim_budget || 10
  const skipExtract = plan.phases?.['1_claim_extraction']?.skip === true
  const skipPhase4 =
    plan.phases?.['4_prosecution_defense']?.skipped === true || outputShape === 'finding[]'

  // --- Extract --------------------------------------------------------------
  if (typeof phase === 'function') phase('Extract')

  let claims = []
  if (skipExtract) {
    claims = [
      {
        claim: plan.scope_arg || t.claim || '',
        source_locator: 'cli:claim',
        claim_type: 'factual',
      },
    ]
  } else {
    const extractPrompt = loadPrompt('claim-extractor', {
      SCOPE_TYPE: plan.scope,
      INPUT_TEXT: t.input_text || plan.scope_arg || '',
      CLAIM_BUDGET: String(claimBudget),
    })
    const extracted = await safeAgent(extractPrompt, {
      schema: ClaimsSchema,
      agentType: 'dev-team:ic4',
      phase: 'Extract',
      label: 'claim-extractor',
    })
    if (extracted && Array.isArray(extracted.claims)) {
      claims = extracted.claims.slice(0, claimBudget)
    } else {
      // self-verify path: orchestrator-equivalent minimal claim from input
      markDegraded()
      claims = [
        {
          claim: (t.input_text || plan.scope_arg || 'unparsed input').slice(0, 500),
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
      : flavors.filter((f) => f === 'paranoid-ic' || f === 'jaded-senior').length >= 2
        ? flavors.filter((f) => f === 'paranoid-ic' || f === 'jaded-senior')
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
    ;['paranoid-ic', 'jaded-senior'].forEach((flavor) => {
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
    })
    const res = await safeAgent(prompt, {
      schema: EvidenceSchema,
      agentType: 'dev-team:ic4',
      phase: 'Investigate',
      label: `inv:${claimId}:${flavor}`,
    })
    if (!res || !Array.isArray(res.bundles)) {
      // orchestrator self-verify stub bundle (tools would run in live session)
      markDegraded()
      return [
        {
          tool_use_id: `self-verify-${claimId}-${flavor}`,
          raw_blob: `(self-verified) no investigator spawn for claim: ${claim.claim || claim.description || ''}`,
          file_line: claim.source_locator || 'unknown:0',
          reproducible_command: 'echo self-verified',
          claim_id: claimId,
          flavor,
        },
      ]
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
    return { ok: false, error: 'zero evidence bundles after investigate+self-verify', exit_code: 5 }
  }

  // --- Cross-review ---------------------------------------------------------
  if (typeof phase === 'function') phase('Cross-review')

  let crossStatus = 'Phase 2.5 not run'
  let crossRankings = '_Phase 2.5 not run — no cross-review rankings._'
  let crossScores = '_Phase 2.5 not run — no Borda scores._'
  let orderedBundles = bundles

  if (bundles.length >= 3) {
    const labs = labelsFor(bundles.length)
    const reviewers = bundles.map((_, ri) => ri)
    const runReview = async (ri) => {
      const others = bundles
        .map((b, i) => ({ b, i }))
        .filter((x) => x.i !== ri)
      const block = others
        .map((x, j) => {
          const lab = labs[j] || String.fromCharCode(65 + j)
          return `### ${lab}\nclaim_id=${x.b.claim_id}\ntool_use_id=${x.b.tool_use_id}\n\`\`\`\n${x.b.raw_blob}\n\`\`\``
        })
        .join('\n\n')
      const claimText = claims[0]?.claim || plan.scope_arg || ''
      const prompt = loadPrompt('cross-reviewer', {
        CLAIM_TEXT: claimText,
        BUNDLE_BLOCK: block,
      })
      return safeAgent(prompt, {
        schema: RankingSchema,
        agentType: 'dev-team:ic4',
        phase: 'Cross-review',
        label: `cross:${ri}`,
      })
    }

    let rankings
    if (typeof parallel === 'function') {
      rankings = await parallel(reviewers.map((ri) => () => runReview(ri)))
    } else {
      rankings = []
      for (const ri of reviewers) rankings.push(await runReview(ri))
    }
    const valid = rankings.filter((r) => r && Array.isArray(r.ranking) && r.ranking.length)
    if (valid.length === 0) {
      crossStatus = 'bypassed: no valid cross-review rankings collected'
      markDegraded()
    } else {
      const br = bordaRank(bundles, valid)
      orderedBundles = br.ordered
      crossStatus = br.status
      crossRankings = valid.map((r, i) => `reviewer_${i}: ${(r.ranking || []).join(' > ')}`).join('\n')
      crossScores = br.scores.join(', ')
    }
  } else {
    crossStatus = `bypassed: fewer than 3 investigators (${bundles.length} found)`
  }

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
        agentType: 'dev-team:ic4',
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
    PROSECUTOR_BRIEF: prosecutorBrief || '_skipped (finding[] shape)_',
    ADVOCATE_BRIEF: advocateBrief || '_skipped (finding[] shape)_',
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

  if (!judgeOut) {
    // Orchestrator emits judge JSON — never grant tools to a judge persona
    markDegraded()
    if (outputShape === 'finding[]') {
      judgeOut = {
        findings: orderedBundles.map((b) => ({
          file: (b.file_line || 'unknown:0').split(':')[0],
          line: parseInt((b.file_line || '0:0').split(':')[1], 10) || 0,
          severity: 'warning',
          category: b.flavor || 'quality',
          description: `(self-verified) ${b.raw_blob}`.slice(0, 500),
          suggestion: 're-run council with full investigator fleet',
          confidence: 50,
          tool_use_id: b.tool_use_id,
        })),
        struck_lines: [],
      }
    } else {
      judgeOut = {
        verdicts: claims.map((c, i) => ({
          claim: c.claim,
          claim_id: `c${i}`,
          verdict: 'UNVERIFIED',
          confidence: 40,
          evidence_blob: orderedBundles
            .filter((b) => b.claim_id === `c${i}`)
            .map((b) => b.raw_blob)
            .join('\n')
            .slice(0, 2000) || '(no evidence)',
        })),
        struck_lines: [],
      }
    }
  }

  if (!judgeOut.struck_lines) judgeOut.struck_lines = struck

  // --- Finalize handoff -----------------------------------------------------
  if (typeof phase === 'function') phase('Finalize')

  const evidenceDoc = {
    bundles: orderedBundles,
    prosecutor_brief: prosecutorBrief,
    advocate_brief: advocateBrief,
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
