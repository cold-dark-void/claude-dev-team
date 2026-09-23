# Slice 05 — autopilot + epic review

Reviewer scope: 18 files from `slices/05-autopilot-epic.txt`, all read in full (11,291 lines).
Evidence runs (read-only, in throwaway temp repos only):
- `bash skills/autopilot/test.sh` → `PASS=311 FAIL=0`
- `bash skills/epic/test.sh` → `PASS=745 FAIL=0`
- `bash -n` on all 9 slice `.sh` files → clean. `shellcheck` is not installed.
- `bash skills/skill-lint/check-skill-bash.sh` and `check-docs-drift.sh` → nothing flagged for slice files.
- Custom repro scripts for findings F1, F5, F6 and F8 (outputs quoted below).

## Slice summary

- **What it does:** `skills/autopilot` is the one working copy of the SPEC-033 autopilot policy. It has three parts:
  - Procedure prose: the self-answer engine, the ship-gate council, and the land end-state.
  - Six bash CLIs: flag parsing, budget/BC6 checks, LOC exclusion, the decision-card writer and reader, and resume lookup.
  - A QA fixture document.

  `/epic` (command + skill + `epic-lib.sh` + its own `parse-flags.sh`) breaks an umbrella epic into child tickets with a DAG. It stores state under `.claude/epics/<ID>/state.json` (flock + tmp/mv), walks ready children via `/kickoff` or `/orchestrate`, and can optionally run one integration worktree plus an end-of-epic seal (`/release` once).
- **Overall grade: C.** The bash layer is careful: strict validation, path-traversal guards, atomic writes, a concurrency test, and 1,056 passing assertions. But there are real safety and portability defects, and the prose layer has drifted.
- **Biggest risk (P0):** `epic-lib.sh seal` wipes the user's **untracked files** in the main checkout (including `.claude/` when it is not gitignored) whenever the squash-stage fails or the hook fails. The dirty-tree precheck ignores untracked files, and `_seal_reset_main` runs `git clean -fd`. Reproduced.
- **Portability (P1):** `epic-lib.sh` needs `flock` (not on stock macOS) for every state mutation, and `declare -A` (bash ≥4) for `waves`. So `/epic` does not work on a default macOS setup, and neither requirement is documented.
- **Contract drift (P1):** `commands/epic.md` says `--autopilot` is "Unused by /epic … Independent of --worktree/--release". But `skills/epic/SKILL.md` Step 0.5, SPEC-033 M11a/CDT-196 and AGENTS.md all say a patch/minor/major token is **seal-intent** that sets `release_bump` and turns on the worktree. The autopilot SKILL M5 table still says "/epic never ships (no worktrees)".
- **LLM cost:** `skills/epic/SKILL.md` is about 80 KB (~20k tokens), and 24 copies of the ~870-byte PDH stanza make up about 26% of it. The autopilot procedure set (SKILL + self-answer + ship-gate + end-state) is about 25k tokens. The prose is dense with ticket IDs (56 `CDT-` references in the epic SKILL) and spec clause codes (M14(a), N13, AC9…).
- **Tests:** both suites pass, but neither runs in CI (`.github/workflows/smoke.yml`). A large share of the assertions just grep for exact prose phrases, which is brittle and does not check behavior. None of the destructive git paths (end-state squash, seal with untracked files, a seal that has to switch branches) are tested for user-data safety.
- **Stale / inconsistent pieces:**
  - The scenarios doc still reports gaps that were fixed long ago as open.
  - Several stale line-number citations.
  - Tests whose labels no longer match what they actually test (argc 14 became a legal argument count).
  - An undefined "shared C4 Decision→action map".

## Per-file review

| File | Lines | Purpose (short) | Verdict | Findings (concise, with line numbers) |
|---|---|---|---|---|
| commands/epic.md | 96 | `/epic` slash-command entrypoint and router | Issue | L36 `--autopilot` row says "Unused by /epic … Independent of --worktree/--release", which contradicts SKILL L209-213/L242-247, SPEC-033 M11a and AGENTS.md (seal-intent) (F3). L35 "Orthogonal to `--autopilot`" is the same contradiction. The description (L3-11) leaves out `--autopilot`, though argument-hint has it. L18 shows a cwd-relative `bash skills/epic/epic-lib.sh`. Frontmatter OK. |
| docs/commands/epic.md | 97 | User docs for `/epic` | Minor | Flags table (L33-42) is missing `--autopilot` and `--no-context-discipline` rows. The Usage block has no autopilot form. L67 heading "Mid-epic forbid (release=end)" uses `end`, a token that is itself rejected (L46). No frontmatter, which is correct for docs. |
| skills/autopilot/SKILL.md | 535 | SPEC-033 contract home: gates, BC1-8, budget, M10, M13 card schema | Issue | L147 "/epic never ships (M11: … no worktrees)" is stale against the M14 carve-out and seal (F3). L9-10/L18 "when wired (later CDT-111 children)" and L403 "ship … in CDT-111-C2" are stale future tense. L325-327: M10.1 is "evaluated at … plan-approve", but at plan-approve BC4 (same threshold, ordered earlier) always fires first, so M10.1 can never be reached there (F11). L535 relies on PIPE_BUF atomicity (F14). About 8.4k tokens. Frontmatter OK. |
| skills/autopilot/append-card.sh | 343 | M13 decision-card JSONL writer (hard-fail 64) | Issue | L131-134/L166: an overflowing integer `confidence` (e.g. 99999999999999999999999) skips both the 0..100 range check and the BC7 `<80` invariant. `[` errors (rc 2) inside an `&&` list, so `set -e` does not trip. The card is written with an absurd confidence and bc=7 (F6, reproduced). The same class applies to `iteration` and `wall_clock_s`. L260-261: env caps are not validated, so junk makes jq fail and the error reads "cannot write decision card" (misleading). L283-285: PIPE_BUF comment (F14). |
| skills/autopilot/budget-check.sh | 184 | BC6 budget check + M9b `derive` | OK | Clean validation. Huge integers hit the same `[`-overflow class as F6 (low impact: only the orchestrator builds these inputs). |
| skills/autopilot/end-state.md | 330 | Autopilot land procedure (release vs land-no-release) | Issue | §4 L146-155: `git reset --hard` on the main repo after a squash conflict, with no clean-tree precheck, loses the user's uncommitted tracked edits (F2). §3 L101-111: BC3 ancestry check uses a stale `origin/*` ref (no `git fetch`), so a non-fast-forward push is only found after the local commit on the baseline (F12). L83/L154/L249/L256: `return` in top-level fences; bash prints an error and **continues** (F7, reproduced). L315-319 cite "§5a/§5b", but the sections are named "5-release"/"5-land-no-release". L190-191 cites `release/SKILL.md lines 11–19` (brittle). |
| skills/autopilot/loc-exclude.sh | 77 | M15 counted-LOC exclusion helper | OK | Matches the SPEC-033 M15 list exactly. Fails open. `git check-attr` resolves the path relative to cwd, so callers must run it from the repo root (undocumented, minor). |
| skills/autopilot/parse-flags.sh | 254 | Parses `--autopilot/--council-tier/--tier/--max-loc` into 6-key JSON | Minor | Repeat semantics differ per flag and are only partly documented. `--autopilot=patch --autopilot` keeps `patch` (L113-120). `--max-loc=5 --max-loc` → 64 (L148-150). `--autopilot=patch --autopilot=minor` silently takes the last one (not documented; `--tier` rejects duplicates). |
| skills/autopilot/read-cards.sh | 142 | Ledger reader with null backfill + invariant (c) recheck | OK | Correct backfill order, traversal guard, and empty-ledger `[]`. The header comment L20-21 does not mention the `max_loc`/`budget` backfills (they are covered at L29-37). |
| skills/autopilot/resume-state.sh | 150 | Plan Tracking lookup + accumulated wall-clock | Issue | L112 glob `*-<ID>-*.md` is prefix-ambiguous: `resume-state.sh CDV-30` returns the child plan `…-CDV-30-C1-api.md` along with its `autopilot_on/bump` (F5, reproduced). L129-130 grep the whole file, not just the `## Tracking` section. L83 comment "(copied from read-cards.sh:47-54)" has stale line numbers. It reads `$MROOT/.claude/plans`, while kickoff writes plans under `<WT_PATH>/.claude/plans` (unverified mismatch, F15). |
| skills/autopilot/self-answer-scenarios.md | 709 | QA acceptance fixtures for the self-answer engine | Minor | Only the tests and SPEC-033 reference it (not loaded at runtime). FE L548-563 and "Gaps found" 1-3 (L664-696) are stale. The exit-64 branch now exists (self-answer.md L159-169) and "merge⇒bump engine-only" is already annotated (L282-288). Gap 3 cites `self-answer.md:147/149-168`, which no longer matches. L696 says "all 12 fixtures", L700 says 13. F12 fixture (L500-518) merges into a "NON-protected integration branch", but end-state §3 halts BC3 on any target other than the default, so the fixture cannot happen end to end. Contains process notes ("Recommend Tech Lead (Task 4)"). About 11.8k tokens. |
| skills/autopilot/self-answer.md | 357 | Gate self-answer engine procedure | Minor | L6, L89 ("T4 owns…"), L311 ("wiring … is C4") are stale ticket-phase references. L159-163 calls exit 64 "never external input", but the argc=2 path reads user env caps, so junk env is external input. |
| skills/autopilot/ship-gate-council.md | 364 | M14 ship-gate council pass + card #2 | Minor | L262 cites `append-card.sh:140`; the invariant is at L166. §2a L69-71: "fresh halt card if card #1 is unreadable" does not say which `run_id` to use. The two ship-choice cards cannot be told apart in the writer (acknowledged, L319-327). |
| skills/autopilot/test.sh | 2233 | Bite tests for all autopilot CLIs + prose greps | Minor | Passes 311/0. Labels are stale: c3 L173 "argc=14 (one over) → 64" and ao1 L628 "argc=14 (tier without reason)" now pass only because `extra`/`light` are invalid `max_loc` values (argc 14 is legal). Header L22 says "5-key JSON" (now 6). `process_stamps_ok` L70-92 tests a predicate defined in the test itself, so §2a coverage is circular. Many assertions are exact-phrase greps of prose. The ORCH SKILL ≤80-lines check (L1575) belongs to another subsystem. No tests for end-state, the resume-state prefix collision, or numeric overflow. Not in CI (F10). |
| skills/epic/SKILL.md | 1277 | Full `/epic` protocol (Modes A-F, M13, M14 seal) | Issue | 24 PDH copies (about 21 KB) plus two duplicated model/effort resolver blocks (L262-320), about 20k tokens (E1). L393/L402/L718 reference a "shared C4 Decision→action map" that is defined nowhere (F9). L402-403: A.5 `reroute-epic` → "hand to `/epic` decompose" loops back into itself. L881/L885: `return` in top-level fences (F7). L1009-1011 and L1240 recommend `seal --abort --force` (= `git clean -fd`) as routine recovery (F1). L48 `--worktree` row leaves out `sync` from the illegal list (L137 has it). L122/L125/L222 pass `"$@"`, which is empty in the Bash tool, so an LLM has to substitute real argv (unclear instruction). B.7 fences L956-993 have broken list indentation. L399-401: autopilot halt "zero disk side effects" even though a card is written. Frontmatter OK, but the description leaves out `--autopilot`/`--no-context-discipline`. |
| skills/epic/epic-lib.sh | 1987 | Epic state CLI: init, children, ready-set, worktree, seal, seed, sync | Major | L982 + L1147-1150: squash/hook failure runs `git clean -fd` after a dirty check that ignores untracked files → **user untracked files deleted** (F1, P0, reproduced). L253 etc.: `flock` is required with no fallback (F4). L1410-1412: `declare -A` is bash ≥4 (F4). `status_of` is unused. L515-519: `die "${erc:-1}"` with erc=0 and empty path → **exit 0** after printing an error (F8, reproduced). L878-888: default branch hard-coded "master preferred, else main", ignoring `origin/HEAD` (F13). L1141-1146: silently `git checkout`s the user's main checkout onto master **before** the dirty check (F13). L1178: `eval "$EPIC_SEAL_RELEASE_HOOK"` is an env-controlled eval (test-only; P3). L1863-1876: sync-apply also applies backward moves (in_progress→pending), though SKILL/docs say "pull status forward" (P3). |
| skills/epic/parse-flags.sh | 156 | M14 `--worktree`/`--release` parser | OK | Correct and well tested. Behavior note: the space form `--release <x>` takes the next non-dash token, so the epic text can be swallowed as a bump (still exits 64, safe). |
| skills/epic/test.sh | 2000 | Bite tests for epic-lib + parse-flags + prose greps | Minor | Passes 745/0. `run_lib/run_in` flip `set -e` on globally (L30-33) in a script that starts with only `set -u`. C5 fixtures gitignore `.claude/epics/` and `.worktrees/` (L1207-1208) and never put an untracked user file in main during a squash conflict, which hides F1. No coverage for F8 (ensure rc=0/empty path), seal from a non-default branch, or bash 3.2/no-flock environments. Many exact-phrase doc greps (L429-577, L1494-1588). The trap only covers TMPROOT/C2_TMP; other temp dirs leak on early abort. Not in CI (F10). |

## Findings

1. **[P0] Seal failure path deletes the user's untracked files (and possibly `.claude/` state).**
   `skills/epic/epic-lib.sh:1147-1150` checks cleanliness with `git diff --quiet` / `--cached --quiet`, which ignores untracked files. Then on squash or hook failure, `_seal_reset_main` (L979-983) runs `git reset --hard` **and `git clean -fd`**. SKILL B.7 (L1009-1011, L1240) and the handoff JSON `on_failure` (L1239) also make `seal --abort --force` the routine recovery, and that also runs `clean -fd`.
   Evidence (temp repo, master and `feat/epic-E1` conflicting on `f`, untracked `user-notes.txt`, `.claude/` not ignored):
   ```
   ?? .claude/
   ?? user-notes.txt
   error: seal: squash conflict/fail for feat/epic-E1 — master restored (rc=1): ...
   rc=1
   f            # <- user-notes.txt AND .claude/ (epic state.json) gone
   ```
   Fix: gate the live seal on `git status --porcelain` being empty (untracked included), the same check `_seal_main_is_dirty` already does for abort. Remove `git clean -fd` from `_seal_reset_main` (after `merge --squash`, `reset --hard` alone restores the tree; merge --squash creates no untracked files except in rename/delete conflicts, and those can be cleaned by path). Stop recommending `--force` as routine recovery in SKILL B.7 and in `on_failure`. Add a test with an untracked user file present during a squash conflict.

2. **[P1] Autopilot end-state can lose uncommitted tracked edits in the main checkout.**
   `skills/autopilot/end-state.md:144-155` runs `git merge --squash <branch>` in `<main-repo-path>`, and on conflict runs `git reset --hard`. §6.5 L298 and L304 also `reset --hard`. There is no clean-tree precheck before §4 (§3 and §3.5 check only the branch and ancestry).
   Fix: add a mandatory `[ -z "$(git -C <main-repo-path> status --porcelain)" ] || { halt card BC3; exit 1; }` before §4. Treat a dirty main as BC3 (it would overwrite user data).

3. **[P1] The `--autopilot` contract for `/epic` contradicts itself across files.**
   `commands/epic.md:36`: "Unused by `/epic` (never ships) but resolved+carried for seed parity … Independent of `--worktree`/`--release`." L35: "Orthogonal to `--autopilot`."
   On the other side, `skills/epic/SKILL.md:209-213` says it "**is** seal-intent when ∈ {patch,minor,major}: persist `release_bump` + enable worktree (BC5 / CDT-196). Do **not** treat the token as unused." SKILL L242-247 and AGENTS.md ("Token is not unused") agree with the skill. `skills/autopilot/SKILL.md:147` (mirrors SPEC-033 L173) still says "/epic never ships (M11: no code, no worktrees…)".
   The LLM reads `commands/epic.md` first, so it can land children on master, which is the AGENTS.md "Never FF-merge epic children" failure.
   Fix: rewrite the commands/epic.md L35-36 rows to say "patch|minor|major token ⇒ seal-intent (sets `release_bump` + worktree, CDT-196); `master` ⇒ no seal". Update the autopilot SKILL and SPEC-033 M5 table cell to "ships only via B.7 seal (M14)". Add a test that greps commands/epic.md for "Independent of" in the autopilot row and fails if found.

4. **[P1] `/epic` state CLI does not work on stock macOS (flock + bash 4).**
   `epic-lib.sh` calls `flock -x 9` in every mutator (L253, 329, 393, 430, 462, 534, 1066, 1191, 1265, 1661, 1767) with no `command -v flock` fallback. `flock` is util-linux and is not on macOS. `cmd_waves` uses `declare -A` (L1410-1412), which macOS `/bin/bash` 3.2 rejects. `show`, `rollup` and `build-seed` swallow the `waves` failure with `|| true`, but `bash epic-lib.sh waves` (SKILL B.1 L646) hard-fails. Neither dependency is in docs/setup.md, the README or SPEC-025 prerequisites (`grep -i flock docs README.md` → none).
   Fix: add a `mkdir`-based lock fallback (as other repo scripts do) or an explicit `command -v flock || die 1 "flock required (brew install util-linux / flock)"`. Rewrite `waves` in jq (Kahn levels are easy in jq) and drop the associative arrays. Document the prerequisites.

5. **[P2] `resume-state.sh` picks up a child's plan for the parent ticket (prefix glob).**
   `skills/autopilot/resume-state.sh:112` uses `MATCHES=("$PLANS_DIR"/*-"$ISSUE_ID"-*.md)`. Evidence:
   ```
   plan: .claude/plans/2026-09-01-CDV-30-C1-api.md
   $ resume-state.sh CDV-30
   {"found":true,"plan":".../2026-09-01-CDV-30-C1-api.md","autopilot_on":true,"autopilot_bump":"minor"}
   ```
   Epic children are named `<EPIC>-C<n>`, so resuming `/orchestrate <EPIC>` can inherit a child's `autopilot_on`/`bump` (ship intent).
   Fix: parse `ticket_id:` from the plan's `## Tracking` section and require an exact match, or match `^[0-9]{4}-[0-9]{2}-[0-9]{2}-<ID>-[a-z0-9]` with a slug that does not start with `C[0-9]+-`. Also limit the `autopilot_*` greps to the Tracking section. Add a regression test.

6. **[P2] `append-card.sh` numeric guards can be bypassed by integer overflow (BC7 invariant broken).**
   L131-134 and L166 use `[ "$CONFIDENCE" -gt 100 ] && die …`. Evidence:
   ```
   append-card.sh orchestrate T1 scope-confirm halt auto null 99999999999999999999999 7 r1 1 0 orch x
   line 134: [: 99999999999999999999999: integer expression expected
   line 166: [: 99999999999999999999999: integer expression expected
   exit=0   → card has "confidence":99999999999999999999999,"blocking_condition":7
   ```
   The writer promises hard-fail on every bad argument, so this breaks its own contract.
   Fix: cap the length (`[ ${#CONFIDENCE} -le 3 ]`) or use `case` patterns `[0-9]|[1-9][0-9]|100`. Apply the same to `blocking_condition`, `iteration` and `wall_clock_s` (and to budget-check.sh). Validate `AUTOPILOT_*_CAP` env (L260-261) with a clear error.

7. **[P2] `return` in top-level bash fences does not stop execution.**
   `end-state.md:83,154,249,256` and `skills/epic/SKILL.md:881,885`. Evidence:
   ```
   bash -c 'X=""; [ -n "$X" ] || { echo unset; return 1; }; echo "CONTINUED past return"'
   unset
   bash: line 1: return: can only `return' from a function or sourced script
   CONTINUED past return      rc=0
   ```
   For example, end-state L247-251 would go on to run `check-ship-history --since "<SHIP_START_SHA>"`, and B.6 would run `validate-seed ""` after a build-seed failure. Each fence runs as a fresh Bash-tool shell.
   Fix: use `exit 1` (or `exit 0` where "stop quietly" is meant). Add a skill-lint rule that flags top-level `return`.

8. **[P2] `ensure-integration-worktree` exits 0 on failure.**
   `epic-lib.sh:515-519` runs `die "${erc:-1}" …`. When worktree-lib exits 0 with empty stdout, erc=0, so `die 0` exits successfully. Evidence (mock lib that exits 0 with no output): `error: … worktree-lib ensure failed for epic-E2 (rc=0)` then `rc=0`. The same pattern appears in `ensure-ticket-worktree` L752 (`exit "${erc:-1}"`).
   Fix: `local rc=$erc; [ "$rc" -eq 0 ] && rc=1; die "$rc" …`. Add a test.

9. **[P2] The epic SKILL references a "shared C4 Decision→action map" that does not exist, and the A.5 reroute is self-recursive.**
   `skills/epic/SKILL.md:393,402,718`. `grep -rn 'Decision→action map' skills commands specs` finds only these three references. At A.5 (already inside `/epic` decompose), "`reroute-epic` → … then hand to `/epic` decompose" loops back into itself.
   Fix: define the map inline (proceed / halt / reroute-epic), and state that inside `/epic` A.5 a BC5 result maps to halt (or to "soft-warn >8 children") rather than a reroute. At B.3, spell out that a nested epic for a child is allowed or forbidden.

10. **[P2] Neither slice test suite runs in CI.**
    `.github/workflows/smoke.yml` runs retro-gate, release, memory-store, wrap-ticket, plugin-dir and agent-memory tests, but not `skills/autopilot/test.sh` or `skills/epic/test.sh`. `tools/smoke/run.sh` does not reference them either. SPEC-009 L403 and SPEC-025 done-when rely on them.
    Fix: add two jobs (both take a few seconds and need only jq, git and python3).

11. **[P2] M10.1 overflow is unreachable at plan-approve.**
    `skills/autopilot/SKILL.md:325-327` says M10.1 is "Evaluated at `scope-confirm` and `plan-approve`". BC4 per-PR uses the same threshold and comes earlier in BC order, and it only fires at plan-approve (L207-211). So a counted-LOC overflow at plan-approve always **halts** (BC4) and never **reroutes** (BC5). Scenario F4-n-tight (self-answer-scenarios.md L193-195) confirms this: "M10.1 would also match but BC4 precedes BC5."
    Fix (in SPEC-033 first, since the SKILL only carries it): either drop "and plan-approve" from M10.1, or order an overflow-reroute check before BC4 at plan-approve. Document the intended behavior.

12. **[P2] The end-state BC3 ancestry check uses stale remote refs.**
    `end-state.md:101-111` runs `merge-base --is-ancestor "origin/$DEFAULT_BRANCH" …` with no fetch. If origin has moved, the check passes, §5 commits on the local baseline, the non-force push is rejected, and the local master is left ahead with an unpushed commit (halt-for-human, L228-229).
    Fix: `git fetch origin "$DEFAULT_BRANCH"` (fail-closed → BC3) before the check.

13. **[P2] `seal` hard-codes the default branch and silently switches the user's main checkout.**
    `epic-lib.sh:878-888` means "master preferred, else main", ignoring `origin/HEAD` (end-state/N3a uses `origin/HEAD`). L1141-1146: when main is on another branch, it runs `git checkout -q "$default"` **before** the dirty check (L1147), so a failed seal leaves the user on a different branch.
    Fix: resolve the default via `git symbolic-ref refs/remotes/origin/HEAD` (fall back to master/main), run the dirty check first, and refuse rather than checkout when HEAD ≠ default.

14. **[P3] The PIPE_BUF atomicity claim does not apply.**
    `append-card.sh:283-285` and SKILL L535. PIPE_BUF guarantees atomicity for pipes, not regular-file `O_APPEND` writes. `rationale` has no length cap, so a card can be well over 4 KB, and jq may issue more than one write(). Concurrent same-ticket writers are rare.
    Fix: cap `rationale` and `grading_reason` (e.g. 1,000 chars) and reword the comment, or build the line in a variable and use a single `printf >>`.

15. **[P3] (unverified) The plan directory may differ between writer and `resume-state.sh`.**
    `skills/kickoff/SKILL.md:674` saves plans to `<WT_PATH>/.claude/plans/…` (worktree), while `resume-state.sh:108` reads `$MROOT/.claude/plans` (main-repo root via git-common-dir). If orchestrate also writes into the worktree, Step-0 resume would never find the plan. Confirm against `skills/orchestrate/steps/04-kickoff.md` and `06-design.md`.

16. **[P3] Stale references and labels in the slice.**
    - self-answer-scenarios.md FE / Gaps 1-3 (L548-563, L664-696) report fixed gaps as open.
    - ship-gate-council.md L262 cites `append-card.sh:140` (actual L166).
    - end-state.md L315-319 cite `§5a/§5b`.
    - resume-state.sh L83 cites `read-cards.sh:47-54`.
    - autopilot SKILL L9-10/L18/L403 and self-answer.md L6/L89/L311 use future-tense "C4/T4/later children".
    - autopilot test.sh c3 (L173) and ao1 (L628) labels are wrong (both pass for a different reason), and header L22 says "5-key".

    Fix: sweep and correct all of these, and make the c3/ao1 tests assert the stderr reason (`invalid max_loc`).

17. **[P3] Docs are missing flags.**
    `docs/commands/epic.md` has no `--autopilot` or `--no-context-discipline` rows. The `commands/epic.md` and `skills/epic/SKILL.md` descriptions leave out `--autopilot`. The SKILL L48 `--worktree` illegal list leaves out `sync`.
    Fix: add the rows and sync the descriptions (docs-drift could check the argument-hint against the flags table).

18. **[P3] `sync-apply` applies backward status moves.**
    `epic-lib.sh:1863-1876` only protects `completed`. in_progress→pending and blocked→pending are applied, but SKILL L1143 and docs L78 say "pull status forward".
    Fix: either document "any non-completed change is applied" or add an ordering (pending < in_progress < blocked? / completed) and skip regressions.

19. **[P3] Other items.**
    - `eval "$EPIC_SEAL_RELEASE_HOOK"` (epic-lib L1178) is an env-driven eval in production code. Gate it on `EPIC_TEST_MODE=1`.
    - `status_of` in `cmd_waves` is dead code.
    - epic test.sh `run_in` leaves `set -e` on globally.
    - A.5 autopilot halt claims "zero disk side effects" while it writes a decision card (say "except the audit card").

## Enhancement proposals

1. **Deduplicate the PDH stanza in `skills/epic/SKILL.md`** (24 copies, about 21 KB, about 5k tokens). Resolve `EPIC_LIB` once in Step 0 and have later fences say `EPIC_LIB=<from Step 0>` (the session already carries run state such as `RUN_ID`). If skill-lint C1 truly needs per-fence resolution, keep only the one-line `EPIC_LIB=$(bash "$PDH/…")` and use a two-line compact PDH helper. Effort M, impact high (about 25% of the epic skill's tokens).
2. **Split `skills/epic/SKILL.md` into a router plus per-mode step files**, the way `/orchestrate` does (`steps/*.md`, with the router ≤80 lines enforced by a test). Load Mode A only when decomposing, B.7 only at seal, and F only for sync. Effort M, impact high (a typical resume would load about 5k tokens instead of 20k).
3. **Move the ticket archaeology out of the LLM-facing prose.** Remove inline `CDT-xxx` provenance and most clause codes (M14(a), N13, AC9…) from the SKILL/procedure bodies, keep them in SPEC changelogs, and keep one short "Contract refs" line per section. Effort M, impact medium-high (clarity plus tokens).
4. **Merge `self-answer.md`, `ship-gate-council.md` and `end-state.md` into one "ship pipeline" procedure** with a single boundary list (the three §1/§7 "does NOT do" sections overlap heavily). Effort M, impact medium (about 4-5k tokens saved; one place to change).
5. **Retire or trim `self-answer-scenarios.md`** into a table-driven fixture file (TSV or JSON) that `test.sh` runs against `append-card.sh`/`budget-check.sh`, instead of 700 lines of prose plus phrase greps. Effort M, impact medium (removes stale "Gaps found" prose and makes fixtures run).
6. **Add git-safety tests** for the end-state squash, seal with untracked and dirty files, seal from a non-default branch, and `ensure-*` with rc=0/empty output. Effort S, impact high (these cover P0-P2 regressions).
7. **Add a portability CI matrix**: run both suites on `macos-latest` (bash 3.2, no flock) or in a `bash:3.2` container. Effort S, impact high.
8. **Replace the prose-phrase greps with structural checks** where possible. For example, check that the SKILL fences reference existing epic-lib subcommands by diffing the fence commands against the `case "$SUBCMD"` list, rather than grepping for exact English sentences. Effort M, impact medium (less brittle; catches real drift like F9).
9. **Make one resolver for a "ticket → plan file"** (exact `ticket_id` from Tracking) and reuse it in resume-state, kickoff and orchestrate. Effort S, impact medium (fixes F5 and F15 together).
10. **Add an `epic-lib doctor`** subcommand that checks jq, flock, bash ≥4, git, and the worktree-lib path, and have `/epic` Step 0 call it once, with a clear message on failure. Effort S, impact medium (turns silent macOS failures into a clear error).

## Coverage attestation

- Files in the slice list (`slices/05-autopilot-epic.txt`): **18**
- Rows in the Per-file review table: **18**
- All 18 files were read in full, including `skills/epic/SKILL.md` (1,277 lines), `skills/epic/epic-lib.sh` (1,987 lines), `skills/epic/test.sh` (2,000 lines) and `skills/autopilot/test.sh` (2,233 lines). The counts match.
