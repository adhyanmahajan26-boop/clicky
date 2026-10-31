//
//  ClaudiaUIPage.swift
//  leanring-buddy
//
//  The page ClaudiaUIServer serves: Claudia's whole UI in one place (the
//  T3 Code Claudia section embeds it). Conversation + composer, Talk
//  (hands-free on Claudia's mic), brain/helper pickers, voice, the
//  whiteboard with its controls, research briefs with sources, and
//  Claudia's screen / spark settings. Plain HTML/JS, no outside requests.
//

enum ClaudiaUIPage {
    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Theo</title>
<style>
:root { --bg:#141312; --panel:#1c1b19; --panel2:#24221f; --line:#2f2c29; --text:#ece8e3; --muted:#9a948c; --accent:#d97757; --ok:#7fb069; --bad:#e06c5b; }
:root[data-theme="light"] { --bg:#f7f5f2; --panel:#ffffff; --panel2:#f1eee9; --line:#e2ddd6; --text:#1f1d1a; --muted:#6f6a63; }
* { box-sizing: border-box; }
body { margin:0; background:var(--bg); color:var(--text); font:14px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; height:100vh; display:flex; flex-direction:column; }
header { display:flex; align-items:center; gap:12px; padding:10px 16px; border-bottom:1px solid var(--line); background:var(--panel); }
header h1 { font-size:15px; margin:0; display:flex; align-items:center; gap:8px; font-weight:600; }
.spark { width:18px; height:18px; color:var(--accent); }
.spacer { flex:1; }
select, input[type=text], textarea { background:var(--panel2); color:var(--text); border:1px solid var(--line); border-radius:8px; padding:6px 8px; font:inherit; }
button { background:var(--panel2); color:var(--text); border:1px solid var(--line); border-radius:8px; padding:6px 10px; font:inherit; cursor:pointer; }
button:hover { border-color:var(--accent); }
button.primary { background:var(--accent); border-color:var(--accent); color:#fff; }
button.on { background:var(--accent); color:#fff; border-color:var(--accent); }
main { flex:1; display:grid; grid-template-columns:minmax(0,1fr) 380px; min-height:0; }
@media (max-width: 860px) { main { grid-template-columns:1fr; } aside { border-left:none; border-top:1px solid var(--line); } }
.chat { display:flex; flex-direction:column; min-height:0; }
#turns { flex:1; overflow:auto; padding:16px; display:flex; flex-direction:column-reverse; gap:14px; }
.turn .you { align-self:flex-end; background:var(--panel2); border:1px solid var(--line); border-radius:12px 12px 4px 12px; padding:8px 12px; max-width:80%; margin-left:auto; width:fit-content; }
.turn .theo { margin-top:6px; padding:2px 2px; max-width:92%; white-space:pre-wrap; }
.turn .board { color:var(--accent); font-size:12px; margin-top:4px; }
.composer { border-top:1px solid var(--line); padding:12px 16px; display:flex; gap:8px; align-items:flex-end; background:var(--panel); }
.composer textarea { flex:1; resize:none; height:44px; }
aside { border-left:1px solid var(--line); overflow:auto; background:var(--panel); }
section { padding:14px 16px; border-bottom:1px solid var(--line); }
section h2 { font-size:12px; text-transform:uppercase; letter-spacing:.06em; color:var(--muted); margin:0 0 10px; font-weight:600; }
.row { display:flex; gap:8px; align-items:center; margin:6px 0; flex-wrap:wrap; }
.row label { color:var(--muted); min-width:84px; }
.row select { flex:1; min-width:0; }
#boardImage { width:100%; border-radius:8px; border:1px solid var(--line); background:#fff; display:none; margin-top:8px; }
#brief { white-space:pre-wrap; font-size:13px; max-height:320px; overflow:auto; }
#sources a { color:var(--accent); display:block; font-size:12px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.muted { color:var(--muted); font-size:12px; }
.status { font-size:12px; color:var(--muted); }
.empty { color:var(--muted); text-align:center; margin:auto; padding:40px; }
.tabs { display:flex; gap:4px; padding:8px 16px 0; border-bottom:1px solid var(--line); background:var(--panel); }
.tabs button { border-radius:8px 8px 0 0; border-bottom:none; background:transparent; }
.tabs button.active { background:var(--bg); border-color:var(--line); color:var(--accent); }
#notesView { display:none; flex:1; min-height:0; overflow:auto; padding:16px; }
.lib { display:grid; grid-template-columns:repeat(auto-fill, minmax(220px, 1fr)); gap:12px; }
.card { background:var(--panel); border:1px solid var(--line); border-radius:12px; padding:10px; display:flex; flex-direction:column; gap:6px; cursor:pointer; }
.card.selected { border-color:var(--accent); box-shadow:0 0 0 1px var(--accent) inset; }
.card img { width:100%; height:120px; object-fit:cover; border-radius:8px; background:#fff; }
.card .kind { font-size:11px; text-transform:uppercase; letter-spacing:.05em; color:var(--accent); }
.card .title { font-weight:600; font-size:13px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.card label { font-size:12px; color:var(--muted); display:flex; gap:6px; align-items:center; }
.codebar { position:sticky; top:0; background:var(--bg); padding-bottom:12px; margin-bottom:12px; border-bottom:1px solid var(--line); display:flex; flex-direction:column; gap:8px; z-index:1; }
#notePreview { white-space:pre-wrap; background:var(--panel); border:1px solid var(--line); border-radius:12px; padding:12px; margin-top:12px; display:none; font-size:13px; max-height:360px; overflow:auto; }
</style>
</head>
<body>
<header>
  <h1><svg class="spark" viewBox="0 0 24 24" fill="currentColor"><path d="M12 1.5l1.6 7.1 5.6-4.6-3.4 6.4 7.2.6-6.9 2.2 5 5.3-6.6-3-1.2 7.1-1.3-7.1-6.6 3 5-5.3-6.9-2.2 7.2-.6-3.4-6.4 5.6 4.6z"/></svg> Theo</h1>
  <span id="version" class="status"></span>
  <span class="spacer"></span>
  <button id="talk" title="Talk to Theo (her mic, hands-free)">🎙 Talk</button>
  <button id="voice" title="Theo speaks her answers">🔊 Voice on</button>
  <button id="stop" title="Stop talking and anything in flight">■ Stop</button>
</header>
<main>
  <div class="chat">
    <div class="tabs"><button id="tabChat" class="active">Conversation</button><button id="tabNotes">Notes</button></div>
    <div id="notesView">
      <div class="codebar">
        <div class="row"><strong>Code with your notes</strong><span class="muted" id="pickedCount"></span><span class="spacer"></span><button id="markScreen">📸 Marked screenshot now</button></div>
        <div class="row"><select id="project" style="flex:1"><option value="">Choose a project…</option></select></div>
        <div class="row"><input type="text" id="codeInstructions" placeholder="What to build or change, e.g. 'make the homepage match my notes and the marked screenshot'" style="flex:1"><button class="primary" id="startCode">Start coding</button></div>
        <div class="muted" id="codeStatus">Tick notes and screenshots below, then start: Claude Code gets them as attachments. Any T3 Code thread can also ask Theo for them (claudia_attachments).</div>
      </div>
      <div class="lib" id="library"></div>
      <div id="notePreview"></div>
    </div>
    <div id="turns"><div class="empty">Ask Theo anything about your screen, or have her draw, research or do something.</div></div>
    <div class="composer">
      <textarea id="ask" placeholder="Ask Theo… (Enter to send, Shift+Enter for a new line)"></textarea>
      <button class="primary" id="send">Ask</button>
    </div>
  </div>
  <aside>
    <section>
      <h2>Brain</h2>
      <div class="row"><label>Answers</label><select id="brain"></select></div>
      <div class="row"><label>Helpers</label><select id="helper"></select></div>
      <div class="muted">Models from your Claude, ChatGPT (Codex), Cursor and OpenCode subscriptions.</div>
    </section>
    <section>
      <h2>Whiteboard</h2>
      <div class="row">
        <button data-board="back">◀</button><button data-board="next">▶</button><button data-board="replay">↺</button>
        <button data-board="expand">Expand</button><button data-board="close">×</button><button id="boardShow">Show here</button>
      </div>
      <div class="row"><label>Auto boards</label><select id="autoBoard"><option value="true">Small side board for complex questions</option><option value="false">Only when I ask</option></select></div>
      <div id="boardStatus" class="muted">No board open.</div>
      <img id="boardImage" alt="Theo's whiteboard">
    </section>
    <section>
      <h2>Research</h2>
      <div class="row"><input type="text" id="researchQuestion" placeholder="Topic, or 'the 3 links on my screen'" style="flex:1"><button id="research">Research</button></div>
      <div class="muted">One Haiku agent per page, then a brief with sources.</div>
      <div id="researchState" class="status"></div>
      <div id="brief"></div>
      <div id="sources"></div>
    </section>
    <section>
      <h2>Screen and spark</h2>
      <div class="row"><label>Her screen</label><select id="claudiaScreen"></select></div>
      <div class="row"><label>Style</label><select id="sparkStyle"></select></div>
      <div class="row"><label>Theme</label><select id="theme"></select></div>
      <div class="row"><label>Spark</label><select id="sparkMode"><option value="cursor">Follows my pointer</option><option value="docked">Lives on its own</option></select></div>
    </section>
  </aside>
</main>
<script>
const token = new URLSearchParams(location.search).get("token") || /*CLAUDIA_TOKEN*/"";
async function api(cmd, body = {}) {
  const response = await fetch("/api/" + cmd, { method: "POST", headers: { "Content-Type": "application/json", "X-Claudia-Token": token }, body: JSON.stringify(body) });
  return response.json();
}
const $ = (id) => document.getElementById(id);
let settings = {};
let lastTurnsKey = "";
let listening = false;

function escapeHTML(text) { return (text || "").replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c])); }

function fillModels(select, models, providerNames, current) {
  select.innerHTML = "";
  for (const [provider, list] of Object.entries(models)) {
    if (!list.length) continue;
    const group = document.createElement("optgroup");
    group.label = providerNames[provider] || provider;
    for (const model of list) {
      const option = document.createElement("option");
      option.value = model; option.textContent = model.includes(":") ? model.split(":").slice(1).join(":") : model;
      group.appendChild(option);
    }
    select.appendChild(group);
  }
  if (![...select.options].some((o) => o.value === current)) {
    const option = document.createElement("option"); option.value = current; option.textContent = current; select.appendChild(option);
  }
  select.value = current;
}

async function loadSettings(change = {}) {
  const reply = await api("settings", change);
  if (!reply.ok) return;
  settings = reply.result;
  $("version").textContent = settings.version || "";
  fillModels($("brain"), settings.models, settings.providerNames, settings.brain);
  fillModels($("helper"), settings.models, settings.providerNames, settings.helper);
  $("voice").textContent = settings.silentMode ? "🔇 Silent" : "🔊 Voice on";
  $("voice").classList.toggle("on", !settings.silentMode);
  $("sparkMode").value = settings.sparkMode;
  $("sparkStyle").innerHTML = (settings.sparkStyles || []).map((s) => `<option value="${s.id}">${escapeHTML(s.name)}</option>`).join("");
  $("sparkStyle").value = settings.sparkStyle;
  $("theme").innerHTML = (settings.themes || []).map((t) => `<option value="${t.id}">${escapeHTML(t.name)}</option>`).join("");
  $("theme").value = settings.theme;
  applyPalette(settings.palette || {});
  $("autoBoard").value = String(settings.autoBoard);
  const screenSelect = $("claudiaScreen");
  screenSelect.innerHTML = '<option value="">Wherever my pointer is</option>' + settings.screens.map((s) => `<option>${escapeHTML(s)}</option>`).join("");
  screenSelect.value = settings.claudiaScreen || "";
}

let lastBoardKey = null, lastResearchKey = null, lastLibraryKey = null;
async function loadTurns() {
  const reply = await api("turns", { limit: 40 });
  if (!reply.ok) return;
  const key = reply.result.map((t) => t.id + (t.claudia || "").length).join(",");
  if (key === lastTurnsKey) return;
  lastTurnsKey = key;
  const container = $("turns");
  if (!reply.result.length) return;
  container.innerHTML = reply.result.map((t) => `<div class="turn"><div class="you">${escapeHTML(t.you)}</div><div class="theo">${escapeHTML(t.claudia)}</div>${t.board ? `<div class="board">▦ Whiteboard: ${escapeHTML(t.board)}</div>` : ""}</div>`).join("");
}

async function loadBoard() {
  const reply = await api("board", { action: "state" });
  if (!reply.ok) return;
  const board = reply.result;
  const boardKey = JSON.stringify(board);
  if (boardKey === lastBoardKey) return;
  lastBoardKey = boardKey;
  $("boardStatus").textContent = board.open ? `${board.title || "Board"} · step ${board.currentStep || 0} of ${board.steps || 0}${board.side ? " · side board" : ""}` : (board.hasBoard ? `${board.title} (closed)` : "No board open.");
}

async function loadResearch() {
  const reply = await api("researchLatest");
  if (!reply.ok) return;
  const r = reply.result || {};
  const researchKey = JSON.stringify([r.state, r.topic, r.brief, (r.sources || []).map((s) => s.url)]);
  if (researchKey === lastResearchKey) return;
  lastResearchKey = researchKey;
  $("researchState").textContent = r.state && r.state !== "idle" ? `${r.topic || "Research"}: ${r.state}` : "";
  $("brief").textContent = r.brief || "";
  $("sources").innerHTML = (r.sources || []).map((s, i) => `<a href="${escapeHTML(s.url)}" target="_blank" rel="noreferrer">[${i + 1}] ${escapeHTML(s.url)}</a>`).join("");
}

async function send() {
  const text = $("ask").value.trim();
  if (!text) return;
  $("ask").value = "";
  const container = $("turns");
  const pending = document.createElement("div");
  pending.className = "turn";
  pending.innerHTML = `<div class="you">${escapeHTML(text)}</div><div class="theo muted">Theo is thinking…</div>`;
  if (container.querySelector(".empty")) container.innerHTML = "";
  container.prepend(pending);
  await api("ask", { text, speak: !settings.silentMode });
  lastTurnsKey = "";
  loadTurns(); loadBoard(); loadResearch();
}

let currentTab = "chat";
function showTab(tab) {
  currentTab = tab;
  $("tabChat").classList.toggle("active", tab === "chat");
  $("tabNotes").classList.toggle("active", tab === "notes");
  $("turns").style.display = tab === "chat" ? "flex" : "none";
  document.querySelector(".composer").style.display = tab === "chat" ? "flex" : "none";
  $("notesView").style.display = tab === "notes" ? "block" : "none";
  if (tab === "notes") { loadLibrary(); loadProjects(); }
}
$("tabChat").onclick = () => showTab("chat");
$("tabNotes").onclick = () => showTab("notes");

async function loadLibrary() {
  const reply = await api("library");
  if (!reply.ok) return;
  const items = reply.result;
  const libraryKey = JSON.stringify(items);
  if (libraryKey === lastLibraryKey) return;
  lastLibraryKey = libraryKey;
  $("pickedCount").textContent = `${items.filter((i) => i.selected).length} picked`;
  $("library").innerHTML = items.length ? items.map((item) => `
    <div class="card ${item.selected ? "selected" : ""}" data-id="${item.id}" data-image="${item.isImage}">
      <div class="kind">${escapeHTML(item.kind)}</div>
      ${item.isImage ? `<img loading="lazy" src="/api/file?id=${encodeURIComponent(item.id)}&token=${encodeURIComponent(token)}">` : ""}
      <div class="title" title="${escapeHTML(item.title)}">${escapeHTML(item.title)}</div>
      <div class="muted">${new Date(item.date).toLocaleString()}</div>
      <label><input type="checkbox" ${item.selected ? "checked" : ""} data-pick="${item.id}"> Use in code</label>
    </div>`).join("") : '<div class="empty">No notes yet. Ask Theo to highlight an article, research something, draw a whiteboard, or take a marked screenshot.</div>';
  document.querySelectorAll("[data-pick]").forEach((box) => box.onclick = async (event) => {
    event.stopPropagation();
    await api("librarySelect", { id: box.dataset.pick, selected: box.checked });
    loadLibrary();
  });
  document.querySelectorAll(".card").forEach((card) => card.onclick = async () => {
    const preview = $("notePreview");
    if (card.dataset.image === "true") { preview.style.display = "none"; return; }
    const note = await api("libraryText", { id: card.dataset.id });
    if (note.ok) { preview.textContent = note.result.text; preview.style.display = "block"; preview.scrollIntoView({ behavior: "smooth" }); }
  });
}
async function loadProjects() {
  const reply = await api("projects");
  if (!reply.ok) return;
  const select = $("project"), current = select.value;
  select.innerHTML = '<option value="">Choose a project…</option>' + reply.result.map((p) => `<option value="${escapeHTML(p.path)}">${escapeHTML(p.name)}</option>`).join("");
  select.value = current;
}
$("markScreen").onclick = async () => {
  $("codeStatus").textContent = "Taking a screenshot with Theo's marks…";
  const reply = await api("markScreen");
  if (reply.ok) { await api("librarySelect", { id: reply.result.id, selected: true }); $("codeStatus").textContent = "Saved and picked for code."; }
  else $("codeStatus").textContent = reply.error || "Couldn't take it.";
  loadLibrary();
};
$("startCode").onclick = async () => {
  const project = $("project").value, instructions = $("codeInstructions").value.trim();
  if (!project || !instructions) { $("codeStatus").textContent = "Pick a project and say what to do."; return; }
  const reply = await api("useInCode", { project, instructions });
  $("codeStatus").textContent = reply.ok ? `Claude Code is working in ${reply.result.project} with ${reply.result.attachments.length} attachment(s). Follow it in Theo's Agents dashboard.` : (reply.error || "Couldn't start.");
};

$("send").onclick = send;
$("ask").addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send(); } });
$("stop").onclick = () => api("stop");
$("voice").onclick = () => loadSettings({ silentMode: !settings.silentMode });
$("talk").onclick = async () => {
  const reply = await api("listen", { on: !listening });
  listening = !!(reply.result && reply.result.listening);
  $("talk").classList.toggle("on", listening);
  $("talk").textContent = listening ? "🎙 Listening… (click to stop)" : "🎙 Talk";
};
$("brain").onchange = (e) => loadSettings({ brain: e.target.value });
$("helper").onchange = (e) => loadSettings({ helper: e.target.value });
$("sparkMode").onchange = (e) => loadSettings({ sparkMode: e.target.value });
$("sparkStyle").onchange = (e) => loadSettings({ sparkStyle: e.target.value });
$("theme").onchange = (e) => loadSettings({ theme: e.target.value });
function applyPalette(palette) {
  const root = document.documentElement.style;
  for (const name of ["bg", "panel", "panel2", "line", "text", "muted", "accent"]) {
    if (palette[name]) root.setProperty("--" + name, palette[name]); else root.removeProperty("--" + name);
  }
}
$("claudiaScreen").onchange = (e) => loadSettings({ claudiaScreen: e.target.value });
$("autoBoard").onchange = (e) => loadSettings({ autoBoard: e.target.value === "true" });
document.querySelectorAll("[data-board]").forEach((b) => b.onclick = async () => { await api("board", { action: b.dataset.board }); loadBoard(); });
$("boardShow").onclick = () => { const img = $("boardImage"); img.src = "/api/board.png?token=" + encodeURIComponent(token) + "&t=" + Date.now(); img.style.display = "block"; };
$("research").onclick = async () => {
  const question = $("researchQuestion").value.trim();
  if (!question) return;
  $("researchState").textContent = "Starting research agents…";
  api("research", { question, speak: false }).then(loadResearch);
  setTimeout(loadResearch, 1500);
};
if (matchMedia("(prefers-color-scheme: light)").matches) document.documentElement.dataset.theme = "light";
loadSettings(); loadTurns(); loadBoard(); loadResearch();
if (location.hash === "#notes") showTab("notes");
setInterval(() => { loadTurns(); loadBoard(); loadResearch(); }, 3000);
</script>
</body>
</html>
"""#
}
