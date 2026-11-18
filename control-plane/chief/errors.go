package chief

import "errors"

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
)
