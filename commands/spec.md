---
name: spec
description: Unified spec management entry — audit/validate, create, find, list,
  update, reverse-generate from code, generate tests, and full-system reflect.
  Usage /spec <check|create|find|list|update|generate|tests|reflect> [args...]
argument-hint: "<check|create|find|list|update|generate|tests|reflect> [args...]"
agent: build
---

# /spec

Thin host over `skills/spec-tooling/`. This file parses the sub, resolves the
protocol file, and Reads it. Protocol is not restated here.

```
Usage: /spec <check|create|find|list|update|generate|tests|reflect> [args...]

Subs:
  check     Audit/validate specs (format, alignment, optional --tests matrix)
  create    Interactive interview → new DRAFT spec
  find      Search specs by keyword
  list      Status overview; flag orphans
  update    Modify a spec with conflict check + version history
  generate  Reverse-engineer INFERRED specs from code
  tests     Generate tests from MUST requirements
  reflect   Full-system health check (all specs)
```

Parse the first positional argument as `<sub>`. If absent or unknown, print
the usage block and stop. Remaining args (including flags) pass through
unchanged.

| `<sub>` | Protocol file |
|---------|---------------|
| `check` | `skills/spec-tooling/check.md` |
| `create` | `skills/spec-tooling/create.md` |
| `find` | `skills/spec-tooling/find.md` |
| `list` | `skills/spec-tooling/list.md` |
| `update` | `skills/spec-tooling/update.md` |
| `generate` | `skills/spec-tooling/SKILL.md` |
| `tests` | `skills/spec-tooling/SKILL.md` |
| `reflect` | `skills/spec-tooling/SKILL.md` |

```
/spec check [--tests] [--gate[=N]] [SPEC-ID]
/spec create
/spec find <keyword>
/spec list
/spec update [SPEC-ID]
/spec generate [<path>]
/spec tests [SPEC-NNN] [--dry-run]
/spec reflect
```

## Step 0: Resolve skill (PDH)

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
SUB=""
for arg in $ARGUMENTS; do
  SUB="$arg"
  break
done
case "$SUB" in
  check)    REL="skills/spec-tooling/check.md" ;;
  create)   REL="skills/spec-tooling/create.md" ;;
  find)     REL="skills/spec-tooling/find.md" ;;
  list)     REL="skills/spec-tooling/list.md" ;;
  update)   REL="skills/spec-tooling/update.md" ;;
  generate|tests|reflect) REL="skills/spec-tooling/SKILL.md" ;;
  *)
    echo "Usage: /spec <check|create|find|list|update|generate|tests|reflect> [args...]" >&2
    exit 1
    ;;
esac
SKILL=$(bash "$PDH/skills/plugin-dir.sh" file "$REL")
if [ -z "$SKILL" ] || [ ! -f "$SKILL" ]; then
  echo "error: $REL not found in the installed plugin" >&2
  exit 1
fi
echo "Loaded spec protocol: $SKILL"
```

## Step 1: Follow the skill

Read `$SKILL` and execute it with remaining args (everything after `<sub>`)
unchanged.

- `check` / `create` / `find` / `list` / `update` live in `skills/spec-tooling/*.md`.
- `generate` / `tests` / `reflect` live in `skills/spec-tooling/SKILL.md` —
  follow the matching mode. Do not guess a default sub.
- Shared assets stay in the skill dir: `spec-skeleton.md`, `source-exclude.md`,
  `check-format.sh`.

Do not restate engine protocol in this command.

## Notes

- Engine: `spec-tooling` (`user-invocable: false`)
- Spec: SPEC-008
- Flag parity that must keep working: `/spec check --tests`,
  `/spec check SPEC-012`, `/spec check SPEC-012 --tests --gate=5`,
  `/spec tests --dry-run`, `/spec generate path/to/pkg`
