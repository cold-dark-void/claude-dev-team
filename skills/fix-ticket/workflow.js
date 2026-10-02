import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { randomBytes } from 'node:crypto'
import { spawnSync } from 'node:child_process'
import { refuteEvidence } from './untracked.js'

const DIR = dirname(fileURLToPath(import.meta.url))
const PROMPT_DIR = join(DIR, 'prompts')

function porcelainOf(wt) {
  try {
    const r = spawnSync('git', ['-C', wt, 'status', '--porcelain', '-uall', '-z'], { encoding: 'utf8' })
    return (r && r.stdout) || ''
  } catch {
    return ''
  }
}

/**
 * fix-ticket Workflow reference asset (CDV-197 / SPEC-028).
 *
 * NON-INVOKED by the plugin MVP path. Markdown Task protocol in SKILL.md is
 * authoritative. Prompts are loaded from prompts/*.md (not copied inline).
 *
 * Do not dual-drive: if a future Workflow runtime is wired, keep schemas and
 * phase order aligned with SKILL.md.
 */

export const meta = {
  name: 'fix-ticket',
  description:
    'Verify premise, implement, and adversarially verify one ticket fix in a worktree (reference Workflow — markdown path authoritative)',
  phases: [
    { title: 'Verify-premise', detail: 'confirm the bug still exists in current code' },
    { title: 'Implement', detail: 'apply the code fix (no version files, no commit)' },
    { title: 'Adversarial-verify', detail: 'independent refuters try to break the fix' },
  ],
}

const PREMISE_SCHEMA = {
  type: 'object',
  properties: {
    holds: {
      type: 'boolean',
      description: 'true = the bug still exists as described in current code',
    },
    current_locations: {
      type: 'array',
      items: { type: 'string' },
      description: 'file:line of the bug AS IT EXISTS NOW',
    },
    evidence: {
      type: 'string',
      description: 'concise: what the current code actually does that is wrong',
    },
    scope_notes: {
      type: 'string',
      description: 'nuance/refinement the fixer must know; empty if none',
    },
    sibling_occurrences: {
      type: 'array',
      items: { type: 'string' },
      description: 'other files with the SAME bug pattern (grep)',
    },
    reference_impl: {
      type: 'string',
      description:
        'if the fix ports an existing correct implementation, its file:line; else empty',
    },
  },
  required: ['holds', 'evidence'],
}

const IMPL_SCHEMA = {
  type: 'object',
  properties: {
    files_changed: { type: 'array', items: { type: 'string' } },
    diff_summary: {
      type: 'string',
      description: 'concise before/after of every change (file:line)',
    },
    changelog_md: {
      type: 'string',
      description: 'one changelog bullet in house style (caller applies)',
    },
    side_effects_checked: {
      type: 'string',
      description: 'what was verified NOT to break',
    },
    validation: {
      type: 'string',
      description: 'validation commands run + their results',
    },
  },
  required: ['files_changed', 'diff_summary', 'changelog_md'],
}

const VERDICT_SCHEMA = {
  type: 'object',
  properties: {
    lens: { type: 'string' },
    holds: {
      type: 'boolean',
      description:
        'true = fix is correct & complete for this lens; false = found a real problem',
    },
    issues: {
      type: 'array',
      items: { type: 'string' },
      description: 'concrete problems (file:line); empty if holds',
    },
    detail: { type: 'string' },
  },
  required: ['lens', 'holds'],
}

const MARKER = 'self-verified — refuters unavailable'
const IMPL_AGENTS = new Set(['ic4', 'ic5'])

export function normalizeLenses(lenses) {
  if (lenses == null || lenses === '') return ['correctness', 'completeness']
  if (typeof lenses === 'string') {
    const parts = lenses.split(',').map((s) => s.trim()).filter((s) => s.length > 0)
    if (parts.length === 0) return ['correctness', 'completeness']
    return parts
  }
  if (!Array.isArray(lenses) || lenses.some((x) => typeof x !== 'string' || x.length === 0)) {
    throw new TypeError('lenses must be a comma-separated string or an array of strings')
  }
  return lenses.slice()
}

export function premiseHolds(premise) {
  if (premise == null || typeof premise !== 'object') return false
  return premise.holds === true
}

export function resolveImplAgent(agent) {
  if (agent == null || agent === '') return { ok: true, agent: 'ic4' }
  if (typeof agent !== 'string' || !IMPL_AGENTS.has(agent)) {
    return { ok: false, error: 'agent must be ic4 or ic5', agent }
  }
  return { ok: true, agent }
}

// A null slot is a failed refuter. Do not drop it: all_hold would then pass
// on a partial fleet, and verification_mode would stay full.
export function summarizeVerdicts(slots) {
  const list = Array.isArray(slots) ? slots : []
  const missing = list.some((v) => v == null || typeof v !== 'object')
  const verdicts = list.filter((v) => v != null && typeof v === 'object')
  const allHold =
    list.length > 0 &&
    !missing &&
    verdicts.length === list.length &&
    verdicts.every((v) => v.holds === true)
  return {
    verdicts,
    all_hold: allHold,
    verification_mode: missing ? 'self-verified' : 'full',
  }
}

export function promptBody(markdown) {
  const m = String(markdown).match(/```[^\n]*\n([\s\S]*?)\n```/)
  return m ? m[1] : String(markdown)
}

export function fillPrompt(template, vars) {
  const src = vars || {}
  let text = String(template)
  const nonce = src.DATA_NONCE == null ? '' : String(src.DATA_NONCE)
  if (nonce !== '') {
    text = text.split('{{DATA_NONCE}}').join(nonce)
  }
  const begin = nonce === '' ? '' : `<<<BEGIN_${nonce}>>>`
  const end = nonce === '' ? '' : `<<<END_${nonce}>>>`
  for (const [key, value] of Object.entries(src)) {
    if (key === 'DATA_NONCE') continue
    let repl = value == null ? '' : String(value)
    if (begin !== '') {
      repl = repl.split(begin).join('').split(end).join('')
    }
    repl = repl.split('{{DATA_NONCE}}').join('')
    text = text.split(`{{${key}}}`).join(repl)
  }
  return text
}

export function loadPrompt(name, vars, dir = PROMPT_DIR) {
  const raw = readFileSync(join(dir, `${name}.md`), 'utf8')
  return fillPrompt(promptBody(raw), vars)
}

function dataNonce() {
  return randomBytes(8).toString('hex')
}

export async function runFixTicket({ args, agent, phase, parallel, promptDir }) {
  let t = args
  if (typeof args === 'string') {
    try {
      t = JSON.parse(args)
    } catch {
      t = {}
    }
  }
  if (!t || typeof t !== 'object' || !t.ticket || !t.worktree) {
    return {
      premise_holds: false,
      error: 'args not interpolated — need ticket + worktree',
      args_type: typeof args,
      args_seen: t,
    }
  }
  if (!t.bug) {
    return {
      premise_holds: false,
      error: 'args missing required field: bug',
      args_type: typeof args,
    }
  }
  const implAgent = resolveImplAgent(t.agent)
  if (!implAgent.ok) {
    return { premise_holds: false, error: implAgent.error, agent: t.agent }
  }

  const WT = t.worktree
  const TICKET = t.ticket
  const BUG = t.bug
  const FIX = t.fix || ''
  let lenses
  try {
    lenses = normalizeLenses(t.lenses)
  } catch (e) {
    return {
      premise_holds: false,
      error: e.message,
      all_hold: false,
      verification_mode: 'self-verified',
      marker: MARKER,
      verdicts: [],
    }
  }

  phase('Verify-premise')
  const premise = await agent(
    loadPrompt('premise', { TICKET, WORKTREE: WT, BUG, DATA_NONCE: dataNonce() }, promptDir),
    {
      schema: PREMISE_SCHEMA,
      agentType: 'dev-team:debugger',
      phase: 'Verify-premise',
      label: `premise:${TICKET}`,
    },
  )

  if (!premiseHolds(premise)) return { premise_holds: false, premise: premise ?? null }

  phase('Implement')
  const impl = await agent(
    loadPrompt(
      'implement',
      {
        TICKET,
        WORKTREE: WT,
        BUG,
        FIX,
        AGENT: implAgent.agent,
        PREMISE_JSON: JSON.stringify(premise),
        DATA_NONCE: dataNonce(),
      },
      promptDir,
    ),
    {
      schema: IMPL_SCHEMA,
      agentType: `dev-team:${implAgent.agent}`,
      phase: 'Implement',
      label: `impl:${TICKET}`,
    },
  )

  phase('Adversarial-verify')
  const slots = await parallel(
    lenses.map((lens) => () =>
      agent(
        loadPrompt(
          'refute',
          {
            TICKET,
            WORKTREE: WT,
            BUG,
            FIX,
            LENS: lens,
            PREMISE_EVIDENCE: premise.evidence || '',
            DATA_NONCE: dataNonce(),
          },
          promptDir,
        ) +
          '\n' +
          refuteEvidence(porcelainOf(WT)),
        {
          schema: VERDICT_SCHEMA,
          agentType: 'dev-team:qa',
          phase: 'Adversarial-verify',
          label: `verify:${TICKET}:${lens}`,
        },
      ),
    ),
  )
  const summary = summarizeVerdicts(slots)
  const degraded = summary.verification_mode === 'self-verified'
  return {
    premise_holds: true,
    premise,
    impl,
    verdicts: summary.verdicts,
    all_hold: summary.all_hold,
    verification_mode: summary.verification_mode,
    marker: degraded ? MARKER : '',
  }
}

const hasRuntime =
  typeof args !== 'undefined' &&
  typeof agent === 'function' &&
  typeof phase === 'function' &&
  typeof parallel === 'function'

if (hasRuntime) {
  await runFixTicket({ args, agent, phase, parallel })
}
