/* Teams: the sidebar's bot list (by team or urgent first), the team page, group chat editing, and the small menus and
   confirmations they share. Ported from the Mac's BotsView (the sidebar), BotTeams (the team page) and BotGroupsView, with
   the same words and rules. The categories themselves live in the engine (crates/theo-core/src/teams.rs, saved as the Mac
   saves them) and come in with every state read as `state.teams`; changes go through the teams control commands
   (teams_control.rs). Loaded before app.js, so it only defines things: app.js's globals are used when these run. */

const SIDEBAR_SORT_KEY = "theo.sidebar.sort.v2";
const CROWN_SVG = `<svg class="crown" viewBox="0 0 24 24" aria-hidden="true"><path d="M3 8l4.5 4L12 5l4.5 7L21 8l-2 11H5z"/></svg>`;
const BUSY_STATES = ["needs", "failed", "working", "thinking"];
const REPORT_SCHEDULES = [["off", "Only when I ask"], ["daily", "Every day at 6 pm"], ["weekdays", "Weekdays at 6 pm"], ["weekly", "Fridays at 5 pm"], ["every", "Every 2 hours"]];

// The sort is this window's own choice, like the Mac's; an unreadable store means the default.
function sidebarSort() { try { return localStorage.getItem(SIDEBAR_SORT_KEY) === "urgent" ? "urgent" : "teams"; } catch (e) { return "teams"; } }
function setSidebarSort(mode) { try { localStorage.setItem(SIDEBAR_SORT_KEY, mode); } catch (e) { /* kept for this session only */ } }
function ceoBotId() { const ceo = state.bots.find((b) => b.primary); return ceo ? ceo.id : "theo"; }
function ceoName() { const ceo = state.bots.find((b) => b.primary); return ceo ? ceo.name : "the CEO"; }
function teamsList() { return state.teams || []; }
function teamById(id) { return teamsList().find((t) => t.id === id); }
function teamsOfBot(botId) { return teamsList().filter((t) => (t.members || []).includes(botId)); }
function botExists(id) { return state.bots.some((b) => b.id === id); }

/* ---------------- the sidebar's bots ---------------- */
function sidebarBotRow(f, opts = {}) {
  const selected = view.kind === "bot" && view.id === f.id ? " selected" : "";
  const detail = f.detail ? ` · ${esc(f.detail)}` : "";
  const manager = opts.manager ? `<span class="mgr" title="Manages this team">${CROWN_SVG}Manager</span>` : "";
  return `<button class="row brow${selected}" data-bot="${esc(f.id)}"${opts.fixed ? "" : ` draggable="true"`}>${botHTML(f.id, 36)}<span class="tx"><span class="nm"><span class="nm-t">${esc(nameOf(f.id))}</span>${manager}</span>`
    + `<span class="st"><span class="s-word-${f.state}">${esc(f.word)}</span>${detail}</span></span>`
    + (f.unread ? `<i class="unread" title="New"></i>` : "") + `<span class="tm">${BUSY_STATES.includes(f.state) ? ago(f.since) : ""}</span></button>`;
}

// The CEO always has the top row, whatever the sort.
function ceoRowHTML(faces) {
  const ceo = faces.find((f) => f.id === ceoBotId());
  return ceo && (!filter || ceo.state === filter) ? sidebarBotRow(ceo, { fixed: true }) : "";
}

function urgentListHTML(faces) {
  let html = ceoRowHTML(faces);
  for (const [lane, label] of GROUPS) {
    const rows = faces.filter((f) => f.id !== ceoBotId() && groupOf(f.state) === lane && (!filter || f.state === filter));
    if (!rows.length) continue;
    html += `<div class="section-label"><span>${label}</span><span>${rows.length}</span></div>`;
    for (const f of rows) html += sidebarBotRow(f);
  }
  return html;
}

// Each category with its manager first (crown and "Manager"), then "Other bots" for anything unfiled, then New category.
function teamsListHTML(faces) {
  const ceo = ceoBotId();
  const faceOf = (id) => faces.find((f) => f.id === id);
  let html = ceoRowHTML(faces);
  const filed = new Set();
  for (const team of teamsList()) {
    const members = (team.members || []).filter((id) => id !== ceo && faceOf(id));
    members.forEach((id) => filed.add(id));
    const manager = team.leader && members.includes(team.leader) ? team.leader : null;
    const rest = members.filter((id) => id !== manager);
    const holdsSelection = view.kind === "bot" && members.includes(view.id);
    const collapsed = team.collapsed && !holdsSelection;
    const selected = view.kind === "team" && view.id === team.id ? " selected" : "";
    html += `<div class="section-label team-label${selected}" data-team="${esc(team.id)}" data-drop="${esc(team.id)}">`
      + `<button class="tl-fold" data-fold="${esc(team.id)}" aria-label="${collapsed ? "Show the team" : "Fold the team"}" title="${collapsed ? "Show the team" : "Fold the team"}">${collapsed ? "&#9656;" : "&#9662;"}</button>`
      + `<button class="tl-name" data-open-team="${esc(team.id)}">${esc(team.name)}</button><span>${members.length}</span></div>`;
    if (collapsed) continue;
    if (manager) html += sidebarBotRow(faceOf(manager), { manager: true });
    for (const id of rest) html += sidebarBotRow(faceOf(id));
    if (!members.length) html += `<div class="drop-hint" data-drop="${esc(team.id)}">Drag bots here</div>`;
  }
  const unfiled = faces.filter((f) => f.id !== ceo && !filed.has(f.id));
  if (unfiled.length) {
    html += `<div class="section-label" data-drop=""><span>Other bots</span><span>${unfiled.length}</span></div>`;
    for (const f of unfiled) html += sidebarBotRow(f);
  }
  html += `<button class="row nav new-category" data-new-category><svg class="ic" viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></svg>New category</button>`;
  html += `<button class="row nav new-category" data-ready-teams title="Add a whole team at once: a manager and its bots"><svg class="ic" viewBox="0 0 24 24"><path d="M9 3.5h6v5H9zM12 8.5v3M6.5 14.5V13a1.5 1.5 0 0 1 1.5-1.5h8a1.5 1.5 0 0 1 1.5 1.5v1.5M3.5 14.5h6v5h-6zM14.5 14.5h6v5h-6z"/></svg>Ready-made teams</button>`;
  return html;
}

function sidebarSortHTML() {
  const mode = filter ? "urgent" : sidebarSort();
  return `<div class="seg" role="tablist" aria-label="Sort bots">${[["teams", "Teams"], ["urgent", "Urgent first"]].map(([k, w]) => `<button role="tab" aria-selected="${mode === k}" class="${mode === k ? "on" : ""}" data-sort="${k}">${w}</button>`).join("")}</div>`;
}

// Called by app.js's renderSidebar when anything shown changed. A counter pill's filter shows its lane without switching for good.
function renderBotList(faces) {
  const byTeams = sidebarSort() === "teams" && !filter;
  const box = $("#bots");
  box.innerHTML = sidebarSortHTML() + (byTeams ? teamsListHTML(faces) : urgentListHTML(faces));
  box.querySelectorAll("[data-sort]").forEach((b) => b.onclick = () => { setSidebarSort(b.dataset.sort); filter = null; refresh(); });
  box.querySelectorAll("[data-bot]").forEach((el) => {
    el.onclick = () => open({ kind: "bot", id: el.dataset.bot });
    el.oncontextmenu = (e) => { e.preventDefault(); showMenu(e, botMenuItems(el.dataset.bot)); };
    el.ondragstart = (e) => { e.dataTransfer.setData("text/plain", "bot:" + el.dataset.bot); e.dataTransfer.effectAllowed = "move"; };
  });
  box.querySelectorAll("[data-open-team]").forEach((el) => el.onclick = () => open({ kind: "team", id: el.dataset.openTeam }));
  box.querySelectorAll("[data-fold]").forEach((el) => el.onclick = async (e) => {
    e.stopPropagation();
    const team = teamById(el.dataset.fold);
    await invoke({ cmd: "teamUpdate", id: el.dataset.fold, collapsed: !(team && team.collapsed) });
    refresh();
  });
  box.querySelectorAll(".team-label").forEach((el) => el.oncontextmenu = (e) => { e.preventDefault(); showMenu(e, teamMenuItems(el.dataset.team)); });
  box.querySelectorAll("[data-drop]").forEach((el) => {
    el.ondragover = (e) => { e.preventDefault(); el.classList.add("drop-on"); };
    el.ondragleave = () => el.classList.remove("drop-on");
    el.ondrop = async (e) => {
      e.preventDefault(); el.classList.remove("drop-on");
      const item = e.dataTransfer.getData("text/plain");
      if (!item.startsWith("bot:")) return;
      await invoke({ cmd: "teamMove", bot: item.slice(4), team: el.dataset.drop || null });
      refresh();
    };
  });
  const add = box.querySelector("[data-new-category]");
  if (add) add.onclick = () => newCategory([]);
  const ready = box.querySelector("[data-ready-teams]");
  if (ready) ready.onclick = () => { settingsJumpOnDraw = "teams"; open({ kind: "settings" }); };
}

async function newCategory(members) {
  const r = await invoke({ cmd: "teamAdd", members });
  if (r.ok) { await refresh(); open({ kind: "team", id: r.result.id }); }
}

/* ---------------- the sidebar's group chats ---------------- */
function renderGroupList() {
  const box = $("#groups");
  box.innerHTML = state.groups.map((g) => `<button class="row${view.kind === "group" && view.id === g.id ? " selected" : ""}" data-group="${esc(g.id)}">`
    + `<span class="mosaic">${botHTML(g.head, 22, { badge: false })}</span>${esc(g.name)}</button>`).join("")
    + `<button class="row nav" data-new-group><svg class="ic" viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></svg>New group chat</button>`;
  box.querySelectorAll("[data-group]").forEach((el) => {
    el.onclick = () => open({ kind: "group", id: el.dataset.group });
    el.oncontextmenu = (e) => {
      e.preventDefault();
      const g = state.groups.find((x) => x.id === el.dataset.group);
      showMenu(e, [["Edit group chat…", () => openGroupEditor(g)], null, ["Delete…", () => deleteGroup(g), "danger"]]);
    };
  });
  box.querySelector("[data-new-group]").onclick = () => openGroupEditor(null);
}

/* ---------------- menus ---------------- */
// items: [label, action, "danger"|"off"] or a string heading or null for a line.
function showMenu(event, items) {
  closeMenu();
  const menu = document.createElement("div");
  menu.id = "ctx-menu";
  menu.className = "menu";
  menu.setAttribute("role", "menu");
  menu.innerHTML = items.map((it, i) => it === null ? `<hr>` : typeof it === "string" ? `<div class="menu-h">${esc(it)}</div>`
    : `<button role="menuitem" data-i="${i}" class="${it[2] || ""}"${it[2] === "off" ? " disabled" : ""}>${esc(it[0])}</button>`).join("");
  document.body.appendChild(menu);
  const width = menu.offsetWidth, height = menu.offsetHeight;
  menu.style.left = Math.min(event.clientX, window.innerWidth - width - 8) + "px";
  menu.style.top = Math.min(event.clientY, window.innerHeight - height - 8) + "px";
  menu.querySelectorAll("[data-i]").forEach((b) => b.onclick = () => { closeMenu(); items[+b.dataset.i][1](); });
  const first = menu.querySelector("button:not([disabled])");
  if (first) first.focus();
  setTimeout(() => document.addEventListener("mousedown", closeMenuOutside), 0);
}
function closeMenuOutside(e) { const m = $("#ctx-menu"); if (m && !m.contains(e.target)) closeMenu(); }
function closeMenu() { const m = $("#ctx-menu"); if (m) m.remove(); document.removeEventListener("mousedown", closeMenuOutside); }
document.addEventListener("keydown", (e) => { if (e.key === "Escape") closeMenu(); });

function botMenuItems(botId) {
  const bot = state.bots.find((b) => b.id === botId) || {};
  const items = [["Settings…", () => { open({ kind: "bot", id: botId }); openBotSettings(botId); }],
    [bot.enabled === false ? "Turn on" : "Turn off", async () => { await invoke({ cmd: "botUpdate", id: botId, enabled: bot.enabled === false }); refresh(); }]];
  if (!bot.primary) {
    const mine = teamsOfBot(botId);
    items.push(null, "Move to category");
    for (const t of teamsList()) items.push([t.name, async () => { await invoke({ cmd: "teamMove", bot: botId, team: t.id }); refresh(); }, mine.some((m) => m.id === t.id) ? "off" : ""]);
    items.push(["New category…", () => newCategory([botId])]);
    if (mine.length) items.push(["Take out of category", async () => { await invoke({ cmd: "teamMove", bot: botId, team: null }); refresh(); }]);
    items.push(null, ["Make primary", async () => { await invoke({ cmd: "botMakePrimary", id: botId }); refresh(); }], ["Delete…", () => deleteBot(botId), "danger"]);
  }
  return items;
}

function teamMenuItems(teamId) {
  const team = teamById(teamId);
  if (!team) return [];
  const hasMembers = (team.members || []).length > 0;
  return [["Open team page", () => open({ kind: "team", id: teamId })],
    [team.collapsed ? "Show the team" : "Fold the team", async () => { await invoke({ cmd: "teamUpdate", id: teamId, collapsed: !team.collapsed }); refresh(); }],
    [`Report to ${ceoName()} now`, () => reportNow(teamId), hasMembers ? "" : "off"],
    ["Rename…", () => { open({ kind: "team", id: teamId }); setTimeout(() => { const n = $("#team-name"); if (n) { n.focus(); n.select(); } }, 60); }],
    null, ["Delete category (keeps its bots)", () => deleteCategory(teamId), "danger"]];
}

/* ---------------- confirmations ---------------- */
function confirmBox(title, message, okWord) {
  return new Promise((resolve) => {
    let d = $("#confirm-dialog");
    if (!d) { d = document.createElement("dialog"); d.id = "confirm-dialog"; document.body.appendChild(d); }
    d.innerHTML = `<form method="dialog"><h2>${esc(title)}</h2><p class="muted">${esc(message)}</p><menu><button value="cancel" class="btn">Cancel</button><button value="ok" class="btn danger">${esc(okWord)}</button></menu></form>`;
    d.onclose = () => resolve(d.returnValue === "ok");
    d.showModal();
  });
}

async function deleteBot(botId) {
  const name = nameOf(botId);
  if (!(await confirmBox(`Delete ${name}?`, "Its chat and routines go too. Turn it off instead to keep it.", "Delete"))) return false;
  const r = await invoke({ cmd: "botDelete", id: botId });
  if (!r.ok) { await confirmBox(r.error, "", "OK"); return false; }
  closeBotSettings();
  if (view.kind === "bot" && view.id === botId) open({ kind: "bot", id: ceoBotId() }); else refresh();
  return true;
}

async function deleteGroup(group) {
  if (!group) return false;
  if (!(await confirmBox(`Delete ${group.name}?`, "Its chat goes too. The bots in it stay.", "Delete"))) return false;
  await invoke({ cmd: "groupDelete", id: group.id });
  if (view.kind === "group" && view.id === group.id) open({ kind: "home" }); else refresh();
  return true;
}

async function deleteCategory(teamId) {
  const team = teamById(teamId);
  if (!team || !(await confirmBox(`Delete ${team.name}?`, "Its bots stay, under Other bots.", "Delete category"))) return;
  await invoke({ cmd: "teamDelete", id: teamId });
  if (view.kind === "team" && view.id === teamId) open({ kind: "home" }); else refresh();
}

async function reportNow(teamId) {
  const r = await invoke({ cmd: "teamReport", id: teamId });
  if (!r.ok) return confirmBox("Couldn't report", r.error, "OK");
  // The roll-up lands in the CEO's chat, so that's where to watch it.
  setTimeout(() => open({ kind: "bot", id: ceoBotId() }), 400);
}

/* ---------------- the header ---------------- */
function teamHeadName() { const t = teamById(view.id); return t ? t.name : "Category"; }
function teamHeadDetail() { const t = teamById(view.id); return t ? `Category · ${(t.members || []).length} bot${(t.members || []).length === 1 ? "" : "s"}` : ""; }
function renderHeadActions() {
  followBotSettings();
  const box = $("#head-actions");
  if (!box) return;
  const kind = view.kind === "bot" ? "bot" : view.kind === "group" ? "group" : "";
  once("head-actions", JSON.stringify([kind, view.id]), () => {
    box.innerHTML = kind === "bot" ? `<button class="btn sm" id="head-settings">Settings</button>` : kind === "group" ? `<button class="btn sm" id="head-edit-group">Edit</button>` : "";
    const s = $("#head-settings"); if (s) s.onclick = () => openBotSettings(view.id);
    const g = $("#head-edit-group"); if (g) g.onclick = () => openGroupEditor(state.groups.find((x) => x.id === view.id));
  });
}

/* ---------------- the team page ---------------- */
function renderTeamPage() {
  const team = teamById(view.id);
  const pane = $("#pane");
  if (!team) { once("team", "gone", () => { pane.innerHTML = `<div class="column"><p class="muted">This category is gone.</p></div>`; }); return; }
  const ceo = ceoBotId();
  const members = (team.members || []).filter((id) => id !== ceo && botExists(id));
  const faceSig = members.map((id) => [id, face(id).state]);
  const botSig = state.bots.map((b) => [b.id, b.name, b.description, b.enabled, b.model, b.primary]);
  once("team", JSON.stringify([team, faceSig, botSig]), () => drawTeamPage(team, members));
}

function drawTeamPage(team, members) {
  const pane = $("#pane");
  const ceo = ceoBotId(), boss = ceoName();
  const manager = team.leader && members.includes(team.leader) ? team.leader : null;
  const plain = members.filter((id) => id !== manager);
  const botOf = (id) => state.bots.find((b) => b.id === id) || {};
  const avatars = (ids) => ids.slice(0, 5).map((id) => botHTML(id, 30, { badge: false })).join("") || `<span class="empty-box"></span>`;
  const node = (title, icon, detail) => `<div class="node"><div class="node-h">${title}</div><div class="node-i">${icon}</div><div class="node-d">${esc(detail)}</div></div>`;
  const arrow = `<span class="flow" aria-hidden="true"></span>`;
  const schedule = team.schedule || "off";
  const scheduleWord = (REPORT_SCHEDULES.find(([k]) => k === schedule) || [])[1];
  const managerOptions = `<option value="">No manager: everyone reports to ${esc(boss)}</option>` + members.map((id) => `<option value="${esc(id)}"${id === team.leader ? " selected" : ""}>${esc(nameOf(id))}</option>`).join("");
  const others = state.bots.filter((b) => !b.primary && !members.includes(b.id));
  const cards = members.map((id) => {
    const b = botOf(id), f = face(id), isLeader = id === team.leader;
    const working = ["working", "thinking"].includes(f.state);
    const status = b.enabled === false ? "Off" : working ? "Working" : "Ready";
    return `<div class="member${isLeader ? " leader" : ""}" data-open="${esc(id)}" tabindex="0">${botHTML(id, 46)}<div class="m-tx"><b>${esc(b.name)}${isLeader ? `<span class="mgr">${CROWN_SVG}Manager</span>` : ""}</b>`
      + `<small>${esc(b.description || "No description yet")}</small><span class="m-st"><i class="${b.enabled === false ? "off" : working ? "busy" : "ready"}"></i>${status} · ${esc(b.model || "")}</span>`
      + `<span class="btns"><button class="btn sm" data-leader="${isLeader ? "" : esc(id)}">${isLeader ? "Remove as manager" : "Make manager"}</button><button class="btn sm ghost" data-remove-member="${esc(id)}">Remove from category</button></span></div></div>`;
  }).join("");
  const empty = `<div class="members-empty"><p class="muted">Make a new bot for this team, add one you have with “Add bot”, or drag one onto this category in the sidebar.</p><button class="btn" data-new-member>Make a new bot</button></div>`;
  const reports = (team.reports || []).slice().reverse().map((r) => `<div class="report">${botExists(r.author) ? botHTML(r.author, 28, { badge: false }) : ""}<div><div class="r-h"><b>${esc(botExists(r.author) ? nameOf(r.author) : "A bot")}</b><time>${ago(r.at)}</time></div><div class="r-t">${md(r.text)}</div></div></div>`).join("")
    || `<p class="muted">${team.leader ? "No reports yet. Members report to the manager, who rolls them up for the CEO." : "No reports yet. With no manager, each bot reports for itself."}</p>`;
  pane.innerHTML = `<div class="column team-page">`
    + `<div class="team-card"><div class="team-id"><input id="team-name" class="team-name" value="${esc(team.name)}" maxlength="80" aria-label="Category name" placeholder="Category name">`
    + `<input id="team-purpose" class="team-purpose" value="${esc(team.purpose || "")}" maxlength="200" aria-label="What this category is for" placeholder="What is this category for?">`
    + `<div class="pills"><span class="pill plain"><i class="dot"></i>${members.length} bot${members.length === 1 ? "" : "s"}</span>${schedule !== "off" ? `<span class="pill plain"><i class="dot"></i>${esc(scheduleWord || schedule)}</span>` : ""}</div></div>`
    + `<button class="btn pri" id="team-report"${members.length ? "" : " disabled"}>Report to ${esc(boss)} now</button></div>`
    + `<div class="team-card chain"><div class="chain-top">${CROWN_SVG.replace('class="crown"', `class="crown${team.hasManager ? " on" : ""}"`)}<span class="tx"><b>Has a manager</b><small>${team.hasManager
      ? `Members send their reports and DMs to ${esc(manager ? nameOf(manager) : "the manager")}, who rolls them up and reports to ${esc(boss)}.`
      : `Every member reports to ${esc(boss)} directly.`}</small></span><label class="switch"><input type="checkbox" id="team-has-manager"${team.hasManager ? " checked" : ""} aria-label="Has a manager"><i></i></label></div>`
    + `<div class="chain-row">${node(team.hasManager ? "Members" : "Team", avatars(plain), plain.length ? plain.map(nameOf).join(", ") : "No bots yet")}${arrow}`
    + (team.hasManager ? `${node("Manager", manager ? `<span class="crowned">${botHTML(manager, 30, { badge: false })}${CROWN_SVG}</span>` : `<span class="empty-box"></span>`, manager ? nameOf(manager) : "Pick one")}${arrow}` : "")
    + `${node("Reports to", botHTML(ceo, 30, { badge: false }), `${boss}, the CEO`)}<div class="chain-pick">`
    + (team.hasManager ? `<label>Team manager<select id="team-leader">${managerOptions}</select></label>` : "")
    + `<label>Report on a schedule<select id="team-schedule">${REPORT_SCHEDULES.map(([k, w]) => `<option value="${k}"${k === schedule ? " selected" : ""}>${w}</option>`).join("")}</select></label></div></div></div>`
    + `<div class="row-h"><h2>Members</h2><select id="team-add" aria-label="Add bot"><option value="">Add bot</option><option value="new">Make a new bot…</option>${others.length ? others.map((b) => `<option value="${esc(b.id)}">${esc(b.name)}</option>`).join("") : `<option disabled>Every bot is already here</option>`}</select></div>`
    + `<div class="members">${cards || empty}</div>`
    + `<h2>Reports to ${esc(boss)}</h2><div class="reports">${reports}</div>`
    + `<div class="team-foot"><button class="btn ghost danger" id="team-delete">Delete category (keeps its bots)</button></div></div>`;
  const id = team.id;
  const update = async (fields) => { await invoke(Object.assign({ cmd: "teamUpdate", id }, fields)); refresh(); };
  $("#team-name").onchange = (e) => { if (e.target.value.trim()) update({ name: e.target.value.trim() }); else e.target.value = team.name; };
  $("#team-name").onkeydown = (e) => { if (e.key === "Enter") e.target.blur(); };
  $("#team-purpose").onchange = (e) => update({ purpose: e.target.value.trim() });
  $("#team-purpose").onkeydown = (e) => { if (e.key === "Enter") e.target.blur(); };
  $("#team-has-manager").onchange = (e) => update({ hasManager: e.target.checked });
  if ($("#team-leader")) $("#team-leader").onchange = (e) => update({ leader: e.target.value || null });
  $("#team-schedule").onchange = async (e) => { await invoke({ cmd: "teamReportSchedule", id, schedule: e.target.value }); refresh(); };
  $("#team-report").onclick = () => reportNow(id);
  $("#team-delete").onclick = () => deleteCategory(id);
  $("#team-add").onchange = async (e) => {
    const choice = e.target.value;
    e.target.value = "";
    if (choice === "new") return newBotForTeam(id);
    if (choice) { await invoke({ cmd: "teamMember", id, bot: choice, action: "add" }); refresh(); }
  };
  pane.querySelectorAll("[data-new-member]").forEach((b) => b.onclick = () => newBotForTeam(id));
  pane.querySelectorAll("[data-leader]").forEach((b) => b.onclick = (e) => { e.stopPropagation(); update({ leader: b.dataset.leader || null }); });
  pane.querySelectorAll("[data-remove-member]").forEach((b) => b.onclick = async (e) => { e.stopPropagation(); await invoke({ cmd: "teamMember", id, bot: b.dataset.removeMember, action: "remove" }); refresh(); });
  pane.querySelectorAll(".member[data-open]").forEach((c) => {
    c.onclick = () => open({ kind: "bot", id: c.dataset.open });
    c.onkeydown = (e) => { if (e.key === "Enter") open({ kind: "bot", id: c.dataset.open }); };
  });
}

// "Make a new bot" from a team page: the bot joins the team and the page stays put, so it shows under Members at once.
let newBotJoinsTeam = null;
function newBotForTeam(teamId) { newBotJoinsTeam = teamId; openBotDialog({ kind: "new" }); }
// Called by app.js once a bot is made. True: it joined a team and the team page stays open.
async function teamTakesNewBot(botId) {
  const teamId = newBotJoinsTeam;
  newBotJoinsTeam = null;
  if (!teamId || view.kind !== "team" || view.id !== teamId) return false;
  await invoke({ cmd: "teamMember", id: teamId, bot: botId, action: "add" });
  refresh();
  return true;
}

/* ---------------- a group chat's head and members ---------------- */
// Like the Mac's: two to six bots, the head included; deleting one takes its chat, never its bots.
function slugOf(name) { return name.toLowerCase().normalize("NFKD").replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 40) || "group"; }
function openGroupEditor(group) {
  const isNew = !group;
  const draft = { id: group ? group.id : "", name: group ? group.name : "", head: group ? group.head || "" : "", members: group ? (group.members || []).slice() : [] };
  let d = $("#group-dialog");
  if (!d) { d = document.createElement("dialog"); d.id = "group-dialog"; document.body.appendChild(d); }
  const draw = () => {
    const all = (draft.head ? [draft.head] : []).concat(draft.members.filter((m) => m !== draft.head));
    const fits = !!draft.head && all.length >= 2 && all.length <= 6;
    d.innerHTML = `<form method="dialog" id="group-form"><h2>${isNew ? "New group" : `Edit ${esc(group.name)}`}</h2>`
      + `<label>Name <input id="group-name" maxlength="60" value="${esc(draft.name)}" placeholder="Marketing, Research team, Side project…"></label>`
      + `<label>Head <select id="group-head"><option value="">Pick a head</option>${state.bots.map((b) => `<option value="${esc(b.id)}"${b.id === draft.head ? " selected" : ""}>${esc(b.name)}</option>`).join("")}</select></label>`
      + `<p class="hint">The head leads the group chat: they hand your request to the others and merge their answers. Ask them to build something and it goes to your coding harness.</p>`
      + `<div class="lbl">Members</div><div class="pick-list">${state.bots.filter((b) => b.id !== draft.head).map((b) => `<label class="pick"><input type="checkbox" data-member="${esc(b.id)}"${draft.members.includes(b.id) ? " checked" : ""}>${botHTML(b.id, 22, { badge: false })}<span>${esc(b.name)}</span><small>${esc(b.model || "")}</small></label>`).join("")}</div>`
      + `<p class="hint${fits ? "" : " warn"}">${fits ? `${all.length} bots` : "Pick a head and 1 to 5 other bots (2 to 6 in all)."}</p>`
      + `<menu>${isNew ? "" : `<button type="button" class="btn danger" id="group-delete">Delete group</button><span class="grow"></span>`}<button value="cancel" class="btn" formnovalidate>Cancel</button><button value="ok" class="btn pri" id="group-save"${fits && draft.name.trim() ? "" : " disabled"}>${isNew ? "Create group" : "Save"}</button></menu></form>`;
    const name = d.querySelector("#group-name");
    name.oninput = () => { draft.name = name.value; d.querySelector("#group-save").disabled = !(fits && draft.name.trim()); };
    d.querySelector("#group-head").onchange = (e) => { draft.head = e.target.value; draft.members = draft.members.filter((m) => m !== draft.head); draw(); };
    d.querySelectorAll("[data-member]").forEach((c) => c.onchange = () => {
      draft.members = c.checked ? draft.members.concat([c.dataset.member]) : draft.members.filter((m) => m !== c.dataset.member);
      draw();
    });
    const del = d.querySelector("#group-delete");
    if (del) del.onclick = async () => { d.close(); await deleteGroup(group); };
    d.querySelector("#group-form").onsubmit = async (e) => {
      if (!e.submitter || e.submitter.value !== "ok") return;
      let id = draft.id;
      if (!id) {
        const base = slugOf(draft.name.trim());
        id = base;
        for (let n = 2; state.groups.some((g) => g.id === id); n++) id = `${base}-${n}`;
      }
      const r = await invoke({ cmd: "groupSave", id, name: draft.name.trim(), head: draft.head, members: draft.members.filter((m) => m !== draft.head) });
      if (r.ok) { await refresh(); open({ kind: "group", id }); }
    };
  };
  draw();
  d.showModal();
  const name = d.querySelector("#group-name"); if (name) name.focus();
}
