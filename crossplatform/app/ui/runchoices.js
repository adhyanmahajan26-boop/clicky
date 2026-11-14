// The card under a bot's final prompt (the Mac's Bots/RunChoices.swift): which coding agent, which folder, which chat, and
// Start. The folders are the projects folder's (the ones earlier runs used first, then all of them), plus a new folder made
// there with git and an empty first commit. The chats are the agent's own chats in that folder (harness_chats.rs), so a run
// can carry one on. Also drawn inside a "Start this coding run?" card, where Start answers it. Two Macs and T3 Code have no
// part here. Loaded before app.js; it uses app.js's helpers only when a chat is drawn.
const RUNCHOICES = (() => {
  let choices = null, choicesAt = 0, asking = false;
  const cards = {};      // message id → what this card has picked
  const chatLists = {};  // "agent|folder" → { chats, continues, loading }

  function loadChoices(force) {
    if (asking || (!force && choices && Date.now() - choicesAt < 30000)) return;
    asking = true;
    invoke({ cmd: "runChoices" }).then((r) => {
      asking = false;
      if (!r.ok) return;
      choices = r.result; choicesAt = Date.now();
      redrawAll();
    });
  }
  function labelOf(agent) {
    const found = choices && choices.agents.find((a) => a.id === agent);
    return found ? found.label : agent === "auto" ? "the first ready agent" : CARDS.brainLabel(agent);
  }
  function lastPart(path) { return String(path || "").split(/[\\/]/).filter(Boolean).pop() || path; }
  // "Continue: <chat>" in the bot's answer names a chat to carry on, by id or title (ProjectWords.chatToContinue).
  function chatNamed(text) {
    const match = String(text).match(/^\s*\*{0,2}Continue:\*{0,2}\s*(.+?)\s*$/im);
    return match ? match[1].replace(/^[`"'* ]+|[`"'* ]+$/g, "") : null;
  }
  function age(iso) {
    const seconds = Math.max(0, (Date.now() - Date.parse(iso)) / 1000);
    return seconds < 60 ? "just now" : seconds < 3600 ? `${Math.floor(seconds / 60)}m` : seconds < 86400 ? `${Math.floor(seconds / 3600)}h` : `${Math.floor(seconds / 86400)}d`;
  }
  // The run this message already started: from this card, or by itself from the owner's words before it.
  function sentRun(messageId, pitchId) {
    return (state.runs || []).find((r) => r.digest === `choice-${messageId}` || r.digest === `card-${messageId}` || (pitchId && r.digest === pitchId));
  }
  function cardState(messageId, text) {
    if (!cards[messageId]) {
      const target = choices && choices.coding ? choices.coding.target : null;
      cards[messageId] = { agent: target || "auto", folder: "", chat: null, chatTitle: "", named: chatNamed(text), problem: "", naming: false, busy: false, text };
    }
    const card = cards[messageId];
    if (card.agent === "auto" && choices && choices.coding && choices.coding.target && !card.touched) card.agent = choices.coding.target;
    return card;
  }
  function chatsFor(card) {
    if (!card.folder || card.folder === "new" || card.agent === "auto") return null;
    const key = `${card.agent}|${card.folder}`;
    if (!chatLists[key]) {
      chatLists[key] = { chats: [], continues: true, loading: true };
      invoke({ cmd: "runChats", harness: card.agent, folder: card.folder }).then((r) => {
        chatLists[key] = r.ok ? { chats: r.result.chats || [], continues: r.result.continues, loading: false } : { chats: [], continues: false, loading: false };
        // The bot's answer can already say which chat it carries on.
        for (const [, c] of Object.entries(cards)) {
          if (c.agent === card.agent && c.folder === card.folder && !c.chat && c.named) {
            const wanted = c.named.toLowerCase();
            const found = chatLists[key].chats.find((x) => x.id.toLowerCase() === wanted || x.title.toLowerCase() === wanted);
            if (found) { c.chat = found.id; c.chatTitle = found.title; }
          }
        }
        redrawAll();
      });
    }
    return chatLists[key];
  }

  function folderOptions(card) {
    if (!choices) return `<option value="">Loading…</option>`;
    const option = (value, label, chosen) => `<option value="${esc(value)}"${chosen ? " selected" : ""}>${esc(label)}</option>`;
    let html = option("", "New project", !card.folder);
    const known = new Set([...choices.recent, ...choices.others].map((p) => p.path));
    if (card.folder && card.folder !== "new" && !known.has(card.folder)) html += option(card.folder, lastPart(card.folder), true);
    if (choices.recent.length) html += `<optgroup label="Used before">${choices.recent.map((p) => option(p.path, p.name, card.folder === p.path)).join("")}</optgroup>`;
    if (choices.others.length) html += `<optgroup label="All folders">${choices.others.map((p) => option(p.path, p.name, card.folder === p.path)).join("")}</optgroup>`;
    html += option("new", "New folder…", card.folder === "new") + option("other", "Another folder…", false);
    return html;
  }
  function chatOptions(card) {
    const list = chatsFor(card);
    const option = (value, label, chosen, disabled) => `<option value="${esc(value)}"${chosen ? " selected" : ""}${disabled ? " disabled" : ""}>${esc(label)}</option>`;
    let html = option("", "New chat", !card.chat);
    if (!list) return html + option("x", card.agent === "auto" ? "Pick an agent to see its chats" : "Pick a folder to see its chats", false, true);
    if (!list.continues) return html + option("x", `${labelOf(card.agent)} can't carry on a chat here`, false, true);
    if (list.loading) return html + option("x", "Looking…", false, true);
    if (!list.chats.length) return html + option("x", `No earlier ${labelOf(card.agent)} chats in this folder`, false, true);
    if (card.chat && !list.chats.some((c) => c.id === card.chat)) html += option(card.chat, card.chatTitle || card.chat, true);
    return html + `<optgroup label="In ${esc(lastPart(card.folder))}">${list.chats.map((c) => option(c.id, `${c.title} · ${age(c.updatedAt)}`, card.chat === c.id)).join("")}</optgroup>`;
  }
  function startWords(card) { return card.chat ? "Continue chat" : !card.folder ? "Start as a new project" : "Start run"; }

  // The card for one message. `messageId` is the bot's answer (with its ```prompt block) or the run card; `pitchId` the
  // owner's message before it.
  function draw(messageId, text, pitchId, room) {
    loadChoices(false);
    const sent = sentRun(messageId, pitchId);
    if (sent) return `<div class="rc-sent">${TP.badge("done", "pg")}<span>Sent to ${esc(labelOf(sent.harness || "auto"))}${sent.continued ? ` · carrying on "${esc(sent.continued)}"` : ""}</span></div>`;
    const card = cardState(messageId, text);
    card.pitch = pitchId;
    const agents = choices ? choices.agents : [];
    const agentOptions = (choices && !choices.coding.target ? `<option value="auto"${card.agent === "auto" ? " selected" : ""}>Best available</option>` : "")
      + agents.map((a) => `<option value="${esc(a.id)}"${a.id === card.agent ? " selected" : ""}>${esc(a.label + (a.installed ? "" : " (not installed)"))}</option>`).join("");
    const naming = card.naming
      ? `<form class="rc-new" data-rc-name="${esc(messageId)}"><input name="name" maxlength="80" placeholder="moon-site" aria-label="New folder name" autocomplete="off" spellcheck="false"><button class="btn pri sm" type="submit">Create</button><button class="btn sm ghost" type="button" data-rc-cancel="${esc(messageId)}">Cancel</button>`
        + `<small>It goes in ${esc(choices ? choices.projectsFolder : "the projects folder")}, with git and an empty first commit.</small></form>` : "";
    const other = card.other
      ? `<form class="rc-new" data-rc-path="${esc(messageId)}"><input name="path" placeholder="C:\\Users\\you\\code\\app" aria-label="Folder path" autocomplete="off" spellcheck="false"><button class="btn pri sm" type="submit">Use this folder</button><button class="btn sm ghost" type="button" data-rc-cancel="${esc(messageId)}">Cancel</button></form>` : "";
    const projects = card.projects
      ? `<form class="rc-new" data-rc-projects-set="${esc(messageId)}"><input name="path" value="${esc(choices && !choices.projectsFolderIsDefault ? choices.projectsFolder : "")}" placeholder="${esc(choices ? choices.projectsFolder : "")}" aria-label="Projects folder" autocomplete="off" spellcheck="false"><button class="btn pri sm" type="submit">Save</button><button class="btn sm ghost" type="button" data-rc-cancel="${esc(messageId)}">Cancel</button><small>New projects go here. Empty goes back to Vello's own Projects folder.</small></form>` : "";
    return `<div class="rc" data-rc="${esc(messageId)}" data-room="${esc(room)}">`
      + `<div class="rc-row"><label class="rc-pick" title="The coding agent that does the work"><svg class="ic" viewBox="0 0 24 24"><path d="M8 9l-3 3 3 3M16 9l3 3-3 3M13.5 6l-3 12"/></svg><select data-rc-agent aria-label="Run on">${agentOptions}</select></label>`
      + `<label class="rc-pick" title="${esc(card.folder && card.folder !== "new" ? card.folder : "Where this runs. A git repo gets its own branch and a draft PR. A plain folder is edited in place.")}"><svg class="ic" viewBox="0 0 24 24"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg><select data-rc-folder aria-label="Folder">${folderOptions(card)}</select></label>`
      + `<label class="rc-pick" title="Carry on a chat this agent already has in this folder, or start a new one."><svg class="ic" viewBox="0 0 24 24"><path d="M4 5h16v10H8l-4 4z"/></svg><select data-rc-chat aria-label="Chat">${chatOptions(card)}</select></label>`
      + `<button class="btn pri sm" data-rc-start${card.busy ? " disabled" : ""}>${esc(startWords(card))}</button></div>`
      + naming + other + projects
      + `<div class="rc-foot">Projects folder: <span title="${esc(choices ? choices.projectsFolder : "")}">${esc(choices ? choices.projectsFolder : "…")}</span> <button class="lnk" data-rc-projects>Change</button></div>`
      + (card.problem ? `<div class="rc-problem">${esc(card.problem)}</div>` : "")
      + `</div>`;
  }

  function redraw(el) {
    const id = el.dataset.rc;
    const card = cards[id];
    if (!card) return;
    const holder = document.createElement("div");
    holder.innerHTML = draw(id, card.text, card.pitch, el.dataset.room);
    const fresh = holder.firstElementChild;
    if (!fresh) return;
    el.replaceWith(fresh);
    wireOne(fresh);
  }
  function redrawAll() { document.querySelectorAll("[data-rc]").forEach(redraw); }

  function wireOne(el) {
    const id = el.dataset.rc;
    const card = cards[id];
    if (!card) return;
    const room = el.dataset.room;
    const agent = el.querySelector("[data-rc-agent]");
    if (agent) agent.onchange = () => { card.agent = agent.value; card.touched = true; card.chat = null; card.problem = ""; redraw(el); };
    const folder = el.querySelector("[data-rc-folder]");
    if (folder) folder.onchange = () => {
      card.problem = ""; card.chat = null; card.naming = false; card.other = false;
      if (folder.value === "new") { card.naming = true; }
      else if (folder.value === "other") { card.other = true; }
      else card.folder = folder.value;
      redraw(el);
      const input = document.querySelector(`[data-rc="${CSS.escape(id)}"] .rc-new input`);
      if (input) input.focus();
    };
    const chat = el.querySelector("[data-rc-chat]");
    if (chat) chat.onchange = () => {
      card.chat = chat.value || null;
      const list = chatsFor(card);
      const found = list && list.chats.find((c) => c.id === card.chat);
      card.chatTitle = found ? found.title : "";
      redraw(el);
    };
    el.querySelectorAll("[data-rc-cancel]").forEach((b) => b.onclick = () => { card.naming = false; card.other = false; card.projects = false; redraw(el); });
    const projectsLink = el.querySelector("[data-rc-projects]");
    if (projectsLink) projectsLink.onclick = () => { card.projects = !card.projects; redraw(el); };
    const nameForm = el.querySelector("[data-rc-name]");
    if (nameForm) nameForm.onsubmit = async (e) => {
      e.preventDefault();
      const name = String(new FormData(nameForm).get("name") || "").trim();
      if (!name) return;
      const r = await invoke({ cmd: "projectMake", name });
      if (!r.ok) { card.problem = r.error; redraw(el); return; }
      card.naming = false; card.folder = r.result.path; card.problem = "";
      loadChoices(true);
      redraw(el);
    };
    const pathForm = el.querySelector("[data-rc-path]");
    if (pathForm) pathForm.onsubmit = (e) => {
      e.preventDefault();
      const path = String(new FormData(pathForm).get("path") || "").trim();
      if (!path) return;
      card.other = false; card.folder = path; card.problem = "";
      redraw(el);
    };
    const projectsForm = el.querySelector("[data-rc-projects-set]");
    if (projectsForm) projectsForm.onsubmit = async (e) => {
      e.preventDefault();
      const r = await invoke({ cmd: "projectsFolderSet", path: String(new FormData(projectsForm).get("path") || "").trim() });
      if (!r.ok) { card.problem = r.error; redraw(el); return; }
      card.projects = false; card.problem = "";
      choices = null; loadChoices(true);
      redraw(el);
    };
    const start = el.querySelector("[data-rc-start]");
    if (start) start.onclick = async () => {
      card.busy = true; card.problem = ""; start.disabled = true;
      const r = await invoke({ cmd: "runChoiceStart", room, message: id, harness: card.agent, folder: card.folder && card.folder !== "new" ? card.folder : "", chat: card.chat || "", chatTitle: card.chatTitle || "" });
      card.busy = false;
      if (!r.ok) { card.problem = r.error; redraw(el); return; }
      sigs.chat = null;
      refresh();
    };
  }
  function wire(root) { root.querySelectorAll("[data-rc]").forEach(wireOne); }
  // What, besides the messages, changes how the cards look.
  function sig() { return JSON.stringify([(state.runs || []).map((r) => r.digest || "").join()]); }

  return { draw, wire, sig, chatNamed };
})();
