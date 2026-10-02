<!-- Shared spec/plan contract. skills/kickoff/SKILL.md, steps/04-kickoff.md, and steps/06-design.md point here. Do not copy this block back into those files. -->

# Spec and plan contract

One plan home. Write the plan to the absolute path `$MROOT/.claude/plans/<YYYY-MM-DD>-<ISSUE-ID>-<slug>.md` (write-through on the shared store). Do not write a second copy under the worktree `.claude/plans`.

`$MROOT` is `dirname` of `git rev-parse --git-common-dir` (else `pwd`). Substitute that absolute directory before the agent writes. Plans are process files. Do not `git add` them.

## Writer rules (SPEC-033 M14(g)/(h))

Write the confirmed ACs into the spec `## Acceptance criteria` section, `### <ISSUE-ID>` subsection. Tag an execution-only AC (asserts only test/gate/CI running, never diff content) `[process]`. Do not tag an AC that asserts diff content. Add a two-space `Verify: bash <test file>` continuation to each technical AC that one test file proves (SPEC-033 M14(g)).

## Tracking

```
## Tracking
- source: linear | backlog | freeform
- ticket_id: <ISSUE-ID>
- closes:
  - backlog/<slug>.md
  - linear:<ID>
- autopilot_on: <true|false>
- autopilot_bump: <patch|minor|major|master|null>
```

Many-to-one is allowed. Empty `closes` only for freeform. Always write `autopilot_on` and `autopilot_bump` from the Step-0 values. `autopilot_bump` is `null` when autopilot is off, or when on in bare/pr-mode. `master` is the land-no-release sentinel. Do not record a separate pr-vs-merge field.

## Copy-extract

Optional. Not a Tracking key. Not per-task. Heading then 0 or 1 token (`COPY-ACCEPTED: divergence-expected` or `EXTRACT-DEFERRED: pre-existing-dup`). Cite the SPEC-003 enum. Do not invent a second vocabulary.

```
## Copy-extract
<0 or 1 canonical token>
```

Omit the heading for the default extract. Both lines, an extra suffix, a synonym, or Simplest/Rejected prose is unknown and is not a waiver.

## Ticket class

Not a Tracking key. Run `skills/orchestrate/ticket-class.sh` on title, body, ACs, and plan text (word boundary, not a substring). `auth` must not match `author`.

Match → `ticket_class: auth-secrets`. No match → `ticket_class: none`. If the script cannot run, emit `ticket_class: auth-secrets` (unsure fails closed).

```
ticket_class: auth-secrets|none
```

Keywords the script treats as whole words: auth, authentication, authorization, oauth, oidc, jwt, session, credential, secret, token, password, apikey, pii, ssn, csrf. Phrases: `api key`, `api-key`, `private key`, `private-key`.

Do not invoke `/council` from this classifier. Step 6c reads the line.

## Process ACs

List the ids tagged `[process]`, in document order.

```
process_acs: <ids|none>
```
