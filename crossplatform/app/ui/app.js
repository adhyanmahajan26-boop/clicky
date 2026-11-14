// Theo's desktop UI on the Theo Pixel kit. Everything goes through one command, `control`, which takes the same JSON commands
// as theod's control inbox. Faces come from the engine's own state ("faces" in botsState), so the window, the tests and the
// Mac app agree on who is working, who needs you and who failed.
const invoke = (cmd) => window.__TAURI__.core.invoke("control", { cmd });
const $ = (s) => document.querySelector(s);
const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const ORDER = ["needs", "failed", "working", "thinking", "done", "awake", "idle", "off"];
const GROUPS = [["needs", "Needs you"], ["failed", "Failed"], ["working", "Working"], ["done", "Done"], ["quiet", "Quiet"]];
const groupOf = (st) => (st === "thinking" ? "working" : ["needs", "failed", "working", "done"].includes(st) ? st : "quiet");

let state = { bots: [], groups: [], faces: [], counts: {}, runs: [] };
let view = { kind: "home" };
let filter = null;
const sigs = {};
let lastSeen = "";

document.body.insertAdjacentHTML("afterbegin", TP.defs());
const light = window.matchMedia("(prefers-color-scheme: light)");
const theme = () => document.documentElement.classList.toggle("on-light", light.matches);
light.addEventListener("change", theme); theme();

function face(id) { return state.faces.find((f) => f.id === id) || { id, state: "awake", word: "Ready", detail: "", look: null }; }
function lookOf(id) { const f = face(id); const b = state.bots.find((x) => x.id === id) || {}; return Object.assign({ name: esc(b.name || id) }, f.look || TP.CREW.builder); }
function botHTML(id, size, opts = {}) { const f = face(id); return TP.bot(lookOf(id), opts.state || f.state, size, opts); }
function nameOf(id) { return (state.bots.find((b) => b.id === id) || {}).name || id; }
function ago(iso) {
  if (!iso) return "";
  const s = Math.max(0, (Date.now() - Date.parse(iso)) / 1000);
  return s < 60 ? "now" : s < 3600 ? `${Math.floor(s / 60)}m` : s < 86400 ? `${Math.floor(s / 3600)}h` : `${Math.floor(s / 86400)}d`;
}
function clock(iso) { if (!iso) return ""; const s = Math.max(0, Math.floor((Date.now() - Date.parse(iso)) / 1000)); return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`; }
function md(text) {
  // A routine block shows as its card, not as JSON.
  text = String(text).replace(/```routine[\s\S]*?(```|$)/g, "").trim();
  const parts = String(text).split(/```(\w*)\n?([\s\S]*?)(?:```|$)/g);
  let out = "";
  for (let i = 0; i < parts.length; i++) {
    if (i % 3 === 0) out += esc(parts[i]).replace(/`([^`\n]+)`/g, "<code>$1</code>").replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>").replace(/_\(([^)]*)\)_/g, "<em>($1)</em>");
    else if (i % 3 === 2) out += `<pre>${esc(parts[i])}</pre>`;
  }
  return out;
}
function room() { return view.kind === "group" ? `group-${view.id}` : view.id; }
function once(key, sig, fn) { if (sigs[key] === sig) return; sigs[key] = sig; fn(); }

/* ---------------- sidebar ---------------- */
function renderSidebar() {
  const faces = state.faces.slice().sort((a, b) => ORDER.indexOf(a.state) - ORDER.indexOf(b.state) || (a.id === "theo" ? -1 : b.id === "theo" ? 1 : 0));
  const minute = Math.floor(Date.now() / 60000);
  const sig = JSON.stringify([faces.map((f) => [f.id, f.state, f.detail, f.unread, f.since]), state.bots.map((b) => b.name), state.groups, view, filter, minute]);
  once("side", sig, () => {
    $("#brand-face").innerHTML = TP.bot(lookOf("theo"), "awake", 22, { badge: false });
    const c = state.counts || {};
    $("#counters").innerHTML = (c.needs ? `<span data-f="needs">${TP.pill("needs", `${c.needs} need${c.needs === 1 ? "s" : ""} you`)}</span>` : "")
      + (c.failed ? `<span data-f="failed">${TP.pill("failed", `${c.failed} failed`)}</span>` : "");
    $("#counters").querySelectorAll("[data-f]").forEach((el) => el.onclick = () => { filter = filter === el.dataset.f ? null : el.dataset.f; refresh(); });
    let html = "";
    for (const [g, label] of GROUPS) {
      const rows = faces.filter((f) => groupOf(f.state) === g && (!filter || f.state === filter));
      if (!rows.length) continue;
      html += `<div class="section-label"><span>${label}</span><span>${rows.length}</span></div>`;
      for (const f of rows) {
        const sel = view.kind === "bot" && view.id === f.id ? " selected" : "";
        const detail = f.detail ? ` · ${esc(f.detail)}` : "";
        html += `<button class="row brow${sel}" data-bot="${esc(f.id)}">${botHTML(f.id, 36)}<span class="tx"><span class="nm">${esc(nameOf(f.id))}</span>`
          + `<span class="st"><span class="s-word-${f.state}">${esc(f.word)}</span>${detail}</span></span>`
          + (f.unread ? `<i class="unread" title="New"></i>` : "") + `<span class="tm">${["needs", "failed", "working", "thinking"].includes(f.state) ? ago(f.since) : ""}</span></button>`;
      }
    }
    $("#bots").innerHTML = html;
    $("#bots").querySelectorAll("[data-bot]").forEach((el) => el.onclick = () => open({ kind: "bot", id: el.dataset.bot }));
    $("#groups").innerHTML = state.groups.map((g) => `<button class="row${view.kind === "group" && view.id === g.id ? " selected" : ""}" data-group="${esc(g.id)}">`
      + `<span class="mosaic">${botHTML(g.head, 22, { badge: false })}</span>${esc(g.name)}</button>`).join("");
    $("#groups").querySelectorAll("[data-group]").forEach((el) => el.onclick = () => open({ kind: "group", id: el.dataset.group }));
    document.querySelectorAll(".row.nav[data-pane]").forEach((r) => r.classList.toggle("selected", view.kind === r.dataset.pane));
  });
}

/* ---------------- header ---------------- */
function renderHead() {
  let faceHTML = "", name = "", pill = "", detail = "";
  if (view.kind === "bot") {
    const f = face(view.id);
    faceHTML = botHTML(view.id, 44); name = nameOf(view.id); pill = TP.pill(f.state === "awake" || f.state === "idle" || f.state === "off" ? (f.state === "idle" ? "idle" : "none") : f.state, f.word);
    detail = [f.detail, ["needs", "failed", "working", "thinking"].includes(f.state) && f.since ? ago(f.since) : ""].filter(Boolean).join(" · ");
  } else if (view.kind === "group") {
    const g = state.groups.find((x) => x.id === view.id) || {};
    faceHTML = botHTML(g.head, 44, { badge: false }); name = g.name || "";
    const writing = Object.entries(state.replyingIn || {}).filter(([, r]) => r === room()).map(([b]) => nameOf(b));
    detail = writing.length ? `${writing.join(", ")} writing…` : `${(g.members || []).length + 1} bots`;
  } else {
    name = { home: "Home", connectors: "Connectors", routines: "Routines", usage: "Usage", settings: "Settings" }[view.kind] || "";
  }
  once("head", JSON.stringify([view, name, pill, detail, faceHTML.length, view.kind === "bot" ? face(view.id).state : ""]), () => {
    $("#head-face").innerHTML = faceHTML; $("#head-name").textContent = name; $("#head-pill").innerHTML = pill; $("#head-detail").textContent = detail;
  });
}

/* ---------------- cards ---------------- */
// The failure, sign-in, choice, brief, private-message, PDF and yes-or-no cards are in cards.js; the run choices in runchoices.js.
function answeredLine(m) {
  let p = {}; try { p = JSON.parse(m.card.slice(9)); } catch (e) {}
  const yes = p.choice === "yes";
  return `<div class="tc-line">${yes ? TP.badge("done", "pg") : `<i class="pg nil"></i>`}<span><b>${esc(p.what || (yes ? "Done" : "Declined"))}</b> · ${esc(m.text.replace(/\?$/, "").slice(0, 120))}</span><time>${ago(p.at)}</time></div>`;
}
function runCard(run, m) {
  const phase = run ? run.phase : "running";
  const tone = { running: "working", done: "done", failed: "failed", stopped: "none" }[phase] || "none";
  const word = { running: `Working ${clock(run && run.startedAt)}`, done: "Done", failed: "Failed at Code", stopped: "Stopped" }[phase] || phase;
  const steps = ["Branch", "Code", "Tests", "Push", "PR"].map((s, i) => {
    let cls = "";
    if (phase === "done") cls = i < 4 || (run && run.pullRequest) ? "on" : "";
    else if (phase === "running") cls = i === 0 ? "on" : i === 1 ? "act" : "";
    else if (phase === "failed") cls = i === 0 ? "on" : i === 1 ? "bad" : "";
    return `<div class="${cls}"><i></i>${s}</div>`;
  }).join("");
  const pr = run && run.pullRequest ? `<div class="tc-obj"><span class="app"><svg class="ic" viewBox="0 0 24 24"><circle cx="6" cy="6" r="2"/><circle cx="6" cy="18" r="2"/><circle cx="18" cy="18" r="2"/><path d="M6 8v8M18 16V9a3 3 0 0 0-3-3h-4"/></svg></span><span class="tx"><b>Draft pull request</b><small>${esc(run.pullRequest)}</small></span>${TP.pill("ok", "Open")}</div>` : "";
  return `<div class="tc${phase === "failed" ? " bad" : ""}"><div class="tc-h"><span class="app"><svg class="ic" viewBox="0 0 24 24"><path d="M8 9l-3 3 3 3M16 9l3 3-3 3M13.5 6l-3 12"/></svg></span><span class="who"><b>${esc(run ? run.title : "Coding run")}</b> · ${esc(run ? run.folder.split(/[\\/]/).pop() : "")}${run && run.continued ? ` · carrying on "${esc(run.continued)}"` : ""}</span>${TP.pill(tone, word)}</div>`
    + `<div class="steps">${steps}</div><p>${md(m.text)}</p>${pr}</div>`;
}

/* ---------------- a chat ---------------- */
async function renderChat() {
  const r = await invoke({ cmd: "botChat", id: room(), limit: 300 });
  const msgs = r.result || [];
  const writing = Object.entries(state.replyingIn || {}).filter(([, x]) => x === room()).map(([b]) => b);
  $("#send").classList.toggle("stop", writing.length > 0);
  $("#send").innerHTML = writing.length ? "&#9632;" : "&#8593;";
  const live = writing.map((b) => [b, (state.live || {})[b] || ""]);
  const faceSig = view.kind === "bot" ? face(view.id).state : "";
  const runSig = state.runs.map((x) => x.id + x.phase + (x.pullRequest || "")).join();
  const sig = JSON.stringify([view, msgs.length, msgs.length && msgs[msgs.length - 1].id, msgs.map((m) => m.card || "").join(), faceSig, runSig, live.map(([b]) => b), CARDS.sig(), RUNCHOICES.sig()]);
  const pane = $("#pane");
  if (view.kind === "bot" && msgs.length && lastSeen !== msgs[msgs.length - 1].id + view.id) { lastSeen = msgs[msgs.length - 1].id + view.id; invoke({ cmd: "chatSeen", id: view.id }); }
  if (sigs.chat === sig) {
    // Only the words still streaming in change.
    for (const [b, t] of live) { const el = pane.querySelector(`[data-live="${CSS.escape(b)}"] .body`); if (el) el.innerHTML = md(t || "…"); }
    return;
  }
  sigs.chat = sig;
  const atBottom = pane.scrollHeight - pane.scrollTop - pane.clientHeight < 80;
  const lastFailure = [...msgs].reverse().find((m) => m.author !== "user" && m.author !== "note" && /^Couldn't reply:/.test(m.text));
  const ownerAfter = (i) => msgs.slice(i + 1).some((x) => x.author === "user");
  // A prompt the owner didn't ask for has its "Start this coding run?" card right after it, which carries the run choices.
  const runCardAfter = (i) => msgs.slice(i + 1, i + 4).some((x) => /^(ask|answered):/.test(x.card || "") && x.card.includes('"kind":"run"'));
  let html = "", last = null;
  if (!msgs.length) html = `<div class="empty">${view.kind === "bot" ? botHTML(view.id, 112, { badge: false }) : ""}<div>Say hello to ${esc(view.kind === "bot" ? nameOf(view.id) : (state.groups.find((g) => g.id === view.id) || {}).name)}.</div></div>`;
  msgs.forEach((m, i) => {
    if (m.card && m.card.startsWith("ask:")) { html += CARDS.ask(m, room()); last = null; return; }
    if (m.card && m.card.startsWith("answered:")) { html += answeredLine(m); last = null; return; }
    if (m.card && m.card.startsWith("dm:")) { html += CARDS.dm(m); last = null; return; }
    if (m.card && m.card.startsWith("pdf:")) { html += CARDS.pdf(m); last = null; return; }
    if (m.run) {
      // One card per run, where its latest line is.
      if (msgs.slice(i + 1).some((x) => x.run === m.run)) return;
      html += runCard(state.runs.find((x) => x.id === m.run), m); last = null; return;
    }
    if (m.author === "user") { html += `<div class="msg user">${md(m.text)}</div>`; last = null; return; }
    if (m.author === "note") { html += `<div class="msg note">${md(m.text)}</div>`; last = null; return; }
    if (m.author === "routine") { html += `<div class="msg routine">${md(m.text)}</div>`; last = null; return; }
    if (/^Couldn't reply:/.test(m.text)) { html += CARDS.failure(m, m === lastFailure && !ownerAfter(i)); last = null; return; }
    const who = last !== m.author ? `<div class="who">${botHTML(m.author, 28, { badge: false })}${esc(nameOf(m.author))}</div>` : "";
    // A [CHOOSE:] is a card until the owner's next message answers it; a long answer is a brief card; a final prompt gets the run choices.
    const answer = msgs.slice(i + 1).find((x) => x.author === "user");
    const pitch = msgs.slice(0, i).reverse().find((x) => x.author === "user");
    const body = CARDS.parseCall(m.text) ? CARDS.choose(m, answer ? answer.text : null, i === msgs.length - 1)
      : CARDS.parseBrief(m.text) ? CARDS.brief(m)
      : `<div class="body">${md(m.text)}</div>` + (/```prompt\b/.test(m.text) && !runCardAfter(i) ? RUNCHOICES.draw(m.id, m.text, pitch ? pitch.id : null, room()) : "");
    html += `<div class="msg">${who}${body}</div>`;
    last = m.author;
  });
  if (view.kind === "bot" && face(view.id).state === "off") html += CARDS.off(view.id);
  for (const [b, t] of live) html += `<div class="msg live" data-live="${esc(b)}"><div class="who">${botHTML(b, 28, { badge: false, state: t ? "working" : "thinking" })}${esc(nameOf(b))}</div><div class="body">${md(t || "…")}</div></div>`;
  pane.innerHTML = `<div class="column">${html}</div>`;
  wire(pane);
  CARDS.wire(pane);
  if (atBottom || !sigs.scrolled) { pane.scrollTop = pane.scrollHeight; sigs.scrolled = true; }
}

function wire(root) {
  root.querySelectorAll("[data-card]").forEach((b) => b.onclick = async () => {
    b.disabled = true; await invoke({ cmd: "answerCard", chat: room(), message: b.dataset.card, choice: b.dataset.choice }); sigs.chat = null; refresh();
  });
  root.querySelectorAll("[data-retry]").forEach((b) => b.onclick = async () => { b.disabled = true; await invoke({ cmd: "botRetry", id: b.dataset.retry }); sigs.chat = null; refresh(); });
  root.querySelectorAll("[data-details]").forEach((b) => b.onclick = () => b.closest(".tc").classList.toggle("open"));
  root.querySelectorAll("[data-copy]").forEach((b) => b.onclick = () => { navigator.clipboard && navigator.clipboard.writeText(b.dataset.copy); b.textContent = "Copied"; });
  root.querySelectorAll("[data-say]").forEach((b) => b.onclick = async () => { await say(b.dataset.say); });
  // Opens a terminal with the sign-in command, by the full path of the Claude Code Theo found (setup.rs terminal_command).
  root.querySelectorAll("[data-term]").forEach((b) => b.onclick = async () => { const r = await invoke({ cmd: "openTerminal", which: b.dataset.term }); b.textContent = r.ok ? "Opened" : "Copy the command"; });
  root.querySelectorAll("[data-open]").forEach((b) => b.onclick = () => open({ kind: "bot", id: b.dataset.open }));
}

/* ---------------- home ---------------- */
// The needs-you, failed and working lanes are home.js (the Mac's HomeLanes).
function renderHome() {
  HOME.render();
}

/* ---------------- connectors ---------------- */
// Theo's own connectors, from the connector hub: the page is connectors.js.
async function renderConnectors(refresh = false) {
  return CONNECTORS.render(refresh);
}

/* ---------------- routines, usage, settings ---------------- */
// The list and the editor are routines.js.
async function renderRoutines() {
  return ROUTINES.render();
}
async function renderUsage() {
  const r = (await invoke({ cmd: "botsUsage", days: 7 })).result || { bots: [] };
  const rows = r.bots.map((b) => `<tr><td>${esc(b.name)}</td><td>${b.turns}</td><td>${(b.totalTokens / 1000).toFixed(1)}k</td><td>${b.costUSD == null ? "–" : "$" + b.costUSD.toFixed(2)}</td></tr>`).join("");
  $("#pane").innerHTML = `<div class="column"><h1>Usage</h1><p class="muted">The last 7 days.</p><table class="grid"><tr><th>Bot</th><th>Turns</th><th>Tokens</th><th>Cost</th></tr>${rows}</table></div>`;
}
async function renderSettings() {
  const [doc, gw, st] = await Promise.all([invoke({ cmd: "doctor" }), invoke({ cmd: "gateway" }), invoke({ cmd: "status" })]);
  const rows = (doc.result.findings || []).map((x) => `<div class="crow"><span class="tx"><b>${esc(x.check)}</b><small style="white-space:normal">${esc(x.detail)}</small></span>${TP.pill(x.level === "ok" ? "ok" : x.level === "warn" ? "needs" : "failed", x.level === "ok" ? "OK" : x.level === "warn" ? "Needs you" : "Failed")}</div>`).join("");
  const g = gw.result;
  const ownerName = st.result.ownerName || "";
  $("#pane").innerHTML = `<div class="column"><h1>Settings</h1><h2>You</h2><div class="list"><div class="crow"><span class="tx"><b>Your name</b><small style="white-space:normal">What your bots call you. Empty: they say "the owner".</small></span><span class="act"><input id="owner-name" value="${esc(ownerName)}" maxlength="40" placeholder="Your first name"></span></div></div><section id="brains-settings"></section><h2>Health check</h2><div class="list">${rows}</div>`
    + `<h2>Local API</h2><div class="list"><div class="crow"><span class="tx"><b>Local API</b><small style="white-space:normal">Lets scripts on this computer message a bot on 127.0.0.1:${g.port}. Needs a token; never counts as you.</small></span>${TP.pill(g.listening ? "ok" : "none", g.listening ? "On" : "Off")}<span class="act"><button class="btn sm" id="gw">${g.listening ? "Turn off" : "Turn on"}</button></span></div></div>`
    + `<h2>This computer</h2><div class="list" id="login-row"></div><p class="muted">${esc(st.result.os)} ${esc(st.result.arch)} · data in ${esc(String(st.result.data))} · Theo ${esc(st.result.version)}</p></div>`;
  $("#gw").onclick = async () => { await invoke({ cmd: "gateway", action: g.listening ? "off" : "on" }); renderSettings(); };
  $("#owner-name").oninput = (e) => saveOwnerName(e.target.value);
  // Brains: keys, agents, and which one answers when a bot's own keeps failing.
  const drawBrains = () => {
    const box = $("#brains-settings");
    if (!box) return;
    const b = brainsCache;
    const current = b && b.standIn ? b.standIn.split("|")[0] : "";
    const choices = brainChoices(b).filter(([id]) => id !== "claude");
    box.innerHTML = `${brainsHTML(b)}<h2>When a bot's brain fails</h2><div class="list"><div class="crow"><span class="tx"><b>Answer with</b><small style="white-space:normal">Another brain answers for the turn and the chat says so. The default is Claude Code when it's installed.</small></span>`
      + `<span class="act many"><select id="stand-in" aria-label="Stand-in brain"><option value="">Claude Code (default)</option>${choices.map(([id, label]) => `<option value="${esc(id)}"${id === current ? " selected" : ""}>${esc(label)}</option>`).join("")}</select></span></div></div>`
      + codingSettingsHTML(b && b.coding);
    wireBrains(box, drawBrains);
    if ($("#coding-target")) $("#coding-target").onchange = async (e) => { await invoke({ cmd: "harnessSet", codingTarget: e.target.value }); await loadBrains(); drawBrains(); };
    $("#stand-in").onchange = async (e) => {
      const engine = e.target.value;
      let model = "";
      if (engine.startsWith("api:")) { const m = await invoke({ cmd: "apiModels", provider: engine.slice(4) }); model = m.ok ? m.result.preferredModel || "" : ""; }
      else if (b) { const agent = b.agents.find((a) => a.id === engine); model = agent ? agent.defaultModel : ""; }
      await invoke({ cmd: "standIn", engine, model });
      await loadBrains(); drawBrains();
    };
  };
  drawBrains();
  loadBrains().then(drawBrains);
  // Open at sign-in lives in the app, not the engine; the browser stand-in for the UI has no answer, so the row stays out.
  const drawLogin = (on) => {
    if (typeof on !== "boolean" || !$("#login-row")) return;
    $("#login-row").innerHTML = `<div class="crow"><span class="tx"><b>Open Theo when you sign in</b><small style="white-space:normal">Theo starts in the tray, so routines run without you opening it. Closing the window keeps Theo running; quit it from the tray icon.</small></span>${TP.pill(on ? "ok" : "none", on ? "On" : "Off")}<span class="act"><button class="btn sm" id="login-toggle">${on ? "Turn off" : "Turn on"}</button></span></div>`;
    $("#login-toggle").onclick = async () => drawLogin(await window.__TAURI__.core.invoke("open_at_login", { enabled: !on }).catch(() => on));
  };
  window.__TAURI__.core.invoke("open_at_login", {}).then(drawLogin).catch(() => {});
}

/* ---------------- coding runs ---------------- */
// Which agent does coding runs: the owner's pick, else the first one ready (any of them: none is required).
function codingRowHTML(c, row) {
  if (!c) return "";
  if (!c.target) return row("Coding agent", "&lt;/&gt;", "None yet: install any coding agent in the Brain step (OpenCode's free models need no account). Chats and routines don't need one.", TP.pill("none", "Not installed"), "");
  const line = (c.pickedMissing ? "Your pick isn't installed here, so " : "") + `${esc(c.label)} ${c.runsOnKey ? "runs the coding on your saved API key (it's signed out), which your provider bills you for" : c.ready ? "runs the coding" : "will run the coding once it's signed in"}${c.picked ? "" : " (the first one ready; pick another in Settings)"}.`;
  return row("Coding agent", "&lt;/&gt;", line, c.runsOnKey ? TP.pill("needs", "On your API key") : c.ready ? TP.pill("ok", "Ready") : TP.pill("needs", "Signed out"), "");
}
function codingSettingsHTML(c) {
  if (!c) return "";
  const options = [`<option value="auto"${c.picked ? "" : " selected"}>Automatic${!c.picked && c.label ? ` (${esc(c.label)})` : ""}</option>`]
    .concat(c.choices.map((a) => `<option value="${esc(a.id)}"${c.picked === a.id ? " selected" : ""}>${esc(a.label)}</option>`)).join("");
  const line = c.target ? `${esc(c.label)} ${c.runsOnKey ? "does the work on your saved API key, since it's signed out (your provider bills you for it)" : c.ready ? "does the work" : "will do the work once it's signed in"}${c.pickedMissing ? ", because your pick isn't installed here" : ""}.` : "No coding agent is installed yet. Any one of the agents above will do.";
  return `<h2>Coding runs</h2><div class="list"><div class="crow"><span class="tx"><b>Coding agent</b><small style="white-space:normal">${line}</small></span><span class="act many"><select id="coding-target" aria-label="Coding agent">${options}</select></span></div></div>`;
}

/* ---------------- brains ---------------- */
// Every brain a bot can think with: an API key you paste (quickest), or an agent signed in with your own subscription. None
// is required; any one is enough. Keys go to the Credential Manager, the Keychain or a file only you can read, and never come
// back to this window: only whether one is saved.
let brainsCache = null;
async function loadBrains() { const r = await invoke({ cmd: "brains" }); if (r.ok) brainsCache = r.result; return brainsCache; }
function brainChoices(b) {
  if (!b) return [["claude", "Claude Code"]];
  const agents = b.agents.map((a) => [a.id, a.label + (a.ready ? "" : a.installed ? " (signed out)" : " (not installed)")]);
  const apis = b.apis.filter((a) => a.hasKey || a.keyless).map((a) => [a.engine, a.label + (a.keyless ? " (on this computer)" : " (API key)")]);
  return apis.concat(agents);
}
function brainsHTML(b) {
  if (!b) return `<div class="pills">${TP.pill("checking", "Checking")}</div>`;
  const keyed = b.apis.filter((a) => !a.keyless);
  const saved = keyed.filter((a) => a.hasKey);
  const keyRows = saved.map((a) => `<div class="crow"><span class="tx"><b>${esc(a.label)}</b><small>API key saved</small></span>${TP.pill("ok", "Ready")}<span class="act"><button class="btn sm ghost" data-key-remove="${esc(a.id)}">Remove</button></span></div>`).join("");
  const agentRows = b.agents.map((a) => {
    const pill = a.ready && a.signedIn === true ? TP.pill("ok", "Signed in") : a.ready ? TP.pill("ok", "Installed") : a.runsOnKey ? TP.pill("needs", "On your API key") : a.installed ? TP.pill("needs", "Signed out") : TP.pill("none", "Not installed");
    const line = a.ready ? "Thinks with your own subscription." : a.runsOnKey ? `Signed out: coding runs on it use your saved API key, which your provider bills you for. ${esc(a.signInHint)}` : a.installed ? esc(a.signInHint) : `Install: <code>${esc(a.install)}</code>`;
    const act = a.ready ? "" : a.installed ? `<button class="btn sm" data-term="signin:${esc(a.id)}">Sign in</button>` : `<button class="btn sm" data-term="install:${esc(a.id)}">Install</button>`;
    return `<div class="crow" data-brain="${esc(a.id)}"><span class="tx"><b>${esc(a.label)}</b><small style="white-space:normal">${line}</small></span>${pill}<span class="act">${act}</span></div>`;
  }).join("");
  return `<h2>Quickest start: paste an API key</h2>`
    + `<div class="list"><div class="crow brain-key"><select id="key-provider" aria-label="Provider">${keyed.map((a) => `<option value="${esc(a.id)}" data-page="${esc(a.keyPage)}" data-hint="${esc(a.keyHint)}">${esc(a.label)}</option>`).join("")}</select>`
    + `<input id="key-value" type="password" autocomplete="off" spellcheck="false" placeholder="${esc(keyed[0] ? keyed[0].keyHint : "")}" aria-label="API key"><button class="btn pri sm" id="key-save">Save key</button></div>${keyRows}</div>`
    + `<p class="muted" id="key-note">Get a key at <span id="key-page">${esc(keyed[0] ? keyed[0].keyPage : "")}</span>. It stays on this computer.</p>`
    + `<h2>Or an agent on your own subscription</h2><div class="list">${agentRows}</div>`;
}
function wireBrains(root, redraw) {
  const provider = root.querySelector("#key-provider");
  if (provider) provider.onchange = () => {
    const o = provider.selectedOptions[0];
    root.querySelector("#key-value").placeholder = o.dataset.hint || "";
    root.querySelector("#key-page").textContent = o.dataset.page || "";
  };
  const save = root.querySelector("#key-save");
  if (save) save.onclick = async () => {
    const input = root.querySelector("#key-value");
    if (!input.value.trim()) return;
    save.disabled = true; save.textContent = "Checking";
    const r = await invoke({ cmd: "apiKeySet", provider: provider.value, key: input.value });
    input.value = "";
    await loadBrains(); await redraw();
    // Redrawn, so the note is found again. The answer never has the key in it, only whether it worked.
    const note = document.querySelector("#key-note");
    if (note && !r.ok) note.textContent = r.error;
    else if (note && !r.result.works) note.textContent = `Saved, but it didn't work yet: ${r.result.problem}`;
  };
  root.querySelectorAll("[data-key-remove]").forEach((b) => b.onclick = async () => { await invoke({ cmd: "apiKeyRemove", provider: b.dataset.keyRemove }); await loadBrains(); redraw(); });
  root.querySelectorAll("[data-term]").forEach((b) => b.onclick = async () => { const r = await invoke({ cmd: "openTerminal", which: b.dataset.term }); b.textContent = r.ok ? "Opened" : "Copy the command"; });
}

/* ---------------- the loop ---------------- */
function open(v) { view = v; Object.keys(sigs).forEach((k) => delete sigs[k]); render(); }
async function refresh() {
  try { state = (await invoke({ cmd: "botsState" })).result || state; } catch (e) { console.error(e); }
  // The tray face and notifications come from the app itself (main.rs watch_faces), so they keep working while this window
  // is hidden and its timers are slowed down.
  renderSidebar(); renderHead();
  if (view.kind === "bot" || view.kind === "group") await renderChat();
  else if (view.kind === "home") renderHome();
  $("#composer").style.display = view.kind === "bot" || view.kind === "group" ? "" : "none";
}
function render() {
  refresh();
  if (view.kind === "connectors") renderConnectors();
  if (view.kind === "routines") renderRoutines();
  if (view.kind === "usage") renderUsage();
  if (view.kind === "settings") renderSettings();
}
async function say(text) {
  await invoke({ cmd: "botSay", bot: view.kind === "group" ? `group:${view.id}` : view.id, text });
  sigs.chat = null; refresh();
}

$("#composer").onsubmit = async (e) => {
  e.preventDefault();
  const writing = Object.entries(state.replyingIn || {}).filter(([, r]) => r === room());
  const text = $("#input").value.trim();
  if (!text && writing.length) { await invoke(view.kind === "group" ? { cmd: "groupStop", id: view.id } : { cmd: "botStop", bot: view.id }); return refresh(); }
  if (!text) return;
  $("#input").value = ""; $("#input").style.height = "";
  await say(text);
};
$("#input").addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); $("#composer").requestSubmit(); } });
$("#input").addEventListener("input", (e) => { e.target.style.height = ""; e.target.style.height = e.target.scrollHeight + "px"; });
document.querySelectorAll(".row.nav[data-pane]").forEach((r) => r.onclick = () => open({ kind: r.dataset.pane }));

/* ---------------- Make your bot ---------------- */
// Body, trim, eyes, what's on top and an extra, with the look shown awake and in the five main states.
const pickOne = (a) => a[Math.floor(Math.random() * a.length)];
function randomLook() {
  return { fin: pickOne(Object.keys(TP.FIN)), trim: pickOne(Object.values(TP.TRIMS)), eye: pickOne(Object.keys(TP.EYES)), top: pickOne(TP.TOPS.concat(TP.HATS)), extra: pickOne(TP.EXTRAS) };
}
function eyeSVG(eye) {
  const g = TP.EYES[eye], w = g[0].length, h = g.length, gap = 1, W = w * 2 + gap;
  let r = "";
  g.forEach((line, y) => [...line].forEach((ch, x) => { if (ch === "#") { r += `<rect x="${x}" y="${y}" width=".8" height=".8" rx=".2"/>`; r += `<rect x="${x + w + gap}" y="${y}" width=".8" height=".8" rx=".2"/>`; } }));
  return `<svg viewBox="-.5 -.5 ${W + 0.2} ${h + 0.2}" class="eyes-sw"><g fill="currentColor">${r}</g></svg>`;
}
function mountMaker(el, look, onChange) {
  let cur = Object.assign({}, look);
  const label = { none: "None", ball: "Ball", twin: "Twin", handle: "Handle", dish: "Dish", flag: "Flag", bolt: "Bolt", heart: "Heart", hardhat: "Hard hat", cap: "Cap", beanie: "Beanie", beret: "Beret", tophat: "Top hat", crown: "Crown", headset: "Headset", bowtie: "Bow tie", tie: "Tie", scarf: "Scarf", bezel: "Bezel", pencil: "Pencil", star: "Star" };
  const row = (title, items) => `<div class="mk-row"><div class="mk-h">${title}</div><div class="mk-items">${items}</div></div>`;
  function draw() {
    const sel = (k, v) => (cur[k] === v ? " on" : "");
    el.innerHTML = `<div class="maker"><div class="mk-preview">${TP.bot(cur, "awake", 150, { badge: false })}<div class="mk-states">${["working", "needs", "failed", "done", "idle"].map((s) => `<span title="${TP.STATES[s].label}">${TP.bot(cur, s, 36)}</span>`).join("")}</div>`
      + `<button type="button" class="btn sm" data-shuffle>Shuffle</button></div><div class="mk-opts">`
      + row("Body", Object.entries(TP.FIN).map(([k, f]) => `<button type="button" class="sw${sel("fin", k)}" data-k="fin" data-v="${k}" title="${k}" style="background:linear-gradient(${f.a},${f.b})"></button>`).join(""))
      + row("Trim", Object.entries(TP.TRIMS).map(([k, c]) => `<button type="button" class="sw${sel("trim", c)}" data-k="trim" data-v="${c}" title="${k}" style="background:${c}"></button>`).join(""))
      + row("Eyes", Object.keys(TP.EYES).map((e) => `<button type="button" class="chip eye${sel("eye", e)}" data-k="eye" data-v="${e}" title="${e}">${eyeSVG(e)}</button>`).join(""))
      + row("On top", TP.TOPS.concat(TP.HATS).map((x) => `<button type="button" class="chip face${sel("top", x)}" data-k="top" data-v="${x}" title="${label[x] || x}">${TP.bot(Object.assign({}, cur, { top: x }), "awake", 34, { badge: false, frame: 0 })}<small>${label[x] || x}</small></button>`).join(""))
      + row("Extra", TP.EXTRAS.map((x) => `<button type="button" class="chip face${sel("extra", x)}" data-k="extra" data-v="${x}" title="${label[x] || x}">${TP.bot(Object.assign({}, cur, { extra: x }), "awake", 34, { badge: false, frame: 0 })}<small>${label[x] || x}</small></button>`).join(""))
      + `</div></div>`;
    el.querySelectorAll("[data-k]").forEach((b) => b.onclick = () => { cur[b.dataset.k] = b.dataset.v; draw(); onChange && onChange(cur); });
    el.querySelector("[data-shuffle]").onclick = () => { cur = randomLook(); draw(); onChange && onChange(cur); };
  }
  draw();
  return () => cur;
}

let botDialogMode = { kind: "new" };
let makerLook = null;
function openBotDialog(mode) {
  botDialogMode = mode;
  const editing = mode.kind === "look";
  const look = editing ? lookOf(mode.id) : randomLook();
  makerLook = mountMaker($("#maker"), look, null);
  $("#bot-dialog-title").textContent = editing ? `How ${nameOf(mode.id)} looks` : "New bot";
  $("#bot-fields").style.display = editing ? "none" : "";
  $("#bot-fields").querySelectorAll("input,textarea").forEach((i) => (i.required = !editing && i.name === "name"));
  $("#bot-dialog-ok").textContent = editing ? "Save" : "Create";
  if (!editing) fillBrainPicker();
  $("#bot-dialog").showModal();
}
// The new-bot dialog's brain list (keys first, then agents) and the models it suggests for the one picked. An empty model
// means the brain's own default.
const CLAUDE_MODELS = ["claude-sonnet-5-5", "claude-haiku-5-5", "claude-opus-5-5"];
async function fillBrainPicker() {
  const select = $("#bot-brain");
  const draw = () => {
    const keep = select.value;
    const choices = brainChoices(brainsCache);
    select.innerHTML = choices.map(([id, label]) => `<option value="${esc(id)}">${esc(label)}</option>`).join("");
    // Starts on what works here: a signed-in agent (Claude Code first), else a saved key, else Claude Code.
    const agent = brainsCache && brainsCache.agents.find((a) => a.ready && a.signedIn);
    const key = brainsCache && brainsCache.apis.find((a) => a.ready);
    select.value = choices.some(([id]) => id === keep) ? keep : agent ? agent.id : key ? key.engine : "claude";
    suggestModels();
  };
  draw();
  await loadBrains(); draw();
}
async function suggestModels() {
  const engine = $("#bot-brain").value;
  const model = $("#bot-model");
  let models = [];
  if (engine === "claude") models = CLAUDE_MODELS;
  else if (engine.startsWith("api:")) { const r = await invoke({ cmd: "apiModels", provider: engine.slice(4) }); if (r.ok) { models = r.result.models.slice(0, 200); if (!model.value && r.result.preferredModel) model.placeholder = r.result.preferredModel; } }
  else { const agent = brainsCache && brainsCache.agents.find((a) => a.id === engine); model.placeholder = agent && agent.defaultModel ? agent.defaultModel : "The agent's own default"; }
  if (engine === "claude") model.placeholder = "claude-sonnet-5-5";
  $("#bot-models").innerHTML = models.map((m) => `<option value="${esc(m)}"></option>`).join("");
}
$("#bot-brain").onchange = () => { $("#bot-model").value = ""; suggestModels(); };
$("#new-bot").onclick = () => openBotDialog({ kind: "new" });
$("#head-face").onclick = () => { if (view.kind === "bot") openBotDialog({ kind: "look", id: view.id }); };
$("#bot-form").onsubmit = async (e) => {
  if (e.submitter && e.submitter.value !== "ok") return;
  const look = makerLook();
  if (botDialogMode.kind === "look") { await invoke({ cmd: "botLook", id: botDialogMode.id, look }); Object.keys(sigs).forEach((k) => delete sigs[k]); return refresh(); }
  const f = new FormData(e.target);
  const r = await invoke({ cmd: "botCreate", name: f.get("name"), description: f.get("description"), instructions: f.get("instructions") || `You are ${f.get("name")}.`, provider: f.get("provider") || "claude", model: (f.get("model") || "").trim() || $("#bot-model").placeholder || "" });
  if (r.ok) { await invoke({ cmd: "botLook", id: r.result.id, look }); e.target.reset(); open({ kind: "bot", id: r.result.id }); }
  else { $("#bot-dialog-title").textContent = r.error; $("#bot-dialog").showModal(); }
};

/* ---------------- first run ---------------- */
const SETUP_STEPS = ["Welcome", "Brain", "Coding", "Your first bot", "Done"];
let setup = null;
const TEMPLATES = [
  ["Researcher", "Looks things up and sums them up", "You are Researcher. Read what you're asked about on the web and in files you're given, and answer in a few clear sentences with sources.", { fin: "sky", trim: "#F4F4F5", eye: "round", top: "twin", extra: "none" }],
  ["Builder", "Writes and fixes code", "You are Builder, an engineer. When asked for code, plan it briefly and hand it to a coding run.", { fin: "bone", trim: "#5B8DEF", eye: "wide", top: "handle", extra: "none" }],
  ["Writer", "Drafts emails, posts and docs", "You are Writer. Draft clear, short writing in the owner's voice and ask before anything is sent.", { fin: "slate", trim: "#F4F4F5", eye: "tall", top: "handle", extra: "pencil" }],
];
async function startSetup() {
  setup = { step: 0, st: null, owner: "", look: TEMPLATES[0][3], name: TEMPLATES[0][0], desc: TEMPLATES[0][1], instr: TEMPLATES[0][2], made: null };
  $("#setup").hidden = false;
  drawSetup();
  setup.st = (await invoke({ cmd: "setupState" })).result;
  // The name the bots will use: what's saved, else the computer account's name, saved straight away so what's shown is what they're told.
  setup.owner = (setup.st && (setup.st.ownerName || setup.st.suggestedOwnerName)) || "";
  if (setup.st && !setup.st.ownerName && setup.owner) await saveOwnerName(setup.owner);
  drawSetup();
}
// Empty clears it: the bots then say "the owner".
function saveOwnerName(name) { return invoke({ cmd: "setSetting", key: "owner.name", value: name.trim().slice(0, 40) || null }); }
function setupFace() {
  const s = setup.st;
  if (setup.step === 4) return "done";
  if (setup.step === 1 && s && !s.anyReady) return "needs";
  if (setup.step === 3 && !setup.name.trim()) return "needs";
  return "awake";
}
function drawSetup() {
  const s = setup.st, step = setup.step;
  const steps = SETUP_STEPS.map((n, i) => `<div class="su-step${i === step ? " on" : ""}${i < step ? " done" : ""}">${i < step ? TP.badge("done", "pg") : `<i class="num">${i + 1}</i>`}${n}</div>`).join("");
  let body = "";
  const checking = `<div class="pills">${TP.pill("checking", "Checking")}</div>`;
  if (step === 0) {
    body = `<div class="su-hero">${TP.bot(TP.CREW.theo, "awake", 112, { badge: false })}</div><h1>Meet Theo</h1>`
      + `<p class="lead">Theo runs a team of AI bots on the AI you already have: an API key, or Claude Code, Codex, Cursor, Gemini, Grok or OpenCode on your own subscription. Chats, group chats, routines and coding runs. Bots can't loop, schedule things or start coding without you saying so.</p>`
      + `<div class="su-fields"><label>What should your bots call you? <input id="su-owner" value="${esc(setup.owner)}" maxlength="40" placeholder="Your first name"></label></div>`
      + `<p class="muted">This takes a minute: pick a brain, then make your first bot.</p><div class="btns"><button class="btn pri" data-next>Get started</button></div>`;
  } else if (step === 1) {
    const ready = s && s.anyReady;
    body = `<h1>Pick a brain</h1><p class="lead">Bots think with the AI you already have. Paste an API key, or use an agent you're signed in to. You need one, any one; you can add more later in Settings.</p>`
      + `<div id="su-brains">${brainsHTML(s && s.brains)}</div>`
      + `<div class="btns"><button class="btn pri" data-next${ready ? "" : " disabled"}>Continue</button><button class="btn" data-recheck>Check again</button>${s && !ready ? `<button class="btn ghost" data-next>Skip for now</button>${TP.pill("needs", "Add one to continue")}` : ""}</div>`;
  } else if (step === 2) {
    const g = s && s.git, h = s && s.gh;
    const r = (name, icon, line, pill, act) => `<div class="crow"><span class="app">${icon}</span><span class="tx"><b>${name}</b><small style="white-space:normal">${line}</small></span>${pill}<span class="act">${act}</span></div>`;
    body = `<h1>Coding runs</h1><p class="lead">Optional. When you ask a bot to build or fix something, a coding agent works on its own branch, commits, and with GitHub pushes and opens a draft pull request.</p>`
      + (!s ? checking : `<div class="list">${codingRowHTML(s.coding, r)}`
      + `${r("git", "g", g.installed ? esc(g.version) : "Not installed. Get it from git-scm.com or your package manager.", g.installed ? TP.pill("ok", "Installed") : TP.pill("none", "Not installed"), "")}`
      + r("GitHub CLI", "gh", !h.installed ? "Not installed: runs still commit, they just don't push. cli.github.com" : h.signedIn ? "Signed in: runs can push and open draft PRs." : "Signed out: sign in to push and open draft PRs.",
          !h.installed ? TP.pill("none", "Not installed") : h.signedIn ? TP.pill("ok", "Signed in") : TP.pill("needs", "Signed out"), h.installed && !h.signedIn ? `<button class="btn sm" data-term="gh">Sign in</button>` : "") + `</div>`)
      + `<div class="btns"><button class="btn pri" data-next>Continue</button><button class="btn" data-recheck>Check again</button></div>`;
  } else if (step === 3) {
    body = `<h1>Your first bot</h1><p class="lead">Pick what it does and how it looks. You can change both later.</p>`
      + `<div class="pills su-tpl">${TEMPLATES.map(([n]) => `<button type="button" class="btn sm${setup.name === n ? " pri" : ""}" data-tpl="${n}">${n}</button>`).join("")}</div>`
      + `<div class="su-fields"><label>Name <input id="su-name" value="${esc(setup.name)}" maxlength="40"></label><label>What it does <input id="su-desc" value="${esc(setup.desc)}" maxlength="120"></label></div><div id="su-maker"></div>`
      + `<div class="btns"><button class="btn pri" data-create${setup.name.trim() ? "" : " disabled"}>Make ${esc(setup.name || "it")}</button><button class="btn ghost" data-next>Skip</button></div>`;
  } else {
    const missing = s && !s.anyReady;
    const who = setup.made ? setup.name : "a bot";
    body = `<div class="su-hero">${TP.bot(TP.CREW.theo, "done", 84, { badge: false })}</div><h1>You're all set</h1>`
      + `<p class="lead">Things to try:</p><ul class="su-try"><li>Ask ${esc(who)} something in its chat.</li><li>Ask Theo to get ${esc(who)} to look into something and report back.</li><li>Say "every weekday at 8, send me a brief" to set up a routine.</li></ul>`
      + (missing ? `<div class="tc-line">${TP.badge("needs", "pg")}<span><b>No brain yet</b> · bots can't answer until you add an API key or sign in to an agent in Settings</span></div>` : "")
      + `<div class="btns"><button class="btn pri" data-finish>Open Theo</button></div>`;
  }
  $("#setup").innerHTML = `<div class="su"><aside class="su-side"><div class="su-theo">${TP.bot(TP.CREW.theo, setupFace(), 56)}<b>Setting up Theo</b></div>${steps}</aside><section class="su-main"><div class="su-body">${body}</div></section></div>`;
  const root = $("#setup");
  root.querySelectorAll("[data-next]").forEach((b) => b.onclick = () => { setup.step++; drawSetup(); });
  root.querySelectorAll("[data-recheck]").forEach((b) => b.onclick = async () => { setup.st = null; drawSetup(); setup.st = (await invoke({ cmd: "setupState" })).result; drawSetup(); });
  root.querySelectorAll("[data-term]").forEach((b) => b.onclick = async () => { const r = await invoke({ cmd: "openTerminal", which: b.dataset.term }); b.textContent = r.ok ? "Opened" : "Copy the command"; });
  root.querySelectorAll("[data-tpl]").forEach((b) => b.onclick = () => { const t = TEMPLATES.find((x) => x[0] === b.dataset.tpl); Object.assign(setup, { name: t[0], desc: t[1], instr: t[2], look: t[3] }); drawSetup(); });
  wire(root);
  if (step === 0 && $("#su-owner")) $("#su-owner").oninput = (e) => { setup.owner = e.target.value; saveOwnerName(setup.owner); };
  if (step === 1 && s) wireBrains(root.querySelector("#su-brains"), async () => { setup.st = (await invoke({ cmd: "setupState" })).result; drawSetup(); });
  if (step === 3) {
    const get = mountMaker($("#su-maker"), setup.look, (l) => (setup.look = l));
    $("#su-name").oninput = (e) => { setup.name = e.target.value; root.querySelector("[data-create]").disabled = !setup.name.trim(); root.querySelector("[data-create]").textContent = `Make ${setup.name || "it"}`; };
    $("#su-desc").oninput = (e) => (setup.desc = e.target.value);
    root.querySelector("[data-create]").onclick = async () => {
      // The first bot thinks with the brain setup found: a signed-in agent, else a key on its preferred model.
      const brain = (setup.st && setup.st.suggested) || { engine: "claude", model: "claude-sonnet-5-5" };
      const r = await invoke({ cmd: "botCreate", name: setup.name.trim(), description: setup.desc, instructions: setup.instr || `You are ${setup.name.trim()}.`, provider: brain.engine, model: brain.model });
      if (r.ok) { await invoke({ cmd: "botLook", id: r.result.id, look: get() }); setup.made = r.result.id; setup.step = 4; drawSetup(); }
    };
  }
  root.querySelectorAll("[data-finish]").forEach((b) => b.onclick = async () => {
    await invoke({ cmd: "setupDone" }); $("#setup").hidden = true;
    open(setup.made ? { kind: "bot", id: setup.made } : { kind: "home" });
  });
}

document.addEventListener("keydown", (e) => { if ((e.metaKey || e.ctrlKey) && e.key === "n") { e.preventDefault(); $("#new-bot").click(); } });
setInterval(refresh, 500);
render();
invoke({ cmd: "setupState" }).then((r) => { if (r.ok && !r.result.completed) startSetup(); });
