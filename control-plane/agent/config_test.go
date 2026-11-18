package agent

import (
	"os"
	"path/filepath"
	"testing"
)

// AC: runner selection is a per-node setting; a node with no selection starts
// no run (fail-closed). The resolution is the C7 pattern of
// skills/backlog/linear-gate.sh: the runner key of node.json first,
// $DEVTEAM_RUNNER overriding it, then none — first hit wins, one reader, and
// every unrecognised value resolves to no selection.
func TestResolveRunnerSelection(t *testing.T) {
	cases := []struct {
		name    string
		env     string
		conf    string
		noFile  bool
		wantRun RunnerType
		wantSrc string
		wantCmd string
	}{
		{"env selects native", "native", "", true, RunnerNative, SourceEnv, ""},
		{"env selects container (CDT-647)", "container", "", true, RunnerContainer, SourceEnv, ""},
		{"env junk resolves to no selection (the C7 ruling)", "nativ", "", true, "", SourceEnv, ""},
		{"env none resolves to no selection", "none", "", true, "", SourceEnv, ""},
		{"config selects native", "", `{"runner":"native","command":"claude"}`, false, RunnerNative, SourceNodeConf, "claude"},
		{"config selects container", "", `{"runner":"container","command":"claude"}`, false, RunnerContainer, SourceNodeConf, "claude"},
		{"config junk resolves to no selection", "", `{"runner":"docker"}`, false, "", SourceNone, ""},
		{"config invalid JSON resolves to no selection", "", `{oops`, false, "", SourceNone, ""},
		{"config unknown key resolves to no selection", "", `{"runner":"native","extra":1}`, false, "", SourceNone, ""},
		{"missing file is no selection", "", "", true, "", SourceNone, ""},
		{"env wins over the config", "native", `{"runner":"native","command":"omp"}`, false, RunnerNative, SourceEnv, "omp"},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			t.Setenv("DEVTEAM_MROOT", dir)
			if !tc.noFile {
				path := filepath.Join(dir, ".claude", "dev-team", "node.json")
				if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(path, []byte(tc.conf), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			t.Setenv(EnvRunner, tc.env)
			cfg, err := Load(nil)
			if err != nil {
				t.Fatalf("Load: %v", err)
			}
			if cfg.Runner != tc.wantRun {
				t.Errorf("runner = %q, want %q", cfg.Runner, tc.wantRun)
			}
			if cfg.Source != tc.wantSrc {
				t.Errorf("source = %q, want %q", cfg.Source, tc.wantSrc)
			}
			if cfg.Command != tc.wantCmd {
				t.Errorf("command = %q, want %q", cfg.Command, tc.wantCmd)
			}
			if cfg.Selected() != (tc.wantRun != "") {
				t.Errorf("Selected() = %v for runner %q", cfg.Selected(), cfg.Runner)
			}
		})
	}
}

// AC: the closed selection set. The native runner is the first built and the
// default once selected; the container runner (CDT-647) rides the same
// fail-closed resolution; no other name is a runner.
func TestKnownRunnersAreClosedAndNativeFirst(t *testing.T) {
	if len(KnownRunners) == 0 || KnownRunners[0] != RunnerNative {
		t.Fatalf("KnownRunners = %v, want native first", KnownRunners)
	}
	for _, r := range KnownRunners {
		if !ValidRunner(r) {
			t.Errorf("known runner %q is not valid", r)
		}
	}
	if !ValidRunner(RunnerContainer) {
		t.Errorf("the container runner %q is not in the closed set", RunnerContainer)
	}
	if ValidRunner("docker") {
		t.Error(`"docker" validated as a runner; the contract never names one`)
	}
}
