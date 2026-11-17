package queue

import (
	"fmt"
)

// Request is one runner a workflow offers to the queue: the run it works on,
// the runner identity, and the model string the map resolved for its agent
// (skills/model-map/resolve-model.sh, SPEC-037).
type Request struct {
	// RunID is the run the runner works on. It must match the run whose lease
	// backs the fencing token the caller presents.
	RunID string
	// Runner names the runner: the slot is one runner, one process or one
	// container (AC1). A node runs at most one runner with a given name.
	Runner string
	// Model is the resolved model string — a tier token or a full vendor
	// slug. It feeds the match key derivation (§ the match key).
	Model string
}

func (r Request) validate() error {
	if r.RunID == "" {
		return fmt.Errorf("%w: run_id is required", ErrInvalid)
	}
	if r.Runner == "" {
		return fmt.Errorf("%w: runner is required", ErrInvalid)
	}
	if r.Model == "" {
		return fmt.Errorf("%w: model is required", ErrInvalid)
	}
	return nil
}

// grantIntent is the slot.grant intent payload.
type grantIntent struct {
	Runner string `json:"runner"`
	Model  string `json:"model"`
	// GrantKey is the match key the cap lookup resolved (§ the match key).
	GrantKey string `json:"grant_key"`
	// GrantedModel caps are independent, so the intent names the per-model
	// cap that bound it; 0 means unbounded: no map row for the match key
	// and no "tier-default" row.
	ModelCap int `json:"model_cap,omitempty"`
	// WaitKey names a wait pair this grant closes, when the runner waited
	// first (§ the wait-close rule).
	WaitKey string `json:"wait_key,omitempty"`
}

// grantOutcome is the slot.grant outcome payload. It is always live: the
// append already proved both caps admitted the grant inside the same
// transaction.
type grantOutcome struct {
	Runner string `json:"runner"`
}

// waitIntent is the slot.wait intent payload.
type waitIntent struct {
	Runner string `json:"runner"`
	Model  string `json:"model"`
	// GrantKey is the match key of the model cap the runner waits on.
	GrantKey string `json:"grant_key"`
}

// waitOutcome is the slot.wait outcome payload (§ the wait-close rule).
type waitOutcome struct {
	Runner string `json:"runner"`
	// Granted is true when a later grant closed the wait: the runner got its
	// slot.
	Granted bool `json:"granted"`
	// Released is true when a release closed the wait: the runner left the
	// queue before it was granted.
	Released bool `json:"released"`
}

// releaseIntent is the slot.release intent payload.
type releaseIntent struct {
	Runner string `json:"runner"`
	Model  string `json:"model"`
}

// releaseOutcome is the slot.release outcome payload.
type releaseOutcome struct {
	Runner string `json:"runner"`
}
