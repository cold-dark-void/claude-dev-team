# SPEC-030 agent fixtures

Bite-test fixtures for the Agent check set (SPEC-030 Check set — Agent):

- `clean.md` — all five SPEC-003 fields valid + one valid bash fence -> PASS
- `missing-effort.md` — omits `effort` -> FAIL naming `effort`
- `bad-model.md` — `model: gpt-4` (out of domain) -> FAIL naming `gpt-4`
- `block-list.md` — `tools:` as a YAML block sequence -> PASS

Excluded from live no-arg discovery (the `fixtures` path segment).
