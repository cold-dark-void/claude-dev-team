<!--
  Canonical autopilot off-triad halt verdict — SINGLE SOURCE OF TRUTH (CDT-291 partial, [06 E10]).

  Expanded byte-identically into the orchestrate step files at each self-answer
  verdict site. The marker agent= field carries the HALT GATE NAME (scope-confirm,
  plan-approve, …), substituted at the <AGENT> placeholder in the one-line message
  fence — it is not an agent name here. Sites whose verdict wording or indentation
  differs (08-execute BC1 scope-creep variant, 09-review nested list, kickoff
  FINAL-#4 wording) keep their own text.
-->

- `halt` → emit `task_blocked` (detail = the one-line message below) via **Passive
  notifications → Tier B** (fail-open; § in `cross-cutting.md`), then print the one-line message below and
  return control:
```
<AGENT> <decision>: <rationale> — card: <card-file-path>
