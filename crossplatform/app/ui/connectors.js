// The Connectors page, as the Mac draws it (ConnectorsScreen in Bots/BotsView.swift, Bots/ConnectorHubViews.swift): Theo's
// own apps from the connector hub (crates/theo-connectors, docs/CONNECTORS.md). Each row shows who uses the app, one status
// pill and one button; clicking it opens its details (how it's reached, what it last said, when it last worked, who uses it
// and how far each bot may go, its sign-in, Turn off and Remove). Then the starter apps and "Add your own": an address or a
// command. Loaded before app.js; app.js's renderConnectors calls CONNECTORS.render.
const CONNECTORS = (() => {
  const LEVEL_WORDS = { off: "Off", read: "Read only", readAndDraft: "Read and draft", full: "Everything" };
  const LEVEL_HELP = { read: "Reads only: no drafts, nothing sent.", readAndDraft: "Reads and writes drafts. Sending, sharing and deleting wait for you.", full: "Everything the app can do, when you asked for it yourself." };
  const STATUS_ORDER = ["needsSignIn", "failed", "connected", "unknown", "off"];
  let openRow = null, note = "", poll = null, list = [], catalog = null, checking = false, confirmRemove = null;
  let addKind = "address";

  function idFrom(name, taken) {
    const base = (name || "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 36) || "app";
    let id = base, n = 2;
    while (taken.has(id)) id = `${base}-${n++}`;
    return id;
  }
  function commandWords(line) { return (line.match(/"[^"]*"|\S+/g) || []).map((w) => w.replace(/^"|"$/g, "")); }
  function workedWords(iso) { if (!iso) return "Not seen connected yet"; const a = ago(iso); return a === "now" ? "just now" : `${a} ago`; }
  // Composio: one API key for hundreds of apps, each connected once on Composio with a link (crates/theo-connectors/src/composio.rs).
  const isComposio = (c) => c.kind === "remote" && !!c.composio;
  const COMPOSIO_KEYS = "https://dashboard.composio.dev";
  function appWords(slug) {
    const known = { gmail: "Gmail", googlecalendar: "Google Calendar", googledrive: "Google Drive", googledocs: "Google Docs", googlesheets: "Google Sheets", github: "GitHub", slack: "Slack", notion: "Notion", linear: "Linear", outlook: "Outlook", hubspot: "HubSpot", jira: "Jira", discord: "Discord", twitter: "X (Twitter)", linkedin: "LinkedIn", trello: "Trello", asana: "Asana", airtable: "Airtable", dropbox: "Dropbox", zoom: "Zoom" };
    return known[slug] || slug.charAt(0).toUpperCase() + slug.slice(1);
  }
  function reached(c) {
    if (isComposio(c)) return `Composio, with your Composio API key: every app you connect there, for the account "${(c.composio && c.composio.userId) || "vello"}"`;
    if (c.kind === "claude-account") return `Through your Claude account (${c.server || c.name}), with Claude Code`;
    if (c.kind === "local") return `A program on this computer: ${[c.command].concat(c.args || []).filter(Boolean).join(" ") || "a command"}`;
    const signIn = c.auth === "oauth" ? "signs in in your browser" : c.auth === "token" ? "with a token you pasted" : "no sign-in";
    return `${c.url || c.target || "An address"}, ${signIn}`;
  }
  const takesToken = (c) => c.kind === "remote" && c.auth === "token";
  const browserSignIn = (c) => c.kind === "remote" && c.auth === "oauth";
  function pillOf(c) {
    if (c.enabled === false || c.status === "off") return ["idle", "Off"];
    return { connected: ["ok", "Connected"], needsSignIn: ["needs", "Needs sign-in"], failed: ["failed", "Can't connect"], unknown: ["checking", "Not checked"] }[c.status] || ["none", "Not connected"];
  }
  function users(c) { return state.bots.filter((b) => (b.apps || []).includes(c.id)); }
  function levelOf(bot, id) { return (bot.apps || []).includes(id) ? ((bot.appLevels || {})[id] || "readAndDraft") : "off"; }

  function row(c) {
    const [tone, word] = pillOf(c);
    const using = users(c);
    const who = using.length ? `<span class="cn-users">${using.slice(0, 4).map((b) => botHTML(b.id, 16, { badge: false })).join("")}</span><span>${esc(using.map((b) => b.name).join(", "))}</span>` : `<span>No bot uses it yet</span>`;
    const extra = c.status === "failed" && c.enabled !== false ? `<small class="w-bad">${esc(c.reason || "Not answering")}${c.lastConnected ? ` · worked ${esc(workedWords(c.lastConnected))}` : ""}</small>`
      : c.status === "needsSignIn" && c.enabled !== false ? `<small class="w-ask">${c.kind === "claude-account" ? "Sign in on claude.ai so bots can use it" : isComposio(c) ? "Paste your Composio API key so bots can use it" : takesToken(c) ? "Paste its token so bots can use it" : "Sign in so bots can use it"}</small>` : "";
    let button = "";
    if (c.enabled === false) button = `<button class="btn sm" data-enable="${esc(c.id)}" data-on="1">Turn on</button>`;
    else if (c.status === "needsSignIn" && takesToken(c)) button = `<button class="btn pri sm" data-open-row="${esc(c.id)}">${isComposio(c) ? "Add key" : "Add token"}</button>`;
    else if (c.status === "needsSignIn" && browserSignIn(c)) button = `<button class="btn pri sm" data-signin="${esc(c.id)}">${c.signIn && c.signIn.state === "waiting" ? "Signing in…" : "Sign in"}</button>`;
    else if (c.status === "needsSignIn" && c.kind === "claude-account") button = `<button class="btn pri sm" data-claude-signin="${esc(c.name)}">Sign in</button>`;
    else if (c.status === "failed") button = `<button class="btn sm" data-check="${esc(c.id)}">Try again</button>`;
    const isOpen = openRow === c.id;
    const tile = `<span class="app">${esc(c.name.slice(0, 1).toUpperCase())}${TP.badge(tone === "ok" ? "ok" : tone === "needs" ? "needs" : tone === "failed" ? "failed" : "none")}</span>`;
    const signIn = c.signIn && c.signIn.state === "waiting"
      ? `<div class="tc ask cn-wait"><div class="tc-q">Finish signing in to ${esc(c.name)} in your browser</div><p>Vello opened the sign-in page. If it didn't open, copy the address into your browser.</p><div class="tc-field"><span>${esc(c.signIn.url)}</span><button class="btn sm" data-copy="${esc(c.signIn.url)}">Copy</button></div></div>`
      : c.signIn && c.signIn.state === "failed" ? `<div class="tc bad cn-wait"><div class="tc-q">Signing in to ${esc(c.name)} didn't work</div><p>${esc(c.signIn.error)}</p></div>` : "";
    return `<div class="cn-row${isOpen ? " open" : ""}"><div class="crow cn-head" data-row="${esc(c.id)}"><svg class="ic chev" viewBox="0 0 24 24"><path d="${isOpen ? "M6 9l6 6 6-6" : "M9 6l6 6-6 6"}"/></svg>${tile}`
      + `<span class="tx"><b>${esc(c.name)}</b><small>${who}</small>${extra}</span>${TP.pill(tone, word)}<span class="act cn-act">${button}</span></div>`
      + signIn + (isOpen ? details(c, using) : "") + `</div>`;
  }
  function details(c, using) {
    const line = (title, value) => `<div class="cn-line"><span>${esc(title)}</span><span>${esc(value)}</span></div>`;
    const usedBy = using.length ? using.map((b) => `${b.name} (${(LEVEL_WORDS[levelOf(b, c.id)] || "").toLowerCase()})`).join(", ") : "No bot yet. Give it to a bot below.";
    let html = `<div class="cn-details">` + line("Reached", reached(c)) + (c.status === "failed" && c.reason ? line("What it said", c.reason) : "")
      + line("Last worked", workedWords(c.lastConnected)) + line("Used by", usedBy);
    if (isComposio(c)) {
      const apps = c.composioConnectedApps || [];
      html += line("Apps connected", apps.length ? apps.map(appWords).join(", ") : c.signedIn ? "None yet. Connect one below, or ask a bot to." : "Paste your key first");
      html += `<form class="cn-token" data-token="${esc(c.id)}" data-composio="1"><input type="password" name="token" autocomplete="off" placeholder="${c.signedIn ? "Paste a new API key to replace it" : "Paste your Composio API key"}" aria-label="Composio API key"><button class="btn pri sm" type="submit">Save key</button></form>`
        + `<small class="muted">Get a key in your Composio dashboard (Settings, API keys); the free plan is enough to start. It stays encrypted on this computer, with its key in this computer's credential store. Vello never shows it again. <a href="#" data-composio-keys>Open Composio</a></small>`;
      if (c.signedIn) {
        html += `<div class="cn-h">Connect an app</div><form class="cn-token" data-composio-link="${esc(c.id)}"><input name="toolkit" autocomplete="off" spellcheck="false" placeholder="gmail, slack, github, googlecalendar, notion…" aria-label="App to connect" list="composio-apps"><button class="btn sm" type="submit">Connect</button></form>`
          + `<datalist id="composio-apps">${["gmail", "googlecalendar", "googledrive", "googlesheets", "googledocs", "slack", "github", "notion", "linear", "outlook", "hubspot", "jira", "discord", "trello", "asana", "airtable"].map((slug) => `<option value="${slug}">${appWords(slug)}</option>`).join("")}</datalist>`
          + `<small class="muted">Opens Composio's page in your browser: approve it there, then press Check. Every bot you give Composio can then use that app, on this computer and any other with the same key. A bot can also give you this link in its chat.</small>`;
      }
    } else if (takesToken(c)) {
      html += `<form class="cn-token" data-token="${esc(c.id)}"><input type="password" name="token" autocomplete="off" placeholder="${c.signedIn ? "Paste a new token to replace it" : "Paste its token"}" aria-label="Token"><button class="btn pri sm" type="submit">Save token</button></form>`
        + `<small class="muted">It stays encrypted on this computer, with its key in this computer's credential store. Vello never shows it again.</small>`;
    }
    const acts = [];
    if (browserSignIn(c)) acts.push(c.signedIn ? `<button class="btn sm" data-signout="${esc(c.id)}" data-did="Signed out of ${esc(c.name)}.">Sign out</button>` : `<button class="btn pri sm" data-signin="${esc(c.id)}">Sign in</button>`);
    else if (isComposio(c) && c.signedIn) acts.push(`<button class="btn sm" data-check="${esc(c.id)}">Check</button>`, `<button class="btn sm" data-signout="${esc(c.id)}" data-did="Forgot ${esc(c.name)}'s API key.">Forget key</button>`);
    else if (takesToken(c) && c.signedIn) acts.push(`<button class="btn sm" data-signout="${esc(c.id)}" data-did="Forgot ${esc(c.name)}'s token.">Forget token</button>`);
    else if (c.kind === "claude-account" && (c.status === "needsSignIn" || c.status === "failed")) acts.push(`<button class="btn sm" data-claude-open>Open claude.ai connectors</button>`);
    acts.push(`<button class="btn sm" data-enable="${esc(c.id)}" data-on="${c.enabled === false ? "1" : "0"}">${c.enabled === false ? "Turn on" : "Turn off"}</button>`);
    acts.push(confirmRemove === c.id
      ? `<span class="cn-confirm">Remove ${esc(c.name)} from Vello? Its sign-in is forgotten too. You can add it again any time. <button class="btn sm cn-danger" data-remove="${esc(c.id)}">Remove</button><button class="btn sm ghost" data-remove-cancel>Cancel</button></span>`
      : `<button class="btn sm ghost" data-remove-ask="${esc(c.id)}">Remove…</button>`);
    html += `<div class="btns">${acts.join("")}</div>`;
    // Who may use it, and how far: a bot only gets an app's tools when it's given the app here.
    const levels = state.bots.filter((b) => b.enabled !== false).map((b) => {
      const level = levelOf(b, c.id);
      const options = Object.entries(LEVEL_WORDS).map(([k, w]) => `<option value="${k}"${k === level ? " selected" : ""}>${w}</option>`).join("");
      return `<label class="lvl${level === "off" ? "" : " on"}" title="${esc(LEVEL_HELP[level] || "")}">${botHTML(b.id, 16, { badge: false })}${esc(b.name)} <select data-botapp="${esc(b.id)}" data-app="${esc(c.id)}">${options}</select></label>`;
    }).join("");
    html += `<div class="cn-h">What each bot may do</div><div class="apps-for">${levels}</div>`
      + `<small class="muted">Sending, sharing and deleting happen only on your own words: a routine, another bot or the local API reads and drafts at most.</small></div>`;
    return html;
  }

  function addSection(have, claudeCode) {
    const starters = ((catalog && catalog.apps) || []).filter((a) => !have.has(a.id)).filter((a) => a.kind !== "claude-account" || claudeCode);
    const starterRows = starters.map((a) => `<div class="crow"><span class="app">${esc(a.name.slice(0, 1))}</span><span class="tx"><b>${esc(a.name)}</b><small>${esc([a.description, a.via].filter(Boolean).join(" · "))}</small></span><span class="act"><button class="btn sm" data-add-catalog="${esc(a.id)}" data-name="${esc(a.name)}">Add</button></span></div>`).join("");
    const where = addKind === "address"
      ? `<label class="cn-where">Address <input name="where" required placeholder="https://mcp.example.com/mcp" autocomplete="off" spellcheck="false"></label><label>Sign-in <select name="auth"><option value="oauth">Sign in in the browser</option><option value="token">Paste a token</option><option value="none">No sign-in</option></select></label>`
      : `<label class="cn-where">Command <input name="where" required placeholder="npx -y @modelcontextprotocol/server-filesystem C:\\Notes" autocomplete="off" spellcheck="false"></label>`;
    return (starterRows ? `<h2>Add an app</h2><div class="list">${starterRows}</div>` : "")
      + `<h2>Add your own</h2><p class="muted">Any MCP server: its address (most apps list one in their docs), or a command that starts it on this computer.</p>`
      + `<form class="hub-form cn-add" id="hub-add"><label>Name <input name="name" required maxlength="60" placeholder="Name"></label>`
      + `<span class="seg" role="tablist"><button type="button" class="${addKind === "address" ? "on" : ""}" data-kind="address">Address</button><button type="button" class="${addKind === "command" ? "on" : ""}" data-kind="command">Command</button></span>`
      + where + `<button class="btn pri sm" type="submit">Add</button></form>`;
  }

  async function render(force = false) {
    const pane = $("#pane");
    if (!sigs.connectors) pane.innerHTML = `<div class="column"><h1>Connectors</h1><div class="pills">${TP.pill("checking", "Checking")}</div></div>`;
    checking = true;
    const [r, cat] = await Promise.all([invoke({ cmd: "connectors", refresh: force }), catalog ? Promise.resolve({ ok: true, result: catalog }) : invoke({ cmd: "connectorCatalog" })]);
    checking = false;
    if (view.kind !== "connectors") return;
    if (cat.ok) catalog = cat.result;
    if (!r.ok) { pane.innerHTML = `<div class="column"><h1>Connectors</h1><div class="tc bad"><div class="tc-q">Couldn't list connectors</div><p>${esc(r.error)}</p><div class="btns"><button class="btn" data-refresh>Try again</button></div></div></div>`; pane.querySelector("[data-refresh]").onclick = () => render(true); return; }
    list = r.result.connectors.slice().sort((a, b) => STATUS_ORDER.indexOf(a.enabled === false ? "off" : a.status) - STATUS_ORDER.indexOf(b.enabled === false ? "off" : b.status));
    draw(r.result);
  }
  function draw(result) {
    const pane = $("#pane");
    const keepScroll = pane.scrollTop;
    const count = (s) => list.filter((c) => c.enabled !== false && c.status === s).length;
    const connected = count("connected"), signIn = count("needsSignIn"), failed = count("failed");
    const pills = (connected ? TP.pill("ok", `${connected} connected`) : "") + (signIn ? TP.pill("needs", `${signIn} need${signIn === 1 ? "s" : ""} sign-in`) : "") + (failed ? TP.pill("failed", `${failed} can't connect`) : "");
    const checked = result.checked ? ` Checked ${ago(result.checked) === "now" ? "just now" : `${ago(result.checked)} ago`}.` : "";
    const have = new Set(list.map((c) => c.catalogId || c.id));
    pane.innerHTML = `<div class="column cn"><div><h1>Connectors</h1><p class="muted">Vello's own apps, the same for every bot whatever its brain. Sign in here, then give an app to a bot and say how far it may go. Apps through your Claude account are reached with Claude Code.${checked}</p></div>`
      + (result.helper === false ? `<p class="w-bad">The connector helper is missing from this install, so apps can't be checked or used. Reinstall Vello to put it back.</p>` : "")
      + (result.note ? `<p class="muted">${esc(result.note)}</p>` : "")
      + `<div class="cn-bar"><div class="pills">${pills}</div><button class="btn sm" data-refresh${checking ? " disabled" : ""}><svg class="ic" viewBox="0 0 24 24"><path d="M19.5 12A7.5 7.5 0 1 1 17.3 6.7M13.9 6.8h3.6V3.2"/></svg>${checking ? "Checking…" : "Refresh"}</button></div>`
      + (note ? `<p class="muted cn-note">${esc(note)}</p>` : "")
      + `<div id="signin-help"></div>`
      + (list.length ? `<div class="list">${list.map(row).join("")}</div>` : `<p class="muted">No apps yet. Add one below: an app's MCP address, or a program on this computer.</p>`)
      + addSection(have, result.claudeCode) + `</div>`;
    pane.scrollTop = keepScroll;
    sigs.connectors = true;
    wireAll(pane, result);
    // While a sign-in is waiting for the browser, look again every two seconds.
    clearTimeout(poll);
    if (list.some((c) => c.signIn && c.signIn.state === "waiting")) poll = setTimeout(() => { if (view.kind === "connectors") render(); }, 2000);
  }

  function wireAll(pane, result) {
    wire(pane);
    const help = (title, words) => { $("#signin-help").innerHTML = `<div class="tc bad"><div class="tc-q">${esc(title)}</div><p>${esc(words)}</p></div>`; };
    // One change through the hub, then the list again, with what it did on the note line.
    const act = async (button, promise, did) => {
      if (button) button.disabled = true;
      const a = await promise;
      note = a.ok ? did || "" : a.error;
      render();
      return a;
    };
    pane.querySelectorAll("[data-refresh]").forEach((b) => b.onclick = () => { b.disabled = true; b.textContent = "Checking…"; note = ""; render(true); });
    pane.querySelectorAll("[data-row]").forEach((el) => el.onclick = (e) => {
      if (e.target.closest("button, select, input")) return;
      openRow = openRow === el.dataset.row ? null : el.dataset.row; confirmRemove = null; draw(result);
    });
    pane.querySelectorAll("[data-open-row]").forEach((b) => b.onclick = () => { openRow = b.dataset.openRow; draw(result); const input = pane.querySelector(`[data-token="${CSS.escape(openRow)}"] input`); if (input) input.focus(); });
    pane.querySelectorAll("[data-check]").forEach((b) => b.onclick = () => act(b, invoke({ cmd: "connectorCheck", id: b.dataset.check })));
    pane.querySelectorAll("[data-enable]").forEach((b) => b.onclick = () => {
      const on = b.dataset.on === "1";
      const name = (list.find((c) => c.id === b.dataset.enable) || {}).name || "It";
      act(b, invoke({ cmd: "connectorEnable", id: b.dataset.enable, enabled: on }), on ? `${name} is on.` : `${name} is off: no bot can use it until you turn it on.`);
    });
    pane.querySelectorAll("[data-remove-ask]").forEach((b) => b.onclick = () => { confirmRemove = b.dataset.removeAsk; draw(result); });
    pane.querySelectorAll("[data-remove-cancel]").forEach((b) => b.onclick = () => { confirmRemove = null; draw(result); });
    pane.querySelectorAll("[data-remove]").forEach((b) => b.onclick = () => {
      const name = (list.find((c) => c.id === b.dataset.remove) || {}).name || "It";
      confirmRemove = null; openRow = null;
      act(b, invoke({ cmd: "connectorRemove", id: b.dataset.remove }), `Removed ${name}. Bots that had it lose it; add it again any time.`).then(async () => { state = (await invoke({ cmd: "botsState" })).result || state; });
    });
    pane.querySelectorAll("[data-signout]").forEach((b) => b.onclick = () => act(b, invoke({ cmd: "connectorSignOut", id: b.dataset.signout }), b.dataset.did));
    pane.querySelectorAll("[data-add-catalog]").forEach((b) => b.onclick = () => {
      const entry = ((catalog && catalog.apps) || []).find((a) => a.id === b.dataset.addCatalog) || {};
      // A token app (Composio) opens straight to its key field.
      if (entry.auth === "token") openRow = entry.id;
      act(b, invoke({ cmd: "connectorAdd", catalog: b.dataset.addCatalog }), entry.composio ? `Added ${b.dataset.name}. Paste your Composio API key in its row, then connect your apps.` : `Added ${b.dataset.name}. Give it to a bot in its row.`);
    });
    pane.querySelectorAll("[data-composio-keys]").forEach((a) => a.onclick = async (e) => { e.preventDefault(); const r = await invoke({ cmd: "openLink", url: COMPOSIO_KEYS }); if (!r.ok) { note = r.error; draw(result); } });
    pane.querySelectorAll("form[data-composio-link]").forEach((f) => f.onsubmit = async (e) => {
      e.preventDefault();
      const toolkit = String(new FormData(f).get("toolkit") || "").trim();
      if (!toolkit) return;
      f.querySelector("button").disabled = true;
      const a = await invoke({ cmd: "connectorComposioLink", id: f.dataset.composioLink, toolkit });
      note = a.ok ? `Opened Composio's page to connect ${appWords(a.result.toolkit)}. Approve it there, then press Check. If it didn't open: ${a.result.url}` : a.error;
      render();
    });
    pane.querySelectorAll("[data-signin]").forEach((b) => b.onclick = async () => {
      b.disabled = true; b.textContent = "Signing in…";
      const a = await invoke({ cmd: "connectorSignIn", id: b.dataset.signin });
      if (!a.ok) { b.disabled = false; b.textContent = "Sign in"; help("Couldn't start the sign-in", a.error); return; }
      render();
    });
    pane.querySelectorAll("[data-claude-open]").forEach((b) => b.onclick = async () => { const a = await invoke({ cmd: "openLink", url: "https://claude.ai/settings/connectors" }); b.textContent = a.ok ? "Opened" : a.error; });
    pane.querySelectorAll("[data-claude-signin]").forEach((b) => b.onclick = () => {
      $("#signin-help").innerHTML = `<div class="tc ask"><div class="tc-h"><span class="app">${esc(b.dataset.claudeSignin.slice(0, 1))}${TP.badge("needs")}</span><span class="who"><b>${esc(b.dataset.claudeSignin)}</b> · Claude account</span>${TP.pill("needs", "Needs sign-in")}</div>`
        + `<div class="tc-q">Sign in to ${esc(b.dataset.claudeSignin)}</div><p>This app is on your Claude account: sign in on claude.ai, then press Refresh here.</p>`
        + `<div class="tc-field"><span>https://claude.ai/settings/connectors</span><button class="btn sm" data-copy="https://claude.ai/settings/connectors">Copy</button></div><div class="btns"><button class="btn pri" data-claude-open>Open claude.ai connectors</button></div></div>`;
      wire($("#signin-help"));
      $("#signin-help").querySelector("[data-claude-open]").onclick = async (e) => { const a = await invoke({ cmd: "openLink", url: "https://claude.ai/settings/connectors" }); e.target.textContent = a.ok ? "Opened" : a.error; };
    });
    pane.querySelectorAll("form[data-token]").forEach((f) => f.onsubmit = (e) => {
      e.preventDefault();
      const value = String(new FormData(f).get("token") || "");
      if (!value) return;
      const name = (list.find((c) => c.id === f.dataset.token) || {}).name || "the app";
      act(f.querySelector("button"), invoke({ cmd: "connectorSecret", id: f.dataset.token, value }), f.dataset.composio ? `Saved your Composio key. Connect an app below, then give Composio to a bot.` : `Saved ${name}'s token.`);
    });
    pane.querySelectorAll("select[data-botapp]").forEach((s) => s.onchange = async () => {
      await invoke({ cmd: "botApp", bot: s.dataset.botapp, app: s.dataset.app, level: s.value });
      state = (await invoke({ cmd: "botsState" })).result || state;
      draw(result);
    });
    pane.querySelectorAll("#hub-add [data-kind]").forEach((b) => b.onclick = () => { addKind = b.dataset.kind; draw(result); });
    const form = $("#hub-add");
    if (form) form.onsubmit = async (e) => {
      e.preventDefault();
      const f = new FormData(form);
      const name = String(f.get("name") || "").trim(), where = String(f.get("where") || "").trim();
      if (!name || !where) return;
      const id = idFrom(name, new Set(list.map((c) => c.id)));
      let app;
      if (addKind === "address") {
        // https, or http only to this computer itself.
        if (!/^https:\/\/\S+$/i.test(where) && !/^http:\/\/(localhost|127\.0\.0\.1|\[::1\])(:\d+)?(\/\S*)?$/i.test(where)) { note = "That address doesn't work: it has to start with https:// (or http:// on this computer)."; draw(result); return; }
        app = { id, name, kind: "remote", url: where, auth: f.get("auth") };
      } else {
        const words = commandWords(where);
        app = { id, name, kind: "local", command: words[0], args: words.slice(1) };
      }
      note = "Adding and checking…"; draw(result);
      const a = await invoke({ cmd: "connectorAdd", app });
      if (!a.ok) { note = a.error; render(); return; }
      note = addKind === "address" && app.auth === "oauth" ? `Added ${name}. Press Sign in on its row to connect it.` : addKind === "address" && app.auth === "token" ? `Added ${name}. Open its row and paste its token.` : `Added ${name}.`;
      if (addKind === "address" && app.auth === "token") openRow = id;
      render();
    };
  }
  return { render };
})();
