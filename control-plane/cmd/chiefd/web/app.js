// chiefd web UI — everything on this page rides the Chief's /v1 endpoints.
// No other endpoint exists for the UI alone, and no terminal tab is needed.
"use strict";

const $ = (id) => document.getElementById(id);

async function getJSON(path) {
  const res = await fetch(path);
  if (!res.ok) throw new Error(`${path}: ${res.status}`);
  return res.json();
}

async function postJSON(path, body) {
  const res = await fetch(path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const data = await res.json().catch(() => ({}));
  return { ok: res.ok, status: res.status, data };
}

// Untrusted text never becomes markup: every dynamic string lands through
// textContent, never innerHTML.
function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function pair(list, label, value) {
  const box = el("div");
  box.appendChild(el("dt", "", label));
  box.appendChild(el("dd", "", value === "" || value === undefined || value === null ? "—" : String(value)));
  list.appendChild(box);
}

function item(list, text) {
  list.appendChild(el("li", "", text));
}

function say(who, text) {
  const li = el("li", who === "you" ? "you" : "chief");
  li.appendChild(el("span", "who", who === "you" ? "You" : "Chief"));
  li.appendChild(document.createTextNode(text));
  $("thread").appendChild(li);
  $("thread").scrollTop = $("thread").scrollHeight;
}

// stateKey folds a lifecycle state to the one token that owns its color:
// a named halt (halted:<reason>) is one state, so it takes the halt color
// and prints its reason as text. Color is never the only signal.
function stateKey(state) {
  if (!state) return "new";
  return state.startsWith("halted:") ? "halted" : state;
}

const TERMINAL_STATES = ["completed", "failed"];

// --- The run board ---------------------------------------------------
// The board is the main view: runs grouped by ticket, each run shown as its
// attempt (SPEC-045 AC5). Every field is the API's own (GET /v1/runs).

let runs = [];
let selectedRun = "";

const STATE_ORDER = ["halted", "failed", "running", "claimed", "new", "completed"];

// stateRank is the board's one urgency rank: the position in STATE_ORDER, and
// a state the order does not name ranks last.
function stateRank(state) {
  const i = STATE_ORDER.indexOf(state);
  return i === -1 ? STATE_ORDER.length : i;
}

async function refreshBoard() {
  try {
    const [runsDoc, haltsDoc, queueDoc, checksDoc] = await Promise.all([
      getJSON("/v1/runs"), getJSON("/v1/halts"),
      getJSON("/v1/queue"), getJSON("/v1/checks"),
    ]);
    runs = runsDoc.runs || [];
    renderGroups(runs);
    renderTally(runs);
    renderList($("halts"), haltsDoc.halts || [], haltLine);
    renderList($("queue"), queueDoc.slots || [], slotLine);
    renderList($("checks"), checksDoc.checks || [], checkLine);
    syncRunPickers(runs);
    markGraph();
    refreshSelected();
    $("conn").dataset.state = "live";
    $("conn-text").textContent = "live";
  } catch (err) {
    $("conn").dataset.state = "down";
    $("conn-text").textContent = "the Chief is unreachable: " + err.message;
  }
}

// runsByTicket groups the board rows by the ticket the journal names
// (SPEC-045 M2: the run's ticket field is the grouping key, and the run id
// carries its attempt). A run with no ticket groups under its own id.
function runsByTicket(rows) {
  const groups = new Map();
  for (const r of rows) {
    const key = r.ticket || r.run_id;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(r);
  }
  for (const list of groups.values()) {
    list.sort((a, b) => (a.attempt || 1) - (b.attempt || 1)
      || String(a.run_id).localeCompare(String(b.run_id)));
  }
  // An operator reads a control board by urgency: a group that needs a
  // decision leads, a finished group falls to the bottom.
  return [...groups.entries()].sort((x, y) =>
    (groupPriority(x[1]) - groupPriority(y[1])) || x[0].localeCompare(y[0]));
}

function groupPriority(list) {
  return list.reduce((acc, r) => Math.min(acc, stateRank(stateKey(r.state))),
    STATE_ORDER.length);
}

function renderGroups(rows) {
  const host = $("ticket-groups");
  host.replaceChildren();
  const groups = runsByTicket(rows);
  $("board-empty").hidden = groups.length > 0;
  for (const [ticket, list] of groups) host.appendChild(groupBlock(ticket, list));
}

function groupBlock(ticket, list) {
  const group = el("section", "group");
  const head = el("div", "group-head");
  head.appendChild(el("h3", "group-ticket", ticket));
  head.appendChild(el("span", "group-count",
    list.length === 1 ? "attempt 1" : `${list.length} attempts`));
  const spread = el("span", "spread");
  spread.title = list.map((r) => `${r.run_id}: ${r.state || "new"}`).join("\n");
  for (const r of list) {
    const seg = el("i", "spread-seg");
    seg.dataset.state = stateKey(r.state);
    spread.appendChild(seg);
  }
  head.appendChild(spread);
  group.appendChild(head);

  const cards = el("div", "group-cards");
  for (const r of list) cards.appendChild(runCard(r));
  group.appendChild(cards);
  return group;
}

function runCard(r) {
  const card = el("article", "run-card");
  card.dataset.state = stateKey(r.state);
  card.dataset.run = r.run_id;
  if (r.run_id === selectedRun) card.dataset.selected = "true";

  const top = el("div", "run-top");
  top.appendChild(el("span", "attempt", `#${r.attempt || 1}`));
  const pick = el("button", "run-pick", r.run_id);
  pick.type = "button";
  pick.dataset.run = r.run_id;
  pick.setAttribute("aria-controls", "detail");
  top.appendChild(pick);
  const badge = el("p", "badge", r.state || "new");
  badge.dataset.state = stateKey(r.state);
  top.appendChild(badge);
  card.appendChild(top);

  const meta = el("dl", "meta");
  pair(meta, "Phase", r.phase);
  pair(meta, "Halt", r.halt ? r.halt.reason : "");
  pair(meta, "Retry budget", r.halt ? `${r.halt.retry_remaining}/${r.halt.retry_budget}` : "");
  pair(meta, "Queue", r.queue_position ? `#${r.queue_position} waiting` : r.slot);
  pair(meta, "Node", r.owner);
  pair(meta, "Runner", r.runner_type);
  pair(meta, "Workflow", r.workflow);
  pair(meta, "Host", r.host);
  pair(meta, "Model", r.model);
  card.appendChild(meta);
  return card;
}

function renderTally(rows) {
  const counts = new Map();
  for (const r of rows) {
    const key = stateKey(r.state);
    counts.set(key, (counts.get(key) || 0) + 1);
  }
  const order = [...counts.keys()].sort((a, b) => stateRank(a) - stateRank(b));
  const list = $("tally");
  list.replaceChildren();
  for (const key of order) {
    const li = el("li");
    li.dataset.state = key;
    li.appendChild(el("span", "n", String(counts.get(key))));
    li.appendChild(el("span", "label", key));
    list.appendChild(li);
  }
}

function haltLine(h) {
  return `${h.run_id}: ${h.reason} — ${h.detail || ""} retry ${h.retry_remaining}/${h.retry_budget}` +
    (h.notified ? " (paged)" : " (not paged)");
}

function slotLine(s) {
  return `${s.run_id} · ${s.runner} · ${s.state}` +
    (s.model ? ` · ${s.model}` : "") +
    (s.model_cap ? ` · cap ${s.model_cap}` : "");
}

function checkLine(c) {
  const bits = [c.state];
  if (c.stalled) bits.push("STALLED");
  if (c.pending_effects && c.pending_effects.length) {
    bits.push(`pending: ${c.pending_effects.join(", ")}`);
  }
  bits.push(`${c.repairs} repairs`);
  return `${c.run_id}: ${bits.join(" · ")}`;
}

function renderList(list, rows, line) {
  list.replaceChildren();
  if (!rows.length) item(list, "— none —");
  for (const row of rows) item(list, line(row));
}

function runLabel(r) {
  return `#${r.attempt || 1} ${r.run_id} — ${r.state || "new"}`;
}

function syncRunPickers(rows) {
  for (const id of ["correction-run", "graph-run"]) {
    const picker = $(id);
    const current = picker.value;
    picker.replaceChildren();
    if (!rows.length) {
      picker.appendChild(el("option", "", "no runs"));
      continue;
    }
    for (const r of rows) {
      const opt = document.createElement("option");
      opt.value = r.run_id;
      opt.textContent = runLabel(r);
      picker.appendChild(opt);
    }
    if ([...picker.options].some((o) => o.value === current)) picker.value = current;
  }
}

// --- The run detail pane -------------------------------------------
// Every field is a read of the API: GET /v1/runs/{run} (the detail row),
// GET /v1/runs/{run}/events (the journal rows), and
// GET /v1/runs/{run}/output (the bounded transcript tail, polled at ~2 s
// while the pane is open and the run is not terminal).

const OUTPUT_LINES = 200;
const OUTPUT_POLL_MS = 2000;
let detailRun = null;
let outputTimer = null;

function markSelected() {
  for (const card of $("ticket-groups").querySelectorAll(".run-card")) {
    if (card.dataset.run === selectedRun) card.dataset.selected = "true";
    else delete card.dataset.selected;
  }
}

async function openDetail(runID) {
  selectedRun = runID;
  detailRun = null;
  $("detail").hidden = false;
  $("detail-run").textContent = runID;
  $("detail-badge").textContent = "—";
  $("detail-badge").dataset.state = "unknown";
  hideRefusal();
  gateActions(null);
  $("detail-premise").textContent = "reading…";
  $("detail-fields").replaceChildren();
  $("detail-events").replaceChildren();
  $("detail-output").textContent = "";
  $("output-meta").textContent = "";
  markSelected();
  $("detail").scrollIntoView({ block: "nearest" });
  await refreshSelected();
  await loadEvents(runID);
  await pollOutput(runID);
  startOutputPoll();
}

function closeDetail() {
  selectedRun = "";
  detailRun = null;
  stopOutputPoll();
  $("detail").hidden = true;
  markSelected();
}

// refreshSelected re-reads the selected run on the board's cadence so the
// pane, its colors, and its buttons follow the journal.
async function refreshSelected() {
  if (!$("detail").hidden && selectedRun) {
    try {
      renderDetail(await getJSON(`/v1/runs/${encodeURIComponent(selectedRun)}`));
    } catch (err) {
      showRefusal(`The run detail is unreadable: ${err.message}`);
    }
  }
}

function renderDetail(d) {
  detailRun = d;
  if (d.run_id) selectedRun = d.run_id;
  $("detail-run").textContent = d.run_id || "—";
  const badge = $("detail-badge");
  badge.textContent = d.state || "new";
  badge.dataset.state = stateKey(d.state);
  $("detail-premise").textContent = d.premise || "the journal names no premise for this run.";

  const fields = $("detail-fields");
  fields.replaceChildren();
  pair(fields, "Attempt", d.attempt ? `#${d.attempt}` : "");
  pair(fields, "State", d.state);
  pair(fields, "Phase", d.phase);
  pair(fields, "Ticket", d.ticket);
  pair(fields, "Host", d.host);
  pair(fields, "Model", d.model);
  pair(fields, "Resume route", d.resume_supported ? "the host has a resume route" : "no resume route");
  pair(fields, "Workflow", d.workflow);
  pair(fields, "Halt", d.halt ? `${d.halt.reason} — retry ${d.halt.retry_remaining}/${d.halt.retry_budget}` : "");
  pair(fields, "Node", d.owner);
  pair(fields, "Queue", d.queue_position ? `#${d.queue_position} waiting` : d.slot);
  pair(fields, "Runner", d.runner_type);
  gateActions(d);
}

function renderEvents(events) {
  const list = $("detail-events");
  list.replaceChildren();
  if (!events.length) item(list, "— the journal holds no rows —");
  for (const ev of events) {
    const li = el("li");
    li.appendChild(el("span", "kind", `${ev.kind}`));
    li.appendChild(document.createTextNode(` · ${ev.seq} · ${ev.ts}`));
    const raw = JSON.stringify(ev.payload);
    if (raw && raw !== "null") {
      li.appendChild(document.createTextNode(" · " +
        (raw.length > 300 ? raw.slice(0, 300) + "…" : raw)));
    }
    list.appendChild(li);
  }
}

async function loadEvents(runID) {
  try {
    const doc = await getJSON(`/v1/runs/${encodeURIComponent(runID)}/events`);
    renderEvents(doc.events || []);
  } catch (err) {
    renderEvents([]);
    item($("detail-events"), `the journal rows are unreadable: ${err.message}`);
  }
}

// pollOutput reads the transcript tail the API bounds (lines and bytes);
// an absent transcript answers with its reason, never an error.
async function pollOutput(runID) {
  try {
    const tail = await getJSON(
      `/v1/runs/${encodeURIComponent(runID)}/output?lines=${OUTPUT_LINES}`);
    const lines = tail.lines || [];
    $("detail-output").textContent = lines.join("\n") || tail.reason || "— the tail is empty —";
    $("output-meta").textContent = tail.source
      ? `${tail.host}: ${lines.length} lines${tail.truncated ? " (bounded)" : ""}`
      : tail.reason || "";
  } catch (err) {
    $("detail-output").textContent = `the output tail is unreadable: ${err.message}`;
    $("output-meta").textContent = "";
  }
}

function startOutputPoll() {
  stopOutputPoll();
  // A terminal run has no transcript left to follow: the poll is bounded by
  // the pane being open and the run being unfinished (SPEC-045 AC3).
  if (detailRun && TERMINAL_STATES.includes(stateKey(detailRun.state))) return;
  outputTimer = setInterval(async () => {
    if ($("detail").hidden || !selectedRun) {
      stopOutputPoll();
      return;
    }
    if (detailRun && TERMINAL_STATES.includes(stateKey(detailRun.state))) {
      stopOutputPoll();
      return;
    }
    await pollOutput(selectedRun);
  }, OUTPUT_POLL_MS);
}

function stopOutputPoll() {
  if (outputTimer) {
    clearInterval(outputTimer);
    outputTimer = null;
  }
}

// --- The operator actions ------------------------------------------
// Stop, Resume, Retry ride POST /v1/runs/{run}/<verb>. A button is hidden
// for a state that cannot take the action and disabled only while the
// state is unsettled (no detail read yet). A host with no resume route in
// the capability matrix shows no Resume button at all — Retry only.
const ACTIONS = [
  { id: "action-stop", verb: "stop", from: ["running", "claimed"], body: {} },
  { id: "action-resume", verb: "resume", from: ["halted"], needsResumeRoute: true, body: {} },
  { id: "action-retry", verb: "retry", from: ["failed", "halted"], body: {} },
];

function gateActions(detail) {
  const state = detail ? stateKey(detail.state) : "";
  for (const action of ACTIONS) {
    const btn = $(action.id);
    if (!state) {
      btn.hidden = false;
      btn.disabled = true;
      btn.title = "the run's state is not settled yet";
      continue;
    }
    let allowed = action.from.includes(state);
    if (allowed && action.needsResumeRoute && detail.resume_supported !== true) {
      allowed = false;
    }
    btn.hidden = !allowed;
    btn.disabled = false;
    btn.title = allowed ? "" : `${action.verb} is not valid from ${state}`;
  }
}

function showRefusal(message) {
  const node = $("detail-refusal");
  node.textContent = message;
  node.hidden = false;
}

function hideRefusal() {
  $("detail-refusal").textContent = "";
  $("detail-refusal").hidden = true;
}

async function runAction(action) {
  const runID = selectedRun;
  if (!runID) return;
  hideRefusal();
  say("you", `${action.verb[0].toUpperCase()}${action.verb.slice(1)} ${runID}`);
  const res = await postJSON(`/v1/runs/${encodeURIComponent(runID)}/${action.verb}`, action.body);
  // The refusal is the API's verbatim typed message (SPEC-045 AC7).
  if (!res.ok) {
    showRefusal(`Refused (${res.status}): ${res.data.error || "the Chief gave no reason"}`);
    return;
  }
  if (action.verb === "retry") {
    say("chief", `Retried ${runID}: run ${res.data.run_id} started.`);
    await refreshBoard();
    await openDetail(res.data.run_id);
    return;
  }
  const done = action.verb === "stop"
    ? `Stopped ${runID}: the run is halted:${res.data.halted || "operator_halt"}.`
    : `Resumed ${runID} in place.`;
  say("chief", done);
  await refreshBoard();
  await refreshSelected();
}

for (const action of ACTIONS) {
  $(action.id).addEventListener("click", () => runAction(action));
}

// --- Chat with the Chief -------------------------------------------
// The chat is the C9 verbs, not a new integration: a route is POST
// /v1/route, a correction is POST /v1/runs/{run}/corrections, and the
// Chief's answers are the API's own responses.

const TICKET_KIND = "ticket";
const EPIC_KIND = "epic";

// The autopilot vocabulary is the plugin's own (skills/autopilot/parse-flags.sh);
// the Chief validates the token through that parser, so the form's select is a
// picker over the same six tokens, never a second parser.
//
// composedCommands previews the command a ticket route composes. The
// authoritative command is the route response's `command` field, which the
// route result prints. The page cannot read a ticket record's kind, so the
// preview names both surfaces the ticket route can ride: the Chief runs
// /epic when the routed id names an epic.
// COPY-ACCEPTED: divergence-expected (this preview only).
function composedCommands() {
  const id = $("route-ticket").value.trim();
  if (!id) return null;
  const token = $("route-autopilot").value;
  const flag = token === "bare" ? "--autopilot" : `--autopilot=${token}`;
  return {
    ticket: `/orchestrate ${id} ${flag}`,
    epic: `/epic ${id} ${flag}`,
  };
}

function syncRouteForm() {
  const kind = $("route-kind").value;
  const ticket = kind === TICKET_KIND;
  $("ticket-box").hidden = !ticket;
  $("work-box").hidden = ticket;
  $("children-box").hidden = kind !== EPIC_KIND;
  $("route-ticket").required = ticket;
  $("route-title").required = !ticket;
  $("route-text").required = !ticket;
  const preview = $("command-preview");
  const composed = ticket ? composedCommands() : null;
  preview.hidden = !composed;
  preview.textContent = composed
    ? `Preview (approximate): ${composed.ticket} — ${composed.epic} when the ` +
      "id names an epic. The route reply names the command the run runs."
    : "";
}

$("route-kind").addEventListener("change", syncRouteForm);
$("route-ticket").addEventListener("input", syncRouteForm);
$("route-autopilot").addEventListener("change", syncRouteForm);

// showModelDefault reads the Model map's default for the agent the form
// names, so the operator sees the model before routing (SPEC-045 AC4).
async function showModelDefault() {
  const agent = $("route-agent").value.trim();
  try {
    const m = await getJSON(`/v1/model?agent=${encodeURIComponent(agent)}`);
    $("model-preview").textContent =
      `Model map default for ${agent || "the Tier default"}: ${m.model || "tier default"} (${m.source}).`;
  } catch (err) {
    $("model-preview").textContent = `The Model map is unreadable: ${err.message}`;
  }
}

$("route-agent").addEventListener("change", showModelDefault);

$("route-form").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const kind = $("route-kind").value;
  const body = { kind, host: $("route-host").value };
  if (kind === TICKET_KIND) {
    body.ticket_id = $("route-ticket").value.trim();
    body.autopilot = $("route-autopilot").value;
  } else {
    body.title = $("route-title").value;
    body.text = $("route-text").value;
  }
  if ($("route-agent").value.trim()) body.agent = $("route-agent").value.trim();
  if (kind === EPIC_KIND) {
    body.children = $("route-children").value.split("\n")
      .map((line) => line.trim()).filter(Boolean)
      .map((line) => {
        const [title, ...rest] = line.split("|");
        const child = { title: title.trim() };
        if (rest.length) child.text = rest.join("|").trim();
        return child;
      });
  }
  const said = kind === TICKET_KIND ? `Route ${body.ticket_id} (${body.autopilot})`
    : `Route a ${kind}: ${body.title}`;
  say("you", said);
  const res = await postJSON("/v1/route", body);
  const result = $("route-result");
  result.hidden = false;
  if (!res.ok) {
    const message = `Refused (${res.status}): ${res.data.error || "unknown error"}`;
    result.dataset.state = "refused";
    result.textContent = message;
    say("chief", message);
    return;
  }
  const r = res.data;
  result.dataset.state = "routed";
  const ran = r.command ? ` The Chief runs ${r.command}.` : "";
  result.textContent = (r.run_id
    ? `Run ${r.run_id} started (${r.model}, ${r.model_source}).`
    : "Child tickets written; route each child when it is ready.") + ran;
  say("chief", `Routed to ${r.surface ? r.surface.name : r.kind}.${ran}` +
    (r.run_id ? ` Run ${r.run_id} started (${r.model}, ${r.model_source}).` :
      " Child tickets written."));
  syncRouteForm();
  await refreshBoard();
  if (r.run_id) await openDetail(r.run_id);
});

$("correction-form").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const runID = $("correction-run").value;
  const message = $("correction-message").value;
  say("you", `Correct ${runID}: ${message}`);
  const res = await postJSON(`/v1/runs/${encodeURIComponent(runID)}/corrections`,
    { message });
  if (!res.ok) {
    say("chief", `Refused (${res.status}): ${res.data.error || "unknown error"}`);
    return;
  }
  say("chief", `Recorded for ${runID} — ${res.data.delivered}.`);
  $("correction-message").value = "";
});

// --- The lifecycle graph -------------------------------------------
// Drawn from GET /v1/graph — the C3 graph JSON, no second model. The
// layout is computed here from the order fields; the file carries no
// coordinates. The run's current position is marked: its run-state vertex
// outlined, its phase vertex filled.

let graph = null;
const BOX_W = 104, BOX_H = 34, GAP = 12;

function drawGraph() {
  if (!graph) return;
  const svg = $("lifecycle");
  const phases = graph.vertices.filter((v) => v.kind === "workflow-phase")
    .sort((a, b) => a.order - b.order);
  const states = graph.vertices.filter((v) => v.kind === "run-state")
    .sort((a, b) => a.order - b.order);
  const cols = Math.max(phases.length, states.length);
  const width = cols * (BOX_W + GAP) + GAP;
  const rowY = { "workflow-phase": 24, "run-state": 96 };
  const height = rowY["run-state"] + BOX_H + 16;
  svg.setAttribute("viewBox", `0 0 ${width} ${height}`);

  const ns = "http://www.w3.org/2000/svg";
  const pos = new Map();
  const box = (v, x, y) => {
    pos.set(v.id, { x: x + BOX_W / 2, y: y + BOX_H / 2, top: v.kind === "workflow-phase" });
    const g = document.createElementNS(ns, "g");
    g.setAttribute("class", "box");
    g.dataset.id = v.id;
    const rect = document.createElementNS(ns, "rect");
    rect.setAttribute("x", x); rect.setAttribute("y", y);
    rect.setAttribute("width", BOX_W); rect.setAttribute("height", BOX_H);
    g.appendChild(rect);
    const label = document.createElementNS(ns, "text");
    label.setAttribute("x", x + BOX_W / 2);
    label.setAttribute("y", y + BOX_H / 2 + 4);
    label.setAttribute("text-anchor", "middle");
    label.textContent = v.label;
    g.appendChild(label);
    svg.appendChild(g);
  };
  phases.forEach((v, i) => box(v, GAP + i * (BOX_W + GAP), rowY["workflow-phase"]));
  states.forEach((v, i) => box(v, GAP + i * (BOX_W + GAP), rowY["run-state"]));

  const defs = document.createElementNS(ns, "defs");
  const marker = document.createElementNS(ns, "marker");
  marker.setAttribute("id", "arrow");
  marker.setAttribute("viewBox", "0 0 10 10");
  marker.setAttribute("refX", "9"); marker.setAttribute("refY", "5");
  marker.setAttribute("markerWidth", "6"); marker.setAttribute("markerHeight", "6");
  marker.setAttribute("orient", "auto-start-reverse");
  const path = document.createElementNS(ns, "path");
  path.setAttribute("d", "M 0 0 L 10 5 L 0 10 z");
  path.setAttribute("fill", "#6b6b6b");
  marker.appendChild(path);
  defs.appendChild(marker);
  svg.prepend(defs);

  for (const e of graph.edges) {
    const a = pos.get(e.from), b = pos.get(e.to);
    if (!a || !b) continue;
    const line = document.createElementNS(ns, "path");
    const bend = a.top === b.top ? -18 : 0;
    line.setAttribute("d",
      `M ${a.x} ${a.y + (a.top ? BOX_H / 2 : -BOX_H / 2)}` +
      ` C ${a.x} ${(a.y + b.y) / 2 + bend}, ${b.x} ${(a.y + b.y) / 2 + bend},` +
      ` ${b.x} ${b.y + (b.top ? BOX_H / 2 : -BOX_H / 2)}`);
    line.setAttribute("class", `edge${e.kind === "gate" ? " gate" : ""}`);
    line.setAttribute("marker-end", "url(#arrow)");
    svg.appendChild(line);
    const label = document.createElementNS(ns, "text");
    label.setAttribute("class", "edge-label");
    label.setAttribute("x", (a.x + b.x) / 2);
    label.setAttribute("y", (a.y + b.y) / 2 - (a.top ? 4 : -10));
    label.setAttribute("text-anchor", "middle");
    label.textContent = e.gate || e.label;
    svg.appendChild(label);
  }
}

function markGraph() {
  if (!graph) return;
  const runID = $("graph-run").value;
  const run = runs.find((r) => r.run_id === runID);
  for (const g of $("lifecycle").querySelectorAll("g.box")) {
    g.classList.remove("state-current", "phase-current");
  }
  if (!run) return;
  const mark = (vertex, className) => {
    if (!vertex) return;
    const node = $("lifecycle").querySelector(`g.box[data-id="${CSS.escape(vertex)}"]`);
    if (node) node.classList.add(className);
  };
  mark(run.state, "state-current");
  mark(run.phase, "phase-current");
}

async function loadGraph() {
  try {
    graph = await getJSON("/v1/graph");
    drawGraph();
  } catch (err) {
    $("graph-legend").textContent = "the lifecycle graph is unreadable: " + err.message;
  }
}

// --- Wiring ---------------------------------------------------------
$("ticket-groups").addEventListener("click", (ev) => {
  const pick = ev.target.closest("button.run-pick");
  if (pick) openDetail(pick.dataset.run);
});

$("detail-close").addEventListener("click", closeDetail);
$("graph-run").addEventListener("change", markGraph);
document.addEventListener("keydown", (ev) => {
  if (ev.key === "Escape" && !$("detail").hidden) closeDetail();
});

syncRouteForm();
showModelDefault();
refreshBoard();
loadGraph();
setInterval(refreshBoard, 5000);
