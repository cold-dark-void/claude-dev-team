package hostadapter

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/cold-dark-void/claude-dev-team/control-plane/agent"
	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
)

// fakeAgent is the NodeAgent seam: it records what the adapter routes and
// never touches a host CLI.
type fakeAgent struct {
	mu sync.Mutex

	// starts records every start the adapter handed over, in order.
	starts []agent.StartRequest
	// frames records every steer message the adapter handed over.
	frames []string
	// sessionOut is written into the session output of the next Supervise.
	sessionOut string
	// superviseErr is returned by Supervise after recording.
	superviseErr error
}

func (f *fakeAgent) Supervise(_ context.Context, _ *journal.Engine,
	req agent.StartRequest, sessionOut io.Writer) error {
	f.mu.Lock()
	f.starts = append(f.starts, req)
	msg := f.sessionOut
	f.mu.Unlock()
	if msg != "" {
		if _, err := io.WriteString(sessionOut, msg); err != nil {
			return err
		}
	}
	return f.superviseErr
}

func (f *fakeAgent) Stop(_ context.Context, _ *journal.Engine, _ string, _ time.Duration) error {
	return nil
}

func (f *fakeAgent) Steer(_ context.Context, _ *journal.Engine, _, message string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.frames = append(f.frames, message)
	return nil
}

func (f *fakeAgent) Status(_ context.Context, _ *journal.Engine,
	runID string) (agent.StatusReport, error) {
	return agent.StatusReport{RunID: runID, State: "completed"}, nil
}

func (f *fakeAgent) startCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.starts)
}

func (f *fakeAgent) lastStart() agent.StartRequest {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.starts[len(f.starts)-1]
}

// newFakeAdapter returns an adapter over the seam.
func newFakeAdapter(f *fakeAgent) *Adapter { return &Adapter{Agent: f} }

// startReq is one start request for a host.
func startReq(host Host) StartRequest {
	return StartRequest{RunID: "run-1", Ticket: "CDT-648", Workflow: "orchestrate",
		Model: "sonnet", Host: host}
}

// resumeReq is one resume request for a host.
func resumeReq(host Host) ResumeRequest {
	return ResumeRequest{RunID: "run-1", Ticket: "CDT-648", Workflow: "orchestrate",
		Model: "sonnet", Host: host, SessionID: "sess-123"}
}

// steerReq is one steer request for a host.
func steerReq(host Host, sessionID string) SteerRequest {
	return SteerRequest{RunID: "run-1", Host: host, SessionID: sessionID,
		Message: "Steer: include the exact token STEER-RECEIVED-47 in your final reply."}
}

// The matrix cells are the gate: every supported cell routes, every other
// verdict refuses with the cell it carries (AC6).
func TestMatrixCellsGateEveryRoute(t *testing.T) {
	cases := []struct {
		host     Host
		cap      Capability
		verdict  Verdict
		wantOK   bool
		citation string // substring the refusal must carry
	}{
		{HostClaudeCode, CapHeadlessStream, VerdictSupported, true, "P-CC-B"},
		{HostClaudeCode, CapResume, VerdictSupported, true, "P-CC-A"},
		{HostClaudeCode, CapSteer, VerdictSupported, true, "P-CC-C"},
		{HostGrok, CapHeadlessStream, VerdictSupported, true, "ACP"},
		{HostGrok, CapResume, VerdictSupported, true, "P-GK-CTR-2"},
		{HostGrok, CapSteer, VerdictSupported, true, "P-GK-CTR-3c"},
		{HostOmp, CapHeadlessStream, VerdictSupported, true, "text_delta"},
		{HostOmp, CapResume, VerdictSupported, true, "P-OMP-C-A"},
		{HostOmp, CapSteer, VerdictSupported, true, "P-OMP-C-C"},
		{HostMiniSwe, CapHeadlessStream, VerdictUnsupported, false, "mini-swe-agent.com/latest/usage/mini/"},
		{HostMiniSwe, CapResume, VerdictUnsupported, false, "no resume/continue flag"},
		{HostMiniSwe, CapSteer, VerdictUnsupported, false, "no steer or mid-run injection path"},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(fmt.Sprintf("%s×%s", tc.host, tc.cap), func(t *testing.T) {
			cell, err := cell(tc.host, tc.cap)
			if err != nil {
				t.Fatalf("cell: %v", err)
			}
			if cell.Verdict != tc.verdict {
				t.Errorf("verdict = %q, want %q", cell.Verdict, tc.verdict)
			}
			if cell.Citation == "" {
				t.Error("cell carries no citation (AC-2)")
			}
			f := &fakeAgent{}
			a := newFakeAdapter(f)
			switch tc.cap {
			case CapResume:
				_, err = a.Resume(context.Background(), nil, resumeReq(tc.host))
			case CapSteer:
				err = a.Steer(context.Background(), nil, steerReq(tc.host, "sess-123"))
			default:
				_, err = a.Start(context.Background(), nil, startReq(tc.host))
			}
			if tc.wantOK {
				if err != nil {
					t.Fatalf("route refused: %v", err)
				}
				return
			}
			var ref Refusal
			if !errors.As(err, &ref) {
				t.Fatalf("err = %v, want a Refusal", err)
			}
			if !errors.Is(err, ErrUnsupportedCapability) {
				t.Errorf("refusal does not name ErrUnsupportedCapability")
			}
			if ref.Cell.Host != tc.host || ref.Cell.Capability != tc.cap ||
				ref.Cell.Verdict != tc.verdict {
				t.Errorf("refusal cell = %+v, want the matrix cell", ref.Cell)
			}
			if !strings.Contains(ref.Cell.Citation, tc.citation) {
				t.Errorf("citation %q lacks the doc source %q", ref.Cell.Citation, tc.citation)
			}
			if f.startCount() != 0 || len(f.frames) != 0 {
				t.Error("a refusal reached the node agent")
			}
		})
	}
}

// An unknown host is a named error, never a verdict.
func TestUnknownHostIsNamedError(t *testing.T) {
	a := newFakeAdapter(&fakeAgent{})
	_, err := a.Start(context.Background(), nil, StartRequest{RunID: "r", Host: "codex"})
	if !errors.Is(err, ErrUnknownHost) {
		t.Fatalf("err = %v, want ErrUnknownHost", err)
	}
}

// AC2: the session id is captured at start, from the matrix AC-4 source of
// the host, and a later frame never overwrites it.
func TestSessionIDCapturedAtStartPerHost(t *testing.T) {
	cases := []struct {
		name  string
		host  Host
		lines []string
		want  string
	}{
		{
			"claude code system/init event",
			HostClaudeCode,
			[]string{
				`{"type":"system","subtype":"init","cwd":"/tmp/x","session_id":"462ad42c-1750-4324-9bfa-15e5fcc3dc0f","tools":["Task","Bash"]}`,
				`{"type":"result","session_id":"00000000-0000-0000-0000-000000000000"}`,
			},
			"462ad42c-1750-4324-9bfa-15e5fcc3dc0f",
		},
		{
			"grok headless json result sessionId",
			HostGrok,
			[]string{`{"sessionId":"01a1dddd-7681-7242-961b-303ae89a105a","stopReason":"end_turn","text":"OK","isError":null}`},
			"01a1dddd-7681-7242-961b-303ae89a105a",
		},
		{
			"omp session frame id",
			HostOmp,
			[]string{
				`{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"PONG"}}`,
				`{"type":"session","version":3,"id":"01a1ddda-7a27-760e-bd6c-a123b85f0b5e","timestamp":"2026-11-15T06:17:25.287Z","cwd":"/tmp/omp-probe-627"}`,
				`{"id":"p1","type":"response","command":"steer","success":true}`,
			},
			"01a1ddda-7a27-760e-bd6c-a123b85f0b5e",
		},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			cap := NewCapture(tc.host)
			for _, l := range tc.lines {
				if _, err := io.WriteString(cap, l+"\n"); err != nil {
					t.Fatal(err)
				}
			}
			if got := cap.SessionID(); got != tc.want {
				t.Errorf("SessionID = %q, want %q", got, tc.want)
			}
		})
	}
}

// A capture survives writes split across Write calls: the runner's drain
// does not promise line boundaries.
func TestCaptureSurvivesSplitWrites(t *testing.T) {
	cap := NewCapture(HostGrok)
	line := []byte(`{"sessionId":"01a1de1d-bd76-7712-9628-d9aebeda8dc1","stopReason":"end_turn"}` + "\n")
	for _, chunk := range [][]byte{line[:7], line[7:40], line[40:]} {
		if _, err := cap.Write(chunk); err != nil {
			t.Fatal(err)
		}
	}
	want := "01a1de1d-bd76-7712-9628-d9aebeda8dc1"
	if got := cap.SessionID(); got != want {
		t.Errorf("SessionID = %q, want %q", got, want)
	}
}

// AC4: resume rides the matrix named path of the host — a distinct headless
// invocation, not the steerable launch (review B1: `grok agent stdio`
// accepts no resume flags) — with one spelling of the continue option
// (review B2).
func TestResumeFollowsTheNamedPathPerHost(t *testing.T) {
	cases := []struct {
		name    string
		req     ResumeRequest
		wantCmd string
		wantSub []string
	}{
		{"claude code -p --resume (P-CC-A)", resumeReq(HostClaudeCode), "claude",
			[]string{"-p", "--resume", "sess-123"}},
		{"grok -p --output-format json --resume (P-GK)", resumeReq(HostGrok), "grok",
			[]string{"-p", "--output-format", "json", "--resume", "sess-123"}},
		{"grok --continue (newest in cwd)", ResumeRequest{
			RunID: "run-1", Host: HostGrok, Continue: true,
		}, "grok", []string{"-p", "--output-format", "json", "--continue"}},
		{"grok --fork-session", ResumeRequest{
			RunID: "run-1", Host: HostGrok, SessionID: "sess-123", Fork: true,
		}, "grok", []string{"-p", "--output-format", "json", "--resume", "sess-123", "--fork-session"}},
		{"omp -r (P-OMP-C-A invocation)", resumeReq(HostOmp), "omp",
			[]string{"-p", "--mode", "json", "-r", "sess-123"}},
		{"omp --continue (one spelling)", ResumeRequest{
			RunID: "run-1", Host: HostOmp, Continue: true,
		}, "omp", []string{"-p", "--mode", "json", "--continue"}},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			f := &fakeAgent{}
			a := newFakeAdapter(f)
			if _, err := a.Resume(context.Background(), nil, tc.req); err != nil {
				t.Fatalf("resume: %v", err)
			}
			if f.startCount() != 1 {
				t.Fatalf("starts = %d, want 1", f.startCount())
			}
			got := f.lastStart()
			if got.Command != tc.wantCmd {
				t.Errorf("command = %q, want %q", got.Command, tc.wantCmd)
			}
			if !hasSubseq(got.Args, tc.wantSub) {
				t.Errorf("args = %q, want the resume invocation %q", got.Args, tc.wantSub)
			}
			// Review B1 regression: a resume invocation never rides the
			// steerable transport (grok agent stdio).
			for _, banned := range []string{"agent", "stdio"} {
				for _, arg := range got.Args {
					if arg == banned {
						t.Errorf("resume args %q carry the steerable launch token %q",
							got.Args, banned)
					}
				}
			}
			// Review B2 regression: one spelling of the continue option —
			// the bare -c never appears beside --continue (or at all).
			for _, arg := range got.Args {
				if arg == "-c" {
					t.Errorf("resume args %q carry the bare -c beside --continue", got.Args)
				}
			}
		})
	}
}

// A resume request that sets both Continue and Fork is ambiguous: the two
// paths name different sessions (review N7).
func TestAmbiguousResumeRefuses(t *testing.T) {
	f := &fakeAgent{}
	a := newFakeAdapter(f)
	_, err := a.Resume(context.Background(), nil,
		ResumeRequest{RunID: "run-1", Host: HostGrok, SessionID: "sess-123",
			Continue: true, Fork: true})
	if !errors.Is(err, ErrResumeAmbiguous) {
		t.Fatalf("err = %v, want ErrResumeAmbiguous", err)
	}
	if f.startCount() != 0 {
		t.Error("an ambiguous resume reached the node agent")
	}
}

// A resume by id without the session id captured at start refuses: nothing
// stands in for it.
func TestResumeWithoutSessionIDRefuses(t *testing.T) {
	f := &fakeAgent{}
	a := newFakeAdapter(f)
	_, err := a.Resume(context.Background(), nil,
		ResumeRequest{RunID: "run-1", Host: HostClaudeCode})
	if !errors.Is(err, ErrNoSessionID) {
		t.Fatalf("err = %v, want ErrNoSessionID", err)
	}
	if f.startCount() != 0 {
		t.Error("a refused resume reached the node agent")
	}
}

// A host whose matrix row names no steerable continue or fork path refuses
// the variant, with the why-text naming the AC-4 wording (review N6: the
// Claude Code row mentions -c/--continue only parenthetically on its
// interactive route).
func TestResumeVariantWithoutNamedPathRefuses(t *testing.T) {
	f := &fakeAgent{}
	a := newFakeAdapter(f)
	_, err := a.Resume(context.Background(), nil,
		ResumeRequest{RunID: "run-1", Host: HostClaudeCode, Continue: true})
	var ref Refusal
	if !errors.As(err, &ref) {
		t.Fatalf("err = %v, want a Refusal", err)
	}
	if !strings.Contains(ref.Cell.Citation, "parenthetically") {
		t.Errorf("continue refusal why-text = %q, want the tightened AC-4 wording",
			ref.Cell.Citation)
	}
	_, err = a.Resume(context.Background(), nil,
		ResumeRequest{RunID: "run-1", Host: HostOmp, SessionID: "s", Fork: true})
	if !errors.As(err, &ref) {
		t.Fatalf("err = %v, want a Refusal", err)
	}
	_, err = a.Resume(context.Background(), nil,
		ResumeRequest{RunID: "run-1", Host: HostClaudeCode, SessionID: "s", Fork: true})
	if !errors.As(err, &ref) {
		t.Fatalf("err = %v, want a Refusal", err)
	}
}

// AC3: the steer frame rides the host's control-message format and carries
// the correction as data.
func TestSteerEncodesTheHostFrame(t *testing.T) {
	cases := []struct {
		host     Host
		contains []string
	}{
		{HostClaudeCode, []string{`"type":"user"`, `"text":"Steer: include the exact token STEER-RECEIVED-47 in your final reply."`}},
		{HostGrok, []string{`"method":"session/prompt"`, `"sessionId":"sess-123"`, `"id":1`}},
		{HostOmp, []string{`"type":"steer"`, `"message":"Steer: include the exact token STEER-RECEIVED-47 in your final reply."`}},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(string(tc.host), func(t *testing.T) {
			f := &fakeAgent{}
			a := newFakeAdapter(f)
			if err := a.Steer(context.Background(), nil, steerReq(tc.host, "sess-123")); err != nil {
				t.Fatalf("steer: %v", err)
			}
			if len(f.frames) != 1 {
				t.Fatalf("steers = %d, want 1", len(f.frames))
			}
			for _, want := range tc.contains {
				if !strings.Contains(f.frames[0], want) {
					t.Errorf("frame %q lacks %q", f.frames[0], want)
				}
			}
		})
	}
}

// The ACP request id increments per steer of one run.
func TestSteerRequestIDsIncrement(t *testing.T) {
	f := &fakeAgent{}
	a := newFakeAdapter(f)
	for i := 0; i < 2; i++ {
		if err := a.Steer(context.Background(), nil, steerReq(HostGrok, "sess-123")); err != nil {
			t.Fatal(err)
		}
	}
	if len(f.frames) != 2 {
		t.Fatalf("steers = %d, want 2", len(f.frames))
	}
	for i, want := range []string{`"id":1`, `"id":2`} {
		if !strings.Contains(f.frames[i], want) {
			t.Errorf("frame %d = %q, want %q", i, f.frames[i], want)
		}
	}
}

// Untrusted steer text is marshalled as data: quotes, backslashes, and
// newlines survive as JSON string escapes and never break the frame.
func TestSteerMessageTravelsAsData(t *testing.T) {
	msg := `he said "run rm -rf /"; path C:\tmp; line1
line2`
	f := &fakeAgent{}
	a := newFakeAdapter(f)
	if err := a.Steer(context.Background(), nil,
		SteerRequest{RunID: "run-1", Host: HostOmp, Message: msg}); err != nil {
		t.Fatal(err)
	}
	var frame struct {
		Type    string `json:"type"`
		Message string `json:"message"`
	}
	if err := json.Unmarshal([]byte(f.frames[0]), &frame); err != nil {
		t.Fatalf("frame is not JSON: %v", err)
	}
	if frame.Message != msg {
		t.Errorf("message = %q, want %q", frame.Message, msg)
	}
}

// AC5/B7: the proven-name table gates every injection. A proven name rides
// the run environment; an unproven name fails closed before the agent sees
// the start.
func TestCredentialInjectionIsGatedByProvenNames(t *testing.T) {
	cases := []struct {
		name    string
		creds   []InjectCredential
		wantEnv string // the env entry the runner must carry
		wantErr error
	}{
		{"openai proven name",
			[]InjectCredential{{ProviderOpenAI, "sk-test-value-not-a-secret"}},
			"OPENAI_API_KEY=sk-test-value-not-a-secret", nil},
		{"anthropic proven name",
			[]InjectCredential{{ProviderAnthropic, "sk-test-value-not-a-secret"}},
			"ANTHROPIC_API_KEY=sk-test-value-not-a-secret", nil},
		{"xai proven name",
			[]InjectCredential{{ProviderXAI, "sk-test-value-not-a-secret"}},
			"XAI_API_KEY=sk-test-value-not-a-secret", nil},
		{"google proven name is GEMINI_API_KEY",
			[]InjectCredential{{ProviderGoogle, "sk-test-value-not-a-secret"}},
			"GEMINI_API_KEY=sk-test-value-not-a-secret", nil},
		{"groq proven name",
			[]InjectCredential{{ProviderGroq, "sk-test-value-not-a-secret"}},
			"GROQ_API_KEY=sk-test-value-not-a-secret", nil},
		{"llama.cpp has no proven env name",
			[]InjectCredential{{ProviderLlamaCpp, "sk-test-value-not-a-secret"}},
			"", ErrCredentialNameUnproven},
		{"unproven provider name fails closed",
			[]InjectCredential{{Provider("perplexity"), "sk-test-value-not-a-secret"}},
			"", ErrCredentialNameUnproven},
		{"empty value fails closed",
			[]InjectCredential{{ProviderOpenAI, "  "}},
			"", ErrCredentialNameUnproven},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			f := &fakeAgent{}
			a := newFakeAdapter(f)
			_, err := a.Start(context.Background(), nil, StartRequest{
				RunID: "run-1", Host: HostOmp, Credentials: tc.creds,
			})
			if tc.wantErr != nil {
				if !errors.Is(err, tc.wantErr) {
					t.Fatalf("err = %v, want %v", err, tc.wantErr)
				}
				if f.startCount() != 0 {
					t.Error("a refused start reached the node agent")
				}
				return
			}
			if err != nil {
				t.Fatalf("start: %v", err)
			}
			env := f.lastStart().Env
			if len(env) != 1 || env[0] != tc.wantEnv {
				t.Errorf("env = %q, want [%q]", env, tc.wantEnv)
			}
		})
	}
}

// The proven table carries exactly the B7 result: five proven names and the
// llama.cpp negative result.
func TestProvenNameTableMatchesTheB7Probe(t *testing.T) {
	names := ProvenNames()
	if len(names) != 5 {
		t.Fatalf("proven names = %d, want 5", len(names))
	}
	want := map[Provider]string{
		ProviderOpenAI:    "OPENAI_API_KEY",
		ProviderAnthropic: "ANTHROPIC_API_KEY",
		ProviderXAI:       "XAI_API_KEY",
		ProviderGoogle:    "GEMINI_API_KEY",
		ProviderGroq:      "GROQ_API_KEY",
	}
	for _, p := range names {
		if want[p.Provider] != p.EnvVar {
			t.Errorf("%s → %q, want %q", p.Provider, p.EnvVar, want[p.Provider])
		}
		if p.Evidence == "" {
			t.Errorf("%s carries no probe evidence", p.Provider)
		}
	}
	if _, ok := ProvenName(ProviderLlamaCpp); ok {
		t.Error("llama.cpp must not carry a proven env name — its key lives in the auth store")
	}
}

// hasSubseq reports whether want appears in got in order, contiguously.
func hasSubseq(got, want []string) bool {
	for i := 0; i+len(want) <= len(got); i++ {
		ok := true
		for j := range want {
			if got[i+j] != want[j] {
				ok = false
				break
			}
		}
		if ok {
			return true
		}
	}
	return false
}

// The integration seam: a real node agent over a real journal, with the
// native runner's child standing in for the host CLI. The steer the adapter
// hands over lands in the child's stdin at the agent's step boundary — the
// never-interrupts mechanic the six probes hold (AC3) — and every journal
// row it wrote is a machine kind, so the adapter added no event kind.
//
// The seam rewrites the launch command to a shell child: the adapter's host
// argv is asserted in TestResumeFollowsTheNamedPathPerHost, and no test may
// exec a host CLI.
type shAgent struct {
	A *agent.Agent
}

func (s *shAgent) Supervise(ctx context.Context, eng *journal.Engine,
	req agent.StartRequest, sessionOut io.Writer) error {
	req.Command, req.Args = "sh", []string{"-c",
		`printf '%s\n' '{"type":"session","version":3,"id":"01a1ddda-7a27"}'; read l; printf '%s' "$l" > "$CDT648_TEST_STEER_OUT"`}
	s.A.Runner = agent.Native{Stdout: sessionOut}
	return s.A.Supervise(ctx, eng, req)
}

func (s *shAgent) Stop(ctx context.Context, eng *journal.Engine,
	runID string, grace time.Duration) error {
	return s.A.Stop(ctx, eng, runID, grace)
}

func (s *shAgent) Steer(ctx context.Context, eng *journal.Engine,
	runID, message string) error {
	return s.A.Steer(ctx, eng, runID, message)
}

func (s *shAgent) Status(ctx context.Context, eng *journal.Engine,
	runID string) (agent.StatusReport, error) {
	return s.A.Status(ctx, eng, runID)
}

func TestSteerThroughTheAgentDeliversAtTheBoundary(t *testing.T) {
	eng := newEngine(t)
	out := filepath.Join(t.TempDir(), "steered.txt")
	t.Setenv("CDT648_TEST_STEER_OUT", out)
	a := &Adapter{Agent: &shAgent{A: agentNative(io.Discard)}}
	errc := make(chan error, 1)
	go func() {
		_, err := a.Start(context.Background(), eng, StartRequest{
			RunID: "run-steer", Host: HostOmp,
			Ticket: "CDT-648", Workflow: "orchestrate", Model: "sonnet",
		})
		errc <- err
	}()
	// The steer is handed over while the run runs: the delivery waits for
	// the boundary, it never interrupts a turn.
	deadline := time.Now().Add(10 * time.Second)
	for {
		if runReady("run-steer") && isRunning(t, eng, "run-steer") {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("run never started")
		}
		time.Sleep(25 * time.Millisecond)
	}
	if err := a.Steer(context.Background(), eng, SteerRequest{
		RunID: "run-steer", Host: HostOmp, SessionID: "01a1ddda-7a27",
		Message: steerReq(HostOmp, "").Message,
	}); err != nil {
		t.Fatalf("steer: %v", err)
	}
	if err := <-errc; err != nil {
		t.Fatalf("start: %v", err)
	}
	raw, err := os.ReadFile(out)
	if err != nil {
		t.Fatalf("steered output: %v", err)
	}
	var decoded struct {
		Type    string `json:"type"`
		Message string `json:"message"`
	}
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatalf("delivered frame is not JSON: %v (%q)", err, raw)
	}
	if decoded.Type != "steer" ||
		decoded.Message != steerReq(HostOmp, "").Message {
		t.Errorf("delivered frame = %q, want the omp steer frame", raw)
	}

	// The adapter added no event kind and no run state: every row the run
	// carries is one of the machine's closed kinds (CDT-642).
	rows, err := eng.Events(context.Background(), "run-steer")
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) == 0 {
		t.Fatal("the run carried no journal rows")
	}
	known := map[journal.Kind]bool{}
	for _, k := range journal.AllKinds {
		known[k] = true
	}
	for _, e := range rows {
		if !known[e.Kind] {
			t.Errorf("row kind %q is not a machine event kind", e.Kind)
		}
	}

	// Observe surfaces the agent's status reading plus the session id
	// captured at start (AC1, AC2). The runner's output drain finishes
	// shortly after the child exits — the agent is supervisable the moment
	// its process exits — so the capture settles within the drain window.
	deadline = time.Now().Add(5 * time.Second)
	var obs Observation
	for {
		obs, err = a.Observe(context.Background(), eng, "run-steer")
		if err != nil {
			t.Fatalf("observe: %v", err)
		}
		if obs.SessionID == "01a1ddda-7a27" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("session id = %q, want the id captured at start", obs.SessionID)
		}
		time.Sleep(25 * time.Millisecond)
	}
	if obs.Report.RunID != "run-steer" || obs.Report.State != "completed" {
		t.Errorf("report = %+v, want the completed run", obs.Report)
	}
}

// runReady reports whether the run has a recorded runner process: the
// handover the steer verb needs before it can record an intent.
func runReady(runID string) bool {
	raw, err := os.ReadFile(filepath.Join(os.Getenv("DEVTEAM_MROOT"),
		".claude", "runs", "agent", runID+".pid"))
	if err != nil {
		return false
	}
	var rec struct {
		RunnerPID int `json:"runner_pid"`
	}
	return json.Unmarshal(raw, &rec) == nil && rec.RunnerPID > 0
}

// isRunning reports whether the run's replayed state is running.
func isRunning(t *testing.T, eng *journal.Engine, runID string) bool {
	t.Helper()
	st, err := eng.RunState(context.Background(), runID)
	if err != nil {
		return false
	}
	return st.Status == journal.StatusRunning
}

// newEngine opens one journal file in a private directory and points the
// agent's node state at it (the agent_test.go seam).
func newEngine(t *testing.T) *journal.Engine {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("DEVTEAM_MROOT", dir)
	t.Setenv("DEVTEAM_RUN_DB", filepath.Join(dir, "run.db"))
	t.Setenv("DEVTEAM_STALL_LIMIT", "1")
	t.Setenv("DEVTEAM_RUNNER", "native")
	eng, err := journal.OpenPath(context.Background(), os.Getenv("DEVTEAM_RUN_DB"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = eng.Close() })
	return eng
}

// agentNative is an agent whose runner children write nowhere the test
// output reads.
func agentNative(out io.Writer) *agent.Agent {
	return &agent.Agent{Runner: agent.Native{Stdout: out, Stderr: io.Discard}}
}
