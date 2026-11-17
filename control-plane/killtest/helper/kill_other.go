//go:build !unix

package main

import (
	"errors"
	"fmt"
	"os"
)

// selfKill refuses to run on a platform without SIGKILL. The kill test is a
// POSIX-death test; it must not silently degrade into a graceful exit.
func selfKill(string) {
	fmt.Fprintln(os.Stderr, "helper:", errors.New("selfKill: SIGKILL needs a unix build"))
	os.Exit(1)
}
