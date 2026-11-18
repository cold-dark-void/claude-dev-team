package chief

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
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
//	GET  /v1/runs                        run status, from the journal (AC2)
//	GET  /v1/runs/{run}                  one run's status
//	GET  /v1/queue                       the C5 slot ledger (AC2)
//	GET  /v1/checks                      the per-run integrity reading (AC2)
//	GET  /v1/standup                     the stand-up report (AC2)
//	GET  /v1/halts                       named halts, reason + retry budget (AC5)
//	GET  /v1/graph                       the C3 lifecycle graph (AC3)
func (c *Chief) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/route", c.apiRoute)
	mux.HandleFunc("GET /v1/runs", c.apiRuns)
	mux.HandleFunc("GET /v1/runs/{runID}", c.apiRun)
	mux.HandleFunc("POST /v1/runs/{runID}/corrections", c.apiCorrect)
	mux.HandleFunc("GET /v1/queue", c.apiQueue)
	mux.HandleFunc("GET /v1/checks", c.apiChecks)
	mux.HandleFunc("GET /v1/standup", c.apiStandup)
	mux.HandleFunc("GET /v1/halts", c.apiHalts)
	mux.HandleFunc("GET /v1/graph", c.apiGraph)
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

// apiRuns serves GET /v1/runs.
func (c *Chief) apiRuns(w http.ResponseWriter, r *http.Request) {
	runs, err := c.Runs(r.Context())
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"runs": runs})
}

// apiRun serves GET /v1/runs/{runID}.
func (c *Chief) apiRun(w http.ResponseWriter, r *http.Request) {
	rs, err := c.Run(r.Context(), r.PathValue("runID"))
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, rs)
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
	case errors.Is(err, ErrRunExists), errors.Is(err, agent.ErrRunning),
		errors.Is(err, journal.ErrLeaseHeld), errors.Is(err, journal.ErrTerminalState),
		errors.Is(err, journal.ErrStaleToken), errors.Is(err, journal.ErrNotOwner):
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
