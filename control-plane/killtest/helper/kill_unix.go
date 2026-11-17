//go:build unix

package main

import (
	"fmt"
	"os"
	"syscall"
)

// selfKill dies by SIGKILL, at the caller's feet. The signal is not maskable
// and carries no handler, so nothing runs afterwards: no deferred Close, no
// WAL checkpoint, no flush. That is the death the kill test is about.
func selfKill(phase string) {
	fmt.Fprintf(os.Stderr, "helper: self-SIGKILL at %s (pid %d)\n", phase, os.Getpid())
	if err := syscall.Kill(os.Getpid(), syscall.SIGKILL); err != nil {
		fmt.Fprintln(os.Stderr, "helper: self-kill failed:", err)
		os.Exit(1)
	}
	// Unreachable: SIGKILL has already reaped this process.
	for {
	}
}
