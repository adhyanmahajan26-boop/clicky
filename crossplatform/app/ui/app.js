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
const INSTALL = /win/i.test(navigator.platform || navigator.userAgent) ? "irm https://claude.ai/install.ps1 | iex" : "curl -fsSL https://claude.ai/install.sh | bash";
// Kept in step with failover.rs classify's Auth, so a card and the Home lane agree on "signed out".
const SIGNIN = /\/login|invalid api key|invalid x-api-key|authentication_error|isn't installed|not logged in|sign in|unauthori[sz]ed|\b401\b|oauth token (has )?expired/i;
function failureCard(m, latest) {
  const reason = m.text.replace(/^Couldn't reply:\s*/, "");
  const signin = SIGNIN.test(reason);
  if (!latest) return `<div class="tc-line">${TP.badge(signin ? "needs" : "failed", "pg")}<span><b>${signin ? "Signed out" : "Failed"}</b> · ${esc(reason)}</span><time>${ago(m.at)}</time></div>`;
  if (signin) {
    const missing = /isn't installed/i.test(reason);
    return `<div class="tc ask"><div class="tc-h">${botHTML(m.author, 28, { state: "needs" })}<span class="who"><b>${esc(nameOf(m.author))}</b> · ${missing ? "Claude Code" : "Sign-in"}</span>${TP.pill("needs", "Needs you")}</div>`
      + `<div class="tc-q">${missing ? "Install Claude Code on this computer" : "Sign in to Claude Code"}</div>`
      + `<p>${missing ? "Theo runs bots on Claude Code, which isn't installed here yet." : "Theo runs bots on your Claude subscription, and Claude Code on this computer is signed out."}</p>`
      + `<div class="tc-obj"><span class="app"><b>C</b>${TP.badge("needs")}</span><span class="tx"><b>Claude Code</b><small>${missing ? "https://claude.com/claude-code" : "Run this in a terminal, then try again"}</small></span>${TP.pill("needs", missing ? "Not installed" : "Signed out")}</div>`
      + `<div class="tc-field"><span>${missing ? INSTALL : "claude auth login"}</span><button class="btn sm" data-copy="${missing ? INSTALL : "claude auth login"}">Copy</button></div>`
      + `<div class="btns">${missing ? "" : `<button class="btn" data-term="signin">Sign in</button>`}<button class="btn pri" data-retry="${esc(m.author)}">Try again</button></div><div class="tc-foot">Your message is kept; it's asked again when you try.</div></div>`;
  }
  return `<div class="tc bad"><div class="tc-h">${botHTML(m.author, 28, { state: "failed" })}<span class="who"><b>${esc(nameOf(m.author))}</b> · Reply</span>${TP.pill("failed", "Failed")}</div>`
    + `<div class="tc-q">${esc(nameOf(m.author))} couldn't answer</div><p>${esc(reason.split(/(?<=\.)\s/)[0])} Your message is kept, and nothing else was changed.</p>`
    + `<div class="term tall tc-details">${esc(reason)}</div>`
    + `<div class="btns"><button class="btn pri" data-retry="${esc(m.author)}">Try again</button><button class="btn" data-details>See details</button></div></div>`;
}
function askCard(m) {
  let p = {}; try { p = JSON.parse(m.card.slice(4)); } catch (e) {}
  const isRun = p.kind === "run";
  const obj = isRun
    ? `<div class="tc-obj"><span class="app"><svg class="ic" viewBox="0 0 24 24"><path d="M8 9l-3 3 3 3M16 9l3 3-3 3M13.5 6l-3 12"/></svg></span><span class="tx"><b>${esc(p.title || "Coding run")}</b><small>${esc((p.prompt || "").split("\n")[0].slice(0, 110))}</small></span></div>`
    : `<div class="tc-obj"><span class="app"><svg class="ic" viewBox="0 0 24 24"><path d="M19.5 12A7.5 7.5 0 1 1 17.3 6.7M13.9 6.8h3.6V3.2M12 8.6V12l2.3 1.5"/></svg></span><span class="tx"><b>${esc(p.name || "Routine")}</b><small>${esc(p.when || "")} · ${esc(p.do || "")}</small></span></div>`;
  return `<div class="tc ask"><div class="tc-h">${botHTML(p.bot, 28, { state: "needs" })}<span class="who"><b>${esc(nameOf(p.bot))}</b> · ${isRun ? "Coding run" : "New routine"}</span>${TP.pill("needs", "Needs you")}</div>`
    + `<div class="tc-q">${isRun ? "Start this coding run?" : "Set up this routine?"}</div><p>${esc(m.text)}</p>${obj}`
    + `<div class="btns"><button class="btn pri" data-card="${esc(m.id)}" data-choice="yes">${isRun ? "Start it" : "Set it up"}</button><button class="btn" data-card="${esc(m.id)}" data-choice="no">Don't</button></div>`
    + `<div class="tc-foot">${isRun ? "A coding agent works with full access in its own folder." : "A routine runs the bot again and again with nobody watching."} Nothing happens unless you say yes.</div></div>`;
}
function answeredLine(m) {
  let p = {}; try { p = JSON.parse(m.card.slice(9)); } catch (e) {}
  const yes = p.choice === "yes";
  return `<div class="tc-line">${yes ? TP.badge("done", "pg") : `<i class="pg nil"></i>`}<span><b>${esc(p.what || (yes ? "Done" : "Declined"))}</b> · ${esc(m.text.replace(/\?$/, "").slice(0, 120))}</span><time>${ago(p.at)}</time></div>`;
}
function chooseCard(m, answered) {
  const match = m.text.match(/\[CHOOSE:\s*([^\]]+)\]/);
  const parts = match[1].split("|").map((s) => s.trim());
  const q = parts.shift();
  const before = m.text.replace(match[0], "").trim();
  const opts = parts.map((o) => { const [t, ...d] = o.split(":"); return [t.trim(), d.join(":").trim()]; });
  if (answered) return (before ? `<div class="body">${md(before)}</div>` : "") + `<div class="tc-line">${TP.badge("done", "pg")}<span><b>Answered</b> · ${esc(q)}</span></div>`;
  return (before ? `<div class="body">${md(before)}</div>` : "") + `<div class="tc ask"><div class="tc-h">${botHTML(m.author, 28, { state: "needs" })}<span class="who"><b>${esc(nameOf(m.author))}</b> · A choice</span>${TP.pill("needs", "Needs you")}</div>`
    + `<div class="tc-q">${esc(q)}</div><div class="tc-opts">${opts.map(([t, d], i) => `<button class="tc-opt${i === 0 ? " on" : ""}" data-say="${esc(t)}"><i></i><span class="tx"><b>${esc(t)}</b><small>${esc(d)}</small></span></button>`).join("")}</div></div>`;
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
  return `<div class="tc${phase === "failed" ? " bad" : ""}"><div class="tc-h"><span class="app"><svg class="ic" viewBox="0 0 24 24"><path d="M8 9l-3 3 3 3M16 9l3 3-3 3M13.5 6l-3 12"/></svg></span><span class="who"><b>${esc(run ? run.title : "Coding run")}</b> · ${esc(run ? run.folder.split(/[\\/]/).pop() : "")}</span>${TP.pill(tone, word)}</div>`
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
  const sig = JSON.stringify([view, msgs.length, msgs.length && msgs[msgs.length - 1].id, msgs.map((m) => m.card || "").join(), faceSig, runSig, live.map(([b]) => b)]);
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
  let html = "", last = null;
  if (!msgs.length) html = `<div class="empty">${view.kind === "bot" ? botHTML(view.id, 112, { badge: false }) : ""}<div>Say hello to ${esc(view.kind === "bot" ? nameOf(view.id) : (state.groups.find((g) => g.id === view.id) || {}).name)}.</div></div>`;
  msgs.forEach((m, i) => {
    if (m.card && m.card.startsWith("ask:")) { html += askCard(m); last = null; return; }
    if (m.card && m.card.startsWith("answered:")) { html += answeredLine(m); last = null; return; }
    if (m.card && m.card.startsWith("dm:")) {
      const target = m.card.split(":")[2];
      html += `<div class="tc-line">${botHTML(target, 18, { badge: false })}<span><b>${esc(nameOf(m.author))}</b> messaged <b>${esc(nameOf(target))}</b> privately</span><time>${ago(m.at)}</time></div>`; last = null; return;
    }
    if (m.run) {
      // One card per run, where its latest line is.
      if (msgs.slice(i + 1).some((x) => x.run === m.run)) return;
      html += runCard(state.runs.find((x) => x.id === m.run), m); last = null; return;
    }
    if (m.author === "user") { html += `<div class="msg user">${md(m.text)}</div>`; last = null; return; }
    if (m.author === "note") { html += `<div class="msg note">${md(m.text)}</div>`; last = null; return; }
    if (m.author === "routine") { html += `<div class="msg routine">${md(m.text)}</div>`; last = null; return; }
    if (/^Couldn't reply:/.test(m.text)) { html += failureCard(m, m === lastFailure && !ownerAfter(i)); last = null; return; }
    const who = last !== m.author ? `<div class="who">${botHTML(m.author, 28, { badge: false })}${esc(nameOf(m.author))}</div>` : "";
    const body = /\[CHOOSE:[^\]]+\]/.test(m.text) ? chooseCard(m, ownerAfter(i)) : `<div class="body">${md(m.text)}</div>`;
    html += `<div class="msg">${who}${body}</div>`;
    last = m.author;
  });
  for (const [b, t] of live) html += `<div class="msg live" data-live="${esc(b)}"><div class="who">${botHTML(b, 28, { badge: false, state: t ? "working" : "thinking" })}${esc(nameOf(b))}</div><div class="body">${md(t || "…")}</div></div>`;
  pane.innerHTML = `<div class="column">${html}</div>`;
  wire(pane);
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
function renderHome() {
  const faces = state.faces;
  const by = (st) => faces.filter((f) => (Array.isArray(st) ? st : [st]).includes(f.state));
  const c = state.counts || {};
  const hour = new Date().getHours();
  const hello = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening";
  const urgent = by(["needs", "failed"]).map((f) => {
    const failed = f.state === "failed";
    const btn = failed ? `<button class="btn pri sm" data-retry="${esc(f.id)}">Try again</button><button class="btn sm" data-open="${esc(f.id)}">Open</button>` : `<button class="btn pri sm" data-open="${esc(f.id)}">Open</button>`;
    return `<div class="tc ${failed ? "bad" : "ask"}"><div class="tc-h">${botHTML(f.id, 28)}<span class="who"><b>${esc(nameOf(f.id))}</b> · ${esc(f.word)}</span><span class="timer">${ago(f.since)}</span></div>`
      + `<div class="tc-q">${esc(f.detail || f.word)}</div><div class="btns">${btn}</div></div>`;
  }).join("") || `<div class="mini">${TP.bot(lookOf("theo"), "done", 28, { badge: false })}<span class="tx"><b>Nothing needs you</b><small>Bots that need an answer or failed show up here first.</small></span></div>`;
  const working = by(["working", "thinking"]).map((f) => `<div class="mini">${botHTML(f.id, 28)}<span class="tx"><b>${esc(nameOf(f.id))}</b><small>${esc(f.detail || f.word)}</small><div class="bar"><i></i></div></span><span class="timer">${clock(f.since)}</span></div>`).join("");
  const done = by("done").map((f) => `<div class="mini">${botHTML(f.id, 28)}<span class="tx"><b>${esc(nameOf(f.id))}</b><small>${esc(f.detail)}</small></span><button class="btn sm" data-open="${esc(f.id)}">Open</button></div>`).join("");
  const asleep = by(["idle", "awake"]).filter((f) => f.id !== "theo").map((f) => `<div class="mini">${botHTML(f.id, 28)}<span class="tx"><b>${esc(nameOf(f.id))}</b><small>${esc(f.word)}</small></span><button class="btn sm" data-open="${esc(f.id)}">Give it a job</button></div>`).join("");
  const sig = JSON.stringify([faces.map((f) => [f.id, f.state, f.detail]), Math.floor(Date.now() / 1000)]);
  once("home", sig, () => {
    $("#pane").innerHTML = `<div class="column"><div><h1>${hello}.</h1><div class="pills">${TP.pill("needs", `${c.needs || 0} need you`)}${TP.pill("failed", `${c.failed || 0} failed`)}${TP.pill("working", `${c.working || 0} working`)}${TP.pill("done", `${c.done || 0} done`)}</div></div>`
      + `<div class="lanes"><div class="lane"><div class="lane-h"><span>Needs you and failed</span><span>${(c.needs || 0) + (c.failed || 0)}</span></div>${urgent}</div>`
      + `<div class="lane"><div class="lane-h"><span>Working now</span><span>${c.working || 0}</span></div>${working || `<div class="muted">Nobody's working right now.</div>`}`
      + (done ? `<div class="lane-h"><span>Finished</span><span>${c.done || 0}</span></div>${done}` : "")
      + (asleep ? `<div class="lane-h"><span>Asleep</span></div>${asleep}` : "") + `</div></div></div>`;
    wire($("#pane"));
  });
}

/* ---------------- connectors ---------------- */
async function renderConnectors(refresh = false) {
  if (!sigs.connectors) $("#pane").innerHTML = `<div class="column"><div class="pills">${TP.pill("checking", "Checking")}</div><p class="muted">Asking Claude Code which apps it can reach…</p></div>`;
  const r = await invoke({ cmd: "connectors", refresh });
  if (view.kind !== "connectors") return;
  if (!r.ok) { $("#pane").innerHTML = `<div class="column"><div class="tc bad"><div class="tc-q">Couldn't list connectors</div><p>${esc(r.error)}</p></div></div>`; return; }
  const list = r.result.connectors.slice().sort((a, b) => ["needsSignIn", "failed", "connected", "unknown"].indexOf(a.status) - ["needsSignIn", "failed", "connected", "unknown"].indexOf(b.status));
  const n = (s) => list.filter((c) => c.status === s).length;
  const rows = list.map((c) => {
    const kind = { connected: "ok", needsSignIn: "needs", failed: "failed", unknown: "checking" }[c.status] || "none";
    const word = { connected: "Connected", needsSignIn: "Needs sign-in", failed: "Can't connect", unknown: "Checking" }[c.status] || "Not connected";
    const small = c.status === "failed" ? `<small class="w-bad">${esc(c.reason || "Not answering")}${c.lastConnected ? ` · worked ${ago(c.lastConnected)} ago` : ""}</small>`
      : c.status === "needsSignIn" ? `<small class="w-ask">Sign in so bots can use it</small>` : `<small>${esc(c.target)}</small>`;
    const act = c.status === "needsSignIn" ? `<button class="btn pri sm" data-signin="${esc(c.name)}">Sign in</button>` : c.status === "failed" ? `<button class="btn sm" data-refresh>Try again</button>` : "";
    // Who may use it: a bot only gets a connector's tools when it's switched on here (the Mac app's per-bot apps).
    const server = c.server || c.name;
    const who = state.bots.filter((b) => b.enabled !== false).map((b) => {
      const on = (b.apps || []).includes(server);
      return `<button type="button" class="btn sm${on ? " pri" : ""}" data-app="${esc(server)}" data-botapp="${esc(b.id)}" aria-pressed="${on}">${esc(b.name)}</button>`;
    }).join("");
    return `<div class="crow"><span class="app">${esc(c.name.slice(0, 1).toUpperCase())}${TP.badge(kind === "ok" ? "ok" : kind === "needs" ? "needs" : kind === "failed" ? "failed" : "none")}</span><span class="tx"><b>${esc(c.name)}</b>${small}</span>${TP.pill(kind, word)}<span class="act">${act}</span></div>`
      + `<div class="apps-for"><span class="muted">Bots that can use it</span>${who}</div>`;
  }).join("");
  $("#pane").innerHTML = `<div class="column"><div><h1>Connectors</h1><p class="muted">The apps Claude Code can reach for your bots. Checked ${ago(r.result.checked)} ago.</p>`
    + `<div class="pills">${TP.pill("ok", `${n("connected")} connected`)}${n("needsSignIn") ? TP.pill("needs", `${n("needsSignIn")} need sign-in`) : ""}${n("failed") ? TP.pill("failed", `${n("failed")} can't connect`) : ""}<button class="btn sm" data-refresh>Check again</button></div></div>`
    + (list.length ? `<div class="list">${rows}</div>` : `<p class="muted">No connectors yet. Add them in Claude Code (claude.ai connectors, or <code>claude mcp add</code>).</p>`)
    + `<div id="signin-help"></div></div>`;
  sigs.connectors = true;
  $("#pane").querySelectorAll("[data-refresh]").forEach((b) => b.onclick = () => { b.disabled = true; renderConnectors(true); });
  $("#pane").querySelectorAll("[data-botapp]").forEach((b) => b.onclick = async () => {
    const bot = state.bots.find((x) => x.id === b.dataset.botapp);
    if (!bot) return;
    const apps = (bot.apps || []).filter((a) => a !== b.dataset.app);
    if (b.getAttribute("aria-pressed") !== "true") apps.push(b.dataset.app);
    await invoke({ cmd: "botUpdate", id: bot.id, apps });
    state = (await invoke({ cmd: "botsState" })).result || state;
    renderConnectors();
  });
  $("#pane").querySelectorAll("[data-signin]").forEach((b) => b.onclick = () => {
    $("#signin-help").innerHTML = `<div class="tc ask"><div class="tc-h"><span class="app">${esc(b.dataset.signin.slice(0, 1))}${TP.badge("needs")}</span><span class="who"><b>${esc(b.dataset.signin)}</b> · Connector</span>${TP.pill("needs", "Needs sign-in")}</div>`
      + `<div class="tc-q">Sign in to ${esc(b.dataset.signin)}</div><p>claude.ai connectors sign in on claude.ai; others sign in from Claude Code's own <code>/mcp</code> menu. Then check again.</p>`
      + `<div class="tc-field"><span>https://claude.ai/settings/connectors</span><button class="btn sm" data-copy="https://claude.ai/settings/connectors">Copy</button></div></div>`;
    wire($("#signin-help"));
  });
}

/* ---------------- routines, usage, settings ---------------- */
async function renderRoutines() {
  const r = (await invoke({ cmd: "routines" })).result || [];
  const rows = r.map((x) => {
    const last = x.runs.slice(-1)[0];
    const kind = !last ? "none" : { done: "done", quiet: "ok", failed: "failed", missed: "needs", running: "working", skipped: "none" }[last.status] || "none";
    const word = !last ? "Not run yet" : { done: "Done", quiet: "Nothing to report", failed: "Failed", missed: "Missed", running: "Working", skipped: "Skipped" }[last.status];
    const target = x.target.startsWith("group:") ? (state.groups.find((g) => `group:${g.id}` === x.target) || {}).head : x.target;
    return `<div class="crow">${botHTML(target, 30, { badge: false, state: x.paused ? "idle" : "awake" })}<span class="tx"><b>${esc(x.name)}</b><small>${esc(nameOf(target))} · ${esc(x.instruction)}</small></span>${TP.pill(x.paused ? "idle" : kind, x.paused ? "Paused" : word)}`
      + `<span class="btns"><button class="btn sm" data-a="run" data-id="${x.id}">Run now</button><button class="btn sm" data-a="${x.paused ? "resume" : "pause"}" data-id="${x.id}">${x.paused ? "Resume" : "Pause"}</button><button class="btn sm ghost" data-a="delete" data-id="${x.id}">Delete</button></span></div>`;
  }).join("");
  $("#pane").innerHTML = `<div class="column"><h1>Routines</h1>${r.length ? `<div class="list">${rows}</div>` : `<p class="muted">Ask a bot for something on a schedule ("every weekday at 8, send me a brief") and it shows up here.</p>`}</div>`;
  $("#pane").querySelectorAll("button[data-a]").forEach((b) => b.onclick = async () => { await invoke({ cmd: "routines", action: b.dataset.a, id: b.dataset.id }); setTimeout(renderRoutines, 300); });
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
  $("#pane").innerHTML = `<div class="column"><h1>Settings</h1><h2>Health check</h2><div class="list">${rows}</div>`
    + `<h2>Local API</h2><div class="list"><div class="crow"><span class="tx"><b>Local API</b><small style="white-space:normal">Lets scripts on this computer message a bot on 127.0.0.1:${g.port}. Needs a token; never counts as you.</small></span>${TP.pill(g.listening ? "ok" : "none", g.listening ? "On" : "Off")}<span class="act"><button class="btn sm" id="gw">${g.listening ? "Turn off" : "Turn on"}</button></span></div></div>`
    + `<h2>This computer</h2><div class="list" id="login-row"></div><p class="muted">${esc(st.result.os)} ${esc(st.result.arch)} · data in ${esc(String(st.result.data))} · Theo ${esc(st.result.version)}</p></div>`;
  $("#gw").onclick = async () => { await invoke({ cmd: "gateway", action: g.listening ? "off" : "on" }); renderSettings(); };
  // Open at sign-in lives in the app, not the engine; the browser stand-in for the UI has no answer, so the row stays out.
  const drawLogin = (on) => {
    if (typeof on !== "boolean" || !$("#login-row")) return;
    $("#login-row").innerHTML = `<div class="crow"><span class="tx"><b>Open Theo when you sign in</b><small style="white-space:normal">Theo starts in the tray, so routines run without you opening it. Closing the window keeps Theo running; quit it from the tray icon.</small></span>${TP.pill(on ? "ok" : "none", on ? "On" : "Off")}<span class="act"><button class="btn sm" id="login-toggle">${on ? "Turn off" : "Turn on"}</button></span></div>`;
    $("#login-toggle").onclick = async () => drawLogin(await window.__TAURI__.core.invoke("open_at_login", { enabled: !on }).catch(() => on));
  };
  window.__TAURI__.core.invoke("open_at_login", {}).then(drawLogin).catch(() => {});
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
  $("#bot-dialog").showModal();
}
$("#new-bot").onclick = () => openBotDialog({ kind: "new" });
$("#head-face").onclick = () => { if (view.kind === "bot") openBotDialog({ kind: "look", id: view.id }); };
$("#bot-form").onsubmit = async (e) => {
  if (e.submitter && e.submitter.value !== "ok") return;
  const look = makerLook();
  if (botDialogMode.kind === "look") { await invoke({ cmd: "botLook", id: botDialogMode.id, look }); Object.keys(sigs).forEach((k) => delete sigs[k]); return refresh(); }
  const f = new FormData(e.target);
  const r = await invoke({ cmd: "botCreate", name: f.get("name"), description: f.get("description"), instructions: f.get("instructions") || `You are ${f.get("name")}.`, provider: "claude", model: f.get("model") });
  if (r.ok) { await invoke({ cmd: "botLook", id: r.result.id, look }); e.target.reset(); open({ kind: "bot", id: r.result.id }); }
};

/* ---------------- first run ---------------- */
const SETUP_STEPS = ["Welcome", "Claude Code", "Coding", "Your first bot", "Done"];
let setup = null;
const TEMPLATES = [
  ["Researcher", "Looks things up and sums them up", "You are Researcher. Read what you're asked about on the web and in files you're given, and answer in a few clear sentences with sources.", { fin: "sky", trim: "#F4F4F5", eye: "round", top: "twin", extra: "none" }],
  ["Builder", "Writes and fixes code", "You are Builder, an engineer. When asked for code, plan it briefly and hand it to a coding run.", { fin: "bone", trim: "#5B8DEF", eye: "wide", top: "handle", extra: "none" }],
  ["Writer", "Drafts emails, posts and docs", "You are Writer. Draft clear, short writing in the owner's voice and ask before anything is sent.", { fin: "slate", trim: "#F4F4F5", eye: "tall", top: "handle", extra: "pencil" }],
];
async function startSetup() {
  setup = { step: 0, st: null, look: TEMPLATES[0][3], name: TEMPLATES[0][0], desc: TEMPLATES[0][1], instr: TEMPLATES[0][2], made: null };
  $("#setup").hidden = false;
  drawSetup();
  setup.st = (await invoke({ cmd: "setupState" })).result;
  drawSetup();
}
function setupFace() {
  const s = setup.st;
  if (setup.step === 4) return "done";
  if (setup.step === 1 && s && !(s.claude.installed && s.claude.signedIn)) return "needs";
  if (setup.step === 3 && !setup.name.trim()) return "needs";
  return "awake";
}
function drawSetup() {
  const s = setup.st, step = setup.step, c = s && s.claude;
  const steps = SETUP_STEPS.map((n, i) => `<div class="su-step${i === step ? " on" : ""}${i < step ? " done" : ""}">${i < step ? TP.badge("done", "pg") : `<i class="num">${i + 1}</i>`}${n}</div>`).join("");
  let body = "";
  const checking = `<div class="pills">${TP.pill("checking", "Checking")}</div>`;
  if (step === 0) {
    body = `<div class="su-hero">${TP.bot(TP.CREW.theo, "awake", 112, { badge: false })}</div><h1>Meet Theo</h1>`
      + `<p class="lead">Theo runs a team of AI bots on your own Claude subscription: chats, group chats, routines and coding runs. Bots can't loop, schedule things or start coding without you saying so.</p>`
      + `<p class="muted">This takes a minute: check Claude Code, then make your first bot.</p><div class="btns"><button class="btn pri" data-next>Get started</button></div>`;
  } else if (step === 1) {
    const ready = c && c.installed && c.signedIn;
    const pill = !c ? TP.pill("checking", "Checking") : ready ? TP.pill("ok", "Signed in") : c.installed ? TP.pill("needs", "Signed out") : TP.pill("none", "Not installed");
    const line = !c ? "Looking for it on this computer…" : ready ? `${esc(c.version)}${c.plan ? ` · Claude ${esc(c.plan[0].toUpperCase() + c.plan.slice(1))}` : ""}` : c.installed ? "Installed, but signed out. Sign in once with your Claude account." : "Not installed yet. It's free; your Claude subscription pays for what bots do.";
    const act = !c || ready ? "" : `<button class="btn pri sm" data-term="${c.installed ? "signin" : "install"}">${c.installed ? "Sign in" : "Install"}</button>`;
    body = `<h1>Claude Code</h1><p class="lead">Theo's bots think with Claude Code, signed in with your Claude account. Nothing goes through anyone else's server.</p>`
      + `<div class="list"><div class="crow"><span class="app"><b>C</b>${c ? TP.badge(ready ? "ok" : c.installed ? "needs" : "none") : ""}</span><span class="tx"><b>Claude Code</b><small style="white-space:normal">${line}</small></span>${pill}<span class="act">${act}</span></div></div>`
      + (c && !ready ? `<div class="tc-field su-cmd"><span>${esc(c.installed ? c.signIn : c.install)}</span><button class="btn sm" data-copy="${esc(c.installed ? c.signIn : c.install)}">Copy</button></div><p class="muted">${c.installed ? "Sign in opens a terminal with this command; your browser finishes the sign-in." : "Install opens a terminal with Claude Code's own installer."} Then check again.</p>` : "")
      + `<div class="btns"><button class="btn pri" data-next${ready ? "" : " disabled"}>Continue</button><button class="btn" data-recheck>Check again</button>${!ready && c ? `<button class="btn ghost" data-next>Skip for now</button>${TP.pill("needs", "Sign in to continue")}` : ""}</div>`;
  } else if (step === 2) {
    const g = s && s.git, h = s && s.gh;
    const r = (name, icon, line, pill, act) => `<div class="crow"><span class="app">${icon}</span><span class="tx"><b>${name}</b><small style="white-space:normal">${line}</small></span>${pill}<span class="act">${act}</span></div>`;
    body = `<h1>Coding runs</h1><p class="lead">Optional. When you ask a bot to build or fix something, a coding agent works on its own branch, commits, and with GitHub pushes and opens a draft pull request.</p>`
      + (!s ? checking : `<div class="list">${r("git", "g", g.installed ? esc(g.version) : "Not installed. Get it from git-scm.com or your package manager.", g.installed ? TP.pill("ok", "Installed") : TP.pill("none", "Not installed"), "")}`
      + r("GitHub CLI", "gh", !h.installed ? "Not installed: runs still commit, they just don't push. cli.github.com" : h.signedIn ? "Signed in: runs can push and open draft PRs." : "Signed out: sign in to push and open draft PRs.",
          !h.installed ? TP.pill("none", "Not installed") : h.signedIn ? TP.pill("ok", "Signed in") : TP.pill("needs", "Signed out"), h.installed && !h.signedIn ? `<button class="btn sm" data-term="gh">Sign in</button>` : "") + `</div>`)
      + `<div class="btns"><button class="btn pri" data-next>Continue</button><button class="btn" data-recheck>Check again</button></div>`;
  } else if (step === 3) {
    body = `<h1>Your first bot</h1><p class="lead">Pick what it does and how it looks. You can change both later.</p>`
      + `<div class="pills su-tpl">${TEMPLATES.map(([n]) => `<button type="button" class="btn sm${setup.name === n ? " pri" : ""}" data-tpl="${n}">${n}</button>`).join("")}</div>`
      + `<div class="su-fields"><label>Name <input id="su-name" value="${esc(setup.name)}" maxlength="40"></label><label>What it does <input id="su-desc" value="${esc(setup.desc)}" maxlength="120"></label></div><div id="su-maker"></div>`
      + `<div class="btns"><button class="btn pri" data-create${setup.name.trim() ? "" : " disabled"}>Make ${esc(setup.name || "it")}</button><button class="btn ghost" data-next>Skip</button></div>`;
  } else {
    const missing = c && !(c.installed && c.signedIn);
    const who = setup.made ? setup.name : "a bot";
    body = `<div class="su-hero">${TP.bot(TP.CREW.theo, "done", 84, { badge: false })}</div><h1>You're all set</h1>`
      + `<p class="lead">Things to try:</p><ul class="su-try"><li>Ask ${esc(who)} something in its chat.</li><li>Ask Theo to get ${esc(who)} to look into something and report back.</li><li>Say "every weekday at 8, send me a brief" to set up a routine.</li></ul>`
      + (missing ? `<div class="tc-line">${TP.badge("needs", "pg")}<span><b>Claude Code is ${c.installed ? "signed out" : "not installed"}</b> · bots can't answer until it is</span><button class="btn sm" data-term="${c.installed ? "signin" : "install"}">${c.installed ? "Sign in" : "Install"}</button></div>` : "")
      + `<div class="btns"><button class="btn pri" data-finish>Open Theo</button></div>`;
  }
  $("#setup").innerHTML = `<div class="su"><aside class="su-side"><div class="su-theo">${TP.bot(TP.CREW.theo, setupFace(), 56)}<b>Setting up Theo</b></div>${steps}</aside><section class="su-main"><div class="su-body">${body}</div></section></div>`;
  const root = $("#setup");
  root.querySelectorAll("[data-next]").forEach((b) => b.onclick = () => { setup.step++; drawSetup(); });
  root.querySelectorAll("[data-recheck]").forEach((b) => b.onclick = async () => { setup.st = null; drawSetup(); setup.st = (await invoke({ cmd: "setupState" })).result; drawSetup(); });
  root.querySelectorAll("[data-term]").forEach((b) => b.onclick = async () => { const r = await invoke({ cmd: "openTerminal", which: b.dataset.term }); b.textContent = r.ok ? "Opened" : "Copy the command"; });
  root.querySelectorAll("[data-tpl]").forEach((b) => b.onclick = () => { const t = TEMPLATES.find((x) => x[0] === b.dataset.tpl); Object.assign(setup, { name: t[0], desc: t[1], instr: t[2], look: t[3] }); drawSetup(); });
  wire(root);
  if (step === 3) {
    const get = mountMaker($("#su-maker"), setup.look, (l) => (setup.look = l));
    $("#su-name").oninput = (e) => { setup.name = e.target.value; root.querySelector("[data-create]").disabled = !setup.name.trim(); root.querySelector("[data-create]").textContent = `Make ${setup.name || "it"}`; };
    $("#su-desc").oninput = (e) => (setup.desc = e.target.value);
    root.querySelector("[data-create]").onclick = async () => {
      const r = await invoke({ cmd: "botCreate", name: setup.name.trim(), description: setup.desc, instructions: setup.instr || `You are ${setup.name.trim()}.`, provider: "claude", model: "claude-sonnet-5-5" });
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
