package agent

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
)

// EnvRunner overrides the runner selection outright, the $LINEAR_SYNC
// per-invocation override of skills/backlog/linear-gate.sh.
const EnvRunner = "DEVTEAM_RUNNER"

// configRelPath is the node config under $MROOT. It carries the per-node
// runner selection. .gitignore carries the same pattern: it is node state,
// never committed.
const configRelPath = ".claude/dev-team/node.json"

// RunnerType names a runner the node can select. The set is closed; the
// native runner is the first built and the default once a selection exists.
type RunnerType string

// RunnerNative is the native runner: the agent session is a process on the
// node's own OS, using the installed host CLIs and their logins.
const RunnerNative RunnerType = "native"

// KnownRunners is the closed selection set, in selection order.
var KnownRunners = []RunnerType{RunnerNative}

// ValidRunner reports whether t names a runner the node can run.
func ValidRunner(t RunnerType) bool {
	for _, v := range KnownRunners {
		if v == t {
			return true
		}
	}
	return false
}

// RunnerTypeList is the closed selection set, for a status surface.
func RunnerTypeList() []string {
	parts := make([]string, 0, len(KnownRunners))
	for _, r := range KnownRunners {
		parts = append(parts, string(r))
	}
	return parts
}

// Selection sources, reported by Config.Source.
const (
	SourceEnv      = "env"
	SourceNodeConf = "node.json"
	SourceNone     = "none"
)

// Config is the resolved node configuration. A Config with an empty Runner
// starts no run: the fail-closed rule.
type Config struct {
	// Runner is the selected runner, or "" when the node has none.
	Runner RunnerType
	// Command is the host CLI the runner spawns per run slot, when the node
	// config names one. The start verb's --command overrides it.
	Command string
	// Source is where the selection came from: env, node.json, or none.
	Source string
	// Raw is the selection value exactly as read, before the closed-set
	// check. A status surface shows it, so a typo is visible.
	Raw string
	// Path is the config file consulted.
	Path string
}

// Selected reports whether the node has a runner selection.
func (c Config) Selected() bool { return c.Runner != "" }

// Load resolves the node config: the runner key of
// $MROOT/.claude/dev-team/node.json, overridden by $DEVTEAM_RUNNER. It is the
// C7 pattern of skills/backlog/linear-gate.sh: first hit wins, one reader, and
// every unrecognised value resolves to no selection — a node that cannot name
// a runner starts no run. This package is the key's single reader. The
// command key of the config stands under either source: the env override
// selects the runner, the node config still names the host CLI.
func Load(getenv func(string) string) (Config, error) {
	if getenv == nil {
		getenv = os.Getenv
	}
	mroot, err := journal.MROOT()
	if err != nil {
		return Config{}, err
	}
	path := filepath.Join(mroot, configRelPath)

	cfg := Config{Path: path, Source: SourceNone}
	raw, cmd, err := readNodeConfig(path)
	if err != nil {
		// An unreadable or malformed config is a node with no selection, the
		// C7 ruling (junk resolves off). The raw text stays visible so a
		// status surface can show why.
		cfg.Raw = raw
		return cfg, nil
	}
	cfg.Raw, cfg.Command = raw, cmd
	if ValidRunner(RunnerType(raw)) {
		cfg.Runner = RunnerType(raw)
		cfg.Source = SourceNodeConf
	}

	if envRaw := strings.TrimSpace(getenv(EnvRunner)); envRaw != "" {
		cfg.Raw, cfg.Source = envRaw, SourceEnv
		if ValidRunner(RunnerType(envRaw)) {
			cfg.Runner = RunnerType(envRaw)
		} else {
			cfg.Runner = ""
		}
	}
	return cfg, nil
}

// nodeConfigFile is the closed config shape: the runner selection and the
// host CLI command. An unknown key is a broken file, not an extension (the
// spool.parseLine rule).
type nodeConfigFile struct {
	Runner  string `json:"runner"`
	Command string `json:"command"`
}

// readNodeConfig returns the runner value and the command of the node config.
// A missing file is a node with no selection, not an error. raw is the text
// that was read, for the status surface.
func readNodeConfig(path string) (raw, command string, err error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "", "", nil
		}
		return "", "", fmt.Errorf("agent: read %s: %w", path, err)
	}
	dec := json.NewDecoder(strings.NewReader(string(data)))
	dec.DisallowUnknownFields()
	var cfg nodeConfigFile
	if err := dec.Decode(&cfg); err != nil {
		return strings.TrimSpace(string(data)), "", fmt.Errorf("agent: %s is not a valid node config: %w", path, err)
	}
	return cfg.Runner, cfg.Command, nil
}
