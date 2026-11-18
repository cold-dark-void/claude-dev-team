package hostadapter

import "errors"

// Typed errors. Callers branch on these with errors.Is.
var (
	// ErrUnknownHost refuses a host name outside the closed matrix host set.
	ErrUnknownHost = errors.New("hostadapter: host is not in the capability matrix")

	// ErrUnsupportedCapability is the AC6 refusal: the matrix cell for this
	// host × capability names a verdict the adapter must not act on. The
	// refusal carries the cell's verdict and its citation — never a silent
	// no-op, never a guessed fallback.
	ErrUnsupportedCapability = errors.New("hostadapter: the capability matrix refuses this host and capability")

	// ErrNoSessionID refuses a resume whose session id is missing: every
	// resume flag needs the id captured at start (the matrix AC-4 named
	// path), and nothing stands in for it.
	ErrNoSessionID = errors.New("hostadapter: resume needs the session id captured at start")

	// ErrResumeAmbiguous refuses a resume request that sets both Continue
	// (newest session in the cwd) and Fork (resume by id into a new
	// session id): the two paths name different sessions.
	ErrResumeAmbiguous = errors.New("hostadapter: resume request is ambiguous")

	// ErrCredentialNameUnproven is the B7 fail-closed rule: the requested
	// env-var name is not a proven name for this provider, so the adapter
	// does not inject it. There is no fallback chain and no guess.
	ErrCredentialNameUnproven = errors.New("hostadapter: credential env-var name is not proven for this provider")
)
