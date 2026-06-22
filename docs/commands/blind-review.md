# /blind-review

Multi-team blind peer review with quorum analysis. Spawns N unconstrained reviewer agents plus M lens-differentiated reviewer agents in a single parallel wave, then clusters their independent findings by semantic similarity into a confidence-tiered report. Reviewers are blind to each other and to the session narrative, so agreement across teams is real signal rather than groupthink. Use it when you want adversarial, multi-perspective coverage of a whole codebase, a directory, or a set of files.

## Usage

```
/blind-review
/blind-review --teams 3 --lenses security,contributor,spec --target path/
```

## Flags

| Flag / Argument | Description |
|-----------------|-------------|
| `--teams N` | Number of unconstrained reviewer teams to spawn. Default `3`. |
| `--lenses L1,L2,...` | Comma-separated lens teams to spawn. Default `security,contributor,spec`. Available: `security`, `contributor`, `spec`, `architecture`, `logic`. |
| `--target <path>` | Narrow the review to a path or glob. Omit to review the full project (all tracked files, minus lockfiles and generated assets). |
| `--no-council` | Skip the `/council` reverse-validation pass over Tier 1 findings. |

Each lens is a *reading angle*, not a scope restriction: a lens reviewer still reads everything, but approaches it from a fixed perspective (e.g. `security` reasons as an attacker, `contributor` as a newcomer who just cloned the repo, `spec` checks code against its stated contracts). Unrecognised flags print a usage line and stop.

## Examples

**Full-project review with defaults:**
```
/blind-review
```
Spawns 3 unconstrained teams plus the `security`, `contributor`, and `spec` lens teams (6 reviewers total) against all tracked files.

**Expected output after the parallel wave:**
```
Scope: full project
Teams: 3 unconstrained + 3 lens (security contributor spec)
Total reviewers: 6
```

**Scoped review with custom lenses:**
```
/blind-review --teams 2 --lenses logic,architecture --target internal/parser/
```
Reviews only files under `internal/parser/` with 2 unconstrained teams plus the `logic` and `architecture` lenses.

**Expected final summary:**
```
Blind review complete.

Report: .claude/reviews/2026-06-22-blind-review.md

Summary:
  Tier 1 (cross-cohort ≥2 teams): 2 clusters
  Tier 2 (same-cohort ≥2 teams):  4 clusters
  Tier 3 (single team):           9 clusters

Top findings:
  [CLUSTER-001] high — unescaped path joined into shell command (3/4 teams)
  [CLUSTER-002] medium — token-limit constant disagrees with the spec (2/4 teams)
  (showing top 5 Tier 1+2 only)

Council reverse-validation: 2 claims challenged — 1 VERIFIED, 1 PARTIALLY_VERIFIED, 0 UNVERIFIED, 0 CONTRADICTED, 0 FABRICATED
```

## How It Works

`/blind-review` orchestrates the review but never writes findings itself:

1. **Resolve scope** — resolves the project root, then builds the reviewer file list from `git ls-files` (full project, excluding lockfiles, minified assets, generated `.pb` files, `node_modules/`, `dist/`, `vendor/`) or from the `--target` path.
2. **Single parallel wave** — spawns every unconstrained team (`U1`, `U2`, ...) and every lens team (`L-security`, `L-contributor`, ...) at once. Reviewers are read-only and blind; any write invalidates a review.
3. **Namespace and validate** — prefixes each finding with its team ID and drops malformed findings (missing `Category`, `Severity`, `Files`, `Claim`, or `Evidence`) rather than repairing them.
4. **Quorum analysis** — a single non-blind analyst reads every finding, clusters findings that describe the same underlying problem, and assigns each cluster a tier (see below).
5. **Council reverse-validation** — unless `--no-council` is set (or there are no Tier 1 clusters), Tier 1 cluster claims are piped to [`/council`](./council.md), which spawns blind investigators to look for evidence each consensus finding is *wrong or overstated*. Each Tier 1 cluster is annotated `VERIFIED` / `PARTIALLY_VERIFIED` / `UNVERIFIED` / `CONTRADICTED` / `FABRICATED`.
6. **Write the report** — writes `.claude/reviews/<date>-blind-review.md` with all three tiers, council verdicts, the quorum summary, and per-team summaries. The report is always written even if council fails.

### Confidence tiers

| Tier | Condition | Interpretation |
|------|-----------|----------------|
| 1 | Cross-cohort AND ≥2 teams | Highest confidence — found independently by both an unconstrained and a lens reviewer. Only these go to council. |
| 2 | Single-cohort AND ≥2 teams | Good signal within one cohort, not independently confirmed across both. |
| 3 | Exactly 1 team | Minority finding — could be noise, a lens artifact, or a genuine missed issue. Reported but not reverse-validated. |

## See Also

- [`/council`](./council.md) — adversarial tribunal that reverse-validates Tier 1 consensus findings
- [`/review-and-commit`](./review-and-commit.md) — focused diff-mode review of staged changes as a pre-commit gate
