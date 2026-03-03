---
name: review-and-commit
description: Review staged/modified files for bugs and spec drift, update any
  out-of-date specs, append findings to review.md, then commit. Use when the
  user says "review and commit", "review my changes", or wants to gate a commit
  behind a quality check.
---

# Review and Commit

Packages the review → spec-update → commit loop.

## Steps

1. **Reset review.md** — Overwrite `review.md` with a fresh file (do not
   append). Previous feedback is assumed to have been addressed. Start fresh
   each run.

2. **Review** — Read all staged/modified files. Look for bugs, off-by-ones,
   missed early-returns, thread-safety issues.

3. **Spec check** — Find specs in specs/ related to changed behavior.
   Update any that are out of date. Never skip this step.

4. **Write to review.md** — Write a dated section with findings.
   Format: `## YYYY-MM-DD — <summary>` followed by bullet findings.
   If no issues found, note "No issues found."

5. **Commit** — If clear, commit with a conventional commit message
   that summarizes *why* the change was made. **Never stage or commit
   `review.md`** — it is a local scratch file only.

6. **Verify** — Run `git status` to confirm clean state.
