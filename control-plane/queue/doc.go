// Package queue is the control-plane run queue: the slot ledger (CDT-649).
//
// # The slot ruling
//
// One slot is one Runner — one process or one container (CONTEXT.md § Terms,
// amended by CDT-649). The queue counts runners, and the term "Slot" stays.
// The per-model-endpoint variant that phase 0 left open is ruled out; the
// slot never scales with endpoints. The ruling is recorded in CONTEXT.md and
// run-budget.md § Amendment, which this package implements.
//
// # The two caps
//
// The queue enforces two caps independently (CONTEXT.md § Slot; AC2). Both
// must admit a grant; either alone makes the runner wait:
//
//   - the node concurrency setting — the existing Spawn concurrency cap
//     (CDT-573): the COUNCIL_CONCURRENCY env layer and the top-level
//     "concurrency" key of the Model map (skills/model-map/
//     resolve-concurrency.sh). Unset everywhere means unbounded.
//   - the per-model-endpoint cap — a per-model slot ceiling the Model map
//     carries as its top-level "model_slots" object (key: a match key, value:
//     the integer cap). The map never caps a model it does not name: absent
//     key means unbounded. "model_slots" is outside the schema the Model map
//     documents, so every SPEC-037 M22 reader (a pre-CDT-573 reader that
//     ignores unknown top-level keys) ignores it, exactly as those readers
//     already ignore "concurrency".
//
// # The match key
//
// The map key of "model_slots" is the match key that survives full vendor
// model slugs (AC4, the CDT-603 related input). A map value is a tier token
// or a full vendor slug, resolved through skills/model-map/
// resolve-model.sh <agent> — the one Model-map reader, never forked. The
// derivation:
//
//  1. Tier token. If the resolved string is exactly opus, sonnet, or haiku
//     (SPEC-037 M12), the key is that token.
//  2. Full slug. Any other resolved string is a vendor slug (for example
//     "grok-code-fast-1"). The key is the slug itself — never a truncation
//     and never a guessed prefix, so a stale slug matches nothing rather
//     than matching a family (CDT-603's failure mode, applied to slots).
//
// The cap lookup is exact: a runner is capped by the row its match key
// names, or by the "tier-default" row when its key has no row — no other
// key ever stands in. The tier-token key binds only runners whose resolved
// model string IS the token, so an operator can name the token and hold
// one endpoint budget for the whole tier, or name one slug and hold a
// tighter budget for that endpoint alone. A slug is capped only by its own
// row or "tier-default": the tier token of its family never applies (AC4).
// A runner whose key has neither row is unbounded.
//
// # The ledger
//
// Every grant, wait, and release is a run.Machine intent-then-outcome pair
// (the SPEC-040 AC11 pattern) through the C2 run machine — reused, never
// forked — inside one fencing-token-checked transaction:
//
//	slot.grant   intent: the runner takes a slot, subject to both caps.
//	             outcome: the grant is live (always true; the transaction
//	             already proved it).
//	slot.wait    intent: both caps refused, the runner waits. The idem-
//	             potency key carries the grant epoch, so a later grant
//	             records a fresh attempt.
//	slot.release intent: the runner gives its slot back.
//
// The counting is intent-based (AC6): a replay of a grant intent alone
// already counts, so the transaction reads its own intent — the ledger
// reads st.Effects, which the append folded into the state in the same
// transaction — and a kill-and-replay never grants a slot twice.
//
// # The wait-close rule
//
// A wait pair closes with exactly one outcome (the package never leaves a
// pending effect):
//
//   - a later grant for the same runner closes the open wait pair with
//     granted true — the runner got its slot.
//   - a release while the runner still waits closes the open wait pair with
//     granted false and released true — the runner left the queue before it
//     was granted.
//
// # Status surface
//
// Slots() is the status-surface read (AC2): one Held, Waiting, and Released
// count per node, and the per-runner rows. The waiting state is a queue-level
// status on a live runner, not a run state — the lifecycle graph gains no
// vertex (CDT-642; the run machine is unchanged).
package queue
