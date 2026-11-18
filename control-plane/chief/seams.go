package chief

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/cold-dark-void/claude-dev-team/control-plane/run"
)

// TicketCreator is the ticket seam: the writer of the ticket record a route
// names. The real implementation is the plugin's own ticket CLI
// (skills/backlog/ticket.sh — the C7 verbs over the local backlog store, the
// ticket source of truth), never a second writer of the store.
type TicketCreator interface {
	Create(ctx context.Context, req TicketRequest) (TicketRecord, error)
}

// TicketRequest is one ticket record a route writes.
type TicketRequest struct {
	// Kind is one of the store's kinds: ticket, epic, or child.
	Kind string
	// Title is the ticket title; its slug identifies the record.
	Title string
	// Problem is the premise text.
	Problem string
	// EpicParent and ChildID ride the epic frontmatter of a child record.
	EpicParent string
	ChildID    string
}

// ticketCLI is the seam over skills/backlog/ticket.sh. The script is exec'd
// as argv — never sourced, never a shell string — and the record's slug is
// read from its own output ("Added: <path>").
type ticketCLI struct {
	// root is the plugin root the verbs are resolved from.
	root func() (string, error)
	// store is the backlog root the verbs write ($MROOT — the store lives
	// at the repo root, SPEC-009 § Backlog root rule).
	store func() (string, error)
}

// Create runs `ticket.sh create` for one record.
func (t *ticketCLI) Create(ctx context.Context, req TicketRequest) (TicketRecord, error) {
	rec := TicketRecord{Kind: req.Kind, Title: req.Title}
	if req.Title == "" {
		return rec, fmt.Errorf("%w: a ticket record needs a title", ErrInvalid)
	}
	script, err := t.pluginFile("skills/backlog/ticket.sh")
	if err != nil {
		return rec, err
	}
	store, err := t.store()
	if err != nil {
		return rec, err
	}
	args := []string{script, "create", "--root", store,
		"--title", req.Title, "--problem", req.Problem}
	switch req.Kind {
	case "ticket":
	case "epic":
		args = append(args, "--kind", "epic")
	case "child":
		args = append(args, "--kind", "child",
			"--epic-parent", req.EpicParent, "--child-id", req.ChildID)
	default:
		return rec, fmt.Errorf("%w: %q is not a ticket kind of the store", ErrInvalid, req.Kind)
	}
	out, err := bash(ctx, args)
	if err != nil {
		return rec, err
	}
	path, ok := addedPath(out)
	if !ok {
		return rec, fmt.Errorf("%w: ticket.sh create printed no record path for %q",
			ErrInvalid, req.Title)
	}
	rec.Path = path
	rec.Slug = strings.TrimSuffix(filepath.Base(path), ".md")
	return rec, nil
}

// addedPath reads the item path the ticket verbs print.
func addedPath(out string) (string, bool) {
	for _, line := range strings.Split(out, "\n") {
		if rest, found := strings.CutPrefix(line, "Added: "); found {
			rest = strings.TrimSpace(rest)
			if rest != "" {
				return rest, true
			}
		}
	}
	return "", false
}

// ModelResolver is the Model map seam (AC3): the model of a routed run
// resolves through skills/model-map/resolve-model.sh (SPEC-037). An empty
// resolution — no layer, an empty value, an internal name — is the Tier
// default; no flag exists for the model.
type ModelResolver interface {
	// Resolve returns the model and its source: "map" when a layer carried
	// the value, "tier-default" when the resolution was empty. The context
	// is the request's: an unbounded map resolution must stay cancellable.
	Resolve(ctx context.Context, agent string) (model, source string, err error)
}

// bashModelMap is the seam over skills/model-map/resolve-model.sh. The
// script is exec'd as argv; empty stdout is the Tier default
// (run.TierDefault), never a second copy of the map.
type bashModelMap struct {
	root func() (string, error)
}

// Resolve runs `resolve-model.sh <agent>` under the caller's context. An
// unnamed agent resolves directly to the Tier default: there is nothing
// for the map to read.
func (m *bashModelMap) Resolve(ctx context.Context, agent string) (string, string, error) {
	if strings.TrimSpace(agent) == "" {
		return tierDefaultModel(), "tier-default", nil
	}
	script, err := m.pluginFile("skills/model-map/resolve-model.sh")
	if err != nil {
		return "", "", err
	}
	out, err := bash(ctx, []string{script, agent})
	if err != nil {
		return "", "", err
	}
	if model := strings.TrimSpace(out); model != "" {
		return model, "map", nil
	}
	return tierDefaultModel(), "tier-default", nil
}

// tierDefaultModel is the fallback row the map resolution lands on: the run
// budget's own Tier default (control-plane/run/budget.go), not a chief copy.
func tierDefaultModel() string { return run.TierDefault.Model }

// pluginFile resolves one script of the plugin root. The seams exec the
// plugin's own CLIs — the ADR 0001 boundary — and never a copy of them.
func pluginFile(root func() (string, error), rel string) (string, error) {
	dir, err := root()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, rel), nil
}

func (t *ticketCLI) pluginFile(rel string) (string, error) {
	return pluginFile(t.root, rel)
}

func (m *bashModelMap) pluginFile(rel string) (string, error) {
	return pluginFile(m.root, rel)
}

func (p *intercomPhone) pluginFile(rel string) (string, error) {
	return pluginFile(p.root, rel)
}

// Phone is the operator channel for halts (AC5): the Intercom as the phone
// channel. The real implementation is the intercom CLI
// (skills/intercom/intercom.sh, SPEC-038) writing one outbox record the
// poller drains to Telegram.
type Phone interface {
	Page(ctx context.Context, runID, message string) error
}

// intercomPhone is the seam over skills/intercom/intercom.sh `send`. The
// message travels as one argv value; the record root and the bot token stay
// the CLI's own (INTERCOM_STATE_ROOT / the token funnel), inherited through
// the environment.
type intercomPhone struct {
	root func() (string, error)
	// sid pins the operator session; empty lets the CLI resolve its own
	// (INTERCOM_SID, then CLAUDE_SESSION_ID, then the newest transcript).
	sid string
}

// Page sends one halt page.
func (p *intercomPhone) Page(ctx context.Context, _, message string) error {
	script, err := p.pluginFile("skills/intercom/intercom.sh")
	if err != nil {
		return err
	}
	args := []string{script, "send"}
	if p.sid != "" {
		args = append(args, "--sid", p.sid)
	}
	args = append(args, message)
	_, err = bash(ctx, args)
	return err
}

// bash runs one bash argv and returns stdout. Untrusted text travels as
// argv, never as an assembled shell string (AGENTS.md § Code Conventions).
func bash(ctx context.Context, args []string) (string, error) {
	cmd := exec.CommandContext(ctx, "bash", args...)
	var out, errBuf bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errBuf
	if err := cmd.Run(); err != nil {
		detail := strings.TrimSpace(errBuf.String())
		if detail == "" {
			detail = strings.TrimSpace(out.String())
		}
		if detail != "" {
			return "", fmt.Errorf("chief: %s failed: %v: %s",
				filepath.Base(args[0]), err, detail)
		}
		return "", fmt.Errorf("chief: %s failed: %v", filepath.Base(args[0]), err)
	}
	return out.String(), nil
}

// jsonUnmarshal is the package's one decode helper.
func jsonUnmarshal(raw []byte, v any) error { return json.Unmarshal(raw, v) }
