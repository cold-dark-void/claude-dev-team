package chief

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/cold-dark-void/claude-dev-team/control-plane/agent"
	"github.com/cold-dark-void/claude-dev-team/control-plane/hostadapter"
	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
	"github.com/cold-dark-void/claude-dev-team/control-plane/run"
)

// ---------------------------------------------------------------------------
// SPEC-045 AC3/AC4 — the run detail reads, the bounded output tail, and the
// Model map preflight
// ---------------------------------------------------------------------------

// AC3: the run detail view reads the premise the run was sent, the host it
// rides, the resolved model, and the lifecycle state — every field folded from
// the journal rows, never from the in-memory capture a restart loses. The
// attempt number is the one the run id names (M2) and the resume button gates
// on the matrix's CapResume cell.
func TestRunDetailCarriesPremiseHostModelState(t *testing.T) {
	eng := newEngine(t)
	c := newTestChief(t, eng, &fakeAgent{}, &fakeTickets{},
		&fakeModels{model: "opus", source: "map"}, &fakePhone{})
	const premise = "/orchestrate CDT-672 --autopilot=auto"
	seedHostedRun(t, eng, "CDT-672", "CDT-672", "grok", "01a1dead-0000", premise)
	seedHostedRun(t, eng, "CDT-672-r2", "CDT-672", "claude", "01a1beef-0000",
		"the second attempt")
	// A start record that names no known host command: the detail view says
	// so with empty fields, and the resume button stays hidden.
	seedHostedRun(t, eng, "CDT-672-r3", "CDT-672", "mini-swe-agent", "", "")

	srv := httptest.NewServer(c.Handler())
	t.Cleanup(srv.Close)

	var detail RunDetail
	if err := json.Unmarshal(get(t, srv, "/v1/runs/CDT-672"), &detail); err != nil {
		t.Fatal(err)
	}
	if detail.State != "running" || detail.Model != "opus" || detail.Ticket != "CDT-672" {
		t.Errorf("detail state = %+v, want running on model opus for ticket CDT-672", detail)
	}
	if detail.Premise != premise || detail.Host != string(hostadapter.HostGrok) ||
		detail.Attempt != 1 || !detail.ResumeSupported {
		t.Errorf("detail fold = premise %q host %q attempt %d resume %v, want %q on grok at attempt 1 with the grok resume cell",
			detail.Premise, detail.Host, detail.Attempt, detail.ResumeSupported, premise)
	}

	// The board rows carry the same fold — the ticket grouping and the
	// Resume-button gate read the list, not the detail endpoint.
	var doc struct {
		Runs []RunDetail `json:"runs"`
	}
	if err := json.Unmarshal(get(t, srv, "/v1/runs"), &doc); err != nil {
		t.Fatal(err)
	}
	byID := map[string]RunDetail{}
	for _, d := range doc.Runs {
		byID[d.RunID] = d
	}
	if len(byID) != 3 {
		t.Fatalf("board rows = %d, want the three seeded runs", len(byID))
	}
	if got := byID["CDT-672"]; got.Premise != premise || got.Host != "grok" ||
		got.Attempt != 1 || !got.ResumeSupported {
		t.Errorf("board row = %+v, want the detail fold on the list row too", got)
	}
	if got := byID["CDT-672-r2"]; got.Attempt != 2 ||
		got.Host != string(hostadapter.HostClaudeCode) || !got.ResumeSupported ||
		got.Premise != "the second attempt" || got.Ticket != "CDT-672" {
		t.Errorf("attempt row = %+v, want attempt 2 on claude-code with the journaled premise", got)
	}
	if got := byID["CDT-672-r3"]; got.Host != "" || got.ResumeSupported ||
		got.Premise != "" || got.Attempt != 3 {
		t.Errorf("no-host row = %+v, want an empty host, no resume, no premise, attempt 3", got)
	}

	// The state is the journal replay: no route, no in-memory record — a
	// chief that never saw the start answers the same detail.
	restarted := NewWithAdapter(eng, &hostadapter.Adapter{Agent: &fakeAgent{}},
		WithTickets(&fakeTickets{}), WithModelMap(&fakeModels{}), WithPhone(&fakePhone{}))
	fresh, err := restarted.Detail(context.Background(), "CDT-672")
	if err != nil {
		t.Fatal(err)
	}
	if fresh.Premise != premise || fresh.Host != "grok" || fresh.Attempt != 1 ||
		fresh.State != "running" || fresh.ResumeSupported != detail.ResumeSupported {
		t.Errorf("restarted detail = %+v, want the journal fold the first chief read", fresh)
	}
}

// AC6 (SPEC-046 M9): the run detail read shows the run options in effect — the
// composed command the ticket route sent (the premise the run carries,
// SPEC-045 AC3) and the two budget caps. Both fold from the journal: the
// command from the run's premise row, the caps from its run_started row. A
// chief that never saw the start answers the same detail, so the UI needs no
// state source of its own (SPEC-045 AC9). An unset cap renders absent, the
// convention every unset state field follows.
func TestRunDetailShowsTheComposedCommandAndCaps(t *testing.T) {
	eng := newEngine(t)
	plantTicket(t, "CDT-682", "")
	plantTicket(t, "CDT-683", "")
	root, _ := plantAutopilotParser(t, 0)
	seam := &fakeAgent{}
	c := newTicketChief(t, eng, &fakeTickets{}, &fakeModels{model: "opus", source: "map"},
		seam, root)

	const command = "/orchestrate CDT-682 --tier=full --council-tier=light" +
		" --max-loc=800 --concurrency 4 --with-advisor=opus --autopilot=auto"
	res, err := c.Route(context.Background(), RouteRequest{
		Kind: "ticket", TicketID: "CDT-682", Host: hostadapter.HostGrok,
		Tier: "full", CouncilTier: "light", MaxLoc: "800", Concurrency: "4",
		WithAdvisor: "opus", WallclockCap: "7200", IterationCap: "40",
		Autopilot: "auto",
	})
	if err != nil {
		t.Fatalf("route: %v", err)
	}
	if res.Command != command {
		t.Fatalf("route command = %q, want %q", res.Command, command)
	}
	// The spawn carries the composed command as the run's work premise, which
	// is the text the node agent journals as its agent.premise row. The seam
	// journals claim and start (with the caps) and writes no premise row, so
	// the test appends the row the real agent appends.
	reqs := seam.requests()
	if len(reqs) != 1 {
		t.Fatalf("starts = %d, want one", len(reqs))
	}
	if reqs[0].Premise != command {
		t.Fatalf("spawn premise = %q, want the composed command %q", reqs[0].Premise, command)
	}
	appendSeededEffect(t, eng, res.RunID, agent.EffectPremise,
		map[string]any{"premise": reqs[0].Premise, "attempt": 1},
		fmt.Sprintf("agent:premise:%s#1", res.RunID))

	srv := httptest.NewServer(c.Handler())
	t.Cleanup(srv.Close)

	var detail RunDetail
	if err := json.Unmarshal(get(t, srv, "/v1/runs/CDT-682"), &detail); err != nil {
		t.Fatal(err)
	}
	if detail.Premise != command {
		t.Errorf("detail premise = %q, want the composed command %q", detail.Premise, command)
	}
	if detail.WallclockCapS != 7200 || detail.IterationCapS != 40 {
		t.Errorf("detail caps = %d/%d, want the journaled 7200/40",
			detail.WallclockCapS, detail.IterationCapS)
	}

	// The board rows carry the same fold — the run detail view reads the list.
	var doc struct {
		Runs []RunDetail `json:"runs"`
	}
	if err := json.Unmarshal(get(t, srv, "/v1/runs"), &doc); err != nil {
		t.Fatal(err)
	}
	var row RunDetail
	for _, d := range doc.Runs {
		if d.RunID == res.RunID {
			row = d
		}
	}
	if row.Premise != command || row.WallclockCapS != 7200 || row.IterationCapS != 40 {
		t.Errorf("board row = %+v, want the composed command with the caps 7200/40", row)
	}

	// A caps-free run names no caps: the fields render absent, the same shape
	// every unset state field takes.
	bare, err := c.Route(context.Background(), RouteRequest{
		Kind: "ticket", TicketID: "CDT-683", Host: hostadapter.HostGrok})
	if err != nil {
		t.Fatalf("route the caps-free ticket: %v", err)
	}
	var bareDoc map[string]any
	if err := json.Unmarshal(get(t, srv, "/v1/runs/"+bare.RunID), &bareDoc); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"wallclock_cap_s", "iteration_cap_s"} {
		if v, ok := bareDoc[key]; ok {
			t.Errorf("a caps-free run carries %s = %v, want the key absent", key, v)
		}
	}
	var bareDetail RunDetail
	if err := json.Unmarshal(get(t, srv, "/v1/runs/"+bare.RunID), &bareDetail); err != nil {
		t.Fatal(err)
	}
	if bareDetail.WallclockCapS != 0 || bareDetail.IterationCapS != 0 {
		t.Errorf("caps-free caps = %d/%d, want 0/0",
			bareDetail.WallclockCapS, bareDetail.IterationCapS)
	}

	// The read is the journal, not the chief's memory: a restarted chief that
	// never saw either start answers the same command and the same caps.
	restarted := NewWithAdapter(eng, &hostadapter.Adapter{Agent: &fakeAgent{}},
		WithTickets(&fakeTickets{}), WithModelMap(&fakeModels{}), WithPhone(&fakePhone{}))
	fresh, err := restarted.Detail(context.Background(), res.RunID)
	if err != nil {
		t.Fatal(err)
	}
	if fresh.Premise != command || fresh.WallclockCapS != 7200 || fresh.IterationCapS != 40 {
		t.Errorf("restarted detail = %+v, want the journaled command with the caps 7200/40", fresh)
	}
}

// AC3: GET /v1/runs/{run}/events serves the run's journal rows — the closed
// event set as the journal carries them, with a row list an unknown run
// refuses.
func TestRunEventsServeTheClosedKinds(t *testing.T) {
	eng := newEngine(t)
	c := newTestChief(t, eng, &fakeAgent{}, &fakeTickets{}, &fakeModels{}, &fakePhone{})
	seedHostedRun(t, eng, "r-events", "r-events", "grok", "01a1dead-0000", "the premise")

	srv := httptest.NewServer(c.Handler())
	t.Cleanup(srv.Close)

	var doc struct {
		RunID  string          `json:"run_id"`
		Events []journal.Event `json:"events"`
	}
	if err := json.Unmarshal(get(t, srv, "/v1/runs/r-events/events"), &doc); err != nil {
		t.Fatal(err)
	}
	if doc.RunID != "r-events" {
		t.Fatalf("run_id = %q, want r-events", doc.RunID)
	}
	seen := map[journal.Kind]int{}
	for i, ev := range doc.Events {
		var inSet bool
		for _, k := range journal.AllKinds {
			if ev.Kind == k {
				inSet = true
				break
			}
		}
		if !inSet {
			t.Errorf("event %d kind = %q, outside the closed set %v", i, ev.Kind, journal.AllKinds)
		}
		if len(ev.Payload) == 0 {
			t.Errorf("event %d (%s) carries no payload", i, ev.Kind)
		}
		if ev.Seq <= 0 || ev.TS == "" {
			t.Errorf("event %d = %+v, want the journal's seq and ts", i, ev)
		}
		seen[ev.Kind]++
	}
	for _, k := range []journal.Kind{journal.KindRunClaimed, journal.KindRunStarted,
		journal.KindSideEffect} {
		if seen[k] == 0 {
			t.Errorf("kinds = %v, want the run's %s rows in the list", seen, k)
		}
	}
	// The full list, not a page: claim + start + the seeded effect pairs.
	if len(doc.Events) < 7 {
		t.Errorf("events = %d rows, want every row the run carries (%v)", len(doc.Events), seen)
	}

	if status, body := getStatus(t, srv, "/v1/runs/r-unknown/events"); status != http.StatusNotFound {
		t.Errorf("unknown run = %d %s, want 404", status, body)
	}
}

// AC3: the output tail reads the host transcript read-only, bounded by lines
// and by bytes, on each host's layout — and answers an absent transcript with
// an explicit empty result and a reason, never an error.
func TestOutputTailBoundedAndReadOnly(t *testing.T) {
	const (
		cwd         = "/home/malcolm/proj"
		grokSession = "01a1dead-0000-7000-8000-000000000001"
	)
	home := t.TempDir()
	useTranscriptRoots(t, home, cwd)

	eng := newEngine(t)
	c := newTestChief(t, eng, &fakeAgent{}, &fakeTickets{}, &fakeModels{}, &fakePhone{})
	seedHostedRun(t, eng, "r-tail", "r-tail", "grok", grokSession, "the premise")

	// The Grok layout: ~/.grok/sessions/<url-encoded cwd>/<id>/chat_history.jsonl
	grokPath := filepath.Join(home, ".grok", "sessions",
		"%2Fhome%2Fmalcolm%2Fproj", grokSession, "chat_history.jsonl")
	var lines []string
	for i := 1; i <= 500; i++ {
		lines = append(lines, fmt.Sprintf(`{"line":%d}`, i))
	}
	writeFile(t, grokPath, strings.Join(lines, "\n")+"\n")
	if err := os.Chmod(grokPath, 0o444); err != nil {
		t.Fatal(err)
	}
	before := statOf(t, grokPath)

	srv := httptest.NewServer(c.Handler())
	t.Cleanup(srv.Close)

	// The default bound: the last 200 lines, the newest at the end. The
	// transcript is longer than the bound, so the answer says it is a tail.
	tail := getTail(t, srv, "/v1/runs/r-tail/output")
	if tail.Host != "grok" || tail.SessionID != grokSession || tail.Source != grokPath {
		t.Errorf("tail identity = %+v, want grok session %s read from %s",
			tail, grokSession, grokPath)
	}
	if tail.Reason != "" {
		t.Errorf("tail reason = %q, want a clean read", tail.Reason)
	}
	if !tail.Truncated {
		t.Errorf("tail truncated = false, want true: 200 of 500 records is a tail")
	}
	if len(tail.Lines) != 200 || tail.Lines[0] != `{"line":301}` ||
		tail.Lines[199] != `{"line":500}` {
		t.Errorf("tail lines = %d (%s … %s), want the last 200 records",
			len(tail.Lines), firstOf(tail.Lines), lastOf(tail.Lines))
	}

	// The line bound is requested, and clamped to MaxOutputLines.
	clamped := getTail(t, srv, "/v1/runs/r-tail/output?lines=100000")
	if len(clamped.Lines) != 500 || clamped.Truncated {
		t.Errorf("clamped tail = %d lines truncated %v, want all 500 under the 1000 ceiling",
			len(clamped.Lines), clamped.Truncated)
	}
	if five := getTail(t, srv, "/v1/runs/r-tail/output?lines=5"); len(five.Lines) != 5 ||
		five.Lines[4] != `{"line":500}` || !five.Truncated {
		t.Errorf("lines=5 = %d (%s), want the last 5 marked truncated",
			len(five.Lines), lastOf(five.Lines))
	}

	// A tail read writes nothing: the transcript is byte- and timestamp-
	// identical afterwards, on a file the owner cannot even write.
	after := statOf(t, grokPath)
	if after.size != before.size || after.mode != before.mode || !after.mtime.Equal(before.mtime) {
		t.Errorf("transcript stat = %+v, want the read to leave %s untouched (%+v)",
			after, grokPath, before)
	}
	raw, err := os.ReadFile(grokPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(raw) != strings.Join(lines, "\n")+"\n" {
		t.Error("the tail read changed the transcript content")
	}

	// The byte cap: 900 records of 200 bytes each outrun 64 KiB, so the read
	// returns the whole records that fit and says it truncated.
	bigPath := filepath.Join(home, ".grok", "sessions", "%2Fhome%2Fmalcolm%2Fproj",
		grokSession+"-big", "chat_history.jsonl")
	seedHostedRun(t, eng, "r-big", "r-big", "grok", grokSession+"-big", "")
	writeFile(t, bigPath, strings.Repeat("x\n", 1)+strings.Repeat(strings.Repeat("y", 200)+"\n", 900))
	big := getTail(t, srv, "/v1/runs/r-big/output?lines=1000")
	if !big.Truncated {
		t.Errorf("byte-cap tail = %+v, want truncated on a %d-byte transcript",
			big, statOf(t, bigPath).size)
	}
	if len(big.Lines) == 0 || len(big.Lines) > MaxOutputLines || len(big.Lines) >= 900 {
		t.Errorf("byte-cap tail = %d lines, want the whole records of a 64 KiB window",
			len(big.Lines))
	}
	for i, l := range big.Lines {
		if len(l) != 200 {
			t.Fatalf("byte-cap line %d = %d bytes, want a whole record (the partial head is dropped)",
				i, len(l))
		}
	}

	// An absent transcript is an explicit empty result, never an error: the
	// session has not written its first line yet.
	seedHostedRun(t, eng, "r-absent", "r-absent", "grok", "01a1dead-9999", "")
	empty := getTail(t, srv, "/v1/runs/r-absent/output")
	if empty.Reason == "" {
		t.Errorf("absent transcript = %+v, want a reason naming what was read", empty)
	}
	assertEmptyLines(t, srv, "/v1/runs/r-absent/output")

	// A run whose journal names no session, and one whose start record names
	// no known host: both answer the same empty shape.
	seedHostedRun(t, eng, "r-noid", "r-noid", "grok", "", "p")
	if noID := getTail(t, srv, "/v1/runs/r-noid/output"); noID.Reason == "" {
		t.Errorf("no session id = %+v, want a reason", noID)
	}
	assertEmptyLines(t, srv, "/v1/runs/r-noid/output")
	seedHostedRun(t, eng, "r-nohost", "r-nohost", "mystery-cli", "01a1dead-8888", "p")
	noHost := getTail(t, srv, "/v1/runs/r-nohost/output")
	if noHost.Reason == "" || noHost.Host != "" {
		t.Errorf("no host = %+v, want an empty tail with the reason the start record names no host",
			noHost)
	}
	assertEmptyLines(t, srv, "/v1/runs/r-nohost/output")

	// The Claude Code layout: ~/.claude/projects/<cwd as dashes>/<id>.jsonl
	const ccSession = "01a1beef-0000-7000-8000-000000000002"
	ccPath := filepath.Join(home, ".claude", "projects",
		"-home-malcolm-proj", ccSession+".jsonl")
	seedHostedRun(t, eng, "r-cc", "r-cc", "claude", ccSession, "p")
	writeFile(t, ccPath, `{"type":"user"}`+"\n"+`{"type":"assistant"}`+"\n")
	cc := getTail(t, srv, "/v1/runs/r-cc/output")
	if cc.Source != ccPath || len(cc.Lines) != 2 || cc.Reason != "" {
		t.Errorf("claude tail = %+v, want both records from %s", cc, ccPath)
	}

	// The omp layout, per the P-OMP-C-A probe record: the transcript file is
	// the session start timestamp joined to the session id by "_", so the id
	// is the filename's suffix. The same stem also appears as a directory
	// (the session's side files) — the read must take the .jsonl file.
	const ompSession = "01a1ddda-7a27-760e-bd6c-a123b85f0b5e"
	ompDir := filepath.Join(home, ".omp", "agent", "sessions", "-home-malcolm-proj")
	ompPath := filepath.Join(ompDir, "2026-11-15T06-17-25-287Z_"+ompSession+".jsonl")
	seedHostedRun(t, eng, "r-omp", "r-omp", "omp", ompSession, "p")
	if err := os.MkdirAll(filepath.Join(ompDir,
		"2026-11-15T06-17-25-287Z_"+ompSession), 0o755); err != nil {
		t.Fatal(err)
	}
	writeFile(t, ompPath, `{"type":"session","id":"`+ompSession+`"}`+"\nPONG\n")
	omp := getTail(t, srv, "/v1/runs/r-omp/output")
	if omp.Source != ompPath || len(omp.Lines) != 2 || omp.Reason != "" {
		t.Errorf("omp tail = %+v, want both records from %s", omp, ompPath)
	}

	// An unknown run is the typed 404 — the empty-result promise covers an
	// absent transcript, not an absent run.
	if status, body := getStatus(t, srv, "/v1/runs/r-none/output"); status != http.StatusNotFound {
		t.Errorf("unknown run = %d %s, want 404", status, body)
	}
	// A non-numeric bound is the typed 400.
	if status, body := getStatus(t, srv, "/v1/runs/r-tail/output?lines=many"); status != http.StatusBadRequest {
		t.Errorf("lines=many = %d %s, want 400", status, body)
	}
}

// AC4: the route form reads the Model map default through the same
// ModelResolver seam a route rides — a pure read that writes nothing.
func TestModelPreflightServesTheMapDefault(t *testing.T) {
	eng := newEngine(t)
	models := &fakeModels{model: "opus", source: "map"}
	c := newTestChief(t, eng, &fakeAgent{}, &fakeTickets{}, models, &fakePhone{})
	seedHostedRun(t, eng, "r-model", "r-model", "grok", "01a1dead-0000", "p")

	srv := httptest.NewServer(c.Handler())
	t.Cleanup(srv.Close)

	before := allEventRows(t, eng)
	var doc struct {
		Agent  string `json:"agent"`
		Model  string `json:"model"`
		Source string `json:"source"`
	}
	if err := json.Unmarshal(get(t, srv, "/v1/model?agent=ic4"), &doc); err != nil {
		t.Fatal(err)
	}
	if doc.Agent != "ic4" || doc.Model != "opus" || doc.Source != "map" {
		t.Errorf("preflight = %+v, want the map row opus (source map) for agent ic4", doc)
	}
	if models.agent != "ic4" {
		t.Errorf("the seam resolved agent %q, want ic4 — the read rides the route's seam", models.agent)
	}

	// No agent named: the Tier default, which is what a route with no agent
	// will run (SPEC-037 AC3).
	tier := NewWithAdapter(eng, &hostadapter.Adapter{Agent: &fakeAgent{}},
		WithTickets(&fakeTickets{}), WithModelMap(&fakeModels{}), WithPhone(&fakePhone{}))
	tierSrv := httptest.NewServer(tier.Handler())
	t.Cleanup(tierSrv.Close)
	if err := json.Unmarshal(get(t, tierSrv, "/v1/model"), &doc); err != nil {
		t.Fatal(err)
	}
	if doc.Model != tierDefaultModel() || doc.Source != "tier-default" {
		t.Errorf("no-agent preflight = %+v, want the Tier default %q (source tier-default)",
			doc, tierDefaultModel())
	}
	if after := allEventRows(t, eng); after != before {
		t.Errorf("journal rows = %d after the preflight, want %d: the read writes nothing",
			after, before)
	}
}

// ---------------------------------------------------------------------------
// fixtures
// ---------------------------------------------------------------------------

// seedHostedRun records a run in the shape the detail reads take: the claim
// and start rows, the agent.start spawn intent that names the host command,
// and — when the caller names them — the agent.premise and agent.session rows
// the node agent's verbs write.
func seedHostedRun(t *testing.T, eng *journal.Engine, runID, ticket, command,
	sessionID, premise string) {
	t.Helper()
	ctx := context.Background()
	m := run.New(eng, runID)
	token, err := m.Claim(ctx, "node-agent-1", ticket, "orchestrate", "opus")
	if err != nil {
		t.Fatalf("claim %s: %v", runID, err)
	}
	if err := m.Start(ctx, "node-agent-1", token, "opus"); err != nil {
		t.Fatalf("start %s: %v", runID, err)
	}
	appendSeededEffect(t, eng, runID, agent.EffectStart,
		map[string]any{"command": command, "args": []string{"-p"}, "attempt": 1},
		fmt.Sprintf("agent:start:%s#1", runID))
	if premise != "" {
		appendSeededEffect(t, eng, runID, agent.EffectPremise,
			map[string]any{"premise": premise, "attempt": 1},
			fmt.Sprintf("agent:premise:%s#1", runID))
	}
	if sessionID != "" {
		appendSeededEffect(t, eng, runID, agent.EffectSession,
			map[string]any{"session_id": sessionID, "attempt": 1},
			fmt.Sprintf("agent:session:%s#1", runID))
	}
}

// appendSeededEffect records one closed effect pair — the intent row and the
// outcome row that closes it.
func appendSeededEffect(t *testing.T, eng *journal.Engine, runID, effect string,
	payload map[string]any, key string) {
	t.Helper()
	ctx := context.Background()
	raw, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	intent, err := journal.NewEvent(runID, journal.KindSideEffect, journal.Effect{
		Effect: effect, Intent: raw})
	if err != nil {
		t.Fatal(err)
	}
	intent.IdempotencyKey = key
	seq, _, err := eng.AppendChecked(ctx, intent)
	if err != nil {
		t.Fatalf("append %s %s intent: %v", runID, effect, err)
	}
	out, err := journal.NewEvent(runID, journal.KindSideEffect, journal.Effect{
		Effect: effect, Intent: raw, Outcome: raw, IntentSeq: seq})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := eng.AppendChecked(ctx, out); err != nil {
		t.Fatalf("append %s %s outcome: %v", runID, effect, err)
	}
}

// useTranscriptRoots points the transcript seams at one fixture home and cwd.
// The fixture paths are spelled out by the tests, so the encodings are pinned
// against the layouts the probe records name, not against the reader's own.
func useTranscriptRoots(t *testing.T, home, cwd string) {
	t.Helper()
	saved := outputRoots
	t.Cleanup(func() { outputRoots = saved })
	outputRoots = transcriptRoots{
		home: func() (string, error) { return home, nil },
		cwd:  func() (string, error) { return cwd, nil },
	}
}

// writeFile plants one fixture file, creating its directories.
func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

type fileStat struct {
	size  int64
	mode  os.FileMode
	mtime time.Time
}

// statOf reads one fixture file's identity, so the read-only proof can show
// the tail left it untouched.
func statOf(t *testing.T, path string) fileStat {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	return fileStat{size: info.Size(), mode: info.Mode(), mtime: info.ModTime()}
}

// getTail reads one output tail, failing the test on any non-200 answer.
func getTail(t *testing.T, srv *httptest.Server, path string) OutputTail {
	t.Helper()
	var tail OutputTail
	if err := json.Unmarshal(get(t, srv, path), &tail); err != nil {
		t.Fatal(err)
	}
	return tail
}

// assertEmptyLines proves the JSON carries "lines":[] — an empty array, never
// null — so the UI renders an empty tail without a null check.
func assertEmptyLines(t *testing.T, srv *httptest.Server, path string) {
	t.Helper()
	var doc map[string]any
	if err := json.Unmarshal(get(t, srv, path), &doc); err != nil {
		t.Fatal(err)
	}
	lines, ok := doc["lines"].([]any)
	if !ok {
		t.Fatalf("%s lines = %#v, want a JSON array", path, doc["lines"])
	}
	if len(lines) != 0 {
		t.Errorf("%s lines = %d, want the empty array", path, len(lines))
	}
}

// allEventRows counts every journal row the store carries.
func allEventRows(t *testing.T, eng *journal.Engine) int {
	t.Helper()
	events, err := eng.AllEvents(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	return len(events)
}

func firstOf(lines []string) string {
	if len(lines) == 0 {
		return ""
	}
	return lines[0]
}

func lastOf(lines []string) string {
	if len(lines) == 0 {
		return ""
	}
	return lines[len(lines)-1]
}
