// Package chief implements the Chief (CDT-650, CDT-628 C9): the single point
// of contact of control plane Option C+ (CDT-626). It routes work to the
// existing Surfaces and reports from run state.
//
// # Routing
//
// A route turns one request into the Surface that serves it. The Surface set
// is the plugin's own — /debug (commands/debug.md) for a defect, /brainstorm
// (skills/brainstorm/SKILL.md) for an idea, /epic (commands/epic.md) for an
// epic — and none of them is reimplemented here. A route names the Surface in
// the run's workflow field, writes the ticket record the Surface reads
// through the plugin's own ticket verbs (skills/backlog/ticket.sh — the C7
// CLI over the local backlog store, the ticket source of truth), and starts
// the run through the C6 host adapter, which drives the node agent's
// four-verb contract. An epic route ends at the child-ticket records; each
// child gets its own run when the operator routes it.
//
// # Reports
//
// Every report is a fold of journal and queue state, never generated prose:
// run status is the replayed state (control-plane/journal), the checks
// reading is the run's pending effects, repairs, and watchdog reading, and
// the queue view is the C5 slot ledger (control-plane/queue). The stand-up
// report composes those three.
//
// # Model selection
//
// The model of a routed run resolves through the Model map
// (skills/model-map/resolve-model.sh, SPEC-037): the request names a mappable
// agent, the script's stdout is the model, and an empty resolution — no
// layer, an empty value, an internal name — is the Tier default
// (control-plane/run, run.TierDefault). No flag exists for this: the agent
// token rides the route request, never a command line.
//
// # Corrections
//
// A correction rides the C6 steer path unchanged: the host adapter encodes
// the host's control-message frame and hands it to the node agent's steer
// verb, which delivers it at the next step boundary — never mid-turn
// (CONTEXT.md § Steer, the six probes).
//
// # Halts
//
// A named halt is reported with its reason and remaining retry budget (the
// C2 halt states, control-plane/run/budget.go), and reaches the operator
// through the Intercom as the phone channel for halts (SPEC-038): the chief
// writes one outbox record per halt through the intercom CLI. The record of
// what was paged lives in .claude/runs/chief/notified.jsonl — one intent line
// before the page, one outcome line after — and only a delivered outcome
// answers a halt: a page that failed, or one whose intent outlived a crash,
// re-pages on the next scan (at-least-once; the operator phone channel
// prefers a repeat over a lost page).
//
// # Deployment
//
// chiefd is deployed on a dev-team checkout: the plugin root the seams
// resolve the plugin's own CLIs from is the $MROOT checkout the service
// runs against, refused unless it carries the dev-team manifest
// (ErrNoPluginRoot). On any other record root the pages fail and retry —
// the typed refusal rides the record like any page failure — they never
// fail silently.
//
// # One interface
//
// The Chief is reachable only over the HTTP API its Handler serves — the API
// the web UI (CDT-650's sibling C10) consumes. There is no CLI verb and no
// second interface: the boundary to the plugin is files and CLI calls only
// (docs/adr/0001-journal-engine.md § "The narrow-interface boundary"), and
// the boundary to the operator is this API.
package chief
