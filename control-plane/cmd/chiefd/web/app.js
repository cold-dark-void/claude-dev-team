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
function cell(row, className, text) {
  const td = document.createElement("td");
  if (className) td.className = className;
  td.textContent = text;
  row.appendChild(td);
  return td;
}

function item(list, text) {
  const li = document.createElement("li");
  li.textContent = text;
  list.appendChild(li);
}

function say(who, text) {
  const li = document.createElement("li");
  li.className = who === "you" ? "you" : "chief";
  const whoSpan = document.createElement("span");
  whoSpan.className = "who";
  whoSpan.textContent = who === "you" ? "You" : "Chief";
  li.appendChild(whoSpan);
  li.appendChild(document.createTextNode(text));
  $("thread").appendChild(li);
  $("thread").scrollTop = $("thread").scrollHeight;
}

// --- The run board -----------------------------------------------------

let runs = [];

async function refreshBoard() {
  try {
    const [runsDoc, haltsDoc, queueDoc, checksDoc] = await Promise.all([
      getJSON("/v1/runs"), getJSON("/v1/halts"),
      getJSON("/v1/queue"), getJSON("/v1/checks"),
    ]);
    runs = runsDoc.runs || [];
    renderRuns(runs);
    renderList($("halts"), haltsDoc.halts || [], haltLine);
    renderList($("queue"), queueDoc.slots || [], slotLine);
    renderList($("checks"), checksDoc.checks || [], checkLine);
    syncRunPickers(runs);
    markGraph();
    $("conn").textContent = "live";
  } catch (err) {
    $("conn").textContent = "the Chief is unreachable: " + err.message;
  }
}

function renderRuns(runs) {
  const tbody = $("runs").tBodies[0];
  tbody.replaceChildren();
  for (const r of runs) {
    const row = document.createElement("tr");
    const stateClass = r.state && r.state.startsWith("halted:")
      ? "state-halted"
      : `state-${r.state || ""}`;
    cell(row, stateClass, r.run_id || "");
    cell(row, stateClass, r.state || "");
    cell(row, "", r.phase || "—");
    cell(row, "", r.halt ? r.halt.reason : "—");
    cell(row, "", r.halt ? `${r.halt.retry_remaining}/${r.halt.retry_budget}` : "—");
    cell(row, "", r.queue_position ? `#${r.queue_position} waiting` : (r.slot || "—"));
    cell(row, "", r.owner || "—");
    cell(row, "", r.runner_type || "—");
    cell(row, "", r.workflow || "—");
    cell(row, "", r.model || "—");
    tbody.appendChild(row);
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

function syncRunPickers(rows) {
  for (const id of ["correction-run", "graph-run"]) {
    const picker = $(id);
    const current = picker.value;
    picker.replaceChildren();
    if (!rows.length) {
      const opt = document.createElement("option");
      opt.textContent = "no runs";
      picker.appendChild(opt);
      continue;
    }
    for (const r of rows) {
      const opt = document.createElement("option");
      opt.value = r.run_id;
      opt.textContent = `${r.run_id} — ${r.state}`;
      picker.appendChild(opt);
    }
    if ([...picker.options].some((o) => o.value === current)) picker.value = current;
  }
}

// --- Chat with the Chief ----------------------------------------------
// The chat is the C9 verbs, not a new integration: a route is POST
// /v1/route, a correction is POST /v1/runs/{run}/corrections, and the
// Chief's answers are the API's own responses.

$("route-kind").addEventListener("change", () => {
  $("children-box").hidden = $("route-kind").value !== "epic";
});

$("route-form").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const body = {
    kind: $("route-kind").value,
    host: $("route-host").value,
    title: $("route-title").value,
    text: $("route-text").value,
  };
  if ($("route-agent").value.trim()) body.agent = $("route-agent").value.trim();
  if (body.kind === "epic") {
    body.children = $("route-children").value.split("\n")
      .map((line) => line.trim()).filter(Boolean)
      .map((line) => {
        const [title, ...rest] = line.split("|");
        const child = { title: title.trim() };
        if (rest.length) child.text = rest.join("|").trim();
        return child;
      });
  }
  say("you", `Route a ${body.kind}: ${body.title}`);
  const res = await postJSON("/v1/route", body);
  if (!res.ok) {
    say("chief", `Refused (${res.status}): ${res.data.error || "unknown error"}`);
    return;
  }
  const r = res.data;
  const ran = r.run_id ? ` Run ${r.run_id} started (${r.model}, ${r.model_source}).`
    : ` Child tickets written; route each child when it is ready.`;
  say("chief", `Routed to ${r.surface ? r.surface.name : r.kind}.${ran}`);
  refreshBoard();
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

// --- The lifecycle graph ----------------------------------------------
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
  const stateV = graph.vertices.find((v) => v.id === run.state);
  if (stateV) {
    const node = $("lifecycle").querySelector(`g.box[data-id="${CSS.escape(run.state)}"]`);
    if (node) node.classList.add("state-current");
  }
  if (run.phase) {
    const node = $("lifecycle").querySelector(`g.box[data-id="${CSS.escape(run.phase)}"]`);
    if (node) node.classList.add("phase-current");
  }
}

async function loadGraph() {
  try {
    graph = await getJSON("/v1/graph");
    drawGraph();
  } catch (err) {
    $("graph-legend").textContent = "the lifecycle graph is unreadable: " + err.message;
  }
}

$("graph-run").addEventListener("change", markGraph);

refreshBoard();
loadGraph();
setInterval(refreshBoard, 5000);
