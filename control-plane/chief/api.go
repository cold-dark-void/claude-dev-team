package chief

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"

	"github.com/cold-dark-void/claude-dev-team/control-plane/agent"
	"github.com/cold-dark-void/claude-dev-team/control-plane/hostadapter"
	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
)

// Handler returns the Chief's one interface (AC6): the HTTP API the web UI
// consumes. Every verb the Chief offers is here — there is no CLI verb and
// no second interface. The routes:
//
//	POST /v1/route                       route work to a Surface (AC1)
//	POST /v1/runs/{run}/corrections      a correction at the next step boundary (AC4)
//	POST /v1/runs/{run}/stop             the operator halt (SPEC-045 AC2)
//	POST /v1/runs/{run}/resume           the same-run continuation (AC2)
//	POST /v1/runs/{run}/retry            a new attempt of the ticket (AC2)
//	GET  /v1/runs                        run status, from the journal (AC2)
//	GET  /v1/runs/{run}                  one run's status
//	GET  /v1/runs/{run}/events           the run's journal rows (SPEC-045 AC3)
//	GET  /v1/runs/{run}/output?lines=N   the run's bounded transcript tail (AC3)
//	GET  /v1/model?agent=<agent>         the Model map preflight (AC4)
//	GET  /v1/queue                       the C5 slot ledger (AC2)
//	GET  /v1/checks                      the per-run integrity reading (AC2)
//	GET  /v1/standup                     the stand-up report (AC2)
//	GET  /v1/halts                       named halts, reason + retry budget (AC5)
//	GET  /v1/graph                       the C3 lifecycle graph (AC3)
//	GET  /v1/version                     the served build identity (SPEC-043 CDT-678 AC1)
func (c *Chief) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/route", c.apiRoute)
	mux.HandleFunc("GET /v1/runs", c.apiRuns)
	mux.HandleFunc("GET /v1/runs/{runID}", c.apiRun)
	mux.HandleFunc("GET /v1/runs/{runID}/events", c.apiRunEvents)
	mux.HandleFunc("GET /v1/runs/{runID}/output", c.apiRunOutput)
	mux.HandleFunc("POST /v1/runs/{runID}/corrections", c.apiCorrect)
	mux.HandleFunc("POST /v1/runs/{runID}/stop", c.apiStop)
	mux.HandleFunc("POST /v1/runs/{runID}/resume", c.apiResume)
	mux.HandleFunc("POST /v1/runs/{runID}/retry", c.apiRetry)
	mux.HandleFunc("GET /v1/model", c.apiModel)
	mux.HandleFunc("GET /v1/queue", c.apiQueue)
	mux.HandleFunc("GET /v1/checks", c.apiChecks)
	mux.HandleFunc("GET /v1/standup", c.apiStandup)
	mux.HandleFunc("GET /v1/halts", c.apiHalts)
	mux.HandleFunc("GET /v1/graph", c.apiGraph)
	mux.HandleFunc("GET /v1/version", c.apiVersion)
	return mux
}

// apiRoute serves POST /v1/route.
func (c *Chief) apiRoute(w http.ResponseWriter, r *http.Request) {
	var req RouteRequest
	if err := decodeBody(r, &req); err != nil {
		writeError(w, err)
		return
	}
	res, err := c.Route(r.Context(), req)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

// apiRuns serves GET /v1/runs: the board rows — the replayed status plus the
// detail fields the run detail view and the ticket grouping read (SPEC-045
// AC3/AC5).
func (c *Chief) apiRuns(w http.ResponseWriter, r *http.Request) {
	runs, err := c.Details(r.Context())
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"runs": runs})
}

// apiRun serves GET /v1/runs/{runID}.
func (c *Chief) apiRun(w http.ResponseWriter, r *http.Request) {
	rs, err := c.Detail(r.Context(), r.PathValue("runID"))
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, rs)
}

// apiRunEvents serves GET /v1/runs/{runID}/events: the run's full journal row
// list (SPEC-045 AC3). The rows are the closed event set as the journal
// carries them — the detail view renders them, it never re-derives state.
func (c *Chief) apiRunEvents(w http.ResponseWriter, r *http.Request) {
	runID := r.PathValue("runID")
	events, err := c.eng.Events(r.Context(), runID)
	if err != nil {
		writeError(w, err)
		return
	}
	if len(events) == 0 {
		writeError(w, fmt.Errorf("%w: %s", ErrUnknownRun, runID))
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"run_id": runID, "events": events})
}

// apiRunOutput serves GET /v1/runs/{runID}/output?lines=N: the bounded tail
// of the run's host transcript, read-only (SPEC-045 AC3). An absent
// transcript answers 200 with an empty tail and its reason.
func (c *Chief) apiRunOutput(w http.ResponseWriter, r *http.Request) {
	raw := r.URL.Query().Get("lines")
	lines := 0
	if raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil {
			writeError(w, fmt.Errorf("%w: lines must be an integer: %v", ErrInvalid, err))
			return
		}
		lines = n
	}
	tail, err := c.RunOutput(r.Context(), r.PathValue("runID"), lines)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, tail)
}

// apiModel serves GET /v1/model?agent=<agent>: the Model map preflight
// (SPEC-045 AC4) through the same ModelResolver seam a route rides — one copy
// of the map, and a read that writes nothing.
func (c *Chief) apiModel(w http.ResponseWriter, r *http.Request) {
	agentName := r.URL.Query().Get("agent")
	model, source, err := c.models.Resolve(r.Context(), agentName)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"agent": agentName, "model": model, "source": source,
	})
}

// apiCorrect serves POST /v1/runs/{runID}/corrections.
func (c *Chief) apiCorrect(w http.ResponseWriter, r *http.Request) {
	var req CorrectRequest
	if err := decodeBody(r, &req); err != nil {
		writeError(w, err)
		return
	}
	req.RunID = r.PathValue("runID")
	if err := c.Correct(r.Context(), req); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]any{"run_id": req.RunID,
		"delivered": "at the next step boundary"})
}

// apiStop serves POST /v1/runs/{runID}/stop: the operator halt (SPEC-045 AC2).
// 202 carries the halt the journal now names; a state that cannot take the
// action answers its typed refusal (AC7).
func (c *Chief) apiStop(w http.ResponseWriter, r *http.Request) {
	res, err := c.Stop(r.Context(), r.PathValue("runID"))
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, res)
}

// apiResume serves POST /v1/runs/{runID}/resume: the same-run continuation
// through the resume seam (SPEC-045 AC2). 202 names the run it resumed; the
// spent budget, the host with no resume route, and the journal with no session
// id each answer their own refusal (AC7).
func (c *Chief) apiResume(w http.ResponseWriter, r *http.Request) {
	res, err := c.Resume(r.Context(), r.PathValue("runID"))
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, res)
}

// apiRetry serves POST /v1/runs/{runID}/retry: a new run at the ticket's next
// attempt (SPEC-045 AC2). The body is optional — `{"host":"grok"}` names the
// host, empty derives it from the old run's start record — and the answer is
// the new run id.
func (c *Chief) apiRetry(w http.ResponseWriter, r *http.Request) {
	var req RetryRequest
	if err := decodeBody(r, &req); err != nil {
		writeError(w, err)
		return
	}
	res, err := c.Retry(r.Context(), r.PathValue("runID"), req.Host)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

// apiQueue serves GET /v1/queue.
func (c *Chief) apiQueue(w http.ResponseWriter, r *http.Request) {
	slots, err := c.Queue.Slots(r.Context())
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"slots": slots})
}

// apiChecks serves GET /v1/checks.
func (c *Chief) apiChecks(w http.ResponseWriter, r *http.Request) {
	checks, err := c.Checks(r.Context())
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"checks": checks})
}

// apiStandup serves GET /v1/standup.
func (c *Chief) apiStandup(w http.ResponseWriter, r *http.Request) {
	up, err := c.Standup(r.Context())
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, up)
}

// apiHalts serves GET /v1/halts. The read is pure: the pages are the watch
// loop's work, never a side effect of a GET.
func (c *Chief) apiHalts(w http.ResponseWriter, r *http.Request) {
	halts, err := c.Halts(r.Context())
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"halts": halts})
}

// apiGraph serves GET /v1/graph: the C3 lifecycle graph the board draws —
// the validated graph data of control-plane/lifecycle, from the committed
// file, never a second copy and never a rendering. The run's current
// position rides the run rows (the state field names the run-state vertex);
// the board marks it on the drawing.
func (c *Chief) apiGraph(w http.ResponseWriter, r *http.Request) {
	g, err := c.Graph()
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, g)
}

// apiVersion serves GET /v1/version: the identity stamped into this binary at
// build time (SPEC-043 CDT-678 AC1). The values are the binary's own, never a
// file read, so the answer names the code that is running — what the verify
// row and the web UI show. An unstamped binary answers DefaultVersion ("dev")
// and an empty commit. The read writes nothing.
func (c *Chief) apiVersion(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"version": c.version, "commit": c.commit,
	})
}

// decodeBody reads one JSON request body. An empty body is an empty object,
// so a query verb's callers need no body at all.
func decodeBody(r *http.Request, v any) error {
	if r.Body == nil {
		return nil
	}
	raw, err := io.ReadAll(r.Body)
	if err != nil {
		return err
	}
	if len(bytes.TrimSpace(raw)) == 0 {
		return nil
	}
	if err := json.Unmarshal(raw, v); err != nil {
		return fmt.Errorf("%w: request body is not JSON: %v", ErrInvalid, err)
	}
	return nil
}

// writeJSON writes one JSON response.
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// statusOf maps the typed errors to the API's status codes.
func statusOf(err error) int {
	switch {
	case errors.Is(err, ErrInvalid), errors.Is(err, ErrUnknownRoute),
		errors.Is(err, hostadapter.ErrUnknownHost),
		errors.Is(err, hostadapter.ErrUnsupportedCapability),
		errors.Is(err, journal.ErrInvalid):
		return http.StatusBadRequest
	case errors.Is(err, ErrUnknownRun), errors.Is(err, ErrNotSteerable):
		return http.StatusNotFound
	case errors.Is(err, ErrStartUnconfirmed):
		return http.StatusGatewayTimeout
	// The lease and terminal-state refusals and the operator actions' state
	// refusals (SPEC-045 AC7) are all conflicts with the run's current state.
	// The ticket route's refusals are not listed here: they chain to
	// ErrInvalid above, which is their one mapping.
	case errors.Is(err, ErrRunExists), errors.Is(err, agent.ErrRunning),
		errors.Is(err, journal.ErrLeaseHeld), errors.Is(err, journal.ErrTerminalState),
		errors.Is(err, journal.ErrStaleToken), errors.Is(err, journal.ErrNotOwner),
		errors.Is(err, ErrNotStoppable), errors.Is(err, ErrNotResumable),
		errors.Is(err, ErrNotRetryable), errors.Is(err, ErrNoJournaledSession),
		errors.Is(err, journal.ErrBudgetExhausted):
		return http.StatusConflict
	default:
		return http.StatusInternalServerError
	}
}

// writeError writes one JSON error response. The typed errors name their
// cause; the message carries no more than the error already does.
func writeError(w http.ResponseWriter, err error) {
	writeJSON(w, statusOf(err), map[string]any{
		"error": strings.TrimSpace(err.Error()),
	})
}
