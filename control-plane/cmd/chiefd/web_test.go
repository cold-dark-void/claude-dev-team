package main

import (
	"bytes"
	"context"
	"io"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/cold-dark-void/claude-dev-team/control-plane/agent"
	"github.com/cold-dark-void/claude-dev-team/control-plane/chief"
	"github.com/cold-dark-void/claude-dev-team/control-plane/hostadapter"
	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
	runmachine "github.com/cold-dark-void/claude-dev-team/control-plane/run"
	"github.com/cold-dark-void/claude-dev-team/control-plane/spool"
)

// The CDT-672 UI proofs (SPEC-045 AC4/AC5/AC6/AC9). The page is static
// HTML/CSS/JS served through go:embed — there is no build step and no JS
// runtime in the lane — so the board, the gating, and the read contract are
// proved against the shipped bytes, and the endpoints behind them are proved
// over real HTTP on the loopback handler.

// webAsset reads one embedded UI file.
func webAsset(t *testing.T, name string) string {
	t.Helper()
	raw, err := fs.ReadFile(webFS, "web/"+name)
	if err != nil {
		t.Fatalf("the embedded web UI lacks %s: %v", name, err)
	}
	return string(raw)
}

// mustMatch fails when the shipped bytes lose a structure the AC pins. The
// patterns are whitespace-tolerant so the page can be reformatted.
func mustMatch(t *testing.T, name, text string, re *regexp.Regexp) {
	t.Helper()
	if !re.MatchString(text) {
		t.Errorf("%s lacks the structure %s", name, re)
	}
}

var (
	// The board's main view and the container the ticket groups render into.
	boardMain = regexp.MustCompile(`(?s)<section id="board" class="main-view">.*?id="ticket-groups"`)
	// The detail pane is the secondary pane: it ships closed and opens on
	// select (SPEC-045 AC5).
	detailPane = regexp.MustCompile(`<aside id="detail" class="detail"[^>]*hidden[^>]*>`)
	// The grouping key is the journal's ticket field; the group is ordered by
	// the attempt the run id names (SPEC-045 M2/AC5).
	groupByTicket = regexp.MustCompile(`(?s)function runsByTicket\(rows\) \{.*r\.ticket \|\| r\.run_id.*`)
	byAttempt     = regexp.MustCompile(`\(a\.attempt \|\| 1\) - \(b\.attempt \|\| 1\)`)
	attemptBadge  = regexp.MustCompile("attempt\", `#\\$\\{r\\.attempt \\|\\| 1\\}`")
)

// AC5: the board groups runs by ticket and shows each run's attempt number,
// the board is the main view with the detail as a secondary pane, and one
// status color is defined per state.
func TestTheBoardGroupsRunsByTicketWithAttempts(t *testing.T) {
	page := webAsset(t, "index.html")
	js := webAsset(t, "app.js")
	css := webAsset(t, "style.css")

	mustMatch(t, "index.html", page, boardMain)
	mustMatch(t, "index.html", page, detailPane)
	mustMatch(t, "app.js", js, groupByTicket)
	mustMatch(t, "app.js", js, byAttempt)
	mustMatch(t, "app.js", js, attemptBadge)
	if !strings.Contains(js, "function groupBlock(ticket, list)") {
		t.Error("app.js renders no per-ticket group header")
	}
	if strings.Contains(page, `<table id="runs">`) {
		t.Error("the board is still a flat table: the ticket grouping did not land")
	}

	// One status color per state, defined once and read by the board, the
	// tally, and the detail badge through the --st token.
	for _, state := range []string{"claimed", "running", "halted", "completed", "failed"} {
		pattern := `\[data-state="` + state + `"\] \{ --st: var\(--st-` + state + `\); \}`
		if !regexp.MustCompile(pattern).MatchString(css) {
			t.Errorf("style.css defines no status color for the %q state", state)
		}
	}
	// A named halt is one state color and prints its reason as text, so the
	// state name is never carried by color alone.
	mustMatch(t, "app.js", js, regexp.MustCompile(`state\.startsWith\("halted:"\) \? "halted" : state`))

	// Readable at 375 px with no horizontal scroll: a narrow-viewport rule,
	// long tokens wrapped, and no fixed-width content wider than the page.
	mustMatch(t, "style.css", css, regexp.MustCompile(`@media \(max-width: 620px\)`))
	mustMatch(t, "style.css", css, regexp.MustCompile(`overflow-wrap: anywhere`))
	mustMatch(t, "style.css", css, regexp.MustCompile(`html \{ -webkit-text-size-adjust: 100%`))
	if strings.Contains(css, "overflow-x: hidden") {
		t.Error("style.css hides page overflow instead of preventing it")
	}
}

// AC7: Stop, Resume, and Retry are gated on the run's state, the Resume
// button is hidden entirely on a host with no resume route, and a refusal
// renders the API's verbatim typed message.
func TestActionButtonsGateOnStateAndCapability(t *testing.T) {
	page := webAsset(t, "index.html")
	js := webAsset(t, "app.js")

	for _, id := range []string{"action-stop", "action-resume", "action-retry"} {
		pattern := `<button id="` + id + `" type="button" hidden>`
		if !strings.Contains(page, pattern) {
			t.Errorf("index.html lacks the gated action button %q", pattern)
		}
	}

	// Stop is valid from running and claimed; Resume from a named halt and
	// only where the host has a resume route; Retry from failed and halted.
	mustMatch(t, "app.js", js,
		regexp.MustCompile(`verb: "stop", from: \["running", "claimed"\]`))
	mustMatch(t, "app.js", js,
		regexp.MustCompile(`verb: "resume", from: \["halted"\], needsResumeRoute: true`))
	mustMatch(t, "app.js", js,
		regexp.MustCompile(`verb: "retry", from: \["failed", "halted"\]`))

	// The capability verdict is the API's cell (the matrix's CapResume), never
	// a second copy in the page, and the gate hides the button on a host that
	// has no resume route.
	mustMatch(t, "app.js", js,
		regexp.MustCompile(`action\.needsResumeRoute && detail\.resume_supported !== true`))
	mustMatch(t, "app.js", js, regexp.MustCompile(`btn\.hidden = !allowed`))
	// An unsettled state disables (never hides) the buttons.
	mustMatch(t, "app.js", js,
		regexp.MustCompile(`(?s)if \(!state\) \{.*btn\.hidden = false;.*btn\.disabled = true`))

	// The refusal is rendered verbatim in the detail pane.
	mustMatch(t, "app.js", js,
		regexp.MustCompile(`Refused \(\$\{res\.status\}\): \$\{res\.data\.error`))
	mustMatch(t, "app.js", js, regexp.MustCompile(`function showRefusal\(message\)`))

	// The actions ride the API's verbs through one call site: the gate table's
	// verb names the endpoint, so a success and a refusal share one path.
	mustMatch(t, "app.js", js,
		regexp.MustCompile("postJSON\\(`/v1/runs/\\$\\{encodeURIComponent\\(runID\\)\\}/"+
			"\\$\\{action\\.verb\\}`"))
	for _, verb := range []string{"stop", "resume", "retry"} {
		if !regexp.MustCompile(`verb: "` + verb + `"`).MatchString(js) {
			t.Errorf("the action gate names no %q verb", verb)
		}
	}
}

var (
	// The route form's autopilot picker: a picker over the closed six-token
	// vocabulary of the plugin's flag parser (SPEC-045 AC4/M3).
	autopilotSelect = regexp.MustCompile(`(?s)<select id="route-autopilot">.*?</select>`)
	autopilotOption = regexp.MustCompile(`<option value="([a-z]+)"( selected)?>`)
	// The route form's model preview and the verb that fills it.
	modelPreview = regexp.MustCompile(`<p id="model-preview"[^>]*aria-live="polite"`)
	modelFetch   = regexp.MustCompile("getJSON\\(`/v1/model\\?agent=\\$\\{encodeURIComponent\\(agent\\)\\}`\\)")
	modelWiring  = regexp.MustCompile(`addEventListener\("change", showModelDefault\)`)
	modelFilled  = regexp.MustCompile(`\$\("model-preview"\)\.textContent`)
)

// AC4: the autopilot picker offers the plugin's closed six-token vocabulary,
// in the parser's order, and defaults to auto. The picker names the tokens
// the Chief's parser accepts — it adds no token of its own.
func TestTheRouteFormOffersTheAutopilotVocabulary(t *testing.T) {
	page := webAsset(t, "index.html")
	block := autopilotSelect.FindString(page)
	if block == "" {
		t.Fatal(`index.html ships no <select id="route-autopilot"> picker`)
	}
	want := []string{"bare", "auto", "patch", "minor", "major", "master"}
	var values []string
	selected := ""
	for _, m := range autopilotOption.FindAllStringSubmatch(block, -1) {
		values = append(values, m[1])
		if m[2] != "" {
			if selected != "" {
				t.Errorf("the autopilot picker marks both %q and %q selected", selected, m[1])
			}
			selected = m[1]
		}
	}
	if len(values) != len(want) {
		t.Fatalf("the autopilot picker offers %v, want %v", values, want)
	}
	for i, token := range want {
		if values[i] != token {
			t.Fatalf("the autopilot picker offers %v, want %v", values, want)
		}
	}
	if selected != "auto" {
		t.Errorf("the autopilot picker defaults to %q, want auto", selected)
	}
}

// AC4: the route form previews the Model map's default for the agent the form
// names. The preview element ships in the page and the script fills it from
// the /v1/model verb — never from a page-side copy of the Model map.
func TestTheRouteFormPreviewsTheModelMapDefault(t *testing.T) {
	page := webAsset(t, "index.html")
	js := webAsset(t, "app.js")

	mustMatch(t, "index.html", page, modelPreview)
	mustMatch(t, "app.js", js, modelFetch)
	mustMatch(t, "app.js", js, modelWiring)
	mustMatch(t, "app.js", js, modelFilled)
	for _, name := range []string{"sonnet", "opus", "haiku"} {
		if strings.Contains(js, name) {
			t.Errorf("app.js names the %q model: the Model map is the API's, not the page's", name)
		}
	}
}

// SPEC-045 M1: the command preview is a labeled approximation. The page cannot
// read a ticket record's kind, so the preview names both surfaces the ticket
// route can compose — /orchestrate and /epic — and the authoritative command
// is the route response's, shown in the route result.
// COPY-ACCEPTED: divergence-expected (the preview only).
func TestTheCommandPreviewIsALabeledApproximation(t *testing.T) {
	js := webAsset(t, "app.js")

	mustMatch(t, "app.js", js, regexp.MustCompile(`Preview \(approximate\)`))
	mustMatch(t, "app.js", js, regexp.MustCompile(`/orchestrate \$\{id\} \$\{flag\}`))
	mustMatch(t, "app.js", js, regexp.MustCompile(`/epic \$\{id\} \$\{flag\}`))
	if strings.Contains(js, "The Chief composes") {
		t.Error("the preview claims the Chief's authority: the route response names the command")
	}
	// The authoritative command is the prominent one: the route result prints
	// the command the route response names.
	mustMatch(t, "app.js", js,
		regexp.MustCompile("r\\.command \\? ` The Chief runs \\$\\{r\\.command\\}"))
}

// SPEC-046 AC4/AC6: the Advanced section of the ticket-route form, the
// composed-command preview it feeds, and the detail read that shows the
// options a run ran. The proofs are the shipped bytes again — the page has no
// build step and the lane has no JS runtime.
var (
	// The Advanced section: the run options of SPEC-046 M1, mounted on the
	// ticket route alone.
	advancedSection = regexp.MustCompile(`(?s)<details id="route-advanced".*?</details>`)
	inputTag        = regexp.MustCompile(`<input[^>]*id="([^"]+)"[^>]*>`)
)

// advancedFields maps every SPEC-046 M1 JSON name to the form control that
// carries it. The seven fields are six options: the two caps are one option
// (the run budget) carried by two inputs.
var advancedFields = map[string]string{
	"with_advisor":  "route-advisor",
	"tier":          "route-tier",
	"council_tier":  "route-council-tier",
	"max_loc":       "route-max-loc",
	"concurrency":   "route-concurrency",
	"wallclock_cap": "route-wallclock-cap",
	"iteration_cap": "route-iteration-cap",
}

// AC4: the ticket-route form gains an Advanced section that carries the six
// run options, every one empty by default, the caps numeric, the plugin
// vocabularies as client hints only, and the autopilot token outside it. The
// section rides the ticket route alone, and a retry still carries no options.
func TestTheAdvancedSectionCarriesTheSixOptions(t *testing.T) {
	page := webAsset(t, "index.html")
	js := webAsset(t, "app.js")
	css := webAsset(t, "style.css")

	section := advancedSection.FindString(page)
	if section == "" {
		t.Fatal(`index.html ships no <details id="route-advanced"> section`)
	}

	inputs := map[string]string{}
	for _, m := range inputTag.FindAllStringSubmatch(section, -1) {
		inputs[m[1]] = m[0]
	}
	for name, id := range advancedFields {
		tag, ok := inputs[id]
		if !ok {
			t.Errorf("the Advanced section ships no input %q for the %s field", id, name)
			continue
		}
		// Empty by default: an empty field composes nothing, so the shipped
		// control carries no value and asks for none.
		if strings.Contains(tag, "value=") {
			t.Errorf("%s ships a value: every Advanced field starts empty", id)
		}
		if strings.Contains(tag, "required") {
			t.Errorf("%s ships required: an empty option composes nothing", id)
		}
	}

	// The caps and the concurrency cap are numeric inputs.
	for _, id := range []string{"route-concurrency", "route-wallclock-cap", "route-iteration-cap"} {
		if !strings.Contains(inputs[id], `type="number"`) {
			t.Errorf("%s is not a numeric input", id)
		}
	}

	// The plugin vocabularies ride the section as hints: the words are there
	// for the operator to read, and the section validates nothing of its own —
	// SPEC-046 AC2 makes the Chief's seams the gate.
	for _, hint := range []string{"light", "standard", "full", "skip", "unbound"} {
		if !strings.Contains(section, hint) {
			t.Errorf("the Advanced section names no %q client hint", hint)
		}
	}
	for _, banned := range []string{`pattern="`, `min="`, `max="`, `step="`,
		`maxlength="`, "validity"} {
		if strings.Contains(section, banned) {
			t.Errorf("the Advanced section carries %q: the Chief's validation is the gate", banned)
		}
	}
	if strings.Contains(section, "required") {
		t.Error("the Advanced section marks a field required: an empty option composes nothing")
	}

	// The autopilot token stays a first-class field: its picker ships outside
	// the section, ahead of it.
	if strings.Contains(section, "route-autopilot") {
		t.Error("the autopilot picker moved inside the Advanced section")
	}
	if strings.Index(page, `id="route-autopilot"`) > strings.Index(page, `id="route-advanced"`) {
		t.Error("the autopilot picker no longer precedes the Advanced section")
	}

	// The section is mounted on the ticket route alone, and the route body
	// carries the seven M1 field names through the Advanced inputs.
	mustMatch(t, "app.js", js, regexp.MustCompile(`\$\("route-advanced"\)\.hidden = !ticket`))
	mustMatch(t, "app.js", js, regexp.MustCompile(`function advancedOptions\(\)`))
	mustMatch(t, "app.js", js, regexp.MustCompile(`opts\[name\] = advancedValue\(id\)`))
	mustMatch(t, "app.js", js, regexp.MustCompile(`Object\.assign\(body, advancedOptions\(\)\)`))

	// AC5: the retry keeps taking no option inputs — chiefd recomposes the
	// original run's options from the journaled trail.
	mustMatch(t, "app.js", js,
		regexp.MustCompile(`verb: "retry", from: \["failed", "halted"\], body: \{\} \}`))

	// A folded box stays folded: the page's own display rules sit above the
	// user agent's [hidden] rule, so style.css states the fold after them.
	mustMatch(t, "style.css", css, regexp.MustCompile(`\[hidden\] \{ display: none; \}`))
	if strings.Index(css, ".row { display: flex") > strings.Index(css, "[hidden] { display: none; }") {
		t.Error("style.css states the hidden fold before the .row display rule, so it loses")
	}
}

var (
	advancedTable = regexp.MustCompile(`(?s)const ADVANCED_INPUTS = \[.*?\];`)
	advancedFlags = regexp.MustCompile(`(?s)function advancedFlags\(\) \{.*?\n\}`)
	composedBody  = regexp.MustCompile(`(?s)function composedCommands\(\) \{.*?\n\}`)
)

// AC4: the command preview covers the Advanced options in the SPEC-046 M2
// pinned order — --tier, --council-tier, --max-loc, --concurrency N,
// --with-advisor[=<model>] — with --autopilot[=<token>] last. An empty field
// composes nothing, and the caps never enter the command line (M5).
func TestComposedCommandsPreviewCoversTheAdvancedOptions(t *testing.T) {
	js := webAsset(t, "app.js")

	// One table names the Advanced controls: the input id, the JSON name it
	// posts, and whether the value composes into the command.
	table := advancedTable.FindString(js)
	if table == "" {
		t.Fatal("app.js names no ADVANCED_INPUTS table")
	}
	rows := [][3]string{
		{"route-tier", "tier", "true"}, {"route-council-tier", "council_tier", "true"},
		{"route-max-loc", "max_loc", "true"}, {"route-concurrency", "concurrency", "true"},
		{"route-advisor", "with_advisor", "true"},
		{"route-wallclock-cap", "wallclock_cap", "false"},
		{"route-iteration-cap", "iteration_cap", "false"},
	}
	last := -1
	for _, row := range rows {
		i := strings.Index(table, row[0])
		if i < 0 {
			t.Fatalf("ADVANCED_INPUTS names no %q row", row[0])
		}
		pattern := `\[\s*"` + row[0] + `",\s*"` + row[1] + `",\s*` + row[2] + `\s*\]`
		if !regexp.MustCompile(pattern).MatchString(table) {
			t.Errorf("ADVANCED_INPUTS lacks the row [%q, %q, %s]", row[0], row[1], row[2])
		}
		if i < last {
			t.Errorf("ADVANCED_INPUTS lists %q out of the M1 order", row[0])
		}
		last = i
	}

	flags := advancedFlags.FindString(js)
	if flags == "" {
		t.Fatal("app.js composes no advancedFlags() preview helper")
	}
	// The M2 pinned order, read off the order the flags are composed in.
	last = -1
	for _, token := range []string{`--tier=`, `--council-tier=`, `--max-loc=`,
		"--concurrency ", `--with-advisor`} {
		i := strings.Index(flags, token)
		if i < 0 {
			t.Fatalf("the preview composes no %q token", token)
		}
		if i < last {
			t.Fatalf("the preview composes %q out of the SPEC-046 M2 order", token)
		}
		last = i
	}
	// --concurrency is the plugin's two-token space form, never --concurrency=.
	if strings.Contains(flags, "--concurrency=") {
		t.Error("the preview composes --concurrency=N: the plugin's grammar is the space form")
	}
	// Every flag is guarded: an empty field composes nothing.
	if n := strings.Count(flags, "if ("); n < len(rows)-2 {
		t.Errorf("advancedFlags() guards %d fields, want one guard per command option", n)
	}
	// SPEC-046 M5: the caps ride the run's environment, never the command.
	for _, banned := range []string{"wallclock", "iteration", "AUTOPILOT_"} {
		if strings.Contains(flags, banned) {
			t.Errorf("the preview composes %q into the command line: the caps ride the environment", banned)
		}
	}

	body := composedBody.FindString(js)
	if body == "" {
		t.Fatal("app.js has no composedCommands() preview function")
	}
	// The Advanced flags compose after the id and before the autopilot token,
	// which stays last. The no-options form keeps today's exact preview.
	mustMatch(t, "app.js", body, regexp.MustCompile(`const flag = token === "bare"`))
	mustMatch(t, "app.js", body,
		regexp.MustCompile(`/orchestrate \$\{id\} \$\{advanced\.join\(" "\)\} \$\{flag\}`))
	mustMatch(t, "app.js", body, regexp.MustCompile(`/orchestrate \$\{id\} \$\{flag\}`))
	mustMatch(t, "app.js", body, regexp.MustCompile(`/epic \$\{id\} \$\{flag\}`))
	if strings.Index(body, `advanced.join(" ")`) > strings.Index(body, `/orchestrate ${id} ${flag}`) {
		t.Error("the preview composes the autopilot token before the Advanced options")
	}
	// SPEC-046 M4: an epic id applies none of the Advanced options, so the
	// preview names the refusal for it rather than an /epic command.
	mustMatch(t, "app.js", body, regexp.MustCompile(`epic: ""`))
	mustMatch(t, "app.js", js, regexp.MustCompile(`Preview \(approximate\)`))
	// The preview follows the Advanced inputs as the operator types.
	mustMatch(t, "app.js", js,
		regexp.MustCompile(`if \(previews\) \$\(id\)\.addEventListener\("input", syncRouteForm\)`))
}

// AC6: the run detail shows the options the run used — the composed command
// the premise carries and the two caps in effect — read from the detail verb
// only. An unset cap renders the empty state, not a zero.
func TestTheDetailViewRendersTheComposedCommandAndCaps(t *testing.T) {
	js := webAsset(t, "app.js")

	mustMatch(t, "app.js", js, regexp.MustCompile(`\$\("detail-premise"\)\.textContent = d\.premise`))
	mustMatch(t, "app.js", js,
		regexp.MustCompile(`pair\(fields, "Wallclock cap", d\.wallclock_cap_s \?`))
	mustMatch(t, "app.js", js,
		regexp.MustCompile(`pair\(fields, "Iteration cap", d\.iteration_cap_s \?`))
	for _, id := range []string{"route-tier", "route-council-tier", "route-max-loc",
		"route-concurrency", "route-advisor", "route-wallclock-cap", "route-iteration-cap"} {
		if strings.Contains(js, `$("`+id+`").value = ""`) {
			t.Errorf("app.js clears %s after a route: an Advanced field keeps what the operator set", id)
		}
	}
}

var (
	fetchCall  = regexp.MustCompile(`(getJSON|postJSON)\(\s*["\x60]([^"\x60]+)["\x60]`)
	templateIn = regexp.MustCompile(`\$\{[^}]*\}`)
	// The placeholders the script interpolates, with the value the probe
	// substitutes: the output bound is an integer and the action verb comes
	// from the gate table, so the probe names one legal verb — the other two
	// are proved mounted in TestNewEndpointsServeOnTheLoopbackHandler.
	placeholders = strings.NewReplacer("${action.verb}", "stop", "${OUTPUT_LINES}", "200")
)

// AC9: every read the UI makes is a /v1 endpoint of chief.Handler. The fetch
// targets are lifted out of the shipped script and each one is proved to be
// a verb the Chief's own handler answers — no UI-only endpoint, no private
// state source, and no second interface.
func TestTheUIReadsOnlyTheAPI(t *testing.T) {
	js := webAsset(t, "app.js")
	page := webAsset(t, "index.html")

	calls := fetchCall.FindAllStringSubmatch(js, -1)
	if len(calls) < 12 {
		t.Fatalf("the script makes %d API calls, want the board, detail, "+
			"events, output, model, route, correction, and the three actions", len(calls))
	}
	type target struct{ method, path string }
	seen := map[target]bool{}
	for _, m := range calls {
		method := "GET"
		if m[1] == "postJSON" {
			method = "POST"
		}
		// A template placeholder names a value the browser fills in; the
		// probe substitutes a run id the journal does not hold, so the verb
		// is proved with no side effect.
		path := templateIn.ReplaceAllString(placeholders.Replace(m[2]), "ui-probe")
		if !strings.HasPrefix(m[2], "/v1/") {
			t.Errorf("the UI fetches %s, which is not a /v1 endpoint", m[2])
		}
		if strings.HasPrefix(m[2], "//") || strings.Contains(m[2], "://") {
			t.Errorf("the UI fetches the absolute target %q, which leaves loopback", m[2])
		}
		seen[target{method: method, path: path}] = true
	}
	if len(seen) < 12 {
		t.Errorf("the UI reads %d endpoints, want the whole v2 surface", len(seen))
	}
	if !seen[target{method: "POST", path: "/v1/runs/ui-probe/stop"}] {
		t.Error("the action buttons post no /v1/runs/{run}/<verb> endpoint")
	}

	// No private state source and no streaming channel: the page keeps the
	// one read source (AC9) and the bounded polling the spec allows.
	for _, banned := range []string{"localStorage", "sessionStorage", "document.cookie",
		"XMLHttpRequest", "WebSocket", "EventSource", "indexedDB"} {
		if strings.Contains(js, banned) || strings.Contains(page, banned) {
			t.Errorf("the UI uses %q: the state source must stay the API", banned)
		}
	}
	if regexp.MustCompile(`\.innerHTML`).MatchString(js + page) {
		t.Error("the UI assigns to innerHTML: untrusted text must land through textContent")
	}

	_, c := fixtureChief(t)
	srv := httptest.NewServer(withUI(c.Handler()))
	t.Cleanup(srv.Close)

	for target := range seen {
		res, err := probe(srv, target.method, target.path)
		if err != nil {
			t.Errorf("%s %s: %v", target.method, target.path, err)
			continue
		}
		// chief.Handler answers every verb with JSON; a path the handler does
		// not mount answers the mux's plain-text 404 page.
		if ct := res.Header.Get("Content-Type"); !strings.Contains(ct, "application/json") {
			t.Errorf("%s %s = %d %s, want a chief.Handler verb",
				target.method, target.path, res.StatusCode, ct)
		}
		res.Body.Close()
	}
}

// AC6: the new endpoints serve on the same loopback handler as the existing
// API and the page. The action verbs are probed on a run the journal does
// not hold, so the verbs are proved mounted with no run to act on.
func TestNewEndpointsServeOnTheLoopbackHandler(t *testing.T) {
	_, c := fixtureChief(t)
	srv := httptest.NewServer(withUI(c.Handler()))
	t.Cleanup(srv.Close)

	if err := loopbackOnly(strings.TrimPrefix(srv.URL, "http://")); err != nil {
		t.Fatalf("the fixture handler serves off loopback: %v", err)
	}

	// The page and the new reads ride the one port.
	page, body := getStatus(t, srv, "/")
	if page != http.StatusOK || !strings.Contains(body, "Run board") {
		t.Fatalf("GET / = %d %s, want the board page", page, body)
	}
	for _, tc := range []struct {
		path string
		want []string
	}{
		{"/v1/runs", []string{`"run_id":"CDT-672"`, `"ticket":"CDT-672"`, `"attempt":1`,
			`"resume_supported":`}},
		{"/v1/runs/CDT-672", []string{`"state":"running"`, `"attempt":1`}},
		{"/v1/runs/CDT-672/events", []string{`"events":`}},
		{"/v1/runs/CDT-672/output?lines=20", []string{`"lines":[]`, `"reason":`}},
		{"/v1/model?agent=ic5", []string{`"model":"sonnet"`, `"source":"map"`}},
		{"/v1/version", []string{`"version":"` + fixtureVersion + `"`,
			`"commit":"` + fixtureCommit + `"`}},
	} {
		status, got := getStatus(t, srv, tc.path)
		if status != http.StatusOK {
			t.Errorf("GET %s = %d %s, want 200", tc.path, status, got)
			continue
		}
		for _, want := range tc.want {
			if !strings.Contains(got, want) {
				t.Errorf("GET %s = %s, want %s", tc.path, got, want)
			}
		}
	}

	// The three action verbs are mounted: an unknown run answers the Chief's
	// typed refusal, never a page and never a UI-only route.
	for _, verb := range []string{"stop", "resume", "retry"} {
		path := "/v1/runs/ui-unknown/" + verb
		status, got := probeStatus(t, srv, "POST", path)
		if status != http.StatusNotFound || !strings.Contains(got, "chief: unknown run") {
			t.Errorf("POST %s = %d %s, want 404 with the typed refusal", path, status, got)
		}
	}
}

// AC3 (CDT-678): the page names the build it is talking to. The version and
// commit come from GET /v1/version — the one API, no UI-only endpoint, no
// build step — read once at load, and they land through textContent. A failed
// read renders no version at all rather than one the binary did not serve.
func TestThePageShowsTheServedBuildIdentity(t *testing.T) {
	page := webAsset(t, "index.html")
	js := webAsset(t, "app.js")

	mustMatch(t, "index.html", page, regexp.MustCompile(`<span id="build-version" class="muted"></span>`))
	mustMatch(t, "app.js", js, regexp.MustCompile(`getJSON\("/v1/version"\)`))
	mustMatch(t, "app.js", js, regexp.MustCompile(`\$\("build-version"\)\.textContent = `+"`chiefd"))
	// The failed read clears the line: the page renders no version, never a
	// guessed one.
	mustMatch(t, "app.js", js,
		regexp.MustCompile(`(?s)catch \(err\) \{.*\$\("build-version"\)\.textContent = "";`))
	// Read once at load — the identity is the binary's and cannot change under
	// a live board — so the page never polls it.
	mustMatch(t, "app.js", js, regexp.MustCompile(`(?m)^loadVersion\(\);$`))
	if strings.Contains(js, "setInterval(loadVersion") {
		t.Error("the page polls the version: the build identity is read once at load")
	}
	// The shipped markup carries no version of its own.
	if regexp.MustCompile(`<span id="build-version"[^>]*>[^<]+<`).MatchString(page) {
		t.Error("index.html ships a version: the page shows only what the API serves")
	}
}

// fixtureVersion and fixtureCommit stand in for the build stamp (SPEC-043
// CDT-678 AC1): the values -ldflags -X carries into a built chiefd. The
// fixture chief serves them, so the page's version line is proved against the
// API, never against a value the page carries.
const (
	fixtureVersion = "0.4.0-fixture"
	fixtureCommit  = "cafebabe"
)

// fixtureChief builds a Chief over a temp journal with one running run and a
// deterministic Model map, and never touches the host: the phase-event read is
// injected and no run is started, stopped, resumed, or retried.
func fixtureChief(t *testing.T) (*journal.Engine, *chief.Chief) {
	t.Helper()
	eng, err := journal.OpenPath(context.Background(),
		filepath.Join(t.TempDir(), "run.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = eng.Close() })

	m := runmachine.New(eng, "CDT-672")
	token, err := m.Claim(context.Background(), "ui-fixture", "CDT-672", "orchestrate", "sonnet")
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Start(context.Background(), "ui-fixture", token, "sonnet"); err != nil {
		t.Fatal(err)
	}

	c := chief.NewWithAdapter(eng, hostadapter.New(&agent.Agent{}),
		chief.WithModelMap(fixtureModels{}),
		chief.WithVersion(fixtureVersion, fixtureCommit),
		chief.WithPhaseEvents(func(context.Context, string) ([]spool.Record, error) {
			return nil, nil
		}))
	return eng, c
}

// fixtureModels is the Model map the UI reads through the preflight verb.
type fixtureModels struct{}

func (fixtureModels) Resolve(_ context.Context, agentName string) (string, string, error) {
	if agentName == "" {
		return "", "tier-default", nil
	}
	return "sonnet", "map", nil
}

// probe sends one request and returns the response; the caller closes it.
// A GET carries no body; a POST carries the empty object every verb accepts.
func probe(srv *httptest.Server, method, path string) (*http.Response, error) {
	var body io.Reader
	if method == http.MethodPost {
		body = strings.NewReader("{}")
	}
	req, err := http.NewRequest(method, srv.URL+path, body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	return http.DefaultClient.Do(req)
}

func probeStatus(t *testing.T, srv *httptest.Server, method, path string) (int, string) {
	t.Helper()
	res, err := probe(srv, method, path)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	raw, err := io.ReadAll(res.Body)
	if err != nil {
		t.Fatal(err)
	}
	return res.StatusCode, string(raw)
}

func getStatus(t *testing.T, srv *httptest.Server, path string) (int, string) {
	t.Helper()
	res, err := http.Get(srv.URL + path)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var out bytes.Buffer
	if _, err := out.ReadFrom(res.Body); err != nil {
		t.Fatal(err)
	}
	return res.StatusCode, out.String()
}
