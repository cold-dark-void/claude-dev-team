# control-plane

The Control plane service (control plane Option C+ (CDT-626)) lives here: the
container service that owns run state, the queue, and host sessions for one
project. Phase 1 of the Control plane arc builds it.

This directory is an isolated top-level service directory inside the
`dev-team` plugin repository. It is deliberately not plugin product:

- **One version per artifact.** The service version lives in `VERSION` and is
  bumped only by service-owning tickets. `.claude-plugin/plugin.json` stays
  the plugin's only version surface; service tags never use the plugin tag
  shape `vX.Y.Z`.
- **Boundary — single-homed.** The rule that the control plane talks to the
  plugin through files and CLI calls only is owned by
  [`docs/adr/0001-journal-engine.md`](../docs/adr/0001-journal-engine.md)
  (§ "The narrow-interface boundary"). This README cites it and never
  restates it: the service imports no plugin code, and the ADR alone defines
  what may cross.
- **Not a plugin Surface.** Nothing here ships in the installed plugin.
  `install.sh`, `install-test.sh`, and the plugin manifest exclude this
  directory; plugin packaging stays pure markdown/JSON.
- **Not plugin gate territory.** Release-gate, discovery and
  consistency tooling (`detect-surfaces.sh`, docs-drift, the smoke harness,
  the all-suites runner) carve this directory out — see the SPEC-030
  Discovery/R4 amendment and the SPEC-010 S7 service-path wording.

Build outputs (Go and container artifacts) are git-ignored at the repo root
`.gitignore`; this directory carries no checked-in binaries.

## Files

| File | Carries |
|------|---------|
| `VERSION` | Service semantic version (starts `0.1.0`) |
| `image-reference` | Placeholder container-image pin; the real G-02 request is CDT-628-C4's AC |
| `README.md` | This boundary and ownership statement |
