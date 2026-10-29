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
<title>Claudia</title>
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
.turn .claudia { margin-top:6px; padding:2px 2px; max-width:92%; white-space:pre-wrap; }
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
</style>
</head>
<body>
<header>
  <h1><svg class="spark" viewBox="0 0 24 24" fill="currentColor"><path d="M12 1.5l1.6 7.1 5.6-4.6-3.4 6.4 7.2.6-6.9 2.2 5 5.3-6.6-3-1.2 7.1-1.3-7.1-6.6 3 5-5.3-6.9-2.2 7.2-.6-3.4-6.4 5.6 4.6z"/></svg> Claudia</h1>
  <span id="version" class="status"></span>
  <span class="spacer"></span>
  <button id="talk" title="Talk to Claudia (her mic, hands-free)">🎙 Talk</button>
  <button id="voice" title="Claudia speaks her answers">🔊 Voice on</button>
  <button id="stop" title="Stop talking and anything in flight">■ Stop</button>
</header>
<main>
  <div class="chat">
    <div id="turns"><div class="empty">Ask Claudia anything about your screen, or have her draw, research or do something.</div></div>
    <div class="composer">
      <textarea id="ask" placeholder="Ask Claudia… (Enter to send, Shift+Enter for a new line)"></textarea>
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
      <img id="boardImage" alt="Claudia's whiteboard">
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
  $("autoBoard").value = String(settings.autoBoard);
  const screenSelect = $("claudiaScreen");
  screenSelect.innerHTML = '<option value="">Wherever my pointer is</option>' + settings.screens.map((s) => `<option>${escapeHTML(s)}</option>`).join("");
  screenSelect.value = settings.claudiaScreen || "";
}

async function loadTurns() {
  const reply = await api("turns", { limit: 40 });
  if (!reply.ok) return;
  const key = reply.result.map((t) => t.id + (t.claudia || "").length).join(",");
  if (key === lastTurnsKey) return;
  lastTurnsKey = key;
  const container = $("turns");
  if (!reply.result.length) return;
  container.innerHTML = reply.result.map((t) => `<div class="turn"><div class="you">${escapeHTML(t.you)}</div><div class="claudia">${escapeHTML(t.claudia)}</div>${t.board ? `<div class="board">▦ Whiteboard: ${escapeHTML(t.board)}</div>` : ""}</div>`).join("");
}

async function loadBoard() {
  const reply = await api("board", { action: "state" });
  if (!reply.ok) return;
  const board = reply.result;
  $("boardStatus").textContent = board.open ? `${board.title || "Board"} · step ${board.currentStep || 0} of ${board.steps || 0}${board.side ? " · side board" : ""}` : (board.hasBoard ? `${board.title} (closed)` : "No board open.");
}

async function loadResearch() {
  const reply = await api("researchLatest");
  if (!reply.ok) return;
  const r = reply.result || {};
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
  pending.innerHTML = `<div class="you">${escapeHTML(text)}</div><div class="claudia muted">Claudia is thinking…</div>`;
  if (container.querySelector(".empty")) container.innerHTML = "";
  container.prepend(pending);
  await api("ask", { text, speak: !settings.silentMode });
  lastTurnsKey = "";
  loadTurns(); loadBoard(); loadResearch();
}

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
setInterval(() => { loadTurns(); loadBoard(); loadResearch(); }, 3000);
</script>
</body>
</html>
"""#
}
