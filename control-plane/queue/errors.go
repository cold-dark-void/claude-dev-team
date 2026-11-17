package queue

import "errors"

var (
	// ErrConfig is a bad operator setting: a concurrency or model_slots value
	// that is not a positive integer. The queue fails closed and does not
	// grant.
	ErrConfig = errors.New("queue: configuration error")

	// ErrInvalid is a malformed argument: an empty id, an empty runner name,
	// or an empty model string.
	ErrInvalid = errors.New("queue: invalid input")

	// ErrStaleToken is the C2 fencing refusal passed through: the caller
	// presents a token at or below the live one (journal.ErrStaleToken).
	ErrStaleToken = errors.New("queue: stale token")
)
