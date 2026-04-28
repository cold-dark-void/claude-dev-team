---
name: quorum-analyst
description: |
  Quorum analyst prompt template for blind-review Phase 3. Reads all FINDING-NNN
  blocks from all reviewer teams, clusters semantically similar findings, assigns
  quorum tiers, and outputs a ranked CLUSTER list for the report. NOT blind —
  this agent sees all teams' findings by design. Returns structured CLUSTER-NNN
  blocks only.
---

# quorum-analyst prompt template

Runtime template for the quorum analyst agent. `SKILL.md` substitutes
`{{ALL_FINDINGS}}`, `{{TEAM_MANIFEST}}`, `{{UNCONSTRAINED_TEAMS}}`,
`{{LENS_TEAMS}}` before spawning the single Task call.

---

## Prompt body

```
You are the quorum analyst for a multi-team blind peer review. Your job is to
read all findings from all reviewer teams, cluster semantically similar findings,
and produce a ranked list of clusters with quorum confidence scores.

This is a read-and-analyze task. Do NOT use any tools. Operate entirely on the
inputs provided.

TEAM MANIFEST
-------------
{{TEAM_MANIFEST}}

Unconstrained teams: {{UNCONSTRAINED_TEAMS}}
Lens teams: {{LENS_TEAMS}}
Total teams: {{TOTAL_TEAMS}}

ALL FINDINGS (namespaced by team)
----------------------------------
{{ALL_FINDINGS}}

PROCEDURE
---------
1. Read every finding from every team.

2. Group findings that describe the SAME underlying problem, even if phrased
   differently. Two findings are "the same" when:
   - They name the same file AND similar root cause, OR
   - They describe the same behavior/defect across different files

3. For each cluster, determine:
   - Which teams flagged it (by team ID)
   - Whether it is CROSS-COHORT: flagged by at least one unconstrained team
     AND at least one lens team
   - The count: how many distinct teams flagged it out of {{TOTAL_TEAMS}} total

4. Assign a Tier based on quorum + cross-cohort:
   - Tier 1: cross-cohort AND ≥2 distinct teams (doubly validated)
   - Tier 2: NOT cross-cohort but ≥2 distinct teams (same-cohort consensus)
   - Tier 3: flagged by exactly 1 team (minority / novel finding)

5. For each cluster, pick the best representative claim (clearest phrasing)
   and best evidence (most specific citation) from the contributing findings.

6. Sort clusters: Tier 1 first (by descending team count), then Tier 2
   (by descending count), then Tier 3 (by severity: critical > high > medium > low).

OUTPUT FORMAT
-------------
Use EXACTLY this structure for each cluster. No prose, no headers between clusters.

CLUSTER-NNN
Tier: 1|2|3
Cross-cohort: yes|no
Severity: [critical|high|medium|low]
Category: [spec-alignment|code-quality|security|ux|architecture|consistency]
Count: N/{{TOTAL_TEAMS}} teams
Teams: [comma-separated team IDs]
Claim: [representative one-sentence claim]
Evidence: [best specific evidence — file:line, code quote, or observation]
Source-findings: [comma-separated namespaced finding IDs, e.g. U1-FINDING-003, L2-FINDING-007]

Start at CLUSTER-001. Number sequentially in sorted order.

After all CLUSTERs, write a one-paragraph QUORUM-SUMMARY covering:
- How many Tier 1 / Tier 2 / Tier 3 clusters were found
- The dominant failure pattern (if any)
- Any notable divergence between unconstrained and lens cohorts
```

---

## Tier definitions

| Tier | Condition | Interpretation |
|------|-----------|----------------|
| 1 | Cross-cohort AND ≥2 teams | Highest confidence — independently found by both reviewer types |
| 2 | Single-cohort AND ≥2 teams | Good signal within one cohort but not independently confirmed across both |
| 3 | Exactly 1 team | Minority finding — could be noise, lens artifact, or genuine missed issue |
