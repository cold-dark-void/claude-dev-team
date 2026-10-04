# /release

Bump the version across the required pair (`CHANGELOG.md`, `plugin.json`),
fold the release into a **single** commit, tag, and push. Ensures the two
version surfaces stay in sync — never skips either. `marketplace.json` is not
versioned (git-ref install channels pin `stable` / `master`).

## Usage

```
/release                 # infer the bump from the shipped Surfaces
/release <X.Y.Z>         # explicit version (skip-if-present changelog entry)
```

## What it does

1. Prechecks (epic release=end, ship-start snapshot, master bump-class hook).
2. Determines the new version (feature-line versioning for multi-PR arcs).
3. Generates the `### vX.Y.Z` changelog entry (newest first) and bumps both
   files; `marketplace.json` gets no version field.
4. Verifies the version pair matches.
5. Runs the pre-commit gates: include drift, council template drift,
   hook-template hygiene, skill-bash lint, docs-drift, smoke harness,
   bump-class, PDH stanza, all-suites.
6. Folds everything into ONE commit, records ship history, tags, and pushes
   (tag push is atomic and refuses partial states).

## Version policy

- **patch** (x.y.Z) — fixes; new opt-in flags with unchanged defaults.
- **minor** (x.Y.0) — features; default-behavior changes; new command surfaces.
- A new `commands/*.md` on a patch bump MUST NOT commit (bump-class gate).

## See also

- [Versioning](../../README.md#versioning) — repo-level policy
- [SECURITY.md](../../SECURITY.md) — supported versions (regenerated at Step 3d)
- `skills/release/SKILL.md` — the authoritative contract
