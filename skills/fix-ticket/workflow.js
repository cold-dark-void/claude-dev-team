/**
 * fix-ticket Workflow reference asset (CDV-197 / SPEC-028).
 *
 * NON-INVOKED by the plugin MVP path. Markdown Task protocol in SKILL.md is
 * authoritative. This file ports .claude/p0-fix-workflow.js with:
 *   - args-as-JSON-string guard (Workflow authoring convention for CDV-196)
 *   - worktree-aware prompts
 *   - anti-git-checkout refuter language
 *   - no version/commit hard constraints
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

// Workflow authoring convention: args may arrive as a JSON string.
// Always guard before property access; fail loud when required fields missing.
let t = args
if (typeof args === 'string') {
  try {
    t = JSON.parse(args)
  } catch (e) {
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

const WT = t.worktree
const TICKET = t.ticket
const BUG = t.bug
const FIX = t.fix || ''

phase('Verify-premise')
const premise = await agent(
  `You are verifying whether a documented bug (${TICKET}) STILL EXISTS in the CURRENT code. Do NOT edit anything — read only.\n` +
    `Output mode: terse.\n` +
    `Worktree to inspect: ${WT}\n` +
    `Documented bug: ${BUG}\n\n` +
    `Read the relevant CURRENT files under ${WT} (line numbers may have moved). Confirm whether the bug is present as described. Report: the CURRENT file:line locations, concise evidence of the wrong behavior, any scope nuance the fixer must know, every SIBLING file carrying the same bug pattern (grep for it), and — if the fix ports an existing correct implementation elsewhere — that reference's file:line.`,
  {
    schema: PREMISE_SCHEMA,
    agentType: 'dev-team:ic5',
    phase: 'Verify-premise',
    label: `premise:${TICKET}`,
  },
)

if (!premise.holds) return { premise_holds: false, premise }

phase('Implement')
const implAgent = t.agent || 'ic4'
const impl = await agent(
  `You are @${implAgent}. Implement the fix for ${TICKET} in the worktree: ${WT}\n` +
    `Output mode: terse.\n\n` +
    `Bug (verified present): ${BUG}\n` +
    `Current locations: ${JSON.stringify(premise.current_locations || [])}\n` +
    `Scope notes: ${premise.scope_notes || '(none)'}\n` +
    `Sibling occurrences to ALSO fix: ${JSON.stringify(premise.sibling_occurrences || [])}\n` +
    `Reference implementation to port from (if any): ${premise.reference_impl || '(none)'}\n` +
    `Fix instructions: ${FIX}\n\n` +
    `HARD CONSTRAINTS:\n` +
    `- Edit ONLY code/doc files under ${WT}. Do NOT touch .claude-plugin/plugin.json, .claude-plugin/marketplace.json, or README.md version/changelog — the caller does the version bump + changelog.\n` +
    `- Do NOT run git commit / git checkout / git reset / git add. Leave all changes UNCOMMITTED in the worktree.\n` +
    `- Author any file or script containing '!' or '<!--' via the Write tool, never an inline bash heredoc/awk (zsh mangles '!').\n` +
    `- Fix EVERY sibling occurrence listed above (no whack-a-mole).\n` +
    `- Make the SMALLEST change that fully fixes the bug. This is a patch, not a refactor — no scope creep, no new features.\n\n` +
    `Then validate: simulate the fixed code/command against a realistic input and confirm it behaves correctly; if you changed a shell script, syntax-check it (bash -n) and exercise it.\n` +
    `Draft ONE changelog bullet in house style for the CALLER (do not edit CHANGELOG.md): '- **fix: <one-line summary> (${TICKET})** — <2-4 sentences: the bug, the fix, why this scope>.'\n` +
    `Return files_changed, a concise diff_summary (before/after per change), the changelog bullet, what side-effects you checked, and your validation commands+results.`,
  {
    schema: IMPL_SCHEMA,
    agentType: `dev-team:${implAgent}`,
    phase: 'Implement',
    label: `impl:${TICKET}`,
  },
)

phase('Adversarial-verify')
const lenses = t.lenses || ['correctness', 'completeness']
const verdicts = (
  await parallel(
    lenses.map((lens) => () =>
      agent(
        `You are an INDEPENDENT adversarial reviewer. Try hard to REFUTE that the fix for ${TICKET} is correct and complete, through the '${lens}' lens.\n` +
          `Output mode: terse.\n` +
          `Worktree: ${WT}. Inspect the uncommitted changes: cd ${WT} && git diff   (also read the surrounding code).\n` +
          `Original bug: ${BUG}\n` +
          `Intended fix: ${FIX}\n` +
          `Premise evidence: ${premise.evidence}\n\n` +
          `Through the '${lens}' lens, look for: the fix being INCOMPLETE (a sibling site left unfixed), the fix introducing a NEW bug/side-effect, the fix not actually resolving the stated bug, a broken positional/format/column dependency, a contract/spec violation, or a wrong assumption. Read the ACTUAL diff — do not assume. Default to holds=false if you find ANY real problem; holds=true only if you genuinely cannot break it. Cite file:line.\n` +
          `HARD CONSTRAINTS: Prefer read-only. If bite-testing with mutation: backup (cp) → inject → observe → restore FROM BACKUP (cp) or sed-reverse of the injection only. NEVER run git checkout / git restore / git reset to clean bite-tests — those wipe sibling uncommitted work. After mutation assert clean git status of unrelated paths. Do NOT implement alternative fixes. Do NOT commit.`,
        {
          schema: VERDICT_SCHEMA,
          agentType: 'dev-team:qa',
          phase: 'Adversarial-verify',
          label: `verify:${TICKET}:${lens}`,
        },
      ),
    ),
  )
).filter(Boolean)

// Spawn-failure: caller/orchestrator self-verifies missing lenses and sets
// verification_mode=self-verified with marker "self-verified — refuters unavailable".
// Protocol home: skills/council/SKILL.md § Spawn-failure degradation (CDV-199).

return {
  premise_holds: true,
  premise,
  impl,
  verdicts,
  all_hold: verdicts.length > 0 && verdicts.every((v) => v.holds),
  verification_mode: 'full',
}
