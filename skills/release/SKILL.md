---
name: release
description: |
    Bump version across the required pair (CHANGELOG.md, plugin.json), commit,
    tag, and push. Use when releasing any version of this plugin. Ensures the
    two version surfaces stay in sync — never skips either. marketplace.json is
    not versioned (git-ref install channels).
---

# Release

Bumps the version in the required pair, then folds the release into a SINGLE
commit (the actual change + the version bump together), tags, and pushes.

This repo uses **one commit per release**: the work being released is usually
still uncommitted in the working tree when `/release` runs (HEAD sits on the last
tag). So this skill stages the changed source files *and* the version files into
one `fix:/feat: vX.Y.Z — <summary>` commit. It does NOT assume the work was
committed separately, and it does NOT create a standalone `chore: release` commit.

**Usage**: `/release [patch|minor|major|vX.Y.Z]`

## Step 0: Epic release=end precheck (CDT-141-C4)

**Before any version-file edit, commit, tag, or push**, hard-fail mid-epic
`/release` when durable epic state has `release_bump` set and seal is not done.

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)

# Resolve ticket-or-epic (first non-empty wins):
# 1) explicit ticket from session / orchestrate ISSUE-ID
# 2) EPIC_RELEASE_END env (B.4 handoff sets epic id when release_bump set)
# 3) EPIC_ID env
# 4) branch: feat/epic-<ID> or feat/<CHILD-ID>
# 5) cwd under .worktrees/epic-<ID> or .worktrees/<CHILD>
REF="${RELEASE_TICKET:-}"
[ -n "$REF" ] || REF="${EPIC_RELEASE_END:-}"
[ -n "$REF" ] || REF="${EPIC_ID:-}"
if [ -z "$REF" ]; then
  BR=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  case "$BR" in
    feat/epic-*) REF="${BR#feat/epic-}" ;;
    feat/*)      REF="${BR#feat/}" ;;
  esac
fi
if [ -z "$REF" ]; then
  WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  base=$(basename "$WTROOT")
  case "$base" in
    epic-*) REF="${base#epic-}" ;;
    *)      REF="$base" ;;
  esac
fi

if [ -n "$REF" ] && [ "$REF" != "master" ] && [ "$REF" != "main" ] && [ "$REF" != "HEAD" ]; then
  bash "$EPIC_LIB" assert-release-allowed "$REF" || {
    # exit 64 — user-visible: "epic <ID> is in release=end mode until seal (CDT-141)"
    # HALT: zero version bump, tag, push, or version-file change
    exit 64
  }
  # SPEC-025 M16 / CDT-158: warn-only incomplete-child gap callout (not a gate).
  # Print stdout as-is; empty when all-complete / last remaining / unknown.
  # MUST NOT mix into the C4 64 message above. Continue regardless of incomplete.
  bash "$EPIC_LIB" gap-callout "$REF"
fi
```

- **Halt** on exit 64: print the helper's stderr as-is; do **not** edit
  `CHANGELOG.md` / `plugin.json`, do not commit/tag/push.
- **Allow** when: no epic context; epic has `release_bump` null/absent; or
  `sealed=true` (post-C5). C5 seal path may set `EPIC_ALLOW_SEAL_RELEASE=1`.
- **Callout** (M16): after assert rc 0, print `gap-callout` stdout as-is
  (warn-only; incomplete children do not halt). Empty when all-complete / last
  remaining child / unknown. Not a SPEC-033 gate. Do **not** mix into C4's 64
  message. Land-no-release (`bump=master`) is out of scope for this callout.
- Guard reads **durable** `$MROOT/.claude/epics/<ID>/state.json` only — holds
  across resume sessions while mode is active.

Then continue to Step 0.5.

## Step 0.5: Record ship-start SHA (SPEC-010 H6)

**Before any version-file edit, commit, tag, or push**, open ship window W:

```bash
# Ambient SHIP_START_SHA from end-state / train / orchestrate wins when set
# (caller already opened W). Else record HEAD tip now (before any commit).
if [ -n "${SHIP_START_SHA:-}" ]; then
  SHIP_START=$(git rev-parse --verify "$SHIP_START_SHA^{commit}" 2>/dev/null) || {
    echo "release: unresolvable ambient SHIP_START_SHA=$SHIP_START_SHA" >&2
    exit 64
  }
else
  SHIP_START=$(git rev-parse HEAD)
fi
export SHIP_START
# Carry into later fences (agent session state) — each bash fence re-reads env
# or re-derives; do not hardcode a SHA into the skill text.
```

- `SHIP_START` is the sole `--since` value for `check-ship-history.sh` in this
  `/release` (SPEC-010 H1–H12 — cite, do not restate D1–D4).
- Do **not** re-record after the fold commit (that would empty W).

Then continue to Step 0.6.

## Step 0.6: Install master bump-class hook

This repo ships `githooks/pre-commit` so `git commit` on `master` cannot land a
new `commands/*.md` on a patch bump (the 1.7.37 class). Install if present:

```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
INSTALL_HOOKS=$(bash "$PDH/skills/plugin-dir.sh" file skills/release/install-git-hooks.sh)
if [ -f githooks/pre-commit ] && [ -f "$INSTALL_HOOKS" ]; then
  bash "$INSTALL_HOOKS" || exit 1
fi
```

Feature branches are not gated (no version bump until `/release` on master).

Then continue to Step 1.

## Step 1: Determine new version

Read `.claude-plugin/plugin.json` to get the current `"version"` field.

Resolve the new version using these rules (first match wins):

1. **Explicit version in args** (e.g. `v0.14.0` or `0.14.0`) → use it directly
2. **Bump keyword in args** (`patch`, `minor`, or `major`) → compute from current version
3. **No args provided** → auto-detect from everything being released — BOTH
   commits since the last tag AND the current uncommitted changes:
   - `git log $(git describe --tags --abbrev=0)..HEAD --oneline` — committed since tag
   - `git status --short` and `git diff --stat HEAD` — uncommitted work (usually the bulk)
   - If the release adds a new user-facing capability (or any commit subject contains
     `feat:`/`feat(`) → **minor**; otherwise → **patch**
   - Tell the user what you chose and why (e.g. "Auto-detected **patch** — hardening, no new feature")

Version format: no `v` prefix in files, `v` prefix for git tag and changelog heading.

### Feature-line versioning (multi-PR arcs)

The auto-detect rule (`feat:` → minor) governs **independent** feature changes.
When a planned feature ships across several sequential releases (a multi-PR arc
tracked by a single spec), you **MAY** hold the entire arc under one minor line:

- The **first** release in the arc opens the minor (e.g. SPEC-019 PR1 → 0.37.0).
- Subsequent increments of the **same** arc take **patch** bumps via an explicit
  `/release patch`, even though they add capability. A **new** `commands/*.md`
  file is always a new Surface and **MUST** be minor or major (bump-class gate);
  feature-line patch is same-surface only.
- **Keep the `feat:` commit prefix** on those increments — the subject describes
  the change honestly; the patch bump reflects the feature-line policy, not a
  downgrade of the change to a fix. Do **not** relabel feature increments as `fix:`.
- A **new** `commands/*.md` is never a feature-line patch (bump-class gate).
  If a new Surface was already tagged as a patch: fold into the minor, delete
  the patch tag, retag, force-push. Do not leave the false patch in history.
- Because the commits are `feat:`, the no-args auto-detect would choose `minor`
  (opening a new line). To stay on the current line you **must** pass `patch`
  explicitly; passing nothing (`/release`) is also valid — it just opens a new
  minor line instead.

**Worked example** — SPEC-019 shipped entirely under the 0.37 line:
`0.37.0` (PR1 wrapper) → `0.37.1` (PR2 orchestrate integration) →
`0.37.2` (OS-leash) → `0.37.3` (/local-do), all `feat:`, all patches.

## Step 2: Generate changelog entry

**Do NOT ask the user for a description.** Auto-generate it from the actual
changes being released — which include uncommitted working-tree changes, not just
committed history:

1. Gather the full change set:
   - `git diff --stat HEAD` and `git status --short` — uncommitted work (usually the bulk)
   - `git log $(git describe --tags --abbrev=0)..HEAD --oneline --no-merges` — anything already committed since the last tag (exclude `chore: release` commits)
2. Read the actual diffs of changed files as needed to describe them accurately — do not infer from filenames alone.
3. Write the changelog as a bulleted Markdown list — one `- **bold summary** — detail` line per meaningful change, grouping granular edits.
4. Match the style of existing changelog entries in CHANGELOG.md (bold lead, concise but specific).

If there are NO uncommitted changes AND no commits since the last tag, tell the
user "Nothing to release — working tree clean and no commits since last tag" and stop.

### Skip-if-present (explicit version only)

If the resolved version came from an **explicit** version arg (Step 1 rule 1)
AND `CHANGELOG.md` already has `### vX.Y.Z` or `### X.Y.Z` (normalize: strip
optional leading `v` for compare) with ≥1 non-empty bullet/body line under it
before the next `### ` heading:

- Do NOT regenerate bullets; use the existing body as the changelog content
  for the commit-summary derivation in Step 5.
- Skip the "generate new entry" work; jump to Step 3 (which will also
  skip-if-present for 3a).

If the heading exists but body is empty → treat as missing (generate as usual).
If version was auto-detected or bump-keyword → never skip (always generate).

Used by the release train (SPEC-023): train M5c pre-writes the assigned-version
heading; `/release <assigned_version>` verifies rather than duplicates.

## Step 3: Bump the version pair

**CRITICAL — both must be updated. Never skip either.**

### 3a. `CHANGELOG.md`
If skip-if-present matched in Step 2: verify the heading exists with a non-empty
body; do **not** prepend a second section for the same version.

Else: add a new `### vX.Y.Z` section at the top of the changelog — directly under the
file's header block, above the previous version's section:
```markdown
### vX.Y.Z
- <changelog entries>
```
The changelog lives in `CHANGELOG.md`, **not** `README.md` — the README only carries a
pointer to it. Do not re-add changelog entries to the README. (The README may still change
in a release if you altered the command index or other front-page content; stage it as a
normal source file in Step 5, not as the changelog target.)

### 3b. `.claude-plugin/plugin.json`
Update `"version"` field to new version string.

### 3c. `.claude-plugin/marketplace.json` — do **not** set a version field

Install channels pin via `source.ref` (`stable` / `master`). Do **not** reintroduce
`plugins[].version`. Description sync with `plugin.json` remains a docs-drift concern
(`manifest-desc`), not a release version step.

## Step 4: Verify the version pair matches

Confirm the version string is identical in:
- `CHANGELOG.md` changelog heading (`### vX.Y.Z`)
- `.claude-plugin/plugin.json` `"version"` field

If any mismatch: fix before proceeding.

## Step 4.5: Include drift-check (pre-commit gate)

Run:
```bash
python3 skills/agent-memory/sync-includes.py check
```

If it exits non-zero, one or more managed include regions have drifted from their canonical partials (`skills/agent-memory/protocol.md` — the 7-agent `## Persistent Memory` block; `skills/agent-memory/cortex-load.md` — the debug/refactor tiered-cortex block). **Do NOT commit or tag.** Fix the drift first (re-expand the drifted region to match its partial via `python3 skills/agent-memory/sync-includes.py apply`), then re-run until it exits 0.

## Step 4.6: Council template-variable drift-check (pre-commit gate)

Run:
```bash
bash skills/council/check-template-vars.sh
```

If it exits non-zero, the council template-variable contract has drifted: `commands/council.md` substitutes a variable set that no longer matches a prompt's authoritative `## Variables` table (a dead substitution or a literal `{{VAR}}` leak into the spawned subagent, per SPEC-013). **Do NOT commit or tag.** Fix `commands/council.md` (and/or the prompt's `## Variables` table) so each covered prompt's substituted set exactly equals its declared set, then re-run until it exits 0. (Covered: claim-extractor, investigator, cross-reviewer, phase4-brief, judge. Nothing is deferred — the former prosecutor/advocate templates were merged into phase4-brief.)

## Step 4.7: Hook-template hygiene gate (pre-commit gate)

Hook bodies SoT = fenced templates in `skills/init-orchestration/SKILL.md` only
(SPEC-002/SPEC-005; CDT-54). Live `.claude/hooks/*.sh` are **generated** by
`/setup orchestration` (not package product; dual-copy retired).

Run:
```bash
bash skills/init-orchestration/check-hook-templates.sh
```

Template-internal only: each managed hook must have an extractable fenced bash
body after its "create `.claude/hooks/<name>.sh` with this content:" marker, a
bash shebang, and pass `bash -n`. **Does not** require package-tracked live
hooks — missing/stale `.claude/hooks/` is not a release FAIL.

If it exits non-zero, fix the named template in `skills/init-orchestration/SKILL.md`
(marker/fence/shebang/`bash -n`), then re-run until exit 0. Covered:
task-completed, stop-review, memory-capture, bash-compress, precompact-rescue,
rescue-pointer, friction-capture. Regenerate consumer/dev live hooks via
`/setup orchestration`.

## Step 4.8: Skill-bash lint (pre-commit gate)

Run:
```bash
bash skills/skill-lint/check-skill-bash.sh
```

If it exits non-zero, a fenced bash block contains a known prompts-as-code defect
(C1–C4 — see skills/skill-lint/SKILL.md). **Do NOT commit or tag.** Fix or waive
(`# lint-ok: <id>` only if proven safe), re-run until exit 0.
(Covered: commands/**/*.md, skills/**/*.md excl. skill-lint/fixtures/, agents/**/*.md, AGENTS.md; SPEC-021.)

## Step 4.9: Docs-drift check (pre-commit gate)

Run:
```bash
bash skills/docs-drift/check-docs-drift.sh
```

If it exits non-zero, structural documentation has drifted (cmd-index, agent-roster,
docs-hub, or manifest-desc — see skills/docs-drift/SKILL.md; SPEC-010 D1–D8).
**Do NOT commit or tag.** Fix the drift (or waive with `<!-- drift-ok: <check-id> -->`
where allowed), re-run until exit 0.

## Step 4.10: Smoke-harness gate (pre-commit gate)

Run:
```bash
bash tools/smoke/run.sh
```

If it exits non-zero, one or more Surfaces (commands, skills, or engine scripts) failed to
load — frontmatter unparseable, missing `name`/`description`, or a bash block that does not
parse. **Do NOT commit or tag.** Print the `FAIL` lines for the user, fix the broken Surface,
then re-run until exit 0. Contract lives in SPEC-030.

## Step 4.11: Bump-class gate (new command surface)

A newly added `commands/*.md` requires `plugin.json` to bump **minor or major**.
Patch (or unchanged) is a hard fail — this is the 1.7.37 class of defect.

```bash
# Fresh shell — re-resolve PDH (SPEC-021 C1)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
CHECK_BUMP=$(bash "$PDH/skills/plugin-dir.sh" file skills/release/check-bump-class.sh)
bash "$CHECK_BUMP" || exit 1
```

Non-zero → **Do NOT commit, tag, or push.** Bump minor (or major) and re-run.
Edits to existing `commands/*.md` do not trip the gate.

## Step 5: Commit (one folded commit)

Stage the version files **and the actual changed source files** — everything being
released goes into a single commit:
```bash template
git add CHANGELOG.md .claude-plugin/plugin.json
git add <the source files this release changes>   # e.g. README.md, agents/, skills/, commands/
# marketplace.json only if this release actually changed descriptions/refs — not for version
```
Then check `git status --short`: confirm nothing intended is left unstaged and that
no unrelated/untracked files were swept in.

### Staged-path hard gate (SPEC-010 S7; CDT-189)

**After** intentional `git add` above, **before** `git commit`: run the fail-closed
index allowlist. Do **not** reimplement the gate in prose — call the script.

```bash template
# Fresh shell — re-resolve PDH (SPEC-021 C1; same one-liner as Step 0)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
CHECK_STAGED=$(bash "$PDH/skills/plugin-dir.sh" file skills/release/check-staged-paths.sh)
# --intended = every path this release intentionally staged (same set as the git add
# above). Prefer listing the version pair explicitly; the script always allows them
# even if omitted. Product paths are required for pass when staged.
# Multi-ticket ships only: append --allow-extra PATH [PATH...] for extra product paths.
bash "$CHECK_STAGED" \
  --intended CHANGELOG.md .claude-plugin/plugin.json \
             <the source files this release changes>
# e.g. multi-ticket: bash "$CHECK_STAGED" --intended ... --allow-extra other/ticket/file.md
```

- **Exit 0** — staged ⊆ allowed; proceed to commit.
- **Non-zero** (exit 1 foreign path(s), or 64 usage) — **hard-stop**. Print the
  script's stderr as-is. **Do NOT commit, tag, or push.** Fix the index (unstage
  foreign paths or add legitimate paths to `--intended` / `--allow-extra`) and
  re-run the gate until exit 0. The script never mutates the index.
- **`--allow-extra PATH...`** — intentional multi-ticket / multi-arc ships only;
  admits additional staged paths beyond this ticket's product set. Do not use it
  to paper over accidental staging.

Commit message — **type-prefixed subject with the version inline, plus a
Co-Authored-By trailer. No `chore: release`. No prose body:**
```
<feat|fix>: vX.Y.Z — <one-line summary derived from the changelog lead bullet>

Co-Authored-By: <Agent-or-Model> <noreply@…>
```
- `feat:` for feature releases, `fix:` for fixes/hardening — match the bump from Step 1.
- Em-dash (`—`) between version and summary, not a hyphen.
- **Honest identity** — name the agent/model actually performing the release. Do **not** hardcode Claude/Anthropic when the agent is something else (e.g. Grok, Codex, a human). Examples:
  - `Co-Authored-By: Grok <noreply@x.ai>`
  - `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
  - `Co-Authored-By: Claude <model> <noreply@anthropic.com>` (model-agnostic Claude form for consumer templates)
- The CHANGELOG carries the detail; the commit subject stays one line.

After the fold commit succeeds, continue to Step 5.5 **before** tagging.

## Step 5.5: Ship-history cleanliness gate (SPEC-010 H5–H10; CDT-188)

**After** Step 5 fold commit, **before** Step 6 `git tag` + push, and again
**after** the local tag exists (include the new tag in W). Cite SPEC-010 H —
**do not** restate D1–D4 here. Resolve the checker install-aware (plugin-dir);
re-resolve PDH in this fence (skill-lint C1).

```bash template
# Fresh shell — re-resolve PDH + SHIP_START (SPEC-021 C1)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
CHECK_SHIP=$(bash "$PDH/skills/plugin-dir.sh" file skills/release/check-ship-history.sh)
# SHIP_START from Step 0.5 (or ambient SHIP_START_SHA). Fail closed if missing.
SHIP_START="${SHIP_START:-${SHIP_START_SHA:-}}"
[ -n "$SHIP_START" ] || { echo "release: SHIP_START unset — re-run Step 0.5" >&2; exit 64; }
# Pre-tag (optional but preferred H10): catch prior dirty in W before creating the tag.
# After local tag: re-run with --expect-tag vX.Y.Z=$(git rev-parse HEAD) so D4 has a pin.
bash "$CHECK_SHIP" --since "$SHIP_START"
# post-tag form (Step 6, after git tag vX.Y.Z, before push / success claim):
# bash "$CHECK_SHIP" --since "$SHIP_START" --expect-tag "vX.Y.Z=$(git rev-parse HEAD)"
```

- **Exit 0** — clean; proceed to tag (pre-tag) or push / success claim (post-tag).
- **Exit 1 (dirty)** — print the script's evidence as-is (includes exact token
  `history dirty — rewrite needed`). **Do NOT** claim release success, set
  Linear/backlog Done, or print a ship-success line.
  - **Autopilot / `AUTOPILOT_ON` / end-state context (H8):** **halt** with the
    exact phrase `history dirty — rewrite needed` plus H3 evidence. MUST NOT
    silent force-push, amend, retag, or force-push. Leave refs as-is.
  - **Interactive (H7):** print dirty evidence; propose a rewrite plan (which
    commits to fold, which tags to move); **require explicit user confirm**
    before any `git rebase` / `git commit --amend` / tag delete+recreate /
    `git push --force-with-lease`. On decline or no answer → halt; leave refs
    unchanged. After a confirmed rewrite, re-run the checker until exit 0,
    then continue (H10 linearize-before-tag when still pre-push).
- **Exit 64** — usage / unresolvable `--since`: hard-stop; fix invocation; do
  not tag/push/claim success.
- Prefer **not** pushing tags until clean (H5/H10). If push already happened
  and the re-check is dirty → still H7/H8 halt; never silent repair.

## Step 6: Tag and push

**Only after Step 5.5 is clean (or interactive rewrite re-checked clean):**

```bash
git tag vX.Y.Z
```

**Immediately after the local tag**, re-run Step 5.5's checker with
`--expect-tag "vX.Y.Z=$(git rev-parse HEAD)"` (same PDH / `CHECK_SHIP` /
`SHIP_START` resolve). Dirty → H7/H8; **do not push**, do not claim success.

When clean:

```bash
BRANCH=$(git rev-parse --abbrev-ref HEAD)
git push origin "$BRANCH" --tags
```

**If push fails due to sandbox restrictions**: tell the user to run the push manually and print the exact commands:
```
git push origin <branch> --tags
```

Confirm with: `git log --oneline -3` and `git tag --list 'v*' | tail -3`

**Success claim:** only after the post-tag (and post-push if already pushed)
ship-history check is exit 0. Dirty after push still forbids Done / "released"
claims (H5/H8).
