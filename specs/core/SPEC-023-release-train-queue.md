# SPEC-023: Release Train — Multi-Branch Release Queue

**Status**: ACTIVE
**Category**: core
**Created**: 2026-07-03

---

## Overview

A release-queue coordinator for the recurring situation where several feature branches are ready to ship at once, each assuming the same "next feature minor" and each touching the same hot files (the `specs/TDD.md` index and Version-History tables, the `CHANGELOG.md` top section, and the version triplet). Live case at drafting time: `feat/spec-020-craft-loop` and `feat/spec-021-skill-lint` both assume the next feature minor. Landing them serially today means hand-resolving the same conflict classes every time and manually renumbering assumed versions. The train fixes this: register ready branches into a queue state file under `.claude/release-train/`, compute a deterministic landing order and per-slot version assignment, then for each entry in turn — bring its changes onto master as uncommitted working-tree changes, renumber the version the branch assumed, mechanically pre-resolve the KNOWN conflict classes, and drive the existing `/release` skill for all commit/tag/push mechanics. A dry-run mode prints the computed order and version assignments without mutating anything. The train is abort-safe: queue state survives interruption, resume is idempotent, and master is never left half-merged.

The train is a **sequencer, not a releaser**. It owns queue state, ordering, slot-version arithmetic, and a small enumerated set of purely mechanical conflict pre-resolutions; everything about what a single release IS remains owned elsewhere and is invoked, not copied.

**Boundaries & related specs (conflict scan, 2026-07-03):**
- **SPEC-010 (code review & release)** owns single-release mechanics end-to-end: the folded one-commit-per-release rule, commit-message format, changelog generation style, version-triplet sync and verification, the pre-commit drift gates (sync-includes, council template-vars, hook-template gate reduced/retired dual-copy per CDT-54 / SPEC-010 Step 4.7), and the tag/push sequence — all realized in `skills/release/SKILL.md`. The train orchestrates one `/release <explicit-version>` call per queue entry and MUST NOT reimplement, inline, or fork any of it. A `/release` gate failure is a train-blocking event, never something the train works around. When the train pre-writes a CHANGELOG heading for the assigned version (M5c), `/release` uses **skip-if-present** (explicit version only) so Steps 2–3a verify rather than duplicate (SPEC-010 Release MUST).
- **SPEC-016 (worktree isolation)** owns worktree layout, `worktree-lib.sh`, and the serialized-worktree-ops rule ("MUST NOT run parallel `git worktree` operations") — that rule applies to the train in full: entries land strictly one at a time, and the train never runs git operations concurrently with another agent's worktree work. Queued branches may still have live `.worktrees/<slug>` checkouts; the train reads branches via plain git refs and neither creates nor removes worktrees (teardown stays with `/wrap-ticket` per SPEC-016).
- **SPEC-008 (spec management)** owns `specs/TDD.md` — its canonical index columns, the 2-column Version-History row format, atomic index/spec-file updates, and status taxonomy. The train does NOT manage specs: during conflict pre-resolution it only mechanically union-appends index rows and Version-History rows that the queued branches already authored, byte-preserving every existing row. Any TDD.md conflict that is not a pure row-append is outside the enumerated classes and halts the train.
- **SPEC-002 (plugin infrastructure)** owns the version-triplet rule itself (CHANGELOG.md heading + `plugin.json` + `marketplace.json` must match) and the version format conventions. The train renumbers assumed version strings to the assigned slot but final triplet verification remains `/release` Step 4's job.

**Out of scope:** parallel landings; rebasing or otherwise mutating the queued source branches; releasing to any external registry; cross-repo trains; automatic conflict resolution beyond the four enumerated classes; PR-based landing flows (`gh pr merge`) — the train targets this repo's direct-to-master single-folded-commit model.

---

## MUST

- **M1 — Queue state file.** The train MUST persist its queue at `.claude/release-train/queue.json` (project `.claude/` state under the shared MROOT resolved via `git rev-parse --git-common-dir`, never committed — matching the `.claude/ci-watch/` and `.claude/local-agent/` sidecar precedent). Each entry MUST carry at least: `branch`, `bump` (`minor`|`patch` per the `/release` feature-line policy), `assumed_version` (the version the branch pinned in its content, or `null` if it pinned none), `assigned_version` (`null` until its slot is computed), `status` (`pending` | `landing` | `landed` | `blocked`), `base_sha` (master HEAD recorded immediately before this entry's landing begins), and `tag` (set on success). Optional: `blocked_paths` (string array), `registered_at` (ISO-8601). The file MUST be valid JSON at every write (write-temp-then-rename under `${TMPDIR:-/tmp}`).
- **M2 — Deterministic order.** Landing order MUST be deterministic: registration order by default, with an explicit user override at train start. Order and all slot version assignments MUST be computed and frozen into `queue.json` before the first landing begins, so an interrupted train resumes with the same plan it printed.
- **M3 — Slot version assignment & renumbering.** Slot versions MUST be computed relative to the CURRENT master triplet at train start — never hardcoded: slot 1 applies its entry's `bump` to master's version (a feature branch defaults to `minor`, i.e. the next feature minor; `patch` is allowed per the `/release` feature-line arc policy), and each subsequent slot applies its `bump` to the previous slot's result. For an entry whose branch pinned an `assumed_version` (e.g. a `### vX.Y.Z` CHANGELOG heading, `plugin.json`/`marketplace.json` version fields), the train MUST renumber every occurrence of that assumed string in exactly the three version surfaces on the merged working tree to the `assigned_version`. Branches that pinned nothing need no renumbering — `/release`'s own Step-3 bump covers them.
- **M4 — Uncommitted presentation to /release.** Each entry's changes MUST reach master's working tree as UNCOMMITTED changes (e.g. `git merge --squash <branch>` with the index then reset as needed) so that `/release`'s single-folded-commit contract holds: after an entry lands, master has gained exactly ONE commit — the `/release`-authored `feat:/fix: vX.Y.Z — <summary>` commit. The train MUST NOT create merge commits, intermediate commits, or its own release commits on master.
- **M5 — Enumerated conflict pre-resolution (mechanical only).** The train MUST deterministically pre-resolve ONLY these four conflict classes, and each resolution MUST be purely textual — no reflowing, reformatting, or rewriting of rows/sections it did not add: **(a) `specs/TDD.md` Spec Index rows** — union-append: every master row byte-preserved, the branch's new rows appended in spec-ID order; **(b) Version-History tables** (`specs/TDD.md` and individual spec files) — union of rows sorted by date (stable within a date: master's rows first, then the branch's in original order); **(c) `CHANGELOG.md`** — the branch's own entry body under a single `### v<assigned_version>` heading, prepended above master's current top section, yielding exactly one heading per version in descending version order; **(d) version fields** in `plugin.json` / `marketplace.json` — the `assigned_version` wins. Before invoking `/release`, the train MUST ensure exactly one CHANGELOG heading exists for the assigned version (the adopted branch entry), so `/release` Step 3a **skip-if-present** verifies rather than duplicates.
- **M6 — Halt on any other conflict.** Any merge conflict outside the four enumerated classes MUST stop the train for that entry: abort the merge, restore master to the recorded `base_sha` clean state, set the entry's `status` to `blocked` with the conflicting paths recorded in `queue.json`, report to the user, and stop. The train MUST NOT guess at, LLM-improvise, or silently skip a non-enumerated conflict; continuing past a blocked entry requires an explicit user decision (and re-freezing later slots per M2's determinism, since skipping shifts them).
- **M7 — Drive /release per entry.** All commit, tag, and push mechanics MUST go through the existing `/release` skill, invoked once per entry with the EXPLICIT `assigned_version` (never bare `/release` auto-detect mid-train — the working tree context would mis-detect). All of `/release`'s pre-commit gates run unmodified per entry; if `/release` refuses or a gate fails, the train MUST treat it as M6-style blockage: restore master clean, mark the entry `blocked`, stop.
- **M8 — Abort-safety & idempotent resume.** Queue state MUST survive interruption at any point. On restart, the train MUST resume at the first entry whose `status` is not `landed`, and MUST verify a `landed` entry by its recorded `tag` existing on master before skipping it — never re-releasing. At every observable moment master is in exactly one of two states: clean at the last landed release, or clean at `base_sha` after a restore; a half-merged master MUST NOT survive any exit path (including SIGINT — restore via `git merge --abort` / `git reset --hard <base_sha>` on the next invocation if a dirty tree from a prior train run is detected).
- **M9 — Dry-run.** A `--dry-run` invocation MUST print the computed landing order, per-slot version assignments, per-entry renumbering plan (assumed → assigned), and predicted conflict classes per entry — with ZERO mutation: no git state change, no version-file edit, no tag, and no change to entry `status` in `queue.json`. Dry-run may compute an ephemeral plan without setting `frozen=true` or writing status (`freeze --print-only`).
- **M10 — MUST NOT reimplement /release internals.** The train MUST NOT contain its own implementation of commit-message formatting, changelog-entry generation, triplet sync/verification, drift gates, or tag/push sequencing. `train-lib.sh` MUST NOT invoke `git tag`, `git push`, or `git commit`. If `/release`'s contract changes, the train inherits the change by invocation, not by copy (single source of truth per SPEC-010 / AGENTS.md).
- **M11 — MUST NOT mutate queued branches; serialize everything.** The train MUST NOT commit to, rebase, renumber, or otherwise rewrite the queued source branches themselves — renumbering happens only on the merged working tree on master; branches stay untouched for their owners. Entries MUST land strictly sequentially, inheriting SPEC-016's serialized-`git worktree`-operations rule; the train MUST NOT run two landings, or a landing plus any other train git operation, concurrently.
- **M12 — CLI surface.** Mechanical operations MUST be exposed as a subprocess-only CLI: `bash skills/release-train/train-lib.sh <cmd> …` (never sourced). Commands:
  - `init` — ensure dir + empty `queue.json` if missing
  - `register <branch> [--bump minor|patch] [--assumed <ver>|null]`
  - `list` — JSON queue to stdout
  - `drop <branch>` — remove pending entry only
  - `freeze [--order b1,b2,…] [--print-only]` — compute + write order + `assigned_version` from master triplet (`--print-only` prints without writing)
  - `show-plan` — print frozen plan
  - `set-status <branch> <pending|landing|landed|blocked> [--base-sha S] [--tag T] [--paths p1,p2]`
  - `detect-assumed <branch>` — stdout assumed version or empty
  - `renumber <assumed> <assigned>` — rewrite 3 version surfaces in cwd working tree
  - `resolve-tdd-index` / `resolve-vh` / `resolve-changelog <assigned>` / `resolve-json <assigned>` — M5a–d (file-based flags for unit tests)
  - `restore <base_sha>` — `git merge --abort` if needed + `git reset --hard <base_sha>`
  - `verify-tag <tag>` — exit 0 if tag points at an ancestor of HEAD
  - `acquire-lock` / `release-lock`
  - `preflight` — print ok/dirty/wrong-branch diagnostics
  - Exit codes: `0` ok, `1` operational fail, `2` blocked/conflict, `64` usage
- **M13 — Preconditions.** Before the landing loop (`start`): (a) current branch is `master` or `main`; (b) working tree clean OR prior train dirt → auto-restore to last known `base_sha`/landed tip; (c) queue has ≥1 non-landed entry; (d) plan frozen (`assigned_version` set for all pending); (e) lock acquired.
- **M14 — Advisory lock.** `train.lock` under `.claude/release-train/`; second concurrent `acquire-lock` fails exit 1; skill documents release on all exit paths.
- **M15 — Status transitions.** Only: `pending→landing`, `landing→landed`, `landing→blocked`. `drop` only if `pending`. `landed` immutable except verify. No `skipped` status in v1. Illegal transitions exit non-zero.

## SHOULD

- SHOULD warn at registration when a branch's merge-base is far behind master (stale branch — higher odds of non-enumerated conflicts) and suggest the owner refresh it before its slot arrives.
- SHOULD detect dead entries at train start (branch deleted, or already fully contained in master) and prompt to drop them rather than failing mid-train.
- SHOULD print a one-line summary after each landing (`<branch> → vX.Y.Z (tag pushed)`) and a final train summary table.
- SHOULD suggest the per-branch follow-up (`/wrap-ticket`, branch deletion) after a successful landing, without performing it — cleanup stays with SPEC-016/SPEC-009 flows.
- SHOULD keep the pre-resolution helpers in a subprocess CLI (`bash skills/release-train/train-lib.sh <cmd>`, matching the `worktree-lib.sh` / `task-store.sh` precedent) so the union-append logic is deterministically testable without an LLM in the loop.

## Test

1. **Queue registration & state (M1):** register two branches → `.claude/release-train/queue.json` exists, is valid JSON, and each entry carries `branch`, `bump`, `assumed_version`, `assigned_version`, `status`, `base_sha`, `tag`; a second registration preserves the first entry.
2. **Frozen deterministic plan (M2):** start a train, kill it before slot 1 lands, restart → the printed order and slot assignments are identical to the pre-kill plan (read back from `queue.json`, not recomputed differently).
3. **Slot arithmetic & renumbering (M3):** with master at some vX.Y.Z and two queued `feat:` branches (defaults `minor` then declared `patch`), the dry-run assigns the next feature minor to slot 1 and the following patch to slot 2; a branch that pinned an assumed version has its CHANGELOG heading and both JSON version fields renumbered to its slot on the merged tree, and `git log <branch>` shows the source branch unchanged.
4. **Single folded commit (M4):** after one entry lands, `git log --oneline` shows master gained exactly one commit (the `/release` folded commit, matching the SPEC-010 subject format), zero merge commits, and the slot tag exists.
5. **TDD.md union-append (M5a, M5b):** two branches each adding a Spec-Index row and Version-History rows both land → final `specs/TDD.md` contains every pre-train row byte-identical, both new index rows in spec-ID order, and a date-sorted Version-History union.
6. **CHANGELOG stacking (M5c, M5d):** after both land, `CHANGELOG.md` headings descend in version order with exactly one heading per version, each branch's authored bullet content preserved under its renumbered heading, and the triplet matches (per `/release` Step 4 passing).
7. **Non-enumerated conflict halts clean (M6):** seed a queued branch that conflicts with master in an arbitrary skill file → the train aborts that merge, `git status` on master is clean at `base_sha`, the entry is `blocked` with the conflicting path recorded, and the train has stopped without touching later entries.
8. **Delegation, not reimplementation (M7, M10):** inspect the train command/skill sources — every commit/tag/push flows through an explicit-version `/release` invocation; no `git tag`, `git push`, commit-message template, or triplet-edit logic exists in the train outside pre-resolution renumbering; a forced drift-gate failure inside `/release` blocks the entry and restores master.
9. **Idempotent resume (M8):** interrupt the train after slot 1's tag is pushed but before slot 2 begins → restart resumes at slot 2; slot 1 is skipped only after its tag is verified on master; no duplicate commit or tag appears.
10. **Dry-run is inert (M9):** run `--dry-run` → order, versions, renumbering plan, and predicted conflict classes print; `git status` is untouched, no tags are created, and entry `status` values in `queue.json` are unchanged.
11. **Branches untouched & serialized (M11):** after a full train, every queued branch's SHA equals its pre-train SHA; landings observably ran one at a time (state file never shows two entries `landing`).
12. **CLI surface (M12):** every documented subcommand exists; missing args exit 64; unknown subcommand exits 64.
13. **Preconditions (M13):** `preflight` reports wrong-branch / dirty / ok; landing skill refuses off master/main.
14. **Lock (M14):** double `acquire-lock` fails; `release-lock` clears; re-acquire succeeds.
15. **Status transitions (M15):** legal transitions succeed; reverse/illegal transitions fail; drop of non-pending fails.
16. **gitignore:** `.claude/release-train/` is listed in `.gitignore`.

## Validation

- [x] Spec reviewed and promoted to ACTIVE
- [ ] Live two-branch case (`feat/spec-020-craft-loop` + `feat/spec-021-skill-lint`, or successors) lands via the train with zero hand-resolved conflicts in the four enumerated classes
- [ ] A deliberately conflicting third branch blocks cleanly: master never observed half-merged, queue state resumable
- [ ] `--dry-run` output reviewed by the user before the first real train run
- [x] SPEC-010 carries a forward-reference to this spec (skip-if-present + cross-ref, CDV-181)
- [ ] Backlog item `.claude/backlog/release-train-queue.md` closed via `/backlog close` once shipped

## Locked for v1

| ID | Decision |
|----|----------|
| L1 | Manual registration only (no auto-scan of `feat/*`) |
| L2 | Mid-train block → stop; no skip-and-recompute in v1; user restarts after resolve |
| L3 | Closed conflict set a–d only; anything else → blocked |
| L4 | No combined multi-branch single release |
| L5 | CHANGELOG Option A: `/release` skip-if-present when explicit version and heading+body exist (train M5c pre-writes) |
| L6 | `/release` = agent protocol only; train skill orchestrates; train-lib = mechanical only (no git tag/push/commit) |
| L7 | Deferred: per-entry test/doctor battery before landing — `/release` gates are the v1 bar |
| L8 | Deferred: README command-index auto-union — only after evidence of recurring conflicts |

## Version History

| Date | Change |
|------|--------|
| 2026-07-03 | Initial DRAFT — ideation wave 2 |
| 2026-07-13 | CDV-181: lock v1 OQs; M12–M15 CLI/precond/lock/status; CHANGELOG skip-if-present contract; implement train-lib + skill + command; status DRAFT→ACTIVE |
| 2026-07-22 | CDT-54 / CDT-46-C8: cross-ref only — SPEC-010 Step 4.7 dual-copy hook-template gate retired/reduced (no train behavior change) |

**Covers**: `commands/release-train.md` (user entrypoint: register/list/drop/start/dry-run/status), `skills/release-train/SKILL.md` (train protocol: ordering, slot assignment, landing loop), `skills/release-train/train-lib.sh` (subprocess CLI: queue.json state ops + mechanical M5a–d pre-resolvers), `skills/release/SKILL.md` (Step 2–3a skip-if-present only; consumed per entry), `.gitignore` (`.claude/release-train/`).

## Cross-references

- **SPEC-010** — Code Review & Release: owns single-release mechanics (`skills/release/SKILL.md`); the train invokes `/release` per entry with an explicit version and reimplements none of it; skip-if-present enables train M5c pre-write.
- **SPEC-016** — Worktree Isolation: serialized-`git worktree`-operations rule inherited (M11); worktree creation/teardown stays with `worktree-lib.sh` / `/wrap-ticket`.
- **SPEC-008** — Spec Management: owns `specs/TDD.md` format and semantics; the train only mechanically union-appends rows the branches authored (M5a/M5b).
- **SPEC-002** — Plugin Infrastructure: version-triplet rule and version format conventions; final triplet verification stays in `/release` Step 4.
- **SPEC-009** — Ticket Workflow: post-landing branch cleanup flows (`/wrap-ticket`) that the train suggests but never performs.
- **SPEC-021** — Skill-Bash Lint Gate: all fenced bash in train skill/command must pass skill-lint.
- **Backlog**: `.claude/backlog/release-train-queue.md` — the banked item this spec formalizes (live case: `feat/spec-020-craft-loop` + `feat/spec-021-skill-lint` racing the next feature minor).
