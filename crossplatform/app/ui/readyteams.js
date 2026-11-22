// Settings › Bot teams: ready-made teams, each a category with a manager and the bots who report to it, added whole in one
// click (the Mac's Setup/BotTeamsSettings.swift). The owner can change any of them, make their own, keep a category they
// already have as a team, and import or export team files, the same files the Mac reads. The engine side is
// crates/theo-core/src/ready_teams.rs, through the readyTeam* control commands.

let readyTeamsCache = null;
// What the last Add, import or save did, under the team it was about ("" at the top).
let readyTeamsNote = { team: "", text: "", bad: false };
const readyTeamsOpen = new Set();
// Set by the sidebar's "Ready-made teams" link: Settings scrolls to the section once it's drawn.
let settingsJumpOnDraw = null;

async function loadReadyTeams() {
  const r = await invoke({ cmd: "readyTeams" });
  if (r.ok) readyTeamsCache = r.result;
  return readyTeamsCache;
}

function readyTeamsSay(team, text, bad = false) { readyTeamsNote = { team, text, bad }; }

function readyTeamCardHTML(t) {
  const open = readyTeamsOpen.has(t.id);
  const tag = !t.builtIn ? `<span class="rt-tag">Yours</span>` : t.changed ? `<span class="rt-tag">Changed</span>` : "";
  const member = (m, manager) => `<div class="rt-member">${manager ? CROWN_SVG : `<span class="rt-dot"></span>`}<span class="tx"><b>${esc(m.name)}</b>${manager ? `<small class="rt-role">Manager</small>` : ""}${m.model ? `<small class="rt-role">${esc(m.model)}</small>` : ""}${m.does ? `<small>${esc(m.does)}</small>` : ""}</span></div>`;
  const workers = open ? t.workers.map((w) => member(w, false)).join("")
    : `<p class="hint rt-under">Reporting to ${esc(t.manager.name)}: ${esc(wordsList(t.workers.map((w) => w.name)))}.</p>`;
  const note = readyTeamsNote.team === t.id && readyTeamsNote.text ? `<p class="hint${readyTeamsNote.bad ? " err" : ""}">${esc(readyTeamsNote.text)}</p>` : "";
  return `<div class="rt-card" data-rt="${esc(t.id)}"><div class="rt-head"><b>${esc(t.name)}</b>${tag}<span class="grow"></span><small>${t.workers.length + 1} bots</small></div>`
    + (t.purpose ? `<p class="muted rt-purpose">${esc(t.purpose)}</p>` : "")
    + member(t.manager, true) + workers
    + `<div class="btns rt-actions"><button class="btn sm pri" data-rt-add="${esc(t.id)}">Add to Vello</button><button class="btn sm" data-rt-edit="${esc(t.id)}">Edit</button>`
    + `<button class="btn sm ghost" data-rt-open="${esc(t.id)}">${open ? "Hide jobs" : "Show every job"}</button><span class="grow"></span>`
    + `<button class="btn sm ghost" data-rt-more="${esc(t.id)}" aria-label="More for ${esc(t.name)}" title="More for ${esc(t.name)}">&middot;&middot;&middot;</button></div>${note}</div>`;
}

function wordsList(items) {
  if (items.length < 2) return items[0] || "";
  return `${items.slice(0, -1).join(", ")} and ${items[items.length - 1]}`;
}

// Draws the section into #settings-teams-body. Settings calls it each time the page is drawn.
async function drawReadyTeams() {
  const box = $("#settings-teams-body");
  if (!box) return;
  if (!readyTeamsCache) { box.innerHTML = `<p class="muted">Loading the teams…</p>`; await loadReadyTeams(); }
  const data = readyTeamsCache;
  if (!$("#settings-teams-body") || !data) return;
  const categories = teamsList().filter((t) => (t.members || []).some((id) => id !== ceoBotId()));
  const ceo = (state.bots || []).find((b) => b.id === ceoBotId());
  const topNote = readyTeamsNote.team === "" && readyTeamsNote.text ? `<p class="hint${readyTeamsNote.bad ? " err" : ""}">${esc(readyTeamsNote.text)}</p>` : "";
  box.innerHTML = `<div class="list"><div class="crow rt-bar"><span class="btns"><button class="btn sm" data-rt-new>New team</button>`
    + `<label class="btn sm rt-file">Import a team file…<input type="file" accept=".json,application/json" data-rt-import hidden></label>`
    + `<select data-rt-keep aria-label="Save a category as a team"${categories.length ? "" : " disabled"}><option value="">Save a category as a team…</option>${categories.map((c) => `<option value="${esc(c.id)}">${esc(c.name)}</option>`).join("")}</select>`
    + `<button class="btn sm ghost" data-rt-export-all>Export all</button></span></div></div>`
    + `<p class="hint">Adding a team makes its category, its manager and its bots in the sidebar, on your CEO's brain. Adding it again makes a second copy with numbered names. You can also ask ${esc(ceo ? ceo.name : "Vello")} in chat: "add the Research Desk".</p>${topNote}`
    + data.teams.map(readyTeamCardHTML).join("")
    + (data.hasRemoved ? `<button class="btn sm ghost" data-rt-restore>Show Vello's teams I removed</button>` : "");
  wireReadyTeams(box, data);
}

function wireReadyTeams(box, data) {
  const team = (id) => data.teams.find((t) => t.id === id);
  const redraw = async () => { await loadReadyTeams(); drawReadyTeams(); };
  box.querySelector("[data-rt-new]").onclick = async () => { const r = await invoke({ cmd: "readyTeamBlank" }); if (r.ok) openReadyTeamEditor(r.result, true); };
  box.querySelector("[data-rt-import]").onchange = async (e) => {
    const file = e.target.files && e.target.files[0];
    if (!file) return;
    const r = await invoke({ cmd: "readyTeamImport", text: await file.text() });
    readyTeamsSay("", r.ok ? `Imported ${wordsList(r.result.result.added)}. Add ${r.result.result.added.length === 1 ? "it" : "them"} below to make the bots.` : r.error, !r.ok);
    redraw();
  };
  box.querySelector("[data-rt-keep]").onchange = async (e) => {
    if (!e.target.value) return;
    const r = await invoke({ cmd: "readyTeamFromCategory", id: e.target.value });
    if (r.ok) { const s = r.result.result; readyTeamsSay(s.id, `Saved ${s.name} as a team with ${s.count} bots, ${s.manager} managing.`); }
    else readyTeamsSay("", r.error, true);
    redraw();
  };
  box.querySelector("[data-rt-export-all]").onclick = () => exportReadyTeams(null, "");
  const restore = box.querySelector("[data-rt-restore]");
  if (restore) restore.onclick = async () => { await invoke({ cmd: "readyTeamRestore" }); redraw(); };
  box.querySelectorAll("[data-rt-add]").forEach((b) => b.onclick = async () => {
    b.disabled = true; b.textContent = "Adding…";
    const r = await invoke({ cmd: "readyTeamAdd", id: b.dataset.rtAdd });
    readyTeamsSay(b.dataset.rtAdd, r.ok ? r.result.note : r.error, !r.ok);
    await refresh();
    drawReadyTeams();
  });
  box.querySelectorAll("[data-rt-edit]").forEach((b) => b.onclick = () => openReadyTeamEditor(JSON.parse(JSON.stringify(team(b.dataset.rtEdit))), false));
  box.querySelectorAll("[data-rt-open]").forEach((b) => b.onclick = () => {
    const id = b.dataset.rtOpen;
    if (readyTeamsOpen.has(id)) readyTeamsOpen.delete(id); else readyTeamsOpen.add(id);
    drawReadyTeams();
  });
  box.querySelectorAll("[data-rt-more]").forEach((b) => b.onclick = (e) => {
    const t = team(b.dataset.rtMore);
    const items = [
      ["Duplicate", async () => { const r = await invoke({ cmd: "readyTeamDuplicate", id: t.id }); if (r.ok) readyTeamsSay(r.result.result.id, `A copy of ${t.name}, yours to change.`); redraw(); }],
      ["Export to a file", () => exportReadyTeams(t.id, t.id)],
    ];
    if (t.builtIn && t.changed) items.push(["Put back Vello's version", async () => { await invoke({ cmd: "readyTeamReset", id: t.id }); redraw(); }]);
    items.push([t.builtIn ? "Remove from this list" : "Delete this team", async () => { await invoke({ cmd: "readyTeamRemove", id: t.id }); redraw(); }, "danger"]);
    showMenu(e, items);
  });
}

// A team file in Downloads, and on the clipboard too, so it can be pasted into a message.
async function exportReadyTeams(id, noteTeam) {
  const r = await invoke(id ? { cmd: "readyTeamExport", id, save: "downloads" } : { cmd: "readyTeamExport", save: "downloads" });
  if (!r.ok) { readyTeamsSay(noteTeam, r.error, true); drawReadyTeams(); return; }
  let copied = false;
  try { await navigator.clipboard.writeText(r.result.text); copied = true; } catch (e) { copied = false; }
  readyTeamsSay(noteTeam, `Saved to ${r.result.saved}${copied ? ", and copied" : ""}.`);
  drawReadyTeams();
}

/* ---------------- the editor ---------------- */
function openReadyTeamEditor(draft, isNew) {
  const most = (readyTeamsCache && readyTeamsCache.mostWorkers) || 19;
  draft.workers = draft.workers || [];
  let d = $("#ready-team-dialog");
  if (!d) { d = document.createElement("dialog"); d.id = "ready-team-dialog"; document.body.appendChild(d); }
  let problem = "";
  const memberHTML = (m, index) => `<div class="rt-edit" data-index="${index}">`
    + `<div class="rt-edit-row"><input data-f="name" maxlength="40" value="${esc(m.name || "")}" placeholder="${index < 0 ? "Manager's name" : "Bot's name"}" aria-label="Name">`
    + `<input data-f="model" maxlength="80" value="${esc(m.model || "")}" placeholder="Model (empty: the usual one)" aria-label="Model" title="Words a team block takes: haiku, Claude Opus 5.5, or an exact model id. A model this computer doesn't have uses the usual one, and the note says so."></div>`
    + `<input data-f="does" maxlength="200" value="${esc(m.does || "")}" placeholder="One line on its job" aria-label="Its job">`
    + `<textarea data-f="instructions" rows="4" maxlength="4000" placeholder="Its instructions, written to it as &quot;You are …&quot;. Empty: &quot;You are <name>. <its job>&quot;" aria-label="Instructions">${esc(m.instructions || "")}</textarea>`
    + (index >= 0 ? `<div class="btns"><button type="button" class="btn sm ghost" data-make-manager="${index}">Make manager</button><button type="button" class="btn sm ghost danger" data-remove="${index}">Remove</button></div>` : "")
    + `</div>`;
  const read = () => {
    d.querySelectorAll(".rt-edit").forEach((el) => {
      const index = Number(el.dataset.index);
      const m = index < 0 ? draft.manager : draft.workers[index];
      if (!m) return;
      el.querySelectorAll("[data-f]").forEach((f) => { m[f.dataset.f] = f.value; });
      if (!m.model) delete m.model;
    });
    draft.name = d.querySelector("#rt-name").value;
    draft.purpose = d.querySelector("#rt-purpose").value;
  };
  const draw = () => {
    d.innerHTML = `<form method="dialog" id="rt-form"><h2>${isNew ? "New team" : `Edit ${esc(draft.name)}`}</h2><div class="rt-scroll">`
      + `<label>Team name <input id="rt-name" maxlength="80" value="${esc(draft.name || "")}" placeholder="Research Desk"></label>`
      + `<label>What it's for <input id="rt-purpose" maxlength="200" value="${esc(draft.purpose || "")}" placeholder="One line: it becomes the category's purpose"></label>`
      + `<div class="lbl">Manager</div>${memberHTML(draft.manager || {}, -1)}`
      + `<div class="lbl rt-lbl"><span>Bots reporting to the manager</span><span>${draft.workers.length} of ${most}</span></div>`
      + draft.workers.map(memberHTML).join("")
      + `<button type="button" class="btn sm" id="rt-add-bot"${draft.workers.length >= most ? " disabled" : ""}>Add a bot</button></div>`
      + `<p class="hint err" id="rt-problem">${esc(problem)}</p>`
      + `<menu><button value="cancel" class="btn" formnovalidate>Cancel</button><button value="ok" class="btn pri">Save</button></menu></form>`;
    d.querySelector("#rt-add-bot").onclick = () => { read(); draft.workers.push({ name: "", does: "", instructions: "" }); draw(); };
    d.querySelectorAll("[data-make-manager]").forEach((b) => b.onclick = () => {
      read();
      const index = Number(b.dataset.makeManager);
      const old = draft.manager;
      draft.manager = draft.workers[index];
      draft.workers[index] = old;
      draw();
    });
    d.querySelectorAll("[data-remove]").forEach((b) => b.onclick = () => { read(); draft.workers.splice(Number(b.dataset.remove), 1); draw(); });
    d.querySelector("#rt-form").onsubmit = async (e) => {
      if (!e.submitter || e.submitter.value !== "ok") return;
      e.preventDefault();
      read();
      const r = await invoke({ cmd: "readyTeamSave", team: draft });
      if (!r.ok) { problem = r.error; draw(); return; }
      d.close();
      readyTeamsSay(r.result.result.id, "Saved. Add it to put its bots in the sidebar.");
      await loadReadyTeams();
      drawReadyTeams();
    };
  };
  draft.manager = draft.manager || { name: "", does: "", instructions: "" };
  draw();
  d.showModal();
  const name = d.querySelector("#rt-name"); if (name) name.focus();
}
