/* A bot's settings, in a column on the right like the Mac's BotInspector and BotDetailsView: name, what it does, look, on or
   off, instructions, brain, model and effort, who it can message, its category, its apps and their levels, a fresh session,
   make primary, and delete (never the CEO). Text saves as you type (after a pause) and when you leave the field; everything
   else saves at once. Uses `botGet` for what the state report leaves out, then `botUpdate` and friends. Loaded before app.js. */

let botSettingsId = null;
let botSettingsSaveTimer = null;
// Brains that take an effort level on this build, and the levels each accepts (harness.rs passes it straight through).
const EFFORT_LEVELS = { codex: ["minimal", "low", "medium", "high", "xhigh"], grok: ["low", "high"] };

function closeBotSettings() {
  clearTimeout(botSettingsSaveTimer);
  const panel = $("#bot-settings");
  if (panel) panel.remove();
  botSettingsId = null;
}

async function openBotSettings(botId) {
  botSettingsId = botId;
  let panel = $("#bot-settings");
  if (!panel) {
    panel = document.createElement("aside");
    panel.id = "bot-settings";
    panel.setAttribute("aria-label", "Bot settings");
    document.body.appendChild(panel);
  }
  panel.innerHTML = `<div class="bs-head"><b>Settings</b><button class="btn ghost" data-close aria-label="Close">&#10005;</button></div><p class="muted">Loading…</p>`;
  panel.querySelector("[data-close]").onclick = closeBotSettings;
  await drawBotSettings();
  if (!brainsCache) { await loadBrains(); if (botSettingsId === botId) drawBotSettings(); }
}

async function botSettingsUpdate(fields) {
  const r = await invoke(Object.assign({ cmd: "botUpdate", id: botSettingsId }, fields));
  const note = $("#bs-note");
  if (note) note.textContent = r.ok ? "" : r.error;
  refresh();
  return r;
}

async function drawBotSettings() {
  const botId = botSettingsId;
  const panel = $("#bot-settings");
  if (!botId || !panel) return;
  const got = await invoke({ cmd: "botGet", id: botId });
  if (botSettingsId !== botId || !$("#bot-settings")) return;
  if (!got.ok) { closeBotSettings(); return; }
  const bot = got.result;
  const on = bot.enabled !== false;
  const others = state.bots.filter((b) => b.id !== bot.id);
  const level = bot.authorityLevel || "member";
  const canMessage = bot.canMessage || null;
  const brains = brainChoices(brainsCache);
  if (!brains.some(([id]) => id === bot.provider)) brains.unshift([bot.provider, bot.provider]);
  const efforts = EFFORT_LEVELS[bot.provider];
  const appList = (bot.hubApps || []).filter((a) => a.id);
  const myTeam = (bot.teams || [])[0];
  const section = (title, hint, body) => `<section class="bs-sec"><div class="bs-h">${title}</div>${hint ? `<p class="hint">${hint}</p>` : ""}${body}</section>`;
  panel.innerHTML = `<div class="bs-head"><b>Settings</b><button class="btn ghost" data-close aria-label="Close">&#10005;</button></div>`
    + `<div class="bs-id"><button class="bs-look" id="bs-look" title="Change how it looks">${botHTML(bot.id, 56, { badge: false })}</button><div class="bs-names">`
    + `<input id="bs-name" value="${esc(bot.name)}" maxlength="40" aria-label="Name" placeholder="Name">`
    + `<input id="bs-desc" value="${esc(bot.description || "")}" maxlength="120" aria-label="What it does" placeholder="What it does"></div></div>`
    + `<div class="bs-on"><span class="tx"><b class="${on ? "is-on" : ""}">${on ? "On" : "Off"}</b><small>${on ? "Answers, runs its schedules and joins group chats" : "Paused: no replies, schedules or group turns"}</small></span>`
    + `<label class="switch"><input type="checkbox" id="bs-enabled"${on ? " checked" : ""}${bot.primary ? " disabled" : ""} aria-label="On"><i></i></label></div>`
    + section("Instructions", "", `<textarea id="bs-instructions" rows="6">${esc(bot.instructions || "")}</textarea>`)
    + section("Brain and model", "", `<label>Brain<select id="bs-brain">${brains.map(([id, label]) => `<option value="${esc(id)}"${id === bot.provider ? " selected" : ""}>${esc(label)}</option>`).join("")}</select></label>`
      + `<label>Model<input id="bs-model" value="${esc(bot.model || "")}" list="bs-models" maxlength="120" autocomplete="off" spellcheck="false"><datalist id="bs-models"></datalist></label>`
      + (efforts ? `<label>Effort<select id="bs-effort"><option value="">The model's default</option>${efforts.map((e) => `<option value="${e}"${e === bot.effort ? " selected" : ""}>${e}</option>`).join("")}</select></label>` : ""))
    + section("Authority", "Who this bot may give work to. A CEO can message any bot; a lead, the bots of the group chats it heads; anyone, the bots you tick.",
      `<div class="seg wide">${[["member", "Member"], ["lead", "Lead"], ["ceo", "CEO"]].map(([k, w]) => `<button data-authority="${k}" class="${k === level ? "on" : ""}">${w}</button>`).join("")}</div>`
      + (others.length && level !== "ceo" ? `<div class="lbl">Can also message</div><div class="chips"><button class="chip-t${canMessage === null ? " on" : ""}" data-anyone>Anyone</button>${others.map((b) => `<button class="chip-t${canMessage && canMessage.includes(b.id) ? " on" : ""}" data-can="${esc(b.id)}">${esc(b.name)}</button>`).join("")}</div>`
        + `<p class="hint">${canMessage === null ? "It can message any bot. Tick bots to keep it to those (and its team)." : "Only the bots ticked here, plus whoever its team gives it: its manager, or its team and the CEO."}</p>` : ""))
    + section("Category", "", bot.primary ? `<p class="hint">The CEO sits on top of the sidebar, above every category.</p>`
      : `<select id="bs-team" aria-label="Category"><option value="">Other bots (no category)</option>${teamsList().map((t) => `<option value="${esc(t.id)}"${myTeam && myTeam.id === t.id ? " selected" : ""}>${esc(t.name)}${t.leader === bot.id ? " (manager)" : ""}</option>`).join("")}</select>`
        + (bot.role ? `<p class="hint">${esc(bot.role.charAt(0).toUpperCase() + bot.role.slice(1))}.</p>` : ""))
    + section("Apps", appList.length ? "What it may do in each app. It never gets more than read and draft unless you asked for it yourself." : "",
      appList.length ? `<div class="bs-apps">${appList.map((a) => {
        const current = (bot.apps || []).includes(a.id) ? ((bot.appLevels || {})[a.id] || "readAndDraft") : "off";
        return `<label class="bs-app"><span>${esc(a.name)}</span><select data-app="${esc(a.id)}">${Object.entries(LEVEL_WORDS).map(([k, w]) => `<option value="${k}"${k === current ? " selected" : ""}>${w}</option>`).join("")}</select></label>`;
      }).join("")}</div>` : `<p class="hint">No apps yet. Add them on the Connectors page.</p>`)
    + section("Memory", "Its next reply starts a new engine session. Its memory, skills and saved chat carry over.", `<button class="btn sm" id="bs-fresh">Start a fresh session</button>`)
    + `<p class="hint err" id="bs-note" role="status"></p>`
    + (bot.primary ? "" : `<div class="bs-foot"><button class="btn sm" id="bs-primary">Make primary</button><button class="btn sm ghost danger" id="bs-delete">Delete bot…</button></div>`);

  panel.querySelector("[data-close]").onclick = closeBotSettings;
  $("#bs-look").onclick = () => openBotDialog({ kind: "look", id: bot.id });
  const saveText = (el, key, keepNonEmpty) => {
    const send = () => {
      clearTimeout(botSettingsSaveTimer);
      const value = el.value.trim();
      if (keepNonEmpty && !value) return;
      botSettingsUpdate({ [key]: value });
    };
    el.oninput = () => { clearTimeout(botSettingsSaveTimer); botSettingsSaveTimer = setTimeout(send, 600); };
    el.onchange = send;
  };
  saveText($("#bs-name"), "name", true);
  saveText($("#bs-desc"), "description", false);
  saveText($("#bs-instructions"), "instructions", true);
  saveText($("#bs-model"), "model", true);
  $("#bs-enabled").onchange = async (e) => { await botSettingsUpdate({ enabled: e.target.checked }); drawBotSettings(); };
  if ($("#bs-effort")) $("#bs-effort").onchange = (e) => botSettingsUpdate({ effort: e.target.value });
  $("#bs-brain").onchange = async (e) => {
    // A new brain starts on its own model: the agent's default, or the key's preferred one.
    const engine = e.target.value;
    let model = "";
    if (engine === "claude") model = CLAUDE_MODELS[0];
    else if (engine.startsWith("api:")) { const m = await invoke({ cmd: "apiModels", provider: engine.slice(4) }); model = m.ok ? m.result.preferredModel || "" : ""; }
    else { const agent = brainsCache && brainsCache.agents.find((a) => a.id === engine); model = agent ? agent.defaultModel || "" : ""; }
    const fields = { provider: engine };
    if (model) fields.model = model;
    await botSettingsUpdate(fields);
    drawBotSettings();
  };
  suggestSettingsModels(bot.provider);
  panel.querySelectorAll("[data-authority]").forEach((b) => b.onclick = async () => { await botSettingsUpdate({ authority: b.dataset.authority }); drawBotSettings(); });
  const anyone = panel.querySelector("[data-anyone]");
  if (anyone) anyone.onclick = async () => { await botSettingsUpdate({ canMessage: null }); drawBotSettings(); };
  panel.querySelectorAll("[data-can]").forEach((b) => b.onclick = async () => {
    const list = (canMessage || []).slice();
    const id = b.dataset.can;
    const next = list.includes(id) ? list.filter((x) => x !== id) : list.concat([id]);
    await botSettingsUpdate({ canMessage: next });
    drawBotSettings();
  });
  if ($("#bs-team")) $("#bs-team").onchange = async (e) => { await invoke({ cmd: "teamMove", bot: bot.id, team: e.target.value || null }); refresh(); drawBotSettings(); };
  panel.querySelectorAll("[data-app]").forEach((s) => s.onchange = async () => { await invoke({ cmd: "botApp", bot: bot.id, app: s.dataset.app, level: s.value }); refresh(); });
  $("#bs-fresh").onclick = async (e) => { e.target.disabled = true; await invoke({ cmd: "botFresh", id: bot.id }); e.target.textContent = "Fresh session next reply"; };
  if ($("#bs-primary")) $("#bs-primary").onclick = async () => { await invoke({ cmd: "botMakePrimary", id: bot.id }); await refresh(); drawBotSettings(); };
  if ($("#bs-delete")) $("#bs-delete").onclick = () => deleteBot(bot.id);
}

// The column follows the selected bot, and closes when the window shows something else.
function followBotSettings() {
  if (!botSettingsId) return;
  if (view.kind !== "bot") closeBotSettings();
  else if (view.id !== botSettingsId) openBotSettings(view.id);
}

async function suggestSettingsModels(engine) {
  let models = [];
  if (engine === "claude") models = CLAUDE_MODELS;
  else if (engine.startsWith("api:")) { const r = await invoke({ cmd: "apiModels", provider: engine.slice(4) }); if (r.ok) models = r.result.models.slice(0, 200); }
  const list = $("#bs-models");
  if (list) list.innerHTML = models.map((m) => `<option value="${esc(m)}"></option>`).join("");
}
