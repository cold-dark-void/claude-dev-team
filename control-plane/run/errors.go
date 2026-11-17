package run

import "errors"

// ErrConfig is a bad operator setting (a non-numeric stall limit, an unknown
// halt reason). The service reports it and does not start the run.
var ErrConfig = errors.New("run: configuration error")
