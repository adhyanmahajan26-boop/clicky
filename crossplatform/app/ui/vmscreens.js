// VM screens on Windows and Linux: hidden browser windows (headless Chrome or Edge) where research agents open and read
// pages, as the Mac's Studio screens do (leanring-buddy/Studio, Research/BrowserResearcher.swift). This file draws:
// - Settings › VM screens (#settings-vmscreens, filled on "theo-settings"): on or off, how many, the browser found or what
//   to install, the research agents' jobs and pages, and a "Try it" box that opens a page and shows its tile;
// - the VM screens panel (the "vmscreens" pane): one live tile per screen, its page, and what its agent is doing;
// - the chat's research brief card and the "needs you" card for a page asking for a person.
// Everything goes through `control` (theo-core vmscreens/): vmScreens {action}, research {action}, setSetting, openLink.
const VMSCREENS = (() => {
  "use strict";
  const call = (cmd) => window.__TAURI__.core.invoke("control", { cmd });
  const escape = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const set = (key, value) => call({ cmd: "setSetting", key, value });
  const CHROME_PAGE = "https://www.google.com/chrome/";
  let last = null;
  let pollTimer = null;

  function row(title, detail, action) {
    return `<div class="crow"><span class="tx"><b>${title}</b>${detail ? `<small style="white-space:normal">${detail}</small>` : ""}</span>${action ? `<span class="act many">${action}</span>` : ""}</div>`;
  }
  function segments(id, values, current, label) {
    return `<span class="vm-seg" role="radiogroup" aria-label="${escape(label)}">${values.map((v) => `<button class="${v === current ? "on" : ""}" data-seg="${id}" data-value="${v}" role="radio" aria-checked="${v === current}" title="${escape(label)}: ${v}">${v}</button>`).join("")}</span>`;
  }
  function host(address) { try { return new URL(address).host; } catch (e) { return address || ""; } }
  function tilePill(screen) {
    if (screen.state === "working") return TP.pill("working", "Working");
    if (screen.state === "starting") return TP.pill("checking", "Starting");
    if (screen.state === "idle") return TP.pill("idle", "Idle");
    return TP.pill("none", "Asleep");
  }
  function tileHTML(screen) {
    const picture = screen.picture ? `<img src="${screen.picture}" alt="What ${escape(screen.name)} shows">` : `<div class="vm-blank">${screen.state === "asleep" ? "Asleep: opens when an agent needs it" : "Nothing open"}</div>`;
    return `<div class="vm-tile${screen.state === "working" ? " live" : ""}" data-screen="${screen.number}"><div class="vm-shot">${picture}</div>`
      + `<div class="vm-meta"><div class="vm-name"><b>${escape(screen.name)}</b>${tilePill(screen)}</div>`
      + `<div class="vm-title" title="${escape(screen.title)}">${escape(screen.title || (screen.url ? host(screen.url) : "—"))}</div>`
      + `<div class="vm-url" title="${escape(screen.url)}">${escape(screen.url || "")}</div>`
      + `<div class="vm-doing">${escape(screen.doing || (screen.holder ? `Held by ${screen.holder}` : screen.pages ? `${screen.pages} page${screen.pages === 1 ? "" : "s"} read` : ""))}</div></div></div>`;
  }
  function researchLine(r) {
    if (!r || !r.state || r.state === "idle") return "No research running. Ask a bot to research something, or tell Pointer Assistant \"research … for me\".";
    const agents = (r.agents || []).join(" and ");
    const words = { searching: "Searching", reading: "Reading", writing: "Writing the brief", done: "Done", failed: "Didn't finish", cancelled: "Cancelled" }[r.state] || r.state;
    return `${words}: "${escape(r.topic || "")}"${agents ? ` · ${escape(agents)}` : ""}${r.pagesRead ? ` · ${r.pagesRead} page${r.pagesRead === 1 ? "" : "s"} read` : ""}${r.problem ? ` · ${escape(r.problem)}` : ""}`;
  }
  function researching(r) { return r && ["searching", "reading", "writing"].includes(r.state); }

  /* ---------------- Settings › VM screens ---------------- */
  async function drawSettings(box) {
    const r = await call({ cmd: "vmScreens", action: "state" });
    if (!r.ok) { box.innerHTML = `<p class="muted">${escape(r.error)}</p>`; return; }
    const s = last = r.result;
    showSidebarRow(s.on);
    const browserLine = s.browser
      ? `${escape(s.browser.name)}, found on this computer. Each screen is its own hidden window of it with a fresh profile: no sign-ins, nothing kept.`
      : `Vello needs Chrome or Edge for VM screens. Windows has Microsoft Edge; on Linux, install Google Chrome or Chromium.`;
    const roles = (s.roles || []).map((role) => `<label class="vm-role" title="${escape(role.detail)}"><input type="checkbox" data-role="${escape(role.id)}"${role.on ? " checked" : ""}> <b>${escape(role.title)}</b> <small>${escape(role.detail)}</small></label>`).join("");
    box.innerHTML = `<div class="list">`
      + row("VM screens", "Hidden browser windows on this computer where research agents open and read web pages, each on its own screen. Nothing shows on your monitors or taskbar, and they only read: no typing, no forms, no sign-ins. A page asking for a person comes to you as a card.",
        `${TP.pill(s.on ? "ok" : "none", s.on ? "On" : "Off")}<button class="btn sm" id="vm-on">${s.on ? "Turn off" : "Turn on"}</button>`)
      + row("Screens", "How many pages can be read at once. Each closes a minute after its last page, and all of them when Vello quits.", segments("count", [1, 2, 3, 4], s.count, "Screens"))
      + row("Browser", browserLine, s.browser ? TP.pill("ok", "Found") : `${TP.pill("needs", "Needs you")}<button class="btn sm" id="vm-get-chrome">Get Chrome</button>`)
      + row("Research agents per question", "Each question is split between agents with different jobs, one screen each. The brief merges what they find.", segments("agents", [2, 3, 4], s.agents, "Research agents per question"))
      + row("Pages per agent", "More pages take longer.", segments("pages", [2, 3, 4], s.pages, "Pages per agent"))
      + `<div class="crow"><span class="tx" style="flex:1"><b>Jobs</b><small style="white-space:normal">Which jobs an agent can be given, in this order.</small><span class="vm-roles">${roles}</span></span></div>`
      + `<div class="crow"><span class="tx" style="flex:1"><b>Try it</b><small style="white-space:normal">Opens a page on a VM screen and reads it, the way a research agent does.</small>`
      + `<span class="vm-try"><input type="text" id="vm-try-url" placeholder="https://en.wikipedia.org/wiki/Fern" autocomplete="off" spellcheck="false"><button class="btn pri sm" id="vm-try"${s.on && s.browser ? "" : " disabled"}>Open</button><button class="btn sm ghost" id="vm-panel">Open the VM screens panel</button></span>`
      + `<small id="vm-try-result" style="white-space:normal"></small><span id="vm-try-tile"></span></span></div>`
      + `</div>`;
    box.querySelector("#vm-on").onclick = async () => { await call({ cmd: "vmScreens", action: s.on ? "off" : "on" }); drawSettings(box); };
    const get = box.querySelector("#vm-get-chrome");
    if (get) get.onclick = () => call({ cmd: "openLink", url: CHROME_PAGE });
    box.querySelectorAll("[data-seg]").forEach((b) => b.onclick = async () => {
      const key = { count: "vmScreens.count", agents: "research.agents", pages: "research.pages" }[b.dataset.seg];
      await set(key, Number(b.dataset.value));
      drawSettings(box);
    });
    box.querySelectorAll("[data-role]").forEach((c) => c.onchange = () => set(`research.role.${c.dataset.role}`, c.checked));
    box.querySelector("#vm-panel").onclick = () => open({ kind: "vmscreens" });
    const tryIt = async () => {
      const url = box.querySelector("#vm-try-url").value.trim();
      const result = box.querySelector("#vm-try-result");
      if (!url) { result.textContent = "Type a web address first."; return; }
      result.textContent = "Opening…";
      box.querySelector("#vm-try-tile").innerHTML = "";
      const answer = await call({ cmd: "vmScreens", action: "open", url });
      if (!answer.ok) { result.textContent = answer.error; return; }
      const a = answer.result;
      result.textContent = `${a.title || host(a.url)}: ${a.words} words read on VM screen ${a.screen} in ${a.seconds} s.${a.humanCheck ? " It asks for a person, so a research agent would skip it and tell you." : ""}`;
      const st = await call({ cmd: "vmScreens", action: "state", tiles: true });
      const screen = st.ok && st.result.screens.find((x) => x.number === a.screen);
      if (screen) box.querySelector("#vm-try-tile").innerHTML = `<span class="vm-grid one">${tileHTML(screen)}</span>`;
    };
    box.querySelector("#vm-try").onclick = tryIt;
    box.querySelector("#vm-try-url").onkeydown = (e) => { if (e.key === "Enter") tryIt(); };
  }

  /* ---------------- the VM screens panel ---------------- */
  async function drawPanel() {
    if (typeof view === "undefined" || view.kind !== "vmscreens") return stopPolling();
    const r = await call({ cmd: "vmScreens", action: "state", tiles: true });
    if (view.kind !== "vmscreens") return stopPolling();
    const pane = document.querySelector("#pane");
    if (!r.ok) { pane.innerHTML = `<div class="column"><p class="muted">${escape(r.error)}</p></div>`; return; }
    const s = last = r.result;
    showSidebarRow(s.on);
    const top = !s.on
      ? `<div class="tc"><div class="tc-h"><span class="who"><b>VM screens are off</b></span>${TP.pill("none", "Off")}</div><p>Turn them on and research agents read pages on hidden screens you can watch here. Off, they read pages the plain way.</p><div class="btns"><button class="btn pri" id="vm-panel-on"${s.browser ? "" : " disabled"}>Turn on</button><button class="btn" id="vm-panel-settings">Settings</button></div>${s.browser ? "" : `<p class="w-bad">${escape(s.needsBrowser || "")}</p>`}</div>`
      : `<div class="vm-head"><span>${researchLine(s.research)}</span>${researching(s.research) ? `<button class="btn sm" id="vm-cancel">Stop the research</button>` : ""}<button class="btn sm ghost" id="vm-panel-settings">Settings</button></div>`;
    pane.innerHTML = `<div class="vm-panel">${top}<div class="vm-grid">${s.screens.map(tileHTML).join("")}</div>`
      + `<p class="muted vm-foot">${s.browser ? `${escape(s.browser.name)} · ` : ""}${s.running} of ${s.count} running · pictures refresh every 2 seconds while a screen is working.</p></div>`;
    const on = pane.querySelector("#vm-panel-on");
    if (on) on.onclick = async () => { await call({ cmd: "vmScreens", action: "on" }); drawPanel(); };
    const settings = pane.querySelector("#vm-panel-settings");
    if (settings) settings.onclick = () => { open({ kind: "settings" }); setTimeout(() => typeof settingsJump === "function" && settingsJump("vmscreens"), 300); };
    const cancel = pane.querySelector("#vm-cancel");
    if (cancel) cancel.onclick = async () => { cancel.disabled = true; await call({ cmd: "research", action: "cancel" }); drawPanel(); };
    // Every 2 s while anything is working, else every 5 s: an idle panel costs next to nothing.
    const busy = s.screens.some((x) => x.state === "working" || x.state === "starting") || researching(s.research);
    stopPolling();
    pollTimer = setTimeout(drawPanel, busy ? 2000 : 5000);
  }
  function stopPolling() { if (pollTimer) { clearTimeout(pollTimer); pollTimer = null; } }

  // The sidebar's VM screens row shows while they're on.
  function showSidebarRow(on) {
    const rowEl = document.querySelector("#vm-row");
    if (rowEl) rowEl.hidden = !on;
  }

  /* ---------------- the chat's cards ---------------- */
  function handles(m) { return /^(research|browserCheck):/.test(m.card || ""); }
  const briefs = {};
  function payload(m, prefix) { try { return JSON.parse(m.card.slice(prefix.length)); } catch (e) { return {}; } }
  function briefParts(text) {
    const body = String(text || "").split(/\n\n\[1\] /)[0];
    const lines = body.trim().split("\n");
    const title = lines[0].startsWith("#") ? lines[0].replace(/^#+\s*/, "") : "";
    const rest = (title ? lines.slice(1) : lines).join("\n").trim();
    const excerpt = (rest.split(/\n\s*\n/).find((p) => p.trim() && !p.trim().startsWith("#")) || "").replace(/[*_`]/g, "").trim();
    return { title, body: rest, excerpt };
  }
  function card(m) {
    if (m.card.startsWith("browserCheck:")) {
      const p = payload(m, "browserCheck:");
      const safe = /^https:\/\//.test(p.url || "");
      return `<div class="tc ask"><div class="tc-h"><span class="app">${globe()}</span><span class="who"><b>${escape(p.host || "A page")}</b> · research by ${escape(p.by || nameOf(m.author))}</span>${TP.pill("needs", "Needs you")}</div>`
        + `<div class="tc-q">${escape(p.host || "A page")} wants a person to check you're human</div><p>The research agent won't try to get past it, so it skipped that page. Open it in your browser to read it yourself.</p>`
        + `<div class="tc-field"><span title="${escape(p.url || "")}">${escape(p.url || "")}</span><button class="btn sm" data-copy="${escape(p.url || "")}">Copy</button></div>`
        + (safe ? `<div class="btns"><button class="btn pri" data-vm-link="${escape(p.url)}">Open in my browser</button></div>` : "") + `</div>`;
    }
    const p = payload(m, "research:");
    const parts = briefParts(m.text);
    briefs[m.id] = { text: m.text, title: parts.title || p.topic || "Research", body: parts.body, by: p.by };
    const sources = (p.sources || []).map((source) => {
      const link = /^https:\/\//.test(source.url) ? ` data-vm-link="${escape(source.url)}"` : "";
      return `<button class="vm-source${source.ok ? "" : " bad"}"${link} title="${escape(source.url)}"><span class="n">${source.index}</span><span class="tx"><b>${escape(source.title || host(source.url))}</b><small>${escape(source.agent)} · ${escape(host(source.url))}${source.ok ? "" : " · unreadable"}</small></span></button>`;
    }).join("");
    const read = (p.sources || []).filter((x) => x.ok).length;
    return `<div class="tc ok vm-brief"><div class="tc-h"><span class="app">${globe()}</span><span class="who"><b>Research</b> · ${escape((p.agents || []).join(", "))} · ${p.onScreens ? "read on the VM screens" : "read the plain way"}${p.by ? ` · for ${escape(p.by)}` : ""}</span>${TP.pill("ok", "Brief ready")}</div>`
      + `<div class="tc-q">${escape(parts.title || p.topic || "Research")}</div>${parts.excerpt ? `<p>${escape(parts.excerpt.slice(0, 420))}</p>` : ""}`
      + `<div class="vm-sources">${sources}</div>`
      + `<div class="btns"><button class="btn pri" data-vm-brief="${escape(m.id)}">Open the brief</button><button class="btn" data-copy="${escape(m.text)}">Copy</button>${p.saved ? `<button class="btn" data-open-file="${escape(p.saved)}">Open file</button>` : ""}`
      + `<span class="tc-foot">${read} of ${(p.sources || []).length} pages read${p.humanChecks ? ` · ${p.humanChecks} asked for a person` : ""}</span></div></div>`;
  }
  function globe() {
    return `<svg class="ic" viewBox="0 0 24 24"><circle cx="12" cy="12" r="8.5"/><path d="M3.5 12h17M12 3.5c2.6 2.4 3.9 5.2 3.9 8.5s-1.3 6.1-3.9 8.5c-2.6-2.4-3.9-5.2-3.9-8.5s1.3-6.1 3.9-8.5z"/></svg>`;
  }
  function openBrief(id) {
    const b = briefs[id];
    if (!b) return;
    let dialog = document.querySelector("#vm-reader");
    if (!dialog) { dialog = document.createElement("dialog"); dialog.id = "vm-reader"; document.body.appendChild(dialog); }
    const html = typeof CARDS !== "undefined" && CARDS.rich ? CARDS.rich(b.text.replace(/^#[^\n]*\n/, "")) : `<pre>${escape(b.text)}</pre>`;
    dialog.innerHTML = `<div class="reader-h"><span>Research${b.by ? ` for ${escape(b.by)}` : ""}</span><button class="btn sm" data-reader-copy>Copy</button><button class="btn sm" data-reader-close>Close</button></div>`
      + `<div class="reader"><h1 class="reader-title">${escape(b.title)}</h1>${html}</div>`;
    dialog.querySelector("[data-reader-close]").onclick = () => dialog.close();
    dialog.querySelector("[data-reader-copy]").onclick = (e) => { try { navigator.clipboard.writeText(b.text); } catch (x) { /* the button says so anyway */ } e.target.textContent = "Copied"; };
    dialog.showModal();
  }
  function wire(root) {
    root.querySelectorAll("[data-vm-brief]").forEach((b) => b.onclick = () => openBrief(b.dataset.vmBrief));
    root.querySelectorAll("[data-vm-link]").forEach((b) => b.onclick = async () => { const r = await call({ cmd: "openLink", url: b.dataset.vmLink }); if (b.classList.contains("btn")) b.textContent = r.ok ? "Opened" : r.error; });
  }

  /* ---------------- hooking in ---------------- */
  function fill(selector) {
    const box = document.querySelector(selector || "#settings-vmscreens");
    if (!box || box.dataset.vmDrawn) return;
    box.dataset.vmDrawn = "1";
    drawSettings(box);
  }
  document.addEventListener("theo-settings", (e) => fill(e.detail && e.detail.vmscreens));
  call({ cmd: "vmScreens", action: "state" }).then((r) => r && r.ok && showSidebarRow(r.result.on)).catch(() => {});

  return { handles, card, wire, drawPanel, state: () => last };
})();

// app.js draws this pane when the VM screens row is picked.
function renderVMScreens() { return VMSCREENS.drawPanel(); }
