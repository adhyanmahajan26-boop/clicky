// Theo's desktop UI. Everything goes through one command, `control`, which takes the same JSON commands as theod's control inbox.
const invoke = (cmd) => window.__TAURI__.core.invoke("control", { cmd });
const $ = (s) => document.querySelector(s);
const PALETTE = [["#F2784B", "#E0476A"], ["#F5B13D", "#E8782E"], ["#9BD14B", "#3FA65C"], ["#3FC8B4", "#2E8FB8"], ["#4EA8F0", "#4A6FE0"],
  ["#6E7BF0", "#8A55E0"], ["#A468EB", "#D152B8"], ["#F06A8F", "#E24A58"], ["#7C8697", "#4D5666"]];
let state = { bots: [], groups: [] };
let view = { kind: "bot", id: "theo" };
let shownCount = -1;

function hash(s) { let h = 0; for (const c of s) h = (h * 31 + c.charCodeAt(0)) | 0; return Math.abs(h); }
function tile(el, id, name) {
  if (id === "theo") { el.className = "tile graphite"; el.textContent = "T"; el.style.cssText = ""; return el; }
  const [a, b] = PALETTE[hash(id) % PALETTE.length];
  el.className = "tile"; el.style.setProperty("--a", a); el.style.setProperty("--b", b);
  el.textContent = (name || "?").slice(0, 1).toUpperCase();
  return el;
}
function esc(s) { return s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c])); }
// Markdown, lightly: code fences, inline code, bold. Text stays text.
function md(text) {
  const parts = text.split(/```(\w*)\n?([\s\S]*?)(?:```|$)/g);
  let out = "";
  for (let i = 0; i < parts.length; i++) {
    if (i % 3 === 0) out += esc(parts[i]).replace(/`([^`\n]+)`/g, "<code>$1</code>").replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>").replace(/_\(([^)]*)\)_/g, "<em>($1)</em>");
    else if (i % 3 === 2) out += `<pre>${esc(parts[i])}</pre>`;
  }
  return out;
}
function nameOf(id) { return (state.bots.find((b) => b.id === id) || {}).name || id; }
function room() { return view.kind === "group" ? `group-${view.id}` : view.id; }

function renderSidebar() {
  const bots = $("#bots"); bots.innerHTML = "";
  for (const b of state.bots) {
    const row = document.createElement("button");
    row.className = "row" + (view.kind === "bot" && view.id === b.id ? " selected" : "");
    row.append(tile(document.createElement("span"), b.id, b.name), document.createTextNode(b.name));
    if ((state.replying || []).includes(b.id)) { const d = document.createElement("span"); d.className = "dot"; row.append(d); }
    row.onclick = () => open({ kind: "bot", id: b.id });
    bots.append(row);
  }
  const groups = $("#groups"); groups.innerHTML = "";
  for (const g of state.groups) {
    const row = document.createElement("button");
    row.className = "row" + (view.kind === "group" && view.id === g.id ? " selected" : "");
    row.append(tile(document.createElement("span"), g.id, g.name), document.createTextNode(g.name));
    row.onclick = () => open({ kind: "group", id: g.id });
    groups.append(row);
  }
}

function open(v) { view = v; shownCount = -1; refresh(); }

async function renderChat() {
  const isChat = view.kind === "bot" || view.kind === "group";
  $("#composer").style.display = isChat ? "" : "none";
  if (!isChat) return;
  const r = await invoke({ cmd: "botChat", id: room(), limit: 300 });
  const msgs = r.result || [];
  const name = view.kind === "group" ? (state.groups.find((g) => g.id === view.id) || {}).name : nameOf(view.id);
  $("#chat-name").textContent = name || "";
  tile($("#chat-tile"), view.id, name);
  const writing = Object.entries(state.replyingIn || {}).filter(([, r2]) => r2 === room()).map(([b]) => b);
  $("#chat-status").textContent = writing.length ? `${writing.map(nameOf).join(", ")} writing…` : "";
  $("#send").classList.toggle("stop", writing.length > 0);
  $("#send").innerHTML = writing.length ? "&#9632;" : "&#8593;";
  const live = writing.map((b) => [b, (state.live || {})[b] || ""]).filter(([, t]) => t);
  const key = msgs.length + "|" + live.map(([, t]) => t.length).join(",");
  if (key === shownCount) return;
  shownCount = key;
  const pane = $("#pane");
  const atBottom = pane.scrollHeight - pane.scrollTop - pane.clientHeight < 80;
  const col = document.createElement("div"); col.className = "column";
  if (!msgs.length) col.innerHTML = `<div class="empty">Say hello to ${esc(name || "")}.</div>`;
  let last = null;
  for (const m of msgs) {
    const el = document.createElement("div");
    if (m.card && m.card.startsWith("dm:")) {
      el.className = "msg card"; el.textContent = `${nameOf(m.author)} messaged ${nameOf(m.card.split(":")[2])} privately`;
    } else if (m.author === "user") { el.className = "msg user"; el.innerHTML = md(m.text); }
    else if (m.author === "note") { el.className = "msg note"; el.innerHTML = md(m.text); }
    else if (m.author === "routine") { el.className = "msg routine"; el.innerHTML = md(m.text); }
    else {
      el.className = "msg";
      if (last !== m.author) {
        const who = document.createElement("div"); who.className = "who";
        who.append(tile(document.createElement("span"), m.author, nameOf(m.author)), document.createTextNode(nameOf(m.author)));
        el.append(who);
      }
      const body = document.createElement("div"); body.innerHTML = md(m.text); el.append(body);
    }
    last = m.author; col.append(el);
  }
  for (const [b, t] of live) {
    const el = document.createElement("div"); el.className = "msg live";
    el.innerHTML = `<div class="who">${esc(nameOf(b))}</div>${md(t)}`; col.append(el);
  }
  pane.replaceChildren(col);
  if (atBottom || shownCount === -1) pane.scrollTop = pane.scrollHeight;
}

async function renderRoutines() {
  const r = (await invoke({ cmd: "routines" })).result || [];
  $("#chat-name").textContent = "Routines"; $("#chat-status").textContent = ""; tile($("#chat-tile"), "routines", "R");
  const rows = r.map((x) => `<tr><td>${esc(x.name)}</td><td>${esc(x.target.startsWith("group:") ? "Group" : nameOf(x.target))}</td>
    <td class="muted">${esc((x.runs.slice(-1)[0] || {}).status || "not run yet")}</td>
    <td><button class="btn" data-a="run" data-id="${x.id}">Run now</button> <button class="btn" data-a="${x.paused ? "resume" : "pause"}" data-id="${x.id}">${x.paused ? "Resume" : "Pause"}</button>
    <button class="btn" data-a="delete" data-id="${x.id}">Delete</button></td></tr>`).join("");
  $("#pane").innerHTML = `<div class="column"><h1>Routines</h1>${r.length ? `<table class="list"><tr><th>Name</th><th>Runs</th><th>Last</th><th></th></tr>${rows}</table>`
    : `<p class="muted">Ask a bot for something on a schedule ("every weekday at 8, send me a brief") and it sets one up here.</p>`}</div>`;
  $("#pane").querySelectorAll("button[data-a]").forEach((b) => b.onclick = async () => { await invoke({ cmd: "routines", action: b.dataset.a, id: b.dataset.id }); renderRoutines(); });
}

async function renderUsage() {
  const r = (await invoke({ cmd: "botsUsage", days: 7 })).result || { bots: [] };
  $("#chat-name").textContent = "Usage"; $("#chat-status").textContent = "Last 7 days"; tile($("#chat-tile"), "usage", "U");
  const rows = r.bots.map((b) => `<tr><td>${esc(b.name)}</td><td>${b.turns}</td><td>${(b.totalTokens / 1000).toFixed(1)}k</td><td>${b.costUSD == null ? "–" : "$" + b.costUSD.toFixed(2)}</td></tr>`).join("");
  $("#pane").innerHTML = `<div class="column"><h1>Usage</h1><table class="list"><tr><th>Bot</th><th>Turns</th><th>Tokens</th><th>Cost</th></tr>${rows}</table></div>`;
}

async function renderSettings() {
  const [doc, gw, st] = await Promise.all([invoke({ cmd: "doctor" }), invoke({ cmd: "gateway" }), invoke({ cmd: "status" })]);
  $("#chat-name").textContent = "Settings"; $("#chat-status").textContent = ""; tile($("#chat-tile"), "settings", "S");
  const f = (doc.result.findings || []).map((x) => `<div class="finding ${x.level}"><span class="mark">${x.level === "ok" ? "✓" : x.level === "warn" ? "!" : "✗"}</span><strong>${esc(x.check)}</strong>: ${esc(x.detail)}</div>`).join("");
  const g = gw.result;
  $("#pane").innerHTML = `<div class="column"><h1>Settings</h1>
    <h2>Health check</h2>${f}
    <h2>Local API</h2><p class="muted">Lets scripts on this computer message a bot on 127.0.0.1:${g.port}. Off by default; needs a token; never counts as you.</p>
    <button class="btn" id="gw">${g.listening ? "Turn off" : "Turn on"}</button>
    <h2>This computer</h2><p class="muted">${esc(st.result.os)} ${esc(st.result.arch)} · data in ${esc(String(st.result.data))} · Theo ${esc(st.result.version)}</p></div>`;
  $("#gw").onclick = async () => { await invoke({ cmd: "gateway", action: g.listening ? "off" : "on" }); renderSettings(); };
}

async function refresh() {
  try {
    state = (await invoke({ cmd: "botsState" })).result || state;
    renderSidebar();
    document.querySelectorAll(".footer .row").forEach((r) => r.classList.toggle("selected", view.kind === r.dataset.pane));
    if (view.kind === "bot" || view.kind === "group") await renderChat();
  } catch (e) { console.error(e); }
}

$("#composer").onsubmit = async (e) => {
  e.preventDefault();
  const writing = Object.entries(state.replyingIn || {}).filter(([, r]) => r === room()).map(([b]) => b);
  const text = $("#input").value.trim();
  if (!text && writing.length) {
    if (view.kind === "group") await invoke({ cmd: "groupStop", id: view.id }); else await invoke({ cmd: "botStop", bot: view.id });
    return refresh();
  }
  if (!text) return;
  $("#input").value = ""; $("#input").style.height = "";
  await invoke({ cmd: "botSay", bot: view.kind === "group" ? `group:${view.id}` : view.id, text });
  shownCount = -1; refresh();
};
$("#input").addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); $("#composer").requestSubmit(); } });
$("#input").addEventListener("input", (e) => { e.target.style.height = ""; e.target.style.height = e.target.scrollHeight + "px"; });
document.querySelectorAll(".footer .row").forEach((r) => r.onclick = () => {
  view = { kind: r.dataset.pane }; renderSidebar(); $("#composer").style.display = "none";
  ({ routines: renderRoutines, usage: renderUsage, settings: renderSettings })[r.dataset.pane]();
  document.querySelectorAll(".footer .row").forEach((x) => x.classList.toggle("selected", x === r));
});
$("#new-bot").onclick = () => $("#bot-dialog").showModal();
$("#bot-form").onsubmit = async (e) => {
  if (e.submitter && e.submitter.value !== "ok") return;
  const f = new FormData(e.target);
  const r = await invoke({ cmd: "botCreate", name: f.get("name"), description: f.get("description"), instructions: f.get("instructions") || `You are ${f.get("name")}.`, provider: "claude", model: f.get("model") });
  e.target.reset();
  if (r.ok) open({ kind: "bot", id: r.result.id });
};
document.addEventListener("keydown", (e) => { if ((e.metaKey || e.ctrlKey) && e.key === "n") { e.preventDefault(); $("#bot-dialog").showModal(); } });
setInterval(refresh, 400);
refresh();
