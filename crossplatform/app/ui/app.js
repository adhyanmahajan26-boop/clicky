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
const SIGNIN = /\/login|invalid api key|isn't installed|not logged in|sign in/i;
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
      + `<div class="tc-field"><span>${missing ? "npm install -g @anthropic-ai/claude-code" : "claude auth login"}</span><button class="btn sm" data-copy="${missing ? "npm install -g @anthropic-ai/claude-code" : "claude auth login"}">Copy</button></div>`
      + `<div class="btns"><button class="btn pri" data-retry="${esc(m.author)}">Try again</button></div><div class="tc-foot">Your message is kept; it's asked again when you try.</div></div>`;
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
    return `<div class="crow"><span class="app">${esc(c.name.slice(0, 1).toUpperCase())}${TP.badge(kind === "ok" ? "ok" : kind === "needs" ? "needs" : kind === "failed" ? "failed" : "none")}</span><span class="tx"><b>${esc(c.name)}</b>${small}</span>${TP.pill(kind, word)}<span class="act">${act}</span></div>`;
  }).join("");
  $("#pane").innerHTML = `<div class="column"><div><h1>Connectors</h1><p class="muted">The apps Claude Code can reach for your bots. Checked ${ago(r.result.checked)} ago.</p>`
    + `<div class="pills">${TP.pill("ok", `${n("connected")} connected`)}${n("needsSignIn") ? TP.pill("needs", `${n("needsSignIn")} need sign-in`) : ""}${n("failed") ? TP.pill("failed", `${n("failed")} can't connect`) : ""}<button class="btn sm" data-refresh>Check again</button></div></div>`
    + (list.length ? `<div class="list">${rows}</div>` : `<p class="muted">No connectors yet. Add them in Claude Code (claude.ai connectors, or <code>claude mcp add</code>).</p>`)
    + `<div id="signin-help"></div></div>`;
  sigs.connectors = true;
  $("#pane").querySelectorAll("[data-refresh]").forEach((b) => b.onclick = () => { b.disabled = true; renderConnectors(true); });
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
    + `<h2>This computer</h2><p class="muted">${esc(st.result.os)} ${esc(st.result.arch)} · data in ${esc(String(st.result.data))} · Theo ${esc(st.result.version)}</p></div>`;
  $("#gw").onclick = async () => { await invoke({ cmd: "gateway", action: g.listening ? "off" : "on" }); renderSettings(); };
}

/* ---------------- the loop ---------------- */
function open(v) { view = v; Object.keys(sigs).forEach((k) => delete sigs[k]); render(); }
let traySig = "";
function updateTray() {
  const c = state.counts || {};
  const [st, n, label] = c.failed ? ["failed", c.failed, `${c.failed} failed`] : c.needs ? ["needs", c.needs, `${c.needs} need${c.needs === 1 ? "s" : ""} you`] : c.working ? ["working", c.working, `${c.working} working`] : ["awake", 0, ""];
  const sig = `${st}${n}`;
  if (sig === traySig || !window.__TAURI__.core.invoke) return;
  traySig = sig;
  window.__TAURI__.core.invoke("set_tray", { state: st, count: n, label }).catch(() => {});
}
async function refresh() {
  try { state = (await invoke({ cmd: "botsState" })).result || state; } catch (e) { console.error(e); }
  updateTray();
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

/* Make your bot: a look, shown awake and in the five main states. */
let draft = null;
function shuffle() {
  const pick = (a) => a[Math.floor(Math.random() * a.length)];
  draft = { fin: pick(Object.keys(TP.FIN)), trim: pick(Object.values(TP.TRIMS)), eye: pick(Object.keys(TP.EYES)), top: pick(TP.TOPS.concat(TP.HATS)), extra: pick(TP.EXTRAS) };
  $("#maker-face").innerHTML = TP.bot(draft, "awake", 96, { badge: false });
  $("#maker-states").innerHTML = ["working", "needs", "failed", "done", "idle"].map((s) => TP.bot(draft, s, 36)).join("");
}
$("#shuffle").onclick = shuffle;
$("#new-bot").onclick = () => { shuffle(); $("#bot-dialog").showModal(); };
$("#bot-form").onsubmit = async (e) => {
  if (e.submitter && e.submitter.value !== "ok") return;
  const f = new FormData(e.target);
  const r = await invoke({ cmd: "botCreate", name: f.get("name"), description: f.get("description"), instructions: f.get("instructions") || `You are ${f.get("name")}.`, provider: "claude", model: f.get("model") });
  if (r.ok) { await invoke({ cmd: "botLook", id: r.result.id, look: draft }); e.target.reset(); open({ kind: "bot", id: r.result.id }); }
};
document.addEventListener("keydown", (e) => { if ((e.metaKey || e.ctrlKey) && e.key === "n") { e.preventDefault(); $("#new-bot").click(); } });
setInterval(refresh, 500);
render();
