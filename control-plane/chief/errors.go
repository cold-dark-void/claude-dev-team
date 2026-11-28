package chief

import (
	"errors"
	"fmt"

	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
)

// The chief's typed errors.
var (
	// ErrInvalid is a malformed route, correction, or query.
	ErrInvalid = errors.New("chief: invalid input")
	// ErrUnknownRoute is a route kind outside the closed set.
	ErrUnknownRoute = errors.New("chief: unknown route kind")
	// ErrRunExists refuses a second route onto a run id the journal
	// already carries.
	ErrRunExists = errors.New("chief: a run already exists for the ticket")
	// ErrUnknownRun names a run the journal holds no row for.
	ErrUnknownRun = errors.New("chief: unknown run")
	// ErrNotSteerable refuses a correction whose run names no host the
	// chief can derive: the correction route rides the C6 steer path, and
	// the host is the frame's encoder. The API request carries the host
	// when the chief holds no record of the start.
	ErrNotSteerable = errors.New("chief: the run names no host for a correction")
	// ErrStartUnconfirmed answers a route whose start wait expired or
	// whose caller left: the start goroutine keeps going under the chief's
	// base context, so the run may have claimed after the answer — a
	// retried route then refuses with ErrRunExists.
	ErrStartUnconfirmed = errors.New("chief: the run's start was not confirmed")
	// ErrNoPluginRoot refuses a record root that is not a dev-team
	// checkout: chiefd is deployed on a dev-team checkout and the seams
	// exec the plugin's own CLIs from it — the failure is typed and
	// visible, never a silent one.
	ErrNoPluginRoot = errors.New("chief: the record root is not a dev-team checkout")
	// ErrIllegalAutopilot is an autopilot token the plugin's own flag
	// parser refuses (SPEC-045 M3): skills/autopilot/parse-flags.sh exits 64
	// on it. It chains to ErrInvalid for the same 400 answer.
	ErrIllegalAutopilot = fmt.Errorf("%w: illegal autopilot token", ErrInvalid)
	// ErrIllegalRunOption is a tier, council-tier, or max-loc value the
	// plugin's own flag parser refuses (SPEC-046 M3):
	// skills/autopilot/parse-flags.sh exits 64 on it.
	ErrIllegalRunOption = fmt.Errorf("%w: illegal run option", ErrInvalid)
	// ErrIllegalAdvisorModel is a --with-advisor model token the plugin's own
	// advisor parser refuses (SPEC-046 M3, SPEC-039 M37):
	// skills/advisor/parse-flags.sh exits 64 on it.
	ErrIllegalAdvisorModel = fmt.Errorf("%w: illegal advisor model token", ErrInvalid)
	// ErrIllegalOptionNumber is a concurrency or budget-cap value that is not
	// an integer of at least 1 (SPEC-046 M3): the CDT-573 grammar, cited not
	// copied, and the caps' positive-integer rule with no upper ceiling
	// (SPEC-033 N14).
	ErrIllegalOptionNumber = fmt.Errorf("%w: run option is not a positive integer",
		ErrInvalid)
	// ErrOrchestrateOnlyOption is a run option an epic id carries (SPEC-046
	// M4): /epic takes --worktree and --release alone, so the option does not
	// apply and the route refuses it by name.
	ErrOrchestrateOnlyOption = fmt.Errorf("%w: option does not apply to an epic id",
		ErrInvalid)
	// ErrNotStoppable refuses a stop of a run outside running and claimed
	// (SPEC-045 M4/AC7). The state is the reason, so it is a conflict.
	ErrNotStoppable = errors.New("chief: the run is not stoppable")
	// ErrNotResumable refuses a resume of a run that is not in a named halt
	// state, and one whose recorded host the matrix denies the resume route
	// for (SPEC-045 M5/AC7).
	ErrNotResumable = errors.New("chief: the run is not resumable")
	// ErrNotRetryable refuses a retry of a run outside failed and
	// halted:<reason> (SPEC-045 M6/AC7).
	ErrNotRetryable = errors.New("chief: the run is not retryable")
	// ErrResumeSpent refuses a resume whose halt reason has no retry budget
	// left. It chains the journal's own budget exhaustion, so the budget rule
	// stays the one replay enforces (SPEC-045 M5): halted:operator_halt
	// carries budget 0 and is never resumable — its recovery path is retry.
	ErrResumeSpent = fmt.Errorf("%w: the halt's retry budget is spent",
		journal.ErrBudgetExhausted)
	// ErrNoJournaledSession refuses a resume whose journal names no host
	// session id (SPEC-045 M5): the durable agent.session rows are the only
	// resume source, and the in-memory capture is never one.
	ErrNoJournaledSession = errors.New("chief: the run journals no host session id")
)
