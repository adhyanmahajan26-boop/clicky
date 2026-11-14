// Home's top (the Mac's Setup/HomeLanes.swift): a row of count pills, then two lanes. Left, what needs the owner and what
// failed, as the same cards the chat uses, so they can be answered right here. Right, who's working (step, timer and a
// progress bar), what finished today, and who's asleep with their next routine. The primary bot (Theo) isn't in the lanes.
// Loaded before app.js; app.js's renderHome calls HOME.render.
const HOME = (() => {
  const chats = {};     // bot id → { key, messages } for bots that need the owner
  let routines = [], routinesAt = 0, routinesAsking = false;

  function loadRoutines() {
    if (routinesAsking || Date.now() - routinesAt < 10000) return;
    routinesAsking = true;
    invoke({ cmd: "routinesList" }).then((r) => {
      routinesAsking = false; routinesAt = Date.now();
      if (r.ok) { routines = r.result || []; sigs.home = null; }
    });
  }
  // The newest messages of a bot that needs the owner, to draw its own card (a choice, a yes or no).
  function messagesOf(f) {
    const key = `${f.since}|${f.detail}`;
    const known = chats[f.id];
    if (!known || known.key !== key) {
      chats[f.id] = { key, messages: known ? known.messages : null };
      invoke({ cmd: "botChat", id: f.id, limit: 40 }).then((r) => { if (chats[f.id] && chats[f.id].key === key) { chats[f.id].messages = r.result || []; sigs.home = null; } });
    }
    return chats[f.id].messages;
  }
  function team() {
    const primary = new Set(state.bots.filter((b) => b.primary).map((b) => b.id));
    return state.faces.filter((f) => !primary.has(f.id));
  }

  function needsCard(f) {
    if (f.failure && f.failure.kind === "signin") return CARDS.signInCard(f.id, f.failure.reason, f.failure.at);
    const messages = messagesOf(f);
    if (messages) {
      const last = messages[messages.length - 1];
      if (last && last.author === f.id && CARDS.parseCall(last.text || "")) return `<div class="home-call">${CARDS.choose(last, null, false)}</div>`;
      const ask = [...messages].reverse().find((m) => m.card && m.card.startsWith("ask:"));
      if (ask) return CARDS.ask(ask, f.id);
    }
    return `<div class="tc ask"><div class="tc-h">${botHTML(f.id, 28, { state: "needs" })}<span class="who"><b>${esc(nameOf(f.id))}</b></span><span class="timer" data-since="${esc(f.since || "")}">${ago(f.since)}</span></div>`
      + `<div class="tc-q">${esc(f.detail || f.word)}</div><div class="btns"><button class="btn pri" data-open="${esc(f.id)}">Open chat</button></div></div>`;
  }
  // FailedBotCard: what couldn't happen, why, and the one fix.
  function failedCard(f) {
    const failure = f.failure || { reason: "It stopped.", at: f.since };
    if (CARDS.SIGNIN.test(failure.reason)) return CARDS.signInCard(f.id, failure.reason, failure.at);
    const first = CARDS.firstSentence(failure.reason);
    const rest = failure.reason.slice(Math.min(failure.reason.length, first.length)).replace(/^[.\s]+|[.\s]+$/g, "");
    const question = /^can't reach/i.test(failure.reason) ? first : "Couldn't finish the job";
    return `<div class="tc bad"><div class="tc-h">${botHTML(f.id, 28, { state: "failed" })}<span class="who"><b>${esc(nameOf(f.id))}</b> · ${esc(ago(failure.at))}</span>${TP.pill("failed", "Failed")}</div>`
      + `<div class="tc-q">${esc(question)}</div><p>${esc(first)}.${rest ? ` ${esc(rest.split("\n")[0])}.` : ""}</p>`
      + `<div class="btns"><button class="btn pri" data-retry="${esc(f.id)}">Try again</button><button class="btn" data-open="${esc(f.id)}">See details</button></div></div>`;
  }
  // Working now: what it's doing, which step, the timer, and a progress bar (RunSteps.fills: a run is on Code, step 2).
  function workingRow(f) {
    const run = (state.runs || []).find((r) => r.room === f.id && r.phase === "running");
    const done = run ? 1 : 0;
    const progress = Math.min(1, done / 5 + 0.1);
    const words = [esc(f.detail || f.word)].concat(run ? [`step ${done + 1} of 5`, `<span class="timer" data-clock="${esc(run.startedAt)}">${clock(run.startedAt)}</span>`] : []).join(" · ");
    return `<button class="mini home-row" data-open="${esc(f.id)}">${botHTML(f.id, 36)}<span class="tx"><b>${esc(nameOf(f.id))}</b><small>${words}</small><span class="bar still"><i style="width:${Math.round(progress * 100)}%"></i></span></span></button>`;
  }
  function laneRow(f, pose, detail, button) {
    return `<div class="mini home-row" data-row="${esc(f.id)}">${botHTML(f.id, 36, { state: pose })}<span class="tx"><b>${esc(nameOf(f.id))}</b><small>${esc(detail || "")}</small></span>${button}</div>`;
  }
  function asleepRow(f) {
    const next = routines.filter((r) => r.target === f.id && !r.paused && r.nextRunAt).sort((a, b) => Date.parse(a.nextRunAt) - Date.parse(b.nextRunAt))[0];
    if (next) {
      const at = new Date(Date.parse(next.nextRunAt)).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
      return laneRow(f, "idle", `Next routine at ${at}`, `<button class="btn sm" data-routine-run="${esc(next.id)}">Run now</button>`);
    }
    return laneRow(f, "idle", "Nothing to do", `<button class="btn sm" data-open="${esc(f.id)}">Give it a job</button>`);
  }
  const laneTitle = (title, count) => `<div class="lane-h"><span>${esc(title)}</span><span>${count}</span></div>`;
  const quiet = (text) => `<div class="muted home-quiet">${esc(text)}</div>`;

  function render() {
    loadRoutines();
    CARDS.wantBrains();
    const faces = team();
    const of = (...states) => faces.filter((f) => states.includes(f.state));
    const needing = of("needs"), failed = of("failed"), working = of("working", "thinking"), done = of("done"), asleep = of("idle");
    const hour = new Date().getHours();
    const hello = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening";
    const minute = Math.floor(Date.now() / 60000);
    const sig = JSON.stringify([faces.map((f) => [f.id, f.state, f.detail, f.since, f.failure && f.failure.at]), state.bots.map((b) => [b.name, b.provider]),
      (state.runs || []).map((r) => r.id + r.phase), routines.map((r) => [r.id, r.nextRunAt, r.paused]), Object.values(chats).map((c) => c.messages ? c.messages.length : -1), CARDS.sig(), minute]);
    const pane = $("#pane");
    if (sigs.home === sig) {
      // Only the timers move.
      pane.querySelectorAll("[data-clock]").forEach((el) => { el.textContent = clock(el.dataset.clock); });
      return;
    }
    sigs.home = sig;
    const pills = [needing.length ? TP.pill("needs", `${needing.length} need you`) : "", failed.length ? TP.pill("failed", `${failed.length} failed`) : "",
      working.length ? TP.pill("working", `${working.length} working`) : "", done.length ? TP.pill("done", `${done.length} done`) : "", asleep.length ? TP.pill("idle", `${asleep.length} asleep`) : ""].join("");
    const left = laneTitle("Needs you", needing.length) + (needing.length ? needing.map(needsCard).join("") : quiet("Nothing needs you right now."))
      + (failed.length ? laneTitle("Failed", failed.length) + failed.map(failedCard).join("") : "");
    const right = laneTitle("Working now", working.length) + (working.length ? working.map(workingRow).join("") : quiet("Nobody's working. Give a bot a job."))
      + (done.length ? laneTitle("Finished today", done.length) + done.map((f) => laneRow(f, "done", (f.detail || "").replace(/^#+\s*/, ""), `<button class="btn sm" data-open="${esc(f.id)}">Open</button>`)).join("") : "")
      + (asleep.length ? laneTitle("Asleep", asleep.length) + asleep.slice(0, 5).map(asleepRow).join("") : "");
    pane.innerHTML = `<div class="column home"><div><h1>${hello}.</h1>${pills ? `<div class="pills">${pills}</div>` : ""}</div><div class="lanes"><div class="lane">${left}</div><div class="lane">${right}</div></div></div>`;
    wire(pane);
    CARDS.wire(pane);
    pane.querySelectorAll("[data-row]").forEach((row) => row.onclick = (e) => { if (!e.target.closest("button")) open({ kind: "bot", id: row.dataset.row }); });
    pane.querySelectorAll("[data-routine-run]").forEach((b) => b.onclick = async (e) => {
      e.stopPropagation(); b.disabled = true;
      await invoke({ cmd: "routines", action: "run", id: b.dataset.routineRun });
      b.textContent = "Started"; routinesAt = 0;
    });
  }
  return { render };
})();
