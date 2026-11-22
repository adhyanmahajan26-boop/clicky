/* Settings › Bots & categories, as on the Mac (Setup/BotsSettings.swift): every bot and every category on one page. Make a
   bot or a category, rename either, move a bot by dragging it onto a category (or with its Move list), pick a category's
   manager, and delete a bot or a category. It uses the same control commands as the sidebar and the team page
   (botCreate through the new-bot dialog, botUpdate, botDelete, teamAdd, teamUpdate, teamMove, teamDelete). Loaded after
   teams.js and app.js, before settings.js, which calls drawBotsSettings each time the page is drawn. */

// Set while the new-bot dialog was opened from this page, so the new bot's chat doesn't open over Settings.
let newBotFromSettings = false;

function botsSettingsCountLine() {
  const bots = state.bots.length, teams = teamsList().length;
  return `${bots} bot${bots === 1 ? "" : "s"} in ${teams} categor${teams === 1 ? "y" : "ies"}`;
}

function botsSettingsRowHTML(bot, team) {
  const ceo = bot.primary;
  const fixed = ceo || bot.id === "clicky";
  const isManager = team && team.leader === bot.id;
  const detail = [bot.description && bot.description.trim() ? bot.description.trim() : "No job written yet", bot.model || ""].filter(Boolean).join(" · ");
  const moveOptions = teamsList().map((t) => `<option value="${esc(t.id)}"${team && team.id === t.id ? " disabled" : ""}>${esc(t.name)}</option>`).join("")
    + (team ? `<option value="__none">Take out of its category</option>` : "") + `<option value="__new">New category with ${esc(bot.name)}</option>`;
  return `<div class="bs-row" data-bs-bot="${esc(bot.id)}"${fixed ? "" : ` draggable="true"`}>${botHTML(bot.id, 32, { badge: false })}`
    + `<span class="tx"><span class="bs-name"><b data-bs-name="${esc(bot.id)}">${esc(bot.name)}</b>${isManager ? `<span class="mgr" title="Manages this category">${CROWN_SVG}Manager</span>` : ""}`
    + `${bot.enabled === false ? `<span class="bs-chip">Off</span>` : ""}</span><small>${esc(detail)}</small></span>`
    + `<span class="act many">`
    + (fixed ? "" : `<select data-bs-move="${esc(bot.id)}" aria-label="Move ${esc(bot.name)} to a category"><option value="">Move…</option>${moveOptions}</select>`)
    + (bot.id === "clicky" ? "" : `<button class="btn sm ghost" data-bs-rename="${esc(bot.id)}">Rename</button>`)
    + `<button class="btn sm ghost" data-bs-settings="${esc(bot.id)}">Settings</button>`
    + (fixed ? "" : `<button class="btn sm ghost danger" data-bs-delete="${esc(bot.id)}">Delete</button>`)
    + `</span></div>`;
}

function botsSettingsHTML() {
  const ceo = state.bots.find((b) => b.primary);
  const boss = ceoName();
  const botOf = (id) => state.bots.find((b) => b.id === id);
  const filed = new Set();
  let html = `<div class="list"><div class="crow bs-top"><span class="act many"><button class="btn sm pri" data-bs-new-bot>New bot</button><button class="btn sm" data-bs-new-category>New category</button>`
    + `<button class="btn sm ghost" data-bs-ready title="Add a whole category at once: a manager and the bots who report to it">Ready-made teams</button></span><span class="muted bs-count">${esc(botsSettingsCountLine())}</span></div></div>`
    + `<p class="muted">Drag a bot onto a category to move it there, or use Move on its row. You can also ask ${esc(boss)} in chat: “make a bot that checks my email” or “move Ledger to Finance”.</p>`;
  if (ceo) {
    html += `<h2>Your CEO</h2><div class="list bs-list">${botsSettingsRowHTML(ceo, null)}</div>`
      + `<p class="muted">${esc(ceo.name)} runs the company: every category's manager reports here. It can't be deleted, and it can make bots and categories for you when you ask in chat.</p>`;
  }
  for (const team of teamsList()) {
    const members = (team.members || []).map(botOf).filter((b) => b && !b.primary);
    members.forEach((b) => filed.add(b.id));
    const manager = members.find((b) => b.id === team.leader);
    const ordered = manager ? [manager].concat(members.filter((b) => b !== manager)) : members;
    const managerSelect = team.leader === "clicky" ? "" : `<select data-bs-leader="${esc(team.id)}" aria-label="Manager of ${esc(team.name)}"><option value="">No manager: everyone reports to ${esc(boss)}</option>`
      + members.map((b) => `<option value="${esc(b.id)}"${b.id === team.leader ? " selected" : ""}>Manager: ${esc(b.name)}</option>`).join("") + `</select>`;
    html += `<div class="bs-head" data-bs-team="${esc(team.id)}"><b data-bs-team-name="${esc(team.id)}">${esc(team.name)}</b><span class="bs-chip">${members.length}</span><span class="grow"></span>${managerSelect}`
      + `<button class="btn sm ghost" data-bs-team-new-bot="${esc(team.id)}" title="New bot in ${esc(team.name)}">New bot here</button>`
      + `<button class="btn sm ghost" data-bs-team-rename="${esc(team.id)}">Rename</button>`
      + `<button class="btn sm ghost" data-bs-team-open="${esc(team.id)}" title="Reports, schedule and what it's for">Open page</button>`
      + `<button class="btn sm ghost danger" data-bs-team-delete="${esc(team.id)}" title="Its bots stay">Delete</button></div>`
      + `<div class="list bs-list" data-bs-drop="${esc(team.id)}">${ordered.map((b) => botsSettingsRowHTML(b, team)).join("") || `<div class="bs-empty">No bots yet. Drag one here, or make a new one.</div>`}</div>`;
  }
  const unfiled = state.bots.filter((b) => !b.primary && !filed.has(b.id));
  html += `<div class="bs-head"><b>Not in a category</b><span class="bs-chip">${unfiled.length}</span></div>`
    + `<div class="list bs-list" data-bs-drop="">${unfiled.map((b) => botsSettingsRowHTML(b, null)).join("") || `<div class="bs-empty">Every bot is in a category. Drag one here to take it out.</div>`}</div>`;
  return html;
}

// Turns a name into a field in place: Enter or clicking away saves, Escape keeps the old name.
function botsSettingsRenameInPlace(el, save) {
  const old = el.textContent;
  const input = document.createElement("input");
  input.className = "bs-rename";
  input.value = old;
  input.maxLength = 80;
  el.replaceWith(input);
  input.focus(); input.select();
  let done = false;
  const finish = async (keep) => {
    if (done) return;
    done = true;
    const name = input.value.trim();
    if (keep && name && name !== old) await save(name);
    drawBotsSettings();
  };
  input.onkeydown = (e) => { if (e.key === "Enter") { e.preventDefault(); finish(true); } else if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); finish(false); } };
  input.onblur = () => finish(true);
}

async function botsSettingsChanged() { await refresh(); drawBotsSettings(); }

async function drawBotsSettings() {
  const box = $("#settings-bots-body");
  if (!box) return;
  box.innerHTML = botsSettingsHTML();
  box.querySelector("[data-bs-new-bot]").onclick = () => { newBotFromSettings = true; openBotDialog({ kind: "new" }); };
  box.querySelector("[data-bs-new-category]").onclick = async () => {
    const r = await invoke({ cmd: "teamAdd", members: [] });
    await botsSettingsChanged();
    const name = r.ok && box.querySelector(`[data-bs-team-name="${CSS.escape(r.result.id)}"]`);
    if (name) botsSettingsRenameInPlace(name, (n) => invoke({ cmd: "teamUpdate", id: r.result.id, name: n }));
  };
  box.querySelector("[data-bs-ready]").onclick = () => settingsJump("teams");
  box.querySelectorAll("[data-bs-move]").forEach((s) => s.onchange = async () => {
    const bot = s.dataset.bsMove, choice = s.value;
    if (!choice) return;
    if (choice === "__new") {
      const r = await invoke({ cmd: "teamAdd", members: [bot] });
      await botsSettingsChanged();
      const name = r.ok && box.querySelector(`[data-bs-team-name="${CSS.escape(r.result.id)}"]`);
      if (name) botsSettingsRenameInPlace(name, (n) => invoke({ cmd: "teamUpdate", id: r.result.id, name: n }));
      return;
    }
    await invoke({ cmd: "teamMove", bot, team: choice === "__none" ? null : choice });
    botsSettingsChanged();
  });
  box.querySelectorAll("[data-bs-rename]").forEach((b) => b.onclick = () => {
    const id = b.dataset.bsRename;
    const name = box.querySelector(`[data-bs-name="${CSS.escape(id)}"]`);
    if (name) botsSettingsRenameInPlace(name, async (n) => { await invoke({ cmd: "botUpdate", id, name: n }); await refresh(); });
  });
  box.querySelectorAll("[data-bs-settings]").forEach((b) => b.onclick = () => { open({ kind: "bot", id: b.dataset.bsSettings }); openBotSettings(b.dataset.bsSettings); });
  box.querySelectorAll("[data-bs-delete]").forEach((b) => b.onclick = async () => { if (await deleteBot(b.dataset.bsDelete)) botsSettingsChanged(); });
  box.querySelectorAll("[data-bs-leader]").forEach((s) => s.onchange = async () => {
    await invoke({ cmd: "teamUpdate", id: s.dataset.bsLeader, leader: s.value || null });
    botsSettingsChanged();
  });
  box.querySelectorAll("[data-bs-team-new-bot]").forEach((b) => b.onclick = () => { newBotFromSettings = true; newBotJoinsTeam = b.dataset.bsTeamNewBot; openBotDialog({ kind: "new" }); });
  box.querySelectorAll("[data-bs-team-rename]").forEach((b) => b.onclick = () => {
    const id = b.dataset.bsTeamRename;
    const name = box.querySelector(`[data-bs-team-name="${CSS.escape(id)}"]`);
    if (name) botsSettingsRenameInPlace(name, async (n) => { await invoke({ cmd: "teamUpdate", id, name: n }); await refresh(); });
  });
  box.querySelectorAll("[data-bs-team-open]").forEach((b) => b.onclick = () => open({ kind: "team", id: b.dataset.bsTeamOpen }));
  box.querySelectorAll("[data-bs-team-delete]").forEach((b) => b.onclick = async () => {
    const id = b.dataset.bsTeamDelete;
    const team = teamById(id);
    if (!team || !(await confirmBox(`Delete ${team.name}?`, "Its bots stay, under Not in a category.", "Delete category"))) return;
    await invoke({ cmd: "teamDelete", id });
    botsSettingsChanged();
  });
  // Dragging: a row picks up as "bot:<id>", the same as the sidebar's, so it drops here or there.
  box.querySelectorAll(".bs-row[draggable]").forEach((row) => row.ondragstart = (e) => {
    e.dataTransfer.setData("text/plain", "bot:" + row.dataset.bsBot);
    e.dataTransfer.effectAllowed = "move";
  });
  box.querySelectorAll("[data-bs-drop]").forEach((el) => {
    el.ondragover = (e) => { e.preventDefault(); el.classList.add("drop-on"); };
    el.ondragleave = (e) => { if (!el.contains(e.relatedTarget)) el.classList.remove("drop-on"); };
    el.ondrop = async (e) => {
      e.preventDefault(); el.classList.remove("drop-on");
      const item = e.dataTransfer.getData("text/plain");
      if (!item.startsWith("bot:")) return;
      await invoke({ cmd: "teamMove", bot: item.slice(4), team: el.dataset.bsDrop || null });
      botsSettingsChanged();
    };
  });
}
