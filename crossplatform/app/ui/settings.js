// Settings, in the Mac's sections (Setup/TheoSettingsWindow.swift), with a list on the left that jumps to each one. Every
// section is on the one page, so other parts of the window can fill their own: Clicky's and Dictation's settings go in
// #settings-clicky and #settings-dictation, and the "theo-settings" event on document fires each time the page is drawn.
const SETTINGS_SECTIONS = [
  ["about", "About", "Your name and the setup guide."],
  ["products", "Products", "Vello, Pointer Assistant and Dictation are separate. Turn on the ones you want."],
  ["brains", "Models & API keys", "Bring your own key for any provider, or use an agent you're signed in to. Any one is enough."],
  ["coding", "Coding runs", "Your coding agents and where builds go."],
  ["connectors", "Connectors", "The apps your bots can use, and what each bot may do with them."],
  ["clicky", "Pointer Assistant", "Everything about your screen companion, in one place."],
  ["dictation", "Dictation", "Talk into the chat box, or hold a shortcut in any app."],
  ["updates", "Updates", "Keep Vello current."],
  ["api", "Local API", "Scripts on this computer can message a bot."],
  ["login", "Start at sign-in", "Vello in the tray, so routines run without you opening it."],
  ["health", "Health check", "What Vello checked on this computer."],
];

function settingsJump(id) {
  const target = document.getElementById(`set-${id}`);
  if (target) target.scrollIntoView({ block: "start", behavior: "smooth" });
}

function settingRowHTML(title, detail, act, extraClass = "") {
  return `<div class="crow${extraClass}"><span class="tx"><b>${title}</b>${detail ? `<small style="white-space:normal">${detail}</small>` : ""}</span>${act ? `<span class="act many">${act}</span>` : ""}</div>`;
}

// The page itself: the list on the left, every section on the right.
async function renderSettingsPage() {
  const [doc, gw, st] = await Promise.all([invoke({ cmd: "doctor" }), invoke({ cmd: "gateway" }), invoke({ cmd: "status" })]);
  if (view.kind !== "settings") return;
  const rows = (doc.result.findings || []).map((x) => `<div class="crow"><span class="tx"><b>${esc(x.check)}</b><small style="white-space:normal">${esc(x.detail)}</small></span>${TP.pill(x.level === "ok" ? "ok" : x.level === "warn" ? "needs" : "failed", x.level === "ok" ? "OK" : x.level === "warn" ? "Needs you" : "Failed")}</div>`).join("");
  const g = gw.result;
  const s = st.result;
  const section = (id, body) => {
    const [, title, subtitle] = SETTINGS_SECTIONS.find((x) => x[0] === id);
    return `<section class="set-sec" id="set-${id}" data-section="${id}"><h2 class="set-title">${esc(title)}</h2><p class="muted set-sub">${esc(subtitle)}</p>${body}</section>`;
  };
  const productLine = (id) => (typeof productIsOn === "function" && !productIsOn(id))
    ? `<div class="list">${settingRowHTML(`${esc(productTitle(id))} is off`, "Turn it on to use it on this computer.", `<button class="btn sm" data-turn-on="${id}">Turn on</button>`)}</div>` : "";
  const about = `<div class="list">${settingRowHTML("Your name", `What your bots call you. Empty: they say "the owner".`, `<input id="owner-name" value="${esc(s.ownerName || "")}" maxlength="40" placeholder="Your first name">`)}`
    + settingRowHTML("Setup guide", "A brain, your products, coding runs and a first bot, one step at a time.", `<button class="btn sm" data-setup-again>Run it again</button>`)
    + settingRowHTML("This is Vello", `${esc(s.versionLabel || s.version)} on ${esc(s.os)} ${esc(s.arch)}`, "") + `</div>`;
  const coding = `<section id="coding-settings"></section><div class="list" id="projects-folder"></div>`;
  const connectors = `<div class="list">${settingRowHTML("Your apps", "Add apps, sign in to them and choose which bots may use each one, on the Connectors page.", `<button class="btn sm" data-open-connectors>Open Connectors</button>`)}</div>`;
  const api = `<div class="list"><div class="crow"><span class="tx"><b>Local API</b><small style="white-space:normal">Lets scripts on this computer message a bot on 127.0.0.1:${g.port}. Needs a token; never counts as you.</small></span>${TP.pill(g.listening ? "ok" : "none", g.listening ? "On" : "Off")}<span class="act"><button class="btn sm" id="gw">${g.listening ? "Turn off" : "Turn on"}</button></span></div></div>`;
  const login = `<div class="list" id="login-row"></div><p class="muted">Data in ${esc(String(s.data))}.</p>`;
  const nav = SETTINGS_SECTIONS.map(([id, title]) => `<button class="set-nav-item" data-jump="${id}">${esc(title)}</button>`).join("");
  $("#pane").innerHTML = `<div class="settings"><nav class="set-nav" aria-label="Settings sections"><div class="section-label">Settings</div>${nav}</nav><div class="set-body"><h1>Settings</h1>`
    + section("about", about)
    + section("products", `<div id="settings-products-body"></div>`)
    + section("brains", `<section id="brains-settings"></section>`)
    + section("coding", coding)
    + section("connectors", connectors)
    + section("clicky", `${productLine("clicky")}<div id="settings-clicky"><p class="muted">Pointer Assistant's own settings show here once Pointer Assistant is set up on this computer.</p></div>`)
    + section("dictation", `${productLine("dictation")}<div id="settings-dictation"><p class="muted">Dictation's own settings show here once it's set up on this computer.</p></div>`)
    + section("updates", `<div id="settings-updates-body"></div>`)
    + section("api", api)
    + section("login", login)
    + section("health", `<div class="list">${rows}</div>`)
    + `</div></div>`;
  const pane = $("#pane");
  pane.querySelectorAll("[data-jump]").forEach((b) => b.onclick = () => settingsJump(b.dataset.jump));
  pane.querySelector("[data-open-connectors]").onclick = () => open({ kind: "connectors" });
  pane.querySelector("[data-setup-again]").onclick = () => startSetup({ again: true });
  pane.querySelectorAll("[data-turn-on]").forEach((b) => b.onclick = async () => { await setProduct(b.dataset.turnOn, true); renderSettingsPage(); });
  $("#gw").onclick = async () => { await invoke({ cmd: "gateway", action: g.listening ? "off" : "on" }); renderSettingsPage(); };
  $("#owner-name").oninput = (e) => saveOwnerName(e.target.value);
  watchSettingsSections(pane);

  // Products: the same cards as Setup's "Pick products".
  const drawProducts = () => {
    const box = $("#settings-products-body");
    if (!box) return;
    const none = typeof productIsOn === "function" && !["theo", "clicky", "dictation"].some(productIsOn);
    box.innerHTML = (none ? `<p class="w-ask">Nothing is on yet. Turn on the products you want; each one works without the others.</p>` : "") + productCardsHTML();
    wireProductCards(box, () => renderSettingsPage());
  };
  if (typeof productCardsHTML === "function") { drawProducts(); loadProducts().then(drawProducts); }

  // Brains: keys, agents, and which one answers when a bot's own keeps failing.
  const drawBrains = () => {
    const box = $("#brains-settings");
    if (!box) return;
    const b = brainsCache;
    const current = b && b.standIn ? b.standIn.split("|")[0] : "";
    const choices = brainChoices(b).filter(([id]) => id !== "claude");
    box.innerHTML = `${brainsHTML(b)}<h2>When a bot's brain fails</h2><div class="list"><div class="crow"><span class="tx"><b>Answer with</b><small style="white-space:normal">Another brain answers for the turn and the chat says so. The default is Claude Code when it's installed.</small></span>`
      + `<span class="act many"><select id="stand-in" aria-label="Stand-in brain"><option value="">Claude Code (default)</option>${choices.map(([id, label]) => `<option value="${esc(id)}"${id === current ? " selected" : ""}>${esc(label)}</option>`).join("")}</select></span></div></div>`;
    wireBrains(box, drawBrains);
    $("#stand-in").onchange = async (e) => {
      const engine = e.target.value;
      let model = "";
      if (engine.startsWith("api:")) { const m = await invoke({ cmd: "apiModels", provider: engine.slice(4) }); model = m.ok ? m.result.preferredModel || "" : ""; }
      else if (b) { const agent = b.agents.find((a) => a.id === engine); model = agent ? agent.defaultModel : ""; }
      await invoke({ cmd: "standIn", engine, model });
      await loadBrains(); drawBrains(); drawCoding();
    };
  };
  // Coding runs: which agent does them, and the folder new projects go in.
  const drawCoding = () => {
    const box = $("#coding-settings");
    if (!box) return;
    box.innerHTML = codingSettingsHTML(brainsCache && brainsCache.coding).replace("<h2>Coding runs</h2>", "") || `<div class="pills">${TP.pill("checking", "Checking")}</div>`;
    if ($("#coding-target")) $("#coding-target").onchange = async (e) => { await invoke({ cmd: "harnessSet", codingTarget: e.target.value }); await loadBrains(); drawBrains(); drawCoding(); };
  };
  drawBrains(); drawCoding();
  loadBrains().then(() => { drawBrains(); drawCoding(); });
  drawProjectsFolder();

  if (typeof drawUpdatesSettings === "function") { drawUpdatesSettings(); loadUpdates("state"); }

  // Open at sign-in lives in the app, not the engine; the browser stand-in for the UI has no answer, so the row stays out.
  const drawLogin = (on) => {
    if (typeof on !== "boolean" || !$("#login-row")) return;
    $("#login-row").innerHTML = `<div class="crow"><span class="tx"><b>Open Vello when you sign in</b><small style="white-space:normal">Vello starts in the tray, so routines run without you opening it. Closing the window keeps Vello running; quit it from the tray icon.</small></span>${TP.pill(on ? "ok" : "none", on ? "On" : "Off")}<span class="act"><button class="btn sm" id="login-toggle">${on ? "Turn off" : "Turn on"}</button></span></div>`;
    $("#login-toggle").onclick = async () => drawLogin(await window.__TAURI__.core.invoke("open_at_login", { enabled: !on }).catch(() => on));
  };
  window.__TAURI__.core.invoke("open_at_login", {}).then(drawLogin).catch(() => {});
  document.dispatchEvent(new CustomEvent("theo-settings", { detail: { clicky: "#settings-clicky", dictation: "#settings-dictation" } }));
}

// Where coding runs make new projects (code.projectsFolder). Empty means the default, inside Theo's data folder.
async function drawProjectsFolder(problem) {
  const box = $("#projects-folder");
  if (!box) return;
  const r = await invoke({ cmd: "projectsFolder" });
  if (!r.ok || !$("#projects-folder")) return;
  const p = r.result;
  const detail = `${esc(String(p.projectsFolder))}${p.chosen ? "" : " (the default, in Vello's data folder)"}. Made when the first project needs it.`
    + (problem ? `<br><span class="w-bad">${esc(problem)}</span>` : "");
  box.innerHTML = settingRowHTML("Projects folder", detail, `<input id="projects-folder-input" placeholder="${esc(String(p.projectsFolder))}" aria-label="Projects folder" spellcheck="false"><button class="btn sm" data-projects-save>Save</button>${p.chosen ? `<button class="btn sm ghost" data-projects-default>Use the default</button>` : ""}`);
  const input = box.querySelector("#projects-folder-input");
  const save = async () => {
    if (!input.value.trim()) return;
    const answer = await invoke({ cmd: "projectsFolder", folder: input.value.trim() });
    drawProjectsFolder(answer.ok ? "" : answer.error);
  };
  box.querySelector("[data-projects-save]").onclick = save;
  input.onkeydown = (e) => { if (e.key === "Enter") { e.preventDefault(); save(); } };
  const reset = box.querySelector("[data-projects-default]");
  if (reset) reset.onclick = async () => { await invoke({ cmd: "projectsFolder", folder: "" }); drawProjectsFolder(); };
}

// The list on the left follows the section in view.
function watchSettingsSections(pane) {
  if (!("IntersectionObserver" in window)) return;
  const items = pane.querySelectorAll(".set-nav-item");
  const mark = (id) => items.forEach((i) => i.classList.toggle("on", i.dataset.jump === id));
  mark("about");
  const seen = new Map();
  const watcher = new IntersectionObserver((entries) => {
    entries.forEach((e) => seen.set(e.target.dataset.section, e.isIntersecting ? e.intersectionRatio : 0));
    const first = SETTINGS_SECTIONS.map(([id]) => id).find((id) => (seen.get(id) || 0) > 0);
    if (first) mark(first);
  }, { root: $("#pane"), threshold: [0, 0.01, 0.25] });
  pane.querySelectorAll(".set-sec").forEach((sec) => watcher.observe(sec));
}
