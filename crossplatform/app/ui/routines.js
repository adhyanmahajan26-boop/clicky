// The Routines page (the Mac's RoutinesScreen, RoutineList and RoutineEditor in Bots/BotDetailsView.swift): bots doing a
// job on a schedule, each with its controls and recent runs, and an editor to add or change one. Saved with control
// `routineSave` (routine_edit.rs), which checks the schedule the same way the Mac's editor limits it.
// Loaded before app.js; app.js's renderRoutines calls ROUTINES.render.
const ROUTINES = (() => {
  const expanded = new Set();
  let poll = null;
  const DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
  // schedule.rs label, so the editor shows the words the list will.
  function label(s) {
    const time = `${s.hour}:${String(s.minute).padStart(2, "0")}`;
    switch (s.kind) {
      case "daily": return `Every day at ${time}`;
      case "weekdays": return `Weekdays at ${time}`;
      case "weekly": return `Every ${DAYS[(s.weekday + 6) % 7]} at ${time}`;
      case "hourly": return `Every hour at :${String(s.minute).padStart(2, "0")}`;
      default: return s.intervalMinutes % 60 === 0 ? `Every ${s.intervalMinutes / 60} h` : `Every ${s.intervalMinutes} min`;
    }
  }
  function relative(iso) {
    const ms = Date.parse(iso) - Date.now();
    const minutes = Math.round(Math.abs(ms) / 60000);
    const words = minutes < 1 ? "now" : minutes < 60 ? `${minutes} min` : minutes < 60 * 24 ? `${Math.round(minutes / 60)} h` : `${Math.round(minutes / 1440)} days`;
    if (words === "now") return ms >= 0 ? "in a moment" : "just now";
    return ms >= 0 ? `in ${words}` : `${words} ago`;
  }
  function when(iso) { return new Date(Date.parse(iso)).toLocaleString([], { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }); }
  // What each run status means, in words (RoutineQuiet, RoutineCatchUp).
  const STATUS_WORDS = { done: "done", quiet: "nothing to report", failed: "failed", missed: "missed while Vello was closed", running: "running", skipped: "skipped: the bot was busy" };
  const dot = (status) => `<i class="rt-dot rt-${esc(status)}"></i>`;
  function targetName(target) {
    if (target.startsWith("group:")) { const g = state.groups.find((x) => `group:${x.id}` === target); return g ? `${g.name} (group chat)` : "A group chat"; }
    return nameOf(target);
  }
  function targetFace(target) {
    if (target.startsWith("group:")) { const g = state.groups.find((x) => `group:${x.id}` === target); return g ? g.head : null; }
    return target;
  }

  function card(r) {
    const face = targetFace(r.target);
    const last = r.runs[r.runs.length - 1];
    const next = !r.paused && r.nextRunAt ? ` · next ${relative(r.nextRunAt)}` : "";
    const runs = r.runs.length ? `<button class="rt-last" data-rt-toggle="${esc(r.id)}">${dot(last.status)}<span>Last run ${esc(relative(last.startedAt))}: ${esc(STATUS_WORDS[last.status] || last.status)} · ${r.runs.length} run${r.runs.length === 1 ? "" : "s"}</span><svg class="ic chev" viewBox="0 0 24 24"><path d="${expanded.has(r.id) ? "M6 15l6-6 6 6" : "M6 9l6 6 6-6"}"/></svg></button>` : "";
    const list = expanded.has(r.id) ? `<div class="rt-runs">${r.runs.slice().reverse().map((x) => `<div class="rt-run">${dot(x.status)}<time>${esc(when(x.startedAt))}</time><span>${esc(x.summary || STATUS_WORDS[x.status] || x.status)}</span></div>`).join("")}</div>` : "";
    return `<div class="rt${r.paused ? " paused" : ""}"><div class="rt-top">${face ? botHTML(face, 30, { badge: false, state: r.paused ? "idle" : "awake" }) : ""}`
      + `<div class="rt-tx"><div class="rt-name"><b>${esc(r.name)}</b><span class="rt-chip">${esc(targetName(r.target))}</span>${r.paused ? `<span class="rt-paused">Paused</span>` : ""}</div>`
      + `<div class="rt-when">${esc(r.label || label(r.schedule))}${esc(next)}</div><div class="rt-do">${esc(r.instruction)}</div></div>`
      + `<div class="btns rt-acts"><button class="btn sm" data-rt="${r.paused ? "resume" : "pause"}" data-id="${esc(r.id)}">${r.paused ? "Resume" : "Pause"}</button><button class="btn sm" data-rt="run" data-id="${esc(r.id)}">Run now</button>`
      + `<button class="btn sm ghost" data-rt-edit="${esc(r.id)}">Edit…</button><button class="btn sm ghost" data-rt-delete="${esc(r.id)}">Delete</button></div></div>${runs}${list}</div>`;
  }

  let list = [];
  async function render() {
    const r = await invoke({ cmd: "routinesList" });
    if (view.kind !== "routines") return;
    list = r.ok ? r.result || [] : [];
    const sig = JSON.stringify([list, [...expanded], state.bots.map((b) => b.name), state.groups.map((g) => g.name), Math.floor(Date.now() / 60000)]);
    clearTimeout(poll);
    // Not over the "turned off" page when Theo the product was switched off meanwhile (products.js).
    poll = setTimeout(() => { if (view.kind === "routines" && !(window.productGate && window.productGate(view))) render(); }, 3000);
    if (sigs.routines === sig) return;
    sigs.routines = sig;
    const pane = $("#pane");
    pane.innerHTML = `<div class="column"><div class="rt-head"><div><h1>Routines</h1><p class="muted">Bots doing a job on a schedule. Ask any bot in chat ("every weekday at 8, check my inbox…") or add one here.</p></div>`
      + `<button class="btn" data-rt-new><svg class="ic" viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></svg>New routine</button></div>`
      + (list.length ? `<div class="rt-list">${list.map(card).join("")}</div>`
        : `<div class="empty rt-empty"><svg class="ic" viewBox="0 0 24 24"><path d="M19.5 12A7.5 7.5 0 1 1 17.3 6.7M13.9 6.8h3.6V3.2M12 8.6V12l2.3 1.5"/></svg><b>No routines yet</b><span>Try telling a bot: "every weekday at 8:30, sum up what needs a reply".</span></div>`)
      + `</div>`;
    pane.querySelector("[data-rt-new]").onclick = () => edit(null);
    pane.querySelectorAll("[data-rt]").forEach((b) => b.onclick = async () => {
      b.disabled = true; await invoke({ cmd: "routines", action: b.dataset.rt, id: b.dataset.id }); sigs.routines = null; setTimeout(render, 300);
    });
    pane.querySelectorAll("[data-rt-toggle]").forEach((b) => b.onclick = () => { const id = b.dataset.rtToggle; if (expanded.has(id)) expanded.delete(id); else expanded.add(id); render(); });
    pane.querySelectorAll("[data-rt-edit]").forEach((b) => b.onclick = () => edit(list.find((x) => x.id === b.dataset.rtEdit)));
    pane.querySelectorAll("[data-rt-delete]").forEach((b) => b.onclick = async () => {
      if (b.dataset.sure !== "1") { b.dataset.sure = "1"; b.textContent = "Delete it?"; b.classList.remove("ghost"); return; }
      b.disabled = true; await invoke({ cmd: "routines", action: "delete", id: b.dataset.rtDelete }); sigs.routines = null; render();
    });
  }

  /* ---------------- the editor ---------------- */
  function edit(routine) {
    const isNew = !routine;
    const first = state.bots.find((b) => b.enabled !== false) || state.bots[0];
    const r = routine ? JSON.parse(JSON.stringify(routine)) : { name: "", target: first ? first.id : "", instruction: "", paused: false, schedule: { kind: "weekdays", hour: 9, minute: 0, weekday: 2, intervalMinutes: 60 } };
    let dialog = document.querySelector("#routine-dialog");
    if (!dialog) { dialog = document.createElement("dialog"); dialog.id = "routine-dialog"; document.body.appendChild(dialog); }
    const s = r.schedule;
    // Every N hours is Every N minutes in whole hours, as the label reads it.
    const kind = s.kind === "every" && s.intervalMinutes % 60 === 0 ? "hours" : s.kind;
    const botOptions = state.bots.map((b) => `<option value="${esc(b.id)}"${b.id === r.target ? " selected" : ""}>${esc(b.name)}${b.enabled === false ? " (off)" : ""}</option>`).join("")
      + state.groups.filter((g) => g.head).map((g) => `<option value="group:${esc(g.id)}"${`group:${g.id}` === r.target ? " selected" : ""}>${esc(g.name)} (group chat)</option>`).join("");
    const kinds = [["daily", "Every day"], ["weekdays", "Weekdays"], ["weekly", "Weekly"], ["hourly", "Every hour"], ["every", "Every N minutes"], ["hours", "Every N hours"]];
    const time = `${String(s.hour).padStart(2, "0")}:${String(s.minute).padStart(2, "0")}`;
    dialog.innerHTML = `<form method="dialog" class="rt-form"><h2>${isNew ? "New routine" : "Edit routine"}</h2>`
      + `<label>Name <input name="name" maxlength="80" placeholder="Name (Morning inbox, Weekly report…)" value="${esc(r.name)}"></label>`
      + `<label>Who runs it <select name="target">${botOptions}</select></label>`
      + `<label>Instruction <textarea name="do" rows="4" maxlength="8000" placeholder="Sum up what needs a reply in my inbox">${esc(r.instruction)}</textarea></label>`
      + `<div class="rt-when-h">When to run</div><div class="rt-sched"><select name="kind" aria-label="How often">${kinds.map(([k, w]) => `<option value="${k}"${k === kind ? " selected" : ""}>${w}</option>`).join("")}</select>`
      + `<select name="weekday" aria-label="Day">${DAYS.map((d, i) => `<option value="${i + 1}"${i + 1 === s.weekday ? " selected" : ""}>${d}</option>`).join("")}</select>`
      + `<input name="time" type="time" value="${time}" aria-label="Time">`
      + `<span class="rt-minute">at :<input name="minute" type="number" min="0" max="59" step="5" value="${s.minute}" aria-label="Minute"></span>`
      + `<span class="rt-every">every <input name="interval" type="number" min="5" max="1440" step="5" value="${s.intervalMinutes}" aria-label="Minutes"> min</span>`
      + `<span class="rt-hours">every <input name="hours" type="number" min="1" max="24" step="1" value="${Math.max(1, Math.round(s.intervalMinutes / 60))}" aria-label="Hours"> h</span></div>`
      + `<div class="rt-label muted"></div>`
      + `<label class="rt-on"><input type="checkbox" name="on"${r.paused ? "" : " checked"}> On <small>A routine that's off keeps its runs and waits.</small></label>`
      + `<div class="rt-problem"></div>`
      + `<menu><button value="cancel" class="btn" formnovalidate>Cancel</button><button value="ok" class="btn pri" data-rt-save>${isNew ? "Add routine" : "Save"}</button></menu></form>`;
    const form = dialog.querySelector("form");
    const read = () => {
      const f = new FormData(form);
      const k = f.get("kind");
      const [hour, minute] = String(f.get("time") || "9:00").split(":").map(Number);
      const schedule = { kind: k === "hours" ? "every" : k, hour: hour || 0, minute: minute || 0, weekday: Number(f.get("weekday")) || 2, intervalMinutes: Number(f.get("interval")) || 60 };
      if (k === "hourly") schedule.minute = Math.max(0, Math.min(59, Number(f.get("minute")) || 0));
      if (k === "hours") schedule.intervalMinutes = Math.max(1, Math.min(24, Number(f.get("hours")) || 1)) * 60;
      return { k, schedule, name: String(f.get("name") || ""), target: String(f.get("target") || ""), instruction: String(f.get("do") || ""), on: f.get("on") === "on" };
    };
    const update = () => {
      const v = read();
      const show = (sel, yes) => { form.querySelector(sel).style.display = yes ? "" : "none"; };
      show("[name=weekday]", v.k === "weekly");
      show("[name=time]", ["daily", "weekdays", "weekly"].includes(v.k));
      show(".rt-minute", v.k === "hourly");
      show(".rt-every", v.k === "every");
      show(".rt-hours", v.k === "hours");
      form.querySelector(".rt-label").textContent = label(v.schedule);
      form.querySelector("[data-rt-save]").disabled = !v.instruction.trim() || !v.target;
    };
    form.oninput = update; form.onchange = update;
    update();
    form.onsubmit = async (e) => {
      if (e.submitter && e.submitter.value === "cancel") return;
      e.preventDefault();
      const v = read();
      const answer = await invoke({ cmd: "routineSave", id: routine ? routine.id : undefined, name: v.name, target: v.target, do: v.instruction, schedule: v.schedule, paused: !v.on });
      if (!answer.ok) { form.querySelector(".rt-problem").textContent = answer.error; return; }
      dialog.close();
      sigs.routines = null;
      if (view.kind === "routines") render(); else sigs.home = null;
    };
    dialog.showModal();
    form.querySelector(isNew ? "[name=do]" : "[name=name]").focus();
  }

  return { render, edit, label };
})();
