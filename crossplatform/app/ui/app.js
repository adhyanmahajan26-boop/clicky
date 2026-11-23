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
// Only the newest messages are drawn, as on the Mac: rebuilding a 300-message chat (every message's Markdown and avatar)
// whenever something in it changed made clicks and scrolling stutter. Older ones are a click away.
const MESSAGES_PER_PAGE = 40;
let shownMessages = MESSAGES_PER_PAGE;

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
  // Only what changes the rows themselves rebuilds the list. A bot's status line changes with every streamed word and its
  // time every minute: rebuilding the whole list for those (every half second while a bot wrote) redrew every avatar and
  // swapped the row under the pointer, so a click that straddled a rebuild was lost. Those are patched in place below.
  const sig = JSON.stringify([faces.map((f) => [f.id, f.state, f.word, f.unread]), state.bots.map((b) => [b.name, b.primary]), state.groups, state.teams, sidebarSort(), view, filter]);
  once("side", sig, () => {
    $("#brand-face").innerHTML = TP.bot(lookOf("theo"), "awake", 22, { badge: false });
    const c = state.counts || {};
    $("#counters").innerHTML = (c.needs ? `<span data-f="needs">${TP.pill("needs", `${c.needs} need${c.needs === 1 ? "s" : ""} you`)}</span>` : "")
      + (c.failed ? `<span data-f="failed">${TP.pill("failed", `${c.failed} failed`)}</span>` : "");
    $("#counters").querySelectorAll("[data-f]").forEach((el) => el.onclick = () => { filter = filter === el.dataset.f ? null : el.dataset.f; refresh(); });
    // By team (the default) or urgent first, and the group chats: teams.js.
    renderBotList(faces);
    renderGroupList();
    document.querySelectorAll(".row.nav[data-pane]").forEach((r) => r.classList.toggle("selected", view.kind === r.dataset.pane));
  });
  patchSidebarRows(faces);
}

// The status line and time of each row, changed in place only where they differ.
function patchSidebarRows(faces) {
  const byId = new Map(faces.map((f) => [f.id, f]));
  document.querySelectorAll("#bots [data-bot]").forEach((row) => {
    const f = byId.get(row.dataset.bot);
    if (!f) return;
    const statusHTML = sidebarStatusHTML(f);
    if (row.dataset.statusHtml !== statusHTML) {
      const line = row.querySelector(".st");
      if (line) line.innerHTML = statusHTML;
      row.dataset.statusHtml = statusHTML;
    }
    const time = sidebarTimeText(f);
    if (row.dataset.timeText !== time) {
      const box = row.querySelector(".tm");
      if (box) box.textContent = time;
      row.dataset.timeText = time;
    }
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
    name = { home: "Home", connectors: "Connectors", routines: "Routines", usage: "Usage", settings: "Settings", vmscreens: "VM screens", team: teamHeadName() }[view.kind] || "";
    if (view.kind === "team") detail = teamHeadDetail();
  }
  renderHeadActions();
  once("head", JSON.stringify([view, name, pill, detail, faceHTML.length, view.kind === "bot" ? face(view.id).state : ""]), () => {
    $("#head-face").innerHTML = faceHTML; $("#head-name").textContent = name; $("#head-pill").innerHTML = pill; $("#head-detail").textContent = detail;
  });
}

/* ---------------- cards ---------------- */
// The failure, sign-in, choice, brief, private-message, file (PDF and [FILE:]) and yes-or-no cards are in cards.js; the run choices in runchoices.js.
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
  // One more than is shown, to know whether there are earlier ones.
  const r = await invoke({ cmd: "botChat", id: room(), limit: shownMessages + 1 });
  const fetched = r.result || [];
  const hasEarlier = fetched.length > shownMessages;
  const msgs = hasEarlier ? fetched.slice(fetched.length - shownMessages) : fetched;
  const writing = Object.entries(state.replyingIn || {}).filter(([, x]) => x === room()).map(([b]) => b);
  $("#send").classList.toggle("stop", writing.length > 0);
  $("#send").innerHTML = writing.length ? "&#9632;" : "&#8593;";
  const live = writing.map((b) => [b, (state.live || {})[b] || ""]);
  const faceSig = view.kind === "bot" ? face(view.id).state : "";
  const runSig = state.runs.map((x) => x.id + x.phase + (x.pullRequest || "")).join();
  const sig = JSON.stringify([view, shownMessages, hasEarlier, msgs.length, msgs.length && msgs[msgs.length - 1].id, msgs.map((m) => m.card || "").join(), faceSig, runSig, live.map(([b]) => b), CARDS.sig(), RUNCHOICES.sig()]);
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
  let html = hasEarlier ? `<div class="earlier"><button class="btn sm ghost" data-earlier>Show earlier messages</button></div>` : "", last = null;
  if (!msgs.length) html = `<div class="empty">${view.kind === "bot" ? botHTML(view.id, 112, { badge: false }) : ""}<div>Say hello to ${esc(view.kind === "bot" ? nameOf(view.id) : (state.groups.find((g) => g.id === view.id) || {}).name)}.</div></div>`;
  msgs.forEach((m, i) => {
    if (m.card && m.card.startsWith("ask:")) { html += CARDS.ask(m, room()); last = null; return; }
    if (m.card && m.card.startsWith("answered:")) { html += answeredLine(m); last = null; return; }
    if (m.card && m.card.startsWith("dm:")) { html += CARDS.dm(m); last = null; return; }
    if (m.card && (m.card.startsWith("pdf:") || m.card.startsWith("file:"))) { html += CARDS.fileCard(m); last = null; return; }
    if (m.card && typeof VMSCREENS !== "undefined" && VMSCREENS.handles(m)) { html += VMSCREENS.card(m); last = null; return; }
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
  const earlier = pane.querySelector("[data-earlier]");
  if (earlier) earlier.onclick = () => {
    // Keep the message that was at the top where it was, as the earlier ones go in above it.
    const fromBottom = pane.scrollHeight - pane.scrollTop;
    shownMessages += MESSAGES_PER_PAGE; sigs.chat = null;
    refresh().then(() => { pane.scrollTop = pane.scrollHeight - fromBottom; });
  };
  CARDS.wire(pane);
  if (typeof VMSCREENS !== "undefined") VMSCREENS.wire(pane);
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
// Settings live in settings.js: the Mac's sections with a list on the left.
async function renderSettings() { return renderSettingsPage(); }

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
function open(v) { view = v; shownMessages = MESSAGES_PER_PAGE; Object.keys(sigs).forEach((k) => delete sigs[k]); render(); }
async function refresh() {
  try { state = (await invoke({ cmd: "botsState" })).result || state; } catch (e) { console.error(e); }
  // The tray face and notifications come from the app itself (main.rs watch_faces), so they keep working while this window
  // is hidden and its timers are slowed down.
  renderSidebar(); renderHead();
  // A product that's off shows its "turned off" page instead (products.js).
  if (window.productGate && window.productGate(view)) { $("#composer").style.display = "none"; return; }
  if (view.kind === "bot" || view.kind === "group") await renderChat();
  else if (view.kind === "home") renderHome();
  else if (view.kind === "team") renderTeamPage();
  $("#composer").style.display = view.kind === "bot" || view.kind === "group" ? "" : "none";
}
function render() {
  refresh();
  if (window.productGate && window.productGate(view)) return;
  if (view.kind === "connectors") renderConnectors();
  if (view.kind === "routines") renderRoutines();
  if (view.kind === "usage") renderUsage();
  if (view.kind === "settings") renderSettings();
  if (view.kind === "vmscreens" && typeof renderVMScreens === "function") renderVMScreens();
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
const CLAUDE_MODELS = ["claude-sonnet-5-5", "claude-haiku-5-5", "claude-opus-5-5", "claude-fable-5-2"];
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
  if (r.ok) { await invoke({ cmd: "botLook", id: r.result.id, look }); e.target.reset(); if (!(await teamTakesNewBot(r.result.id))) open({ kind: "bot", id: r.result.id }); }
  else { $("#bot-dialog-title").textContent = r.error; $("#bot-dialog").showModal(); }
};

/* ---------------- first run ---------------- */
// The Mac's Setup/SetupGuideWindow.swift: Welcome (and your name), a brain ("paste one API key" first), the products you want,
// then for Theo its coding runs and a first bot, and done. It opens at launch when it was never finished, or when no brain
// at all can think here while Theo or Clicky is on (setupState's needsSetup); opened again like that, or from Settings, it
// can be closed.
const SETUP_TITLES = { welcome: "Welcome", brain: "Brain", products: "Pick products", coding: "Coding runs", bot: "Your first bot", done: "Done" };
let setup = null;
const TEMPLATES = [
  ["Researcher", "Looks things up and sums them up", "You are Researcher. Read what you're asked about on the web and in files you're given, and answer in a few clear sentences with sources.", { fin: "sky", trim: "#F4F4F5", eye: "round", top: "twin", extra: "none" }],
  ["Builder", "Writes and fixes code", "You are Builder, an engineer. When asked for code, plan it briefly and hand it to a coding run.", { fin: "bone", trim: "#5B8DEF", eye: "wide", top: "handle", extra: "none" }],
  ["Writer", "Drafts emails, posts and docs", "You are Writer. Draft clear, short writing in the owner's voice and ask before anything is sent.", { fin: "slate", trim: "#F4F4F5", eye: "tall", top: "handle", extra: "pencil" }],
];
// The steps shown: coding runs and a first bot are Theo's, so they go when Theo is off.
function setupSteps() {
  const theo = typeof productIsOn === "function" ? productIsOn("theo") : true;
  return ["welcome", "brain", "products"].concat(theo ? ["coding", "bot"] : [], ["done"]);
}
// `again`: opened from Settings, or at launch because no brain can think here. It starts at the brain step then and can be closed.
async function startSetup(opts = {}) {
  setup = { step: opts.step || "welcome", again: !!opts.again, st: null, owner: "", look: TEMPLATES[0][3], name: TEMPLATES[0][0], desc: TEMPLATES[0][1], instr: TEMPLATES[0][2], made: null };
  $("#setup").hidden = false;
  drawSetup();
  if (typeof loadProducts === "function") await loadProducts();
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
  if (setup.step === "done") return "done";
  if (setup.step === "brain" && s && !s.anyReady) return "needs";
  if (setup.step === "products" && !anyProductOn()) return "needs";
  if (setup.step === "bot" && !setup.name.trim()) return "needs";
  return "awake";
}
function anyProductOn() { return typeof productIsOn !== "function" || ["theo", "clicky", "dictation"].some(productIsOn); }
function setupNext() {
  const steps = setupSteps();
  setup.step = steps[Math.min(steps.indexOf(setup.step) + 1, steps.length - 1)];
  drawSetup();
}
function closeSetup() { $("#setup").hidden = true; setup = null; render(); }
function drawSetup() {
  if (!setup) return;
  const s = setup.st, step = setup.step;
  const steps = setupSteps();
  const at = steps.indexOf(step);
  const side = steps.map((id, i) => `<div class="su-step${i === at ? " on" : ""}${i < at ? " done" : ""}">${i < at ? TP.badge("done", "pg") : `<i class="num">${i + 1}</i>`}${SETUP_TITLES[id]}</div>`).join("");
  let body = "";
  const checking = `<div class="pills">${TP.pill("checking", "Checking")}</div>`;
  if (step === "welcome") {
    const list = (typeof Products !== "undefined" && Products.list) || [];
    body = `<div class="su-hero">${TP.bot(TP.CREW.theo, "awake", 112, { badge: false })}</div><h1>Hi, I'm Vello</h1>`
      + `<p class="lead">Three products, one app. First pick a brain to think with: the AI you already have, an API key or Claude Code, Codex, Cursor, Gemini, Grok or OpenCode on your own subscription. Then see each product and turn on only the ones you want. Setup takes about two minutes.</p>`
      + (list.length ? `<ul class="su-products">${list.map((p) => `<li><b>${esc(p.title)}</b>: ${esc(p.tagline)}</li>`).join("")}</ul>` : "")
      + `<div class="su-fields"><label>What should your bots call you? <input id="su-owner" value="${esc(setup.owner)}" maxlength="40" placeholder="Your first name"></label></div>`
      + `<div class="btns"><button class="btn pri" data-next>Get started</button></div>`;
  } else if (step === "brain") {
    const ready = s && s.anyReady;
    body = `<h1>Pick a brain</h1><p class="lead">Vello needs one thing to think with: an API key, or a coding agent you already pay for. Any one is enough, and none is required over another. You can add more later in Settings.</p>`
      + `<div id="su-brains">${brainsHTML(s && s.brains)}</div>`
      + `<div class="btns"><button class="btn pri" data-next${ready ? "" : " disabled"}>Continue</button><button class="btn" data-recheck>Check again</button>${s && !ready ? `<button class="btn ghost" data-next>Skip for now</button>${TP.pill("needs", "Add one to continue")}` : ""}</div>`;
  } else if (step === "products") {
    const any = anyProductOn();
    body = `<h1>Pick what you want</h1><p class="lead">Vello, Pointer Assistant and Dictation are separate products. Watch each one and turn on only the ones you want; you can change this any time in Settings › Products.</p>`
      + `<div id="su-products">${typeof productCardsHTML === "function" ? productCardsHTML() : checking}</div>`
      + `<div class="btns"><button class="btn pri" data-next${any ? "" : " disabled"}>Continue</button>${any ? "" : TP.pill("needs", "Pick at least one")}</div>`;
  } else if (step === "coding") {
    const g = s && s.git, h = s && s.gh;
    const r = (name, icon, line, pill, act) => `<div class="crow"><span class="app">${icon}</span><span class="tx"><b>${name}</b><small style="white-space:normal">${line}</small></span>${pill}<span class="act">${act}</span></div>`;
    body = `<h1>Coding runs</h1><p class="lead">Optional. When you ask a bot to build or fix something, a coding agent works on its own branch, commits, and with GitHub pushes and opens a draft pull request.</p>`
      + (!s ? checking : `<div class="list">${codingRowHTML(s.coding, r)}`
      + `${r("git", "g", g.installed ? esc(g.version) : "Not installed. Get it from git-scm.com or your package manager.", g.installed ? TP.pill("ok", "Installed") : TP.pill("none", "Not installed"), "")}`
      + r("GitHub CLI", "gh", !h.installed ? "Not installed: runs still commit, they just don't push. cli.github.com" : h.signedIn ? "Signed in: runs can push and open draft PRs." : "Signed out: sign in to push and open draft PRs.",
          !h.installed ? TP.pill("none", "Not installed") : h.signedIn ? TP.pill("ok", "Signed in") : TP.pill("needs", "Signed out"), h.installed && !h.signedIn ? `<button class="btn sm" data-term="gh">Sign in</button>` : "") + `</div>`
      + (s.projectsFolder ? `<p class="muted">New projects go in ${esc(String(s.projectsFolder))}. You can pick another folder in Settings › Coding runs.</p>` : ""))
      + `<div class="btns"><button class="btn pri" data-next>Continue</button><button class="btn" data-recheck>Check again</button></div>`;
  } else if (step === "bot") {
    body = `<h1>Your first bot</h1><p class="lead">Pick what it does and how it looks. You can change both later.</p>`
      + `<div class="pills su-tpl">${TEMPLATES.map(([n]) => `<button type="button" class="btn sm${setup.name === n ? " pri" : ""}" data-tpl="${n}">${n}</button>`).join("")}</div>`
      + `<div class="su-fields"><label>Name <input id="su-name" value="${esc(setup.name)}" maxlength="40"></label><label>What it does <input id="su-desc" value="${esc(setup.desc)}" maxlength="120"></label></div><div id="su-maker"></div>`
      + `<div class="btns"><button class="btn pri" data-create${setup.name.trim() ? "" : " disabled"}>Make ${esc(setup.name || "it")}</button><button class="btn ghost" data-next>Skip</button></div>`;
  } else {
    const missing = s && !s.anyReady;
    const who = setup.made ? setup.name : "a bot";
    const theo = typeof productIsOn !== "function" || productIsOn("theo");
    const tries = theo
      ? [`Ask ${esc(who)} something in its chat.`, `Ask Vello to get ${esc(who)} to look into something and report back.`, `Say "every weekday at 8, send me a brief" to set up a routine.`]
      : ["Your products are on. Their settings are in Settings.", "Turn on Vello any time in Settings › Products for bots, teams and coding runs."];
    body = `<div class="su-hero">${TP.bot(TP.CREW.theo, "done", 84, { badge: false })}</div><h1>You're all set</h1>`
      + (anyProductOn() ? "" : `<p class="w-ask">Nothing is on yet. Go back to Pick products and turn on at least one.</p>`)
      + `<p class="lead">Things to try:</p><ul class="su-try">${tries.map((t) => `<li>${t}</li>`).join("")}</ul>`
      + (missing ? `<div class="tc-line">${TP.badge("needs", "pg")}<span><b>No brain yet</b> · bots can't answer until you add an API key or sign in to an agent in Settings</span></div>` : "")
      + `<div class="btns"><button class="btn pri" data-finish${anyProductOn() ? "" : " disabled"}>Open Vello</button>${anyProductOn() ? "" : `<button class="btn" data-goto="products">Pick products</button>`}</div>`;
  }
  const close = setup.again ? `<button class="btn ghost su-close" data-close>Not now</button>` : "";
  $("#setup").innerHTML = `<div class="su"><aside class="su-side"><div class="su-theo">${TP.bot(TP.CREW.theo, setupFace(), 56)}<b>Setting up Vello</b></div>${side}${close}</aside><section class="su-main"><div class="su-body">${body}</div></section></div>`;
  const root = $("#setup");
  root.querySelectorAll("[data-next]").forEach((b) => b.onclick = setupNext);
  root.querySelectorAll("[data-goto]").forEach((b) => b.onclick = () => { setup.step = b.dataset.goto; drawSetup(); });
  root.querySelectorAll("[data-close]").forEach((b) => b.onclick = closeSetup);
  root.querySelectorAll("[data-recheck]").forEach((b) => b.onclick = async () => { setup.st = null; drawSetup(); setup.st = (await invoke({ cmd: "setupState" })).result; drawSetup(); });
  root.querySelectorAll("[data-term]").forEach((b) => b.onclick = async () => { const r = await invoke({ cmd: "openTerminal", which: b.dataset.term }); b.textContent = r.ok ? "Opened" : "Copy the command"; });
  root.querySelectorAll("[data-tpl]").forEach((b) => b.onclick = () => { const t = TEMPLATES.find((x) => x[0] === b.dataset.tpl); Object.assign(setup, { name: t[0], desc: t[1], instr: t[2], look: t[3] }); drawSetup(); });
  wire(root);
  if (step === "welcome" && $("#su-owner")) $("#su-owner").oninput = (e) => { setup.owner = e.target.value; saveOwnerName(setup.owner); };
  if (step === "brain" && s) wireBrains(root.querySelector("#su-brains"), async () => { setup.st = (await invoke({ cmd: "setupState" })).result; drawSetup(); });
  if (step === "products" && typeof wireProductCards === "function") wireProductCards(root.querySelector("#su-products"), drawSetup);
  if (step === "bot") {
    const get = mountMaker($("#su-maker"), setup.look, (l) => (setup.look = l));
    $("#su-name").oninput = (e) => { setup.name = e.target.value; root.querySelector("[data-create]").disabled = !setup.name.trim(); root.querySelector("[data-create]").textContent = `Make ${setup.name || "it"}`; };
    $("#su-desc").oninput = (e) => (setup.desc = e.target.value);
    root.querySelector("[data-create]").onclick = async () => {
      // The first bot thinks with the brain setup found: a signed-in agent, else a key on its preferred model.
      const brain = (setup.st && setup.st.suggested) || { engine: "claude", model: "claude-sonnet-5-5" };
      const r = await invoke({ cmd: "botCreate", name: setup.name.trim(), description: setup.desc, instructions: setup.instr || `You are ${setup.name.trim()}.`, provider: brain.engine, model: brain.model });
      if (r.ok) { await invoke({ cmd: "botLook", id: r.result.id, look: get() }); setup.made = r.result.id; setup.step = "done"; drawSetup(); }
    };
  }
  root.querySelectorAll("[data-finish]").forEach((b) => b.onclick = async () => {
    await invoke({ cmd: "setupDone" });
    const made = setup.made;
    $("#setup").hidden = true; setup = null;
    if (typeof loadProducts === "function") await loadProducts();
    open(made ? { kind: "bot", id: made } : { kind: "home" });
  });
}

document.addEventListener("keydown", (e) => { if ((e.metaKey || e.ctrlKey) && e.key === "n") { e.preventDefault(); $("#new-bot").click(); } });
setInterval(refresh, 500);
render();
// Setup opens when it was never finished, or when no brain can think here (then at its brain step, and it can be closed).
invoke({ cmd: "setupState" }).then((r) => { if (r.ok && r.result.needsSetup) startSetup(r.result.completed ? { again: true, step: "brain" } : {}); });
