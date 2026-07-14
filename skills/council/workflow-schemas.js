/**
 * Operational JSON Schema objects for the Council-on-Workflow path (CDV-196).
 * Canonical shapes: specs/core/SPEC-013 + skills/council/SKILL.md Phase 2/5.
 * Taxonomies are enum-locked. Workflow path MUST NOT repair schema violations.
 */

export const VERDICT_TAXONOMY = [
  'VERIFIED',
  'PARTIALLY_VERIFIED',
  'UNVERIFIED',
  'CONTRADICTED',
  'FABRICATED',
]

export const FINDING_SEVERITY = ['critical', 'warning', 'nitpick']

export const CLAIM_TYPES = ['factual', 'causal', 'recommendation']

/** Phase 1 claim list (verdict[]-shape extraction). */
export const ClaimsSchema = {
  type: 'object',
  properties: {
    claims: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          claim: { type: 'string' },
          source_locator: { type: 'string' },
          claim_type: { type: 'string', enum: CLAIM_TYPES },
        },
        required: ['claim', 'source_locator', 'claim_type'],
      },
    },
    truncated: { type: 'boolean' },
    unaudited: { type: 'array', items: { type: 'string' } },
  },
  required: ['claims'],
}

/** Single evidence bundle (Phase 2 investigator return). */
export const EvidenceBundleSchema = {
  type: 'object',
  properties: {
    tool_use_id: { type: 'string', description: 'MANDATORY tool_use_id from the tool call' },
    raw_blob: { type: 'string', description: 'Raw tool output, NOT paraphrased' },
    file_line: { type: 'string', description: 'path/to/file:42 or equivalent locator' },
    reproducible_command: { type: 'string' },
    claim_id: { type: 'string', description: 'Claim id carried for Phase 4 claim-blind briefs' },
    flavor: { type: 'string' },
  },
  required: ['tool_use_id', 'raw_blob', 'file_line', 'reproducible_command'],
}

/** Investigator may return one or more bundles. */
export const EvidenceSchema = {
  type: 'object',
  properties: {
    bundles: {
      type: 'array',
      items: EvidenceBundleSchema,
    },
  },
  required: ['bundles'],
}

/** Phase 2.5 cross-review ranking. */
export const RankingSchema = {
  type: 'object',
  properties: {
    ranking: {
      type: 'array',
      items: { type: 'string' },
      description: 'Ordered labels best-first, e.g. ["B","A","C"]',
    },
    ranking_line: {
      type: 'string',
      description: 'Optional RANKING: X > Y > Z form for audit trail',
    },
  },
  required: ['ranking'],
}

/** Phase 4 prosecutor / advocate brief. */
export const BriefSchema = {
  type: 'object',
  properties: {
    briefs: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          claim_id: { type: 'string' },
          evidence_against: { type: 'string' },
          evidence_for: { type: 'string' },
          requested_verdict: { type: 'string', enum: VERDICT_TAXONOMY },
          supporting_tool_use_ids: { type: 'array', items: { type: 'string' } },
        },
        required: ['claim_id', 'requested_verdict', 'supporting_tool_use_ids'],
      },
    },
    struck_lines: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          claim_id: { type: 'string' },
          line: { type: 'string' },
          reason: { type: 'string' },
        },
      },
    },
  },
  required: ['briefs', 'struck_lines'],
}

/** Phase 5 verdict[] judge output. */
export const VerdictSchema = {
  type: 'object',
  properties: {
    verdicts: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          claim: { type: 'string' },
          claim_id: { type: 'string' },
          verdict: { type: 'string', enum: VERDICT_TAXONOMY },
          confidence: { type: 'integer', minimum: 0, maximum: 100 },
          evidence_blob: { type: 'string' },
        },
        required: ['claim', 'verdict', 'confidence', 'evidence_blob'],
      },
    },
    struck_lines: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          claim: { type: 'string' },
          line: { type: 'string' },
          reason: { type: 'string' },
        },
      },
    },
  },
  required: ['verdicts', 'struck_lines'],
}

/** Phase 5 finding[] judge output (diff-mode). */
export const FindingSchema = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          file: { type: 'string' },
          line: { type: 'integer' },
          severity: { type: 'string', enum: FINDING_SEVERITY },
          category: { type: 'string' },
          description: { type: 'string' },
          suggestion: { type: 'string' },
          confidence: { type: 'integer', minimum: 0, maximum: 100 },
          tool_use_id: { type: 'string' },
        },
        required: [
          'file',
          'line',
          'severity',
          'category',
          'description',
          'suggestion',
          'confidence',
          'tool_use_id',
        ],
      },
    },
    struck_lines: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          claim: { type: 'string' },
          line: { type: 'string' },
          reason: { type: 'string' },
        },
      },
    },
  },
  required: ['findings', 'struck_lines'],
}
