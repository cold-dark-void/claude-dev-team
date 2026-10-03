<!-- /bug-hunt stage body — load via SKILL.md router; read only the current stage. -->

## Traceability

| Requirement | Where |
|-------------|--------|
| Surface / args / floor / `--proceed` / `materialize` / `handoff` / `--start-phase` | Arguments; S0; SPEC-034 M1–M5 / M8 / M46 |
| Continuous S1→S2 | Pipeline; Invariants; M7, N8 |
| Finding model + AC8 | Finding model; S1 §1f; M10–M13 |
| Floor filter / dropped | Finding model; S1 §1f; M14–M15 |
| Compose SPEC-013 blind (discover) | Overview; **S1**; M16 / **M33** |
| Phase-done M20 discover | S1 §1g |
| Phase-done M21 refute | **S2** §2k; **REPORT** R1 |
| Refute compose ≥2 distinct flavors (M34) | **S2** §2b–2e |
| Disposition confirmed\|refuted; no leftover candidate | **S2** §2g–2i (AC7) |
| AC8 fields on confirmed | **S2** §2i; Finding model; **REPORT** R1 |
| confirmed_actionable = confirmed ∧ ≥floor (M32/AC9) | **S2** §2i; **REPORT** R1–R2 |
| Zero-actionable terminal (AC10) | **S2** §2l; **REPORT** R1 / R4; **S3b/S3g** |
| S3 load json/report (AC1 / M38) | **S3a** (prefer json → report → loud fail 64) |
| S3 filter confirmed ∧ ≥floor (AC2) | **S3b**; `BH_ACTIONABLE[]` |
| Zero actionable (AC10 / M41) | **S3b** §3b.3; **S3g** M22 zeros |
| Findings plan path (AC3 / M39) | **S3c**; `BH_PLAN`; `templates/findings-plan.md` |
| Proceed before materialize (AC4 / M8 / M41) | **S3d**; Invariants |
| Programmatic write-back only (AC5 / M40) | **S3e**; compose table; backlog SKILL |
| bh-quality body + slugs + linkage (AC6–AC8) | **S3e** §3e.3–3e.6; **S3f** |
| Phase-done M22 materialize (AC9) | **S3g** §3g.2–3g.3 |
| Proceed forms flag\|token; plan-only stop (M41) | **S3d** §3d.2–3d.5 |
| Idempotent skip linked (OQ3) | **S3e** §3e.2 |
| Programmatic Direct write Linear-first (M40) | **S3e** §3e.5; backlog § Programmatic write-back |
| Hard walls no invoke engines/fix/re-S1–S3 invent | Invariants; **S3g**; **S4** |
| S4 handoff args `handoff` / `--start-phase` | Arguments; S0; **S4** |
| S4 load C3 plan + phaseable OQ3 (AC1 / M42) | **S4a** (loud fail 64; N13) |
| S4 severity bands omit-empty renumber (AC2 / M43) | **S4b** §4b.1 |
| S4 zero path 0 phases M23 (AC11) | **S4b** §4b.3 → **S4d** minimal → **S4g** §4g.2 |
| S4 phase artifacts write (AC3 / AC8 / M44) | **S4d**; `templates/phase-plan.md` + `handoff-phase.md` |
| S4 route rule M18/M45 (AC4) | **S4c** §4c.1 — `/epic` iff phase_count≥2 ∧ item_count≥2 |
| S4 phase lock M9/M46 (AC5) | **S4e** — `--start-phase n` \| typed `start-phase-n` |
| S4 arm + invocation_hint only (AC9 / OQ10) | **S4f** — MUST NOT spawn engines |
| S4 exit metrics on template (AC6 / M47) | **S4d** emit + **S4f** signoff; `templates/handoff-phase.md` |
| S4 phase-done M23 full + zero (AC7 / M48) | **S4g** §4g.1–4g.2 |
| S4 bindings BH_PHASE* / BH_ROUTE / BH_ARM / BH_HANDOFF_N | Arguments bindings; **S4a–S4g** |
| S4 pipeline S4a–S4g emit-only | Pipeline; **S4** |
| CDV-199 degradation | Invariants; S1 §1c; **S2** §2h; **REPORT** R1 banner; council § Spawn-failure degradation |
| Report path / uncommitted (M31/M25) | **REPORT** R0–R3; `.gitignore` → `.claude/bug-hunt/` |
| SHOULD findings JSON (S3 intermediate) | **REPORT** R3; **S3a**; `templates/findings.json` |

SPEC-034 M31–M34 live (C2). S3 cites **M8** / **M22** / **M38–M41** (CDT-138).
S4 cites **M42–M48** live (CDT-139): load/band/write + route/locks/ARM/M23.

---

## Interaction with other components

| Component | Relationship |
|-----------|--------------|
| `commands/bug-hunt.md` | Thin entry; PDH → this skill; stages 1–4 surface (CDT-139 T5) |
| `skills/council/SKILL.md` | Blind-review path (S1) + investigator + degradation (S2) |
| `commands/council.md` | Blind-review dispatch surface + substitutions (cite for S1) |
| `skills/council/prompts/*` | `unconstrained-reviewer`, `lens-reviewer`, `quorum-analyst`, `investigator` |
| `skills/council/flavors/*` | Existing flavors only for S2 pairs |
| `skills/backlog/SKILL.md` | § Programmatic write-back — **only** dual-write path for S3e (no fork) |
| `skills/bug-hunt/templates/phase-plan.md` | S4d phase index template (T3) |
| `skills/bug-hunt/templates/handoff-phase.md` | S4d per-phase handoff template (T3) |
| `specs/core/SPEC-034-bug-hunt-workflow.md` | Product contract (M8, M38–M41, M42–M48) |
| `specs/core/SPEC-013-adversarial-council-tribunal.md` | Blind + investigator MUSTs |
| `specs/core/SPEC-009-*` (backlog) | Dual-write / index contract composed by backlog skill |
| `.claude/bug-hunt/` | Hunt reports + plans + phase handoffs (uncommitted) |
| `/debug`, `/orchestrate`, `/epic` | Neighbors; **not invoked** by stages 1–4 (S4 print-only hints) |

---

## Implementation fill-in map (epic tasks)

| Task | Fills |
|------|--------|
| — C2/C3 filled — | S0–S3; REPORT; materialize |
| T0 | SPEC-034 M42–M48 additive (∥ T1; DRAFT) |
| T1 | S4 skeleton walls/args/bindings/stubs |
| T2 | S4a LOAD + S4b BAND + zero path |
| T3 | phase-plan + handoff-phase templates + S4d write |
| T4 | S4c route + S4e locks + S4f ARM + S4g M23 (**this**) |
| T5 | `commands/bug-hunt.md` thin host stages 1–4 |
| T6 | `skills/bug-hunt/test.sh` C4 static contracts |
| T7 | docs/commands + README touch |
| T8 | QA AC matrix |
