// Package lifecycle loads the control-plane lifecycle graph (CDT-642 AC1, AC2).
//
// The graph data is the contract, and it lives in one committed file:
// docs/internal/control-plane/lifecycle-graph.json. This package adds no graph
// data of its own. It decodes that file, validates it, cross-checks it against
// the machine it describes, and answers questions about it.
//
// The file carries four sections:
//
//   - vertices: the workflow phases of the /orchestrate ladder, and the run
//     states of the C2 run machine (control-plane/run, control-plane/journal);
//   - edges: transitions, each guarded by SPEC-033 blocking conditions. A guard
//     carries a citation (path:line) and never restates the condition
//     (SPEC-033 M6, specs/core/SPEC-033-autopilot-policy.md:229; CDT-642 AC6);
//   - kill_test_boundaries: the one boundary list the kill test iterates (AC2);
//   - checkpoints: the points a run resumes from (AC2).
//
// Load cross-checks the graph against the code it describes, so the file cannot
// drift from the machine: every run-state vertex is a state the machine can be
// in (journal.Status names plus run.RetryBudgets for halted:<reason>), every
// halted:<reason> is in journal.HaltReasons, every edge event is a journal event
// kind, and the terminal flag agrees with the machine's terminal set.
//
// Every load failure is a *GraphError that names the cause, the element kind, the
// element id, and the field. Callers branch on the cause with errors.Is.
//
// Trust rule (AGENTS.md § Code Conventions): the graph is read-only data. The
// path arrives as an argument, as $DEVTEAM_LIFECYCLE_GRAPH, or from the working
// directory. Text inside the file is never assembled into a command, a shell
// string, or SQL.
package lifecycle
