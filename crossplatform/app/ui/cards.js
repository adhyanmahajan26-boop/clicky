// The chat's cards, as the Mac app draws them (Bots/HairlineCards.swift, Bots/PixelCards.swift, BotDMCard.swift): a long
// answer as a brief card, a [CHOOSE: …] question as a yes/no or a choice, a failure in the words of the brain the bot is on
// (sign in, an API key, install, or a plain failure), a bot that's off, a private message between bots, and a PDF Theo made.
// Loaded before app.js; it uses app.js's helpers (invoke, esc, md, botHTML, nameOf, ago, open, say, room, sigs) only when
// a chat is drawn.
const CARDS = (() => {
  /* ---------------- a long answer: the brief card (ClickyCore BriefCard.parse) ---------------- */
  const BRIEF_MINIMUM = 900;
  function strip(text) { return String(text).replace(/\*\*/g, "").replace(/`/g, "").replace(/__/g, ""); }
  function fallbackTitle(paragraph) {
    const first = (paragraph.split(/[.!?:]/)[0] || paragraph).trim();
    const words = first.split(" ");
    return words.length > 12 ? words.slice(0, 12).join(" ") + "…" : first;
  }
  function parseBrief(text) {
    const trimmed = String(text || "").trim();
    if (trimmed.length < BRIEF_MINIMUM || trimmed.includes("```prompt") || /\[CHOOSE:/.test(trimmed)) return null;
    const lines = trimmed.split(/\r?\n/);
    const headings = [], paragraphs = [];
    let inFence = false, body = "";
    for (const line of lines) {
      const clean = line.trim();
      if (clean.startsWith("```")) { inFence = !inFence; continue; }
      if (inFence) continue;
      if (clean.startsWith("#")) { if (body) { paragraphs.push(body); body = ""; } headings.push(clean.replace(/^#+/, "").trim()); }
      else if (!clean) { if (body) { paragraphs.push(body); body = ""; } }
      else if (!/^[-*|]/.test(clean)) body += (body ? " " : "") + clean;
    }
    if (body) paragraphs.push(body);
    if (!headings.length && paragraphs.length < 4) return null;
    const opensWithTitle = lines[0].trim().startsWith("#");
    const title = opensWithTitle ? headings[0] : fallbackTitle(paragraphs[0] || trimmed);
    const sections = (opensWithTitle ? headings.slice(1) : headings).slice(0, 5).map(strip);
    const words = trimmed.split(/\s+/).length;
    const lowered = title.toLowerCase();
    const kind = lowered.includes("plan") ? "Plan" : lowered.includes("doc") ? "Doc" : "Brief";
    return { title: strip(title), excerpt: strip(paragraphs.find((p) => p !== title) || ""), sections, minutes: Math.max(1, Math.ceil(words / 220)), kind };
  }
  const briefs = {};
  function brief(m) {
    const card = parseBrief(m.text);
    if (!card) return "";
    briefs[m.id] = { card, text: m.text, author: m.author };
    const when = Date.now() - Date.parse(m.at) < 90000 ? "just now" : `${ago(m.at)} ago`;
    return `<div class="brief"><div class="brief-cover">${botHTML(m.author, 60, { badge: false, state: "working" })}</div><div class="brief-main">`
      + `<div class="brief-kind"><b>${esc(card.kind.toUpperCase())}</b> · ${card.minutes} min read · ${esc(when)}</div>`
      + `<div class="brief-title">${esc(card.title)}</div><p class="brief-excerpt">${esc(card.excerpt)}</p>`
      + (card.sections.length ? `<div class="brief-sections">${card.sections.map((s) => `<span>${esc(s)}</span>`).join("")}</div>` : "")
      + `</div><div class="brief-foot"><button class="btn pri sm" data-brief-open="${esc(m.id)}">Open</button><button class="btn sm" data-brief-share="${esc(m.id)}" title="Copy the document">Share</button>`
      + `<span class="brief-by">${botHTML(m.author, 18, { badge: false })}by ${esc(nameOf(m.author))}</span></div></div>`;
  }
  // The whole document: headings, lists, tables, code, rules and inline marks. Everything is escaped first.
  function inline(text) {
    return esc(text).replace(/`([^`\n]+)`/g, "<code>$1</code>").replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>").replace(/__([^_]+)__/g, "<strong>$1</strong>")
      .replace(/(^|[^*\w])\*([^*\n]+)\*/g, "$1<em>$2</em>").replace(/\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g, "$1 <span class=\"muted\">($2)</span>");
  }
  function rich(text) {
    const lines = String(text).replace(/\r\n/g, "\n").split("\n");
    let html = "", para = [], list = null, i = 0;
    const flush = () => { if (para.length) { html += `<p>${para.map(inline).join("<br>")}</p>`; para = []; } };
    const close = () => { if (list) { html += `</${list}>`; list = null; } };
    const cells = (line) => line.trim().replace(/^\||\|$/g, "").split("|").map((c) => c.trim());
    while (i < lines.length) {
      const line = lines[i], t = line.trim();
      if (t.startsWith("```")) {
        flush(); close(); const code = []; i++;
        while (i < lines.length && !lines[i].trim().startsWith("```")) code.push(lines[i++]);
        html += `<pre>${esc(code.join("\n"))}</pre>`; i++; continue;
      }
      if (t.startsWith("|") && i + 1 < lines.length && /^\s*\|?\s*:?-{2,}/.test(lines[i + 1])) {
        flush(); close();
        html += `<table class="grid"><tr>${cells(line).map((c) => `<th>${inline(c)}</th>`).join("")}</tr>`; i += 2;
        while (i < lines.length && lines[i].trim().startsWith("|")) html += `<tr>${cells(lines[i++]).map((c) => `<td>${inline(c)}</td>`).join("")}</tr>`;
        html += "</table>"; continue;
      }
      let h;
      if (!t) { flush(); close(); }
      else if ((h = t.match(/^(#{1,6})\s+(.*)$/))) { flush(); close(); const n = Math.min(4, h[1].length + 1); html += `<h${n}>${inline(h[2])}</h${n}>`; }
      else if (/^(-{3,}|\*{3,}|_{3,})$/.test(t)) { flush(); close(); html += "<hr>"; }
      else if ((h = t.match(/^([-*+]|\d+[.)])\s+(.*)$/))) {
        flush(); const tag = /\d/.test(h[1]) ? "ol" : "ul";
        if (list !== tag) { close(); html += `<${tag}>`; list = tag; }
        html += `<li>${inline(h[2])}</li>`;
      } else { close(); para.push(t); }
      i++;
    }
    flush(); close();
    return html;
  }
  function openBrief(id) {
    const b = briefs[id];
    if (!b) return;
    let dialog = document.querySelector("#brief-dialog");
    if (!dialog) { dialog = document.createElement("dialog"); dialog.id = "brief-dialog"; document.body.appendChild(dialog); }
    // The title is drawn above, so a first-line heading doesn't show twice.
    const lines = b.text.trim().split("\n");
    const body = lines[0].trim().startsWith("#") ? lines.slice(1).join("\n") : b.text;
    dialog.innerHTML = `<div class="reader-h">${botHTML(b.author, 28, { badge: false })}<span>${esc(b.card.kind)} by ${esc(nameOf(b.author))}</span><button class="btn sm" data-reader-copy>Copy</button><button class="btn sm" data-reader-close>Close</button></div>`
      + `<div class="reader"><h1 class="reader-title">${esc(b.card.title)}</h1>${rich(body)}</div>`;
    dialog.querySelector("[data-reader-close]").onclick = () => dialog.close();
    dialog.querySelector("[data-reader-copy]").onclick = (e) => { copy(b.text); e.target.textContent = "Copied"; };
    dialog.showModal();
  }
  function copy(text) { try { navigator.clipboard && navigator.clipboard.writeText(text); } catch (e) { /* the button still says so */ } }

  /* ---------------- [CHOOSE: …]: a yes or no, or a choice (BotCallPrompt, BotCallCard) ---------------- */
  const AUTO_PICK_MINUTES = 10;
  function parseCall(text) {
    const open = text.indexOf("[CHOOSE:");
    if (open < 0) return null;
    const close = text.indexOf("]", open);
    if (close < 0) return null;
    const parts = text.slice(open + 8, close).split("|").map((s) => s.trim());
    if (parts.length < 3 || !parts[0]) return null;
    const options = parts.slice(1, 5).filter(Boolean).map((p) => { const c = p.indexOf(":"); return c < 0 ? { title: p, detail: "" } : { title: p.slice(0, c).trim(), detail: p.slice(c + 1).trim() }; });
    if (options.length < 2) return null;
    return { question: parts[0], options, rest: (text.slice(0, open) + text.slice(close + 1)).trim() };
  }
  const picked = {};
  const autoTimers = [];
  function choose(m, answeredBy, autoPicks) {
    const call = parseCall(m.text);
    if (!call) return `<div class="body">${md(m.text)}</div>`;
    const before = call.rest ? `<div class="body">${md(call.rest)}</div>` : "";
    if (answeredBy !== null && answeredBy !== undefined) {
      const said = call.options.find((o) => o.title.toLowerCase() === String(answeredBy).trim().toLowerCase());
      const skipped = /^skip/i.test(String(answeredBy));
      return before + `<div class="tc-line">${skipped ? `<i class="pg nil"></i>` : TP.badge("done", "pg")}<span><b>${skipped ? "You skipped this" : said ? `You said ${esc(said.title)}` : "You answered"}</b> · ${esc(call.question)}</span></div>`;
    }
    const yesOrNo = call.options.length <= 3 && call.options.every((o) => !o.detail && o.title.length <= 22);
    const deadline = Date.parse(m.at) + AUTO_PICK_MINUTES * 60000;
    const minutes = Math.ceil((deadline - Date.now()) / 60000);
    const who = esc(nameOf(m.author));
    const foot = !autoPicks ? `${who} waits for you. Your other bots keep working.` : minutes > 0 ? `${who} picks the first one in ${minutes} min if you don't. Your other bots keep working.` : `${who} waits here. Your other bots keep working.`;
    const at = picked[m.id] || 0;
    const head = `<div class="tc ask" data-call="${esc(m.id)}" data-deadline="${autoPicks ? deadline : ""}" data-author="${esc(m.author)}"><div class="tc-h">${botHTML(m.author, 28, { state: "needs" })}<span class="who"><b>${who}</b> · waiting ${esc(ago(m.at))}</span>${TP.pill("needs", "Needs you")}</div><div class="tc-q">${esc(call.question)}</div>`;
    const body = yesOrNo
      ? `<div class="btns">${call.options.map((o, i) => `<button class="btn${i === 0 ? " pri" : ""}" data-call-say="${esc(o.title)}" data-call-to="${esc(m.author)}">${esc(o.title)}</button>`).join("")}</div>`
      : `<div class="tc-opts">${call.options.map((o, i) => `<button class="tc-opt${i === at ? " on" : ""}" data-call-pick="${esc(m.id)}" data-index="${i}"><i></i><span class="tx"><b>${esc(o.title)}</b>${o.detail ? `<small>${esc(o.detail)}</small>` : ""}</span></button>`).join("")}</div>`
        + `<div class="btns"><button class="btn pri" data-call-use="${esc(m.id)}" data-call-to="${esc(m.author)}" data-options="${esc(JSON.stringify(call.options.map((o) => o.title)))}">Use this</button><button class="btn ghost" data-call-say="Skip this one for now." data-call-to="${esc(m.author)}">Skip</button></div>`;
    return before + head + body + `<div class="tc-foot">${foot}</div></div>`;
  }
  // The owner's answer to a call goes to that bot's own chat (from Home) or this chat.
  async function answerCall(text, botId) {
    if (typeof view !== "undefined" && (view.kind === "bot" || view.kind === "group")) await say(text);
    else { await invoke({ cmd: "botSay", bot: botId, text }); }
  }

  /* ---------------- failures, in the words of the bot's own brain (PixelCards: sign-in, API key, failure) ---------------- */
  // Kept in step with failover.rs classify's Auth, so a card and the Home lane agree on "signed out".
  const SIGNIN = /\/login|invalid api key|invalid x-api-key|authentication_error|isn't installed|not installed|not logged in|not signed in|signed out|sign in|unauthori[sz]ed|\b401\b|oauth token (has )?expired|not authenticated/i;
  function providerOf(id) { return (state.bots.find((b) => b.id === id) || {}).provider || "claude"; }
  function agentInfo(provider) { return brainsCache && brainsCache.agents ? brainsCache.agents.find((a) => a.id === provider) : null; }
  function apiInfo(provider) { return brainsCache && brainsCache.apis ? brainsCache.apis.find((a) => a.engine === provider) : null; }
  // The list of brains is read once, then again for each new failure, since an agent may have been installed or
  // signed in since (setup loads it before the owner installs anything).
  const brainsAskedFor = new Set();
  function wantBrains(failureAt) {
    const key = failureAt || "first";
    if (brainsAskedFor.has(key) || (brainsCache && !failureAt)) return;
    brainsAskedFor.add(key);
    loadBrains().then(() => { sigs.chat = null; sigs.home = null; });
  }
  const AGENT_LABELS = { claude: "Claude Code", codex: "Codex", cursor: "Cursor Agent", opencode: "OpenCode", grok: "Grok", gemini: "Gemini CLI" };
  function brainLabel(provider) {
    const agent = agentInfo(provider); if (agent) return agent.label;
    const api = apiInfo(provider); if (api) return api.label;
    if (AGENT_LABELS[provider]) return AGENT_LABELS[provider];
    return provider.startsWith("api:") ? provider.slice(4) : provider;
  }
  function firstSentence(reason) {
    const line = String(reason).trim().split("\n")[0];
    const stop = line.indexOf(". ");
    return stop >= 0 ? line.slice(0, stop) : line.replace(/\.$/, "");
  }
  // The card for a bot whose brain is signed out, missing, or whose key didn't work. `botId`, the raw reason, and whether it's live.
  function signInCard(botId, reason, at) {
    wantBrains(at);
    const provider = providerOf(botId);
    const label = brainLabel(provider);
    const name = esc(nameOf(botId));
    const head = (context) => `<div class="tc ask"><div class="tc-h">${botHTML(botId, 28, { state: "needs" })}<span class="who"><b>${name}</b> · ${context}</span>${TP.pill("needs", "Needs you")}</div>`;
    if (provider.startsWith("api:")) {
      const api = apiInfo(provider);
      return head("can't start") + `<div class="tc-q">Your ${esc(label.replace(/ \(API key\)$/, ""))} key didn't work</div><p>${name} thinks with an API key, and the provider turned it down. Paste a working key in Settings, then try again.</p>`
        + `<div class="tc-obj"><span class="app"><b>K</b>${TP.badge("needs")}</span><span class="tx"><b>${esc(label)}</b><small>${esc(api && api.keyPage ? `Get a key at ${api.keyPage}` : firstSentence(reason))}</small></span>${TP.pill("needs", "Key refused")}</div>`
        + `<div class="btns"><button class="btn pri" data-open-pane="settings">Open Settings</button><button class="btn" data-retry="${esc(botId)}">Try again</button></div><div class="tc-foot">Your message is kept; it's asked again when you try.</div></div>`;
    }
    const agent = agentInfo(provider);
    // The agent's own words win: if it answered "not logged in", it ran, so it's installed whatever the cached list says.
    const agentRan = /\/login|not logged in|not signed in|signed out|unauthori[sz]ed|\b401\b|expired|not authenticated/i.test(reason);
    const missing = /isn't installed|not installed/i.test(reason) || (agent && !agent.installed && !agentRan);
    if (missing) {
      const install = agent ? agent.install : "";
      return head("can't start") + `<div class="tc-q">Install ${esc(label)} on this computer</div><p>${name} runs on ${esc(label)}, which isn't installed here yet. Install it, sign in, and ${name} picks the job back up.</p>`
        + (install ? `<div class="tc-field"><span>${esc(install)}</span><button class="btn sm" data-copy="${esc(install)}">Copy</button></div>` : "")
        + `<div class="btns"><button class="btn pri" data-term="install:${esc(provider)}">Install</button><button class="btn" data-open-pane="settings">Use an API key instead</button><button class="btn ghost" data-retry="${esc(botId)}">Try again</button></div>`
        + `<div class="tc-foot">Your message is kept; it's asked again when you try.</div></div>`;
    }
    return head(at ? `waiting ${esc(ago(at))}` : "can't start") + `<div class="tc-q">${esc(label)} is signed out</div><p>${name} runs on ${esc(label)}. Sign in once and try again: ${name} picks the job back up.</p>`
      + `<div class="tc-obj"><span class="app"><svg class="ic" viewBox="0 0 24 24"><path d="M4 6h16v12H4zM7 10l3 2-3 2M12 15h5"/></svg>${TP.badge("needs")}</span><span class="tx"><b>${esc(label)}</b><small>${esc(agent && agent.signInHint ? agent.signInHint : `Your ${label} account`)}</small></span>${TP.pill("needs", "Signed out")}</div>`
      + `<div class="btns"><button class="btn pri" data-term="signin:${esc(provider)}">Sign in</button><button class="btn" data-open-pane="settings">Use an API key instead</button><button class="btn ghost" data-retry="${esc(botId)}">Try again</button></div>`
      + `<div class="tc-foot">Opens a terminal with ${esc(label)}'s own sign-in. Vello never sees your password. Your message is kept.</div></div>`;
  }
  function plainFailureCard(botId, reason, at, context) {
    const first = firstSentence(reason);
    return `<div class="tc bad"><div class="tc-h">${botHTML(botId, 28, { state: "failed" })}<span class="who"><b>${esc(nameOf(botId))}</b> · ${esc(context || `stopped · ${ago(at)}`)}</span>${TP.pill("failed", "Failed")}</div>`
      + `<div class="tc-q">${esc(nameOf(botId))} couldn't answer</div><p>${esc(first)}. Your message is still here and nothing was lost.</p>`
      + `<div class="term tall tc-details">${esc(reason)}</div>`
      + `<div class="btns"><button class="btn pri" data-retry="${esc(botId)}">Try again</button><button class="btn" data-details>See details</button><button class="btn ghost" data-copy="${esc(reason)}">Copy details</button></div></div>`;
  }
  function failure(m, latest) {
    const reason = m.text.replace(/^Couldn't reply:\s*/, "");
    const signin = SIGNIN.test(reason);
    if (!latest) return `<div class="tc-line">${TP.badge(signin ? "needs" : "failed", "pg")}<span><b>${signin ? "Signed out" : "Failed"}</b> · ${esc(firstSentence(reason))}</span><time>${ago(m.at)}</time></div>`;
    return signin ? signInCard(m.author, reason, m.at) : plainFailureCard(m.author, reason, m.at);
  }

  /* ---------------- a yes or no from Theo: a routine to set up, or a coding run to start ---------------- */
  // `chatId` is the chat the card is in, so it can be answered from Home too. A coding run's card carries the run choices
  // (agent, folder, chat), and its Start answers the card.
  function ask(m, chatId) {
    let p = {}; try { p = JSON.parse(m.card.slice(4)); } catch (e) { /* drawn from the words */ }
    const isRun = p.kind === "run";
    const obj = isRun
      ? `<div class="tc-obj"><span class="app"><svg class="ic" viewBox="0 0 24 24"><path d="M8 9l-3 3 3 3M16 9l3 3-3 3M13.5 6l-3 12"/></svg></span><span class="tx"><b>${esc(p.title || "Coding run")}</b><small>${esc((p.prompt || "").split("\n")[0].slice(0, 110))}</small></span></div>`
      : `<div class="tc-obj"><span class="app"><svg class="ic" viewBox="0 0 24 24"><path d="M19.5 12A7.5 7.5 0 1 1 17.3 6.7M13.9 6.8h3.6V3.2M12 8.6V12l2.3 1.5"/></svg></span><span class="tx"><b>${esc(p.name || "Routine")}</b><small>${esc(p.when || "")} · ${esc(p.do || "")}</small></span></div>`;
    const buttons = isRun
      ? (typeof RUNCHOICES !== "undefined" ? RUNCHOICES.draw(m.id, p.answer || "", p.pitch || null, chatId) : "") + `<div class="btns"><button class="btn" data-ask="${esc(m.id)}" data-ask-chat="${esc(chatId)}" data-choice="no">Don't</button></div>`
      : `<div class="btns"><button class="btn pri" data-ask="${esc(m.id)}" data-ask-chat="${esc(chatId)}" data-choice="yes">Set it up</button><button class="btn" data-ask="${esc(m.id)}" data-ask-chat="${esc(chatId)}" data-choice="no">Don't</button></div>`;
    return `<div class="tc ask"><div class="tc-h">${botHTML(p.bot, 28, { state: "needs" })}<span class="who"><b>${esc(nameOf(p.bot))}</b> · ${isRun ? "Coding run" : "New routine"}</span>${TP.pill("needs", "Needs you")}</div>`
      + `<div class="tc-q">${isRun ? "Start this coding run?" : "Set up this routine?"}</div><p>${esc(m.text)}</p>${obj}${buttons}`
      + `<div class="tc-foot">${isRun ? "A coding agent works with full access in its folder." : "A routine runs the bot again and again with nobody watching."} Nothing happens unless you say yes.</div></div>`;
  }

  /* ---------------- a bot that's off ---------------- */
  function off(botId) {
    return `<div class="tc"><div class="tc-h">${botHTML(botId, 28, { state: "off" })}<span class="who"><b>${esc(nameOf(botId))}</b> · switched off</span>${TP.pill("none", "Off")}</div>`
      + `<div class="tc-q">This bot is off</div><p>It keeps its memory and routines. Turn it on to give it work.</p><div class="btns"><button class="btn" data-turn-on="${esc(botId)}">Turn on</button></div></div>`;
  }

  /* ---------------- a private message between bots (BotDMCard) ---------------- */
  const dmOpen = new Set();
  const dmCache = {};
  function dmThread(a, b) { return "dm:" + [a, b].sort().join("+"); }
  function preview(text, limit = 90) {
    const line = String(text).replace(/```/g, " ").replace(/\*\*/g, "").replace(/`/g, "").replace(/#/g, "").split("\n").map((l) => l.trim()).find(Boolean) || "";
    return line.length > limit ? line.slice(0, limit - 1) + "…" : line;
  }
  function dmMessages(exchange, sender, target) {
    const cached = dmCache[exchange];
    const live = (state.exchanges || []).some((e) => e.id === exchange);
    if (!cached || (live && Date.now() - cached.at > 2500) || (!live && cached.live)) {
      if (!cached || !cached.loading) {
        dmCache[exchange] = Object.assign(cached || { messages: [] }, { loading: true });
        invoke({ cmd: "botChat", id: dmThread(sender, target), limit: 400 }).then((r) => {
          const messages = (r.result || []).filter((x) => x.exchange === exchange);
          const changed = !cached || JSON.stringify(cached.messages.map((x) => x.id)) !== JSON.stringify(messages.map((x) => x.id));
          dmCache[exchange] = { messages, at: Date.now(), live, loading: false };
          document.querySelectorAll(`[data-dm="${CSS.escape(exchange)}"]`).forEach((el) => { el.outerHTML = dmHTML(el.dataset.dm, el.dataset.sender, el.dataset.target, el.dataset.at); });
          if (changed) wireDM(document.querySelector("#pane"));
        });
      }
    }
    return (dmCache[exchange] || {}).messages || [];
  }
  function dmHTML(exchange, sender, target, at) {
    const messages = dmMessages(exchange, sender, target);
    const spoken = messages.filter((x) => x.text && x.author !== "note");
    const live = (state.exchanges || []).find((e) => e.id === exchange);
    const last = messages.filter((x) => x.text).slice(-1)[0];
    const looksLive = last && last.author === sender && Date.now() - Date.parse(last.at) < 8 * 60000;
    const status = live ? (live.replying ? `${esc(nameOf(target))} is replying…` : `${esc(nameOf(target))} is busy, and will answer when it's free`) : looksLive ? `${esc(nameOf(target))} is replying…` : "";
    const isOpen = dmOpen.has(exchange);
    const newest = spoken.slice(-1)[0];
    const line = status ? `<small class="dm-status"><i class="typing"><b></b><b></b><b></b></i>${status}</small>` : !isOpen && newest ? `<small>${esc(preview(newest.text))}</small>` : "";
    const time = new Date(Date.parse(at)).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
    let body = "";
    if (isOpen) {
      body = `<div class="dm-body">` + messages.map((x) => {
        if (x.author === "note") return `<div class="msg note">${md(x.text)}</div>`;
        if (!x.text) return "";
        return `<div class="dm-line">${botHTML(x.author, 22, { badge: false })}<div><div class="dm-who"><b>${esc(nameOf(x.author))}</b><time>${new Date(Date.parse(x.at)).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}</time></div><div class="body">${md(x.text)}</div></div></div>`;
      }).join("") + (messages.length ? "" : `<div class="muted">Loading…</div>`) + `</div>`;
    }
    return `<div class="dm${isOpen ? " open" : ""}" data-dm="${esc(exchange)}" data-sender="${esc(sender)}" data-target="${esc(target)}" data-at="${esc(at)}">`
      + `<button class="dm-h" data-dm-toggle="${esc(exchange)}" title="${isOpen ? "Fold this private exchange" : "Open this private exchange"}"><span class="dm-figs">${botHTML(target, 20, { badge: false })}${botHTML(sender, 20, { badge: false })}</span>`
      + `<span class="tx"><span class="dm-head"><b>${esc(nameOf(sender))} messaged ${esc(nameOf(target))} privately</b><time>${esc(time)}</time></span>${line}</span>`
      + `<span class="dm-count">${spoken.length === 1 ? "1 message" : `${spoken.length} messages`}</span><svg class="ic chev" viewBox="0 0 24 24"><path d="M6 9l6 6 6-6"/></svg></button>${body}</div>`;
  }
  function dm(m) {
    const parts = m.card.split(":");
    return dmHTML(parts[1], m.author, parts.slice(2).join(":"), m.at);
  }
  function wireDM(root) {
    if (!root) return;
    root.querySelectorAll("[data-dm-toggle]").forEach((b) => b.onclick = () => {
      const ex = b.dataset.dmToggle;
      if (dmOpen.has(ex)) dmOpen.delete(ex); else dmOpen.add(ex);
      const el = b.closest("[data-dm]");
      el.outerHTML = dmHTML(el.dataset.dm, el.dataset.sender, el.dataset.target, el.dataset.at);
      wireDM(root);
    });
  }

  /* ---------------- a PDF Theo made from a bot's [PDF:] ---------------- */
  function pdf(m) {
    let p = {}; try { p = JSON.parse(m.card.slice(4)); } catch (e) { /* drawn from the words below */ }
    return `<div class="tc ok"><div class="tc-h"><span class="app"><svg class="ic" viewBox="0 0 24 24"><path d="M7 3h7l5 5v13H7zM14 3v5h5M9.5 13h5M9.5 16.5h5"/></svg></span><span class="who"><b>${esc(p.name || "PDF")}</b> · made for ${esc(nameOf(p.bot || ""))}</span>${TP.pill("ok", "Ready")}</div>`
      + `<div class="tc-field"><span title="${esc(p.path || "")}">${esc(p.path || "")}</span><button class="btn sm" data-copy="${esc(p.path || "")}">Copy</button></div>`
      + `<div class="btns"><button class="btn pri" data-open-file="${esc(p.path || "")}">Open</button></div></div>`;
  }

  /* ---------------- wiring ---------------- */
  function wire(root) {
    root.querySelectorAll("[data-brief-open]").forEach((b) => b.onclick = () => openBrief(b.dataset.briefOpen));
    root.querySelectorAll("[data-brief-share]").forEach((b) => b.onclick = () => { const x = briefs[b.dataset.briefShare]; if (x) copy(x.text); b.textContent = "Copied"; });
    root.querySelectorAll("[data-call-pick]").forEach((b) => b.onclick = () => {
      picked[b.dataset.callPick] = Number(b.dataset.index);
      b.parentElement.querySelectorAll(".tc-opt").forEach((o) => o.classList.toggle("on", o === b));
    });
    root.querySelectorAll("[data-call-say]").forEach((b) => b.onclick = async () => { b.disabled = true; await answerCall(b.dataset.callSay, b.dataset.callTo); sigs.chat = null; sigs.home = null; });
    root.querySelectorAll("[data-call-use]").forEach((b) => b.onclick = async () => {
      const options = JSON.parse(b.dataset.options || "[]");
      b.disabled = true; await answerCall(options[picked[b.dataset.callUse] || 0], b.dataset.callTo); sigs.chat = null; sigs.home = null;
    });
    root.querySelectorAll("[data-ask]").forEach((b) => b.onclick = async () => {
      b.disabled = true;
      const r = await invoke({ cmd: "answerCard", chat: b.dataset.askChat, message: b.dataset.ask, choice: b.dataset.choice });
      if (!r.ok) b.textContent = r.error;
      sigs.chat = null; sigs.home = null; refresh();
    });
    if (typeof RUNCHOICES !== "undefined") RUNCHOICES.wire(root);
    root.querySelectorAll("[data-turn-on]").forEach((b) => b.onclick = async () => { b.disabled = true; await invoke({ cmd: "botUpdate", id: b.dataset.turnOn, enabled: true }); sigs.chat = null; refresh(); });
    root.querySelectorAll("[data-open-pane]").forEach((b) => b.onclick = () => open({ kind: b.dataset.openPane }));
    root.querySelectorAll("[data-open-file]").forEach((b) => b.onclick = async () => { const r = await invoke({ cmd: "openFile", path: b.dataset.openFile }); b.textContent = r.ok ? "Opened" : r.error; });
    wireDM(root);
    // Left alone with the chat open, a choice picks its highlighted option after ten minutes; a card more than an hour past that waits.
    while (autoTimers.length) clearTimeout(autoTimers.pop());
    root.querySelectorAll("[data-call][data-deadline]").forEach((card) => {
      const deadline = Number(card.dataset.deadline);
      if (!deadline) return;
      const wait = deadline - Date.now();
      if (wait < -3600000) return;
      autoTimers.push(setTimeout(async () => {
        if (!document.body.contains(card) || card.dataset.answered) return;
        card.dataset.answered = "1";
        const call = parseCall((card.dataset.text) || "");
        const id = card.dataset.call;
        const use = card.querySelector("[data-call-use]");
        const first = card.querySelector("[data-call-say]");
        const options = use ? JSON.parse(use.dataset.options || "[]") : null;
        const text = options ? options[picked[id] || 0] : first ? first.dataset.callSay : call && call.options[0].title;
        if (text) { await say(text); sigs.chat = null; }
      }, Math.max(0, wait)));
    });
  }

  // What, besides the messages, changes how a chat's cards look.
  function sig() {
    return JSON.stringify([(state.exchanges || []).map((e) => e.id + e.replying), [...dmOpen], !!brainsCache, state.bots.map((b) => b.enabled)]);
  }

  return { parseBrief, parseCall, brief, choose, ask, failure, signInCard, plainFailureCard, off, dm, pdf, wire, sig, rich, firstSentence, brainLabel, SIGNIN, wantBrains, answerCall };
})();
