# omp host notes (oh-my-pi)

Host-specific behavior when the dev-team plugin runs under **omp** (oh-my-pi).
Evidence base: omp v18.7.0 on this box. Re-verify when omp changes.

## Enable the plugin

omp loads the plugin through its built-in Claude plugin loader. The loader is
off until you enable the provider:

```bash
omp config set enabledProviders '["claude-plugins"]'
```

The setting lives in `~/.omp/agent/config.yml` under `enabledProviders`.
Without it, omp silently loads no plugin skills — you only see
`Unknown skill` errors. `/doctor` covers this as `omp.enabled_providers`
(CDT-551).

## Agent name dedup

omp dedupes agents by name, and the plugin agent wins. If an omp bundled
agent shares a name with one of ours, our agent replaces it for omp users.
This is the intended precedence, but it means our roster names are a surface:
never add a roster name that omp also bundles without documenting the
shadowing here.

## Roster overlap check (CDT-549)

Verified bundled task agents for omp v18.7.0 (`omp agents unpack` to a temp
dir, then read the `name:` frontmatter):

- `reviewer`
- `scout`
- `security-reviewer`
- `sonic`
- `task`

No name in this set matches our 13-agent roster, so v18.7.0 has no live
clash. The `debugger` clash was reported on omp because omp has bundled a
read-only debugger role in other versions; the risk stands for any omp build
that ships an agent named `debugger` (or any other roster name). When that
happens, our `debugger` (read-only root-cause investigator, spawned by
`/debug ticket` only) silently replaces omp's tool of the same name.

To re-verify:

```bash
D=$(mktemp -d "${TMPDIR:-/tmp}/omp-agents.XXXXXX") && omp agents unpack --dir="$D" >/dev/null
find "$D" -maxdepth 1 -name '*.md' -exec grep -h '^name:' {} + | sort -u
ls agents/ | sed 's/\.md$//' | sort -u
rm -rf "$D"
```

## Decision: document, do not rename (CDT-549)

Renaming `debugger` (for example to `devteam-debugger`) would remove any
future shadowing, but it is a breaking surface change for a rarely-invoked
internal agent: `/debug ticket`, specs, docs, and memory rows all carry the
name. Decision: keep the name, document the clash, and revisit only if a live
clash appears in a shipped omp version.

## Doctor coverage

- `omp.enabled_providers` — PASS/WARN on `enabledProviders` containing
  `claude-plugins`; the fix line is the `omp config set` command above.
  Print-only; doctor never writes omp config.
- `omp.marketplace` — WARN on a stale omp marketplace copy: the marketplace
  clone's `plugin.json` version is older than the highest installed
  `~/.claude/plugins/cache` copy. Fix: update the marketplace clone.
