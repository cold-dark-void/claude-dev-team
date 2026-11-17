// Package killtest is the CDT-643 AC7 kill test: the gate that falsifies
// cost 1 of docs/adr/0001-journal-engine.md.
//
// The claim under test is the ADR's price, not a feature: a SQLite journal
// behind a narrow interface must survive the crash window between a journal
// write and its side effect. So this package kills a real process with SIGKILL
// at every lifecycle phase boundary the run state machine defines, restarts on
// the same journal file, and asserts the run completes exactly once — never
// zero, never twice — and that no external side effect runs twice.
//
// The pieces:
//
//   - PhaseBoundaries and the CDT643_KILLTEST_* environment contract: the
//     boundaries a kill may land at, and how the harness drives the victim. The
//     boundary list the sweep iterates is the lifecycle graph's
//     (docs/internal/control-plane/lifecycle-graph.json, read through
//     control-plane/lifecycle — CDT-642 AC2), and the suite fails when that list
//     and this ladder disagree.
//   - Driver: the one lifecycle script (claim → start → stint → heartbeat →
//     side effect → stall → halt → resume → side effect → complete). It
//     derives its position from the journal replay, so the same script is
//     correct for the first attempt and for the attempt after a kill.
//   - EffectLog: the external side-effect record. It is the observable world
//     the intent-then-outcome pair is reconciled against, and the thing the
//     exactly-once property is finally measured on.
//   - ./helper: the sacrificial process. The harness kills THAT process, so
//     the test proves process death, not a simulated one.
//
// The suite needs no container: it is plain `go test ./...`. The CI lane in
// .github/workflows/smoke.yml runs it in the G-02-approved golang image.
package killtest
