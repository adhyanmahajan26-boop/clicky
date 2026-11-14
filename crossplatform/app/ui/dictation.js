// Dictation in the window: Settings › Dictation (the Mac's DictationSettingsView) and the chat composer's mic (the Mac's
// ComposerDictation). Everything goes through `control` like the rest of the UI: dictationStatus, dictationSet,
// dictationKeySet / dictationKeyRemove, composerDictation {action}. Loaded after settings.js; it fills the Settings page's
// #settings-dictation each time the page is drawn (the "theo-settings" event).
(() => {
  const call = (cmd) => window.__TAURI__.core.invoke("control", { cmd });
  const escape = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const pill = (state, text) => (window.TP && TP.pill ? TP.pill(state, text) : `<span class="pill">${escape(text)}</span>`);
  const keyCaps = (keys) => (keys || []).map((key) => `<kbd class="dict-key">${escape(key)}</kbd>`).join(" + ");
  const KEY_NAMES = { sarvam: "Sarvam", openai: "OpenAI", groq: "Groq", deepgram: "Deepgram", assemblyai: "AssemblyAI" };
  const KEY_HINTS = {
    sarvam: "Indian languages and Hinglish (Saaras)",
    openai: "gpt-4o-transcribe; the same key bots can use",
    groq: "Whisper, very fast; the same key bots can use",
    deepgram: "Nova-3",
    assemblyai: "Universal",
  };
  let status = null;

  async function loadStatus(slow) {
    const answer = await call({ cmd: "dictationStatus", slow: !!slow }).catch(() => null);
    if (answer && answer.ok) status = answer.result;
    updateComposerMic();
    return status;
  }

  const set = async (key, value) => {
    const answer = await call({ cmd: "dictationSet", key, value });
    if (!answer.ok) alert(answer.error);
    // Turning Dictation on or off is the same switch as Settings › Products.
    if (key === "on") await call({ cmd: "setSetting", key: "products.dictation", value: !!value }).catch(() => {});
    return answer.ok;
  };

  /* ---------------- Settings › Dictation ---------------- */

  function row(title, detail, right, extra = "") {
    return `<div class="crow ${extra}"><span class="tx"><b>${title}</b><small style="white-space:normal">${detail}</small></span>${right}</div>`;
  }

  function settingsHTML(s) {
    const chord = (s.chords || []).find((c) => c.id === s.chord) || { title: s.chordTitle, keys: [] };
    const onWindows = s.platform === "windows";
    const hook = s.hotkey || {};
    // The section's own title and subtitle are the Settings page's; this starts with the switch.
    let html = `<div class="list">`;
    html += row("Dictate anywhere", s.on ? `Hold ${keyCaps(chord.keys)} in any app, talk, then let go. Your words are tidied up and typed wherever the cursor is.` : "Dictation is off. It's a product of its own. Turn it on to use the shortcut and the chat box's mic.",
      `${pill(s.on ? "ok" : "none", s.on ? "On" : "Off")}<span class="act"><button class="btn sm" id="dict-on">${s.on ? "Turn off" : "Use Dictation"}</button></span>`);
    if (s.on && onWindows && !hook.dictationListening) {
      html += row("The shortcut isn't listening", escape(hook.problem || "Theo couldn't watch the keyboard. Quit Theo from the tray and open it again."), pill("needs", "Needs you"), "w-ask");
    } else if (s.on && !onWindows) {
      html += row("The shortcut", "Holding a chord to talk works on Windows in this build. The chat box's mic and the test below work here when there's a microphone.", pill("none", "Windows only"));
    }
    const chordOptions = (s.chords || []).map((c) => `<option value="${escape(c.id)}"${c.id === s.chord ? " selected" : ""}>${escape(c.title)}</option>`).join("");
    const clash = s.chord === "ctrlAlt" ? " That's Clicky's push-to-talk too: pick another so the two never overlap." : " Clicky's push-to-talk stays on Ctrl + Alt; the two never overlap.";
    html += row("Shortcut", `Fn never reaches Windows, so the Mac's Control + Fn is ${keyCaps(["Ctrl", "Win"])} here.${clash}`, `<span class="act many"><select id="dict-chord" aria-label="Shortcut">${chordOptions}</select></span>`);
    const mics = s.microphones || [];
    const micOptions = [`<option value="">Windows' default${s.defaultMicrophone ? ` (${escape(s.defaultMicrophone)})` : ""}</option>`]
      .concat(mics.map((m) => `<option value="${escape(m)}"${m === s.microphone ? " selected" : ""}>${escape(m)}</option>`)).join("");
    html += row("Microphone", mics.length || !onWindows ? "Theo never asks for the mic: if Windows' microphone privacy switch is off, the pill says where it is." : "No microphone found. Plug one in.", `<span class="act many"><select id="dict-mic" aria-label="Microphone">${micOptions}</select></span>`);
    html += `</div>`;

    // Hears you with
    const engines = s.engines || [];
    const engineOptions = engines.map((e) => `<option value="${escape(e.id)}"${e.id === s.engine ? " selected" : ""}>${escape(e.title)}${e.id !== "auto" && !e.ready ? (e.key ? " (no key yet)" : " (not on this computer)") : ""}</option>`).join("");
    const listening = (s.wouldListen || []).map((id) => (engines.find((e) => e.id === id) || { title: id }).title);
    const hears = s.nothingCanListen ? escape(s.nothingCanListen) : `Listens with ${escape(listening[0] || "")}${listening.length > 1 ? `, and if that can't be reached, ${escape(listening.slice(1).join(", then "))}` : ""}.`;
    html += `<h2>Hears you with</h2><div class="list">`;
    html += row("Recognizer", `${hears} Windows' own speech recognizer needs no key and works offline, in the languages this PC has speech for.`, `<span class="act many"><select id="dict-engine" aria-label="Recognizer">${engineOptions}</select></span>`);
    for (const engine of engines.filter((e) => e.key)) {
      const id = engine.key;
      html += row(KEY_NAMES[id] || id, `${escape(KEY_HINTS[id] || "")}. The key stays in Windows' Credential Manager.`,
        `${pill(engine.hasKey ? "ok" : "none", engine.hasKey ? "Key saved" : "No key")}<span class="act many dict-keyrow"><input type="password" autocomplete="off" spellcheck="false" placeholder="Paste a key" data-key="${escape(id)}" aria-label="${escape(KEY_NAMES[id] || id)} key">`
        + `<button class="btn sm" data-save="${escape(id)}">Save</button>${engine.hasKey ? `<button class="btn sm" data-remove="${escape(id)}">Remove</button>` : ""}</span>`);
    }
    const languageOptions = (s.languages || []).map((l) => `<option value="${escape(l.id)}"${l.id === s.language ? " selected" : ""}>${escape(l.title)}</option>`).join("");
    html += row("Language", "Detect it lets the service work out the language. Windows' recognizer uses this PC's own language then.", `<span class="act many"><select id="dict-language" aria-label="Language">${languageOptions}</select></span>`);
    html += `</div>`;

    // Clean-up
    const brain = s.cleanup ? (s.cleanupBrain ? `Tidies with ${escape(s.cleanupBrain)}.` : escape(s.cleanupNote || "")) : "";
    html += `<h2>Clean-up</h2><div class="list">`;
    html += row("Tidy up with a fast model", `Small filler words like “um” always go, even with this off. ${brain}`, `${pill(s.cleanup ? "ok" : "none", s.cleanup ? "On" : "Off")}<span class="act"><button class="btn sm" id="dict-cleanup">${s.cleanup ? "Turn off" : "Turn on"}</button></span>`);
    html += `<div class="crow dict-words"><span class="tx"><b>Your words</b><small style="white-space:normal">Names and terms it should always get right. To fix something it keeps mishearing, write it as heard = written.</small>`
      + `<textarea id="dict-dictionary" rows="3" spellcheck="false" placeholder="Sarvam, or theo klicky = Theo Clicky">${escape(s.dictionary || "")}</textarea></span></div>`;
    html += `</div>`;

    // Test
    const last = s.last || {};
    const lastLine = last.engine ? `Last time: heard by ${escape(last.engine)}${last.cleanup ? `, clean-up ${escape(last.cleanup)}` : ""}${last.totalSeconds ? `, ${Number(last.totalSeconds).toFixed(1)} s` : ""}${last.method ? `, ${escape(last.method === "paste" ? "pasted" : "typed")}` : ""}.` : (last.problem ? `Last time: ${escape(last.problem)}` : "");
    html += `<h2>Test dictation</h2><div class="list"><div class="crow dict-test"><span class="tx"><b>Try it here</b><small style="white-space:normal">${s.on && onWindows ? `Click in the box, hold ${keyCaps(chord.keys)} and talk, then let go. Or press Record, talk, and press Stop.` : "Press Record, talk, then press Stop."} ${lastLine}</small>`
      + `<textarea id="dict-test" rows="3" placeholder="Your words land here"></textarea><span class="dict-test-bar"><button class="btn sm" id="dict-record">Record</button><span id="dict-test-note" class="muted"></span></span></span></div></div>`;
    return html;
  }

  function wire(box) {
    const redraw = async (slow) => { await loadStatus(slow); fill(box, true); };
    const on = box.querySelector("#dict-on");
    if (on) on.onclick = async () => { await set("on", !status.on); redraw(false); };
    const bind = (selector, key) => { const el = box.querySelector(selector); if (el) el.onchange = async (e) => { await set(key, e.target.value); redraw(key === "engine"); }; };
    bind("#dict-chord", "chord"); bind("#dict-mic", "microphone"); bind("#dict-engine", "engine"); bind("#dict-language", "language");
    const cleanup = box.querySelector("#dict-cleanup");
    if (cleanup) cleanup.onclick = async () => { await set("cleanup", !status.cleanup); redraw(true); };
    const dictionary = box.querySelector("#dict-dictionary");
    let saving = null;
    if (dictionary) dictionary.oninput = (e) => { clearTimeout(saving); saving = setTimeout(() => set("dictionary", e.target.value), 500); };
    box.querySelectorAll("[data-save]").forEach((button) => button.onclick = async () => {
      const id = button.dataset.save;
      const input = box.querySelector(`input[data-key="${id}"]`);
      const key = input ? input.value.trim() : "";
      if (!key) return;
      const answer = await call({ cmd: "dictationKeySet", provider: id, key });
      if (!answer.ok) alert(answer.error);
      redraw(true);
    });
    box.querySelectorAll("[data-remove]").forEach((button) => button.onclick = async () => { await call({ cmd: "dictationKeyRemove", provider: button.dataset.remove }); redraw(true); });
    const record = box.querySelector("#dict-record");
    const testBox = box.querySelector("#dict-test");
    const note = box.querySelector("#dict-test-note");
    if (record) record.onclick = async () => {
      if (session.target === testBox) { await stopDictating(); record.textContent = "Record"; return; }
      note.textContent = "";
      const started = await startDictating(testBox, (message) => { note.textContent = message; record.textContent = "Record"; });
      if (started) record.textContent = "Stop";
    };
  }

  function fill(box, force) {
    if (!status || (!force && box.dataset.filled === "1")) return;
    box.dataset.filled = "1";
    box.innerHTML = settingsHTML(status);
    wire(box);
  }

  /** settings.js draws the page with an empty #settings-dictation and fires "theo-settings"; this fills it each time. */
  function watchSettings() {
    document.addEventListener("theo-settings", (event) => {
      const box = document.querySelector((event.detail && event.detail.dictation) || "#settings-dictation");
      if (!box || box.dataset.loading === "1") return;
      box.dataset.loading = "1";
      loadStatus(true).then(() => {
        box.dataset.loading = "";
        if (!box.isConnected || !status) return;
        // The first row here is Dictation's own on/off switch, so the page's "Dictation is off · Turn on" line goes.
        const productOff = box.parentNode && box.parentNode.querySelector('[data-turn-on="dictation"]');
        const productLine = productOff && productOff.closest(".list");
        if (productLine) productLine.remove();
        fill(box, true);
      });
    });
  }

  /* ---------------- dictating into a text box (the composer, the test box) ---------------- */

  const session = { target: null, timer: null, onProblem: null };

  function insertAtCursor(target, text) {
    if (!text) return;
    const start = target.selectionStart ?? target.value.length;
    const end = target.selectionEnd ?? start;
    const before = target.value.slice(0, start);
    const after = target.value.slice(end);
    const spaceBefore = before && !/\s$/.test(before) ? " " : "";
    const spaceAfter = after && !/^\s/.test(after) ? " " : "";
    target.value = before + spaceBefore + text + spaceAfter + after;
    const cursor = (before + spaceBefore + text).length;
    target.setSelectionRange(cursor, cursor);
    target.dispatchEvent(new Event("input", { bubbles: true }));
    target.focus();
  }

  function showListening(on, level) {
    const mic = document.getElementById("dict-mic-button");
    if (mic && session.target && session.target.id === "input") {
      mic.classList.toggle("on", on);
      mic.style.setProperty("--level", String(Math.max(0, Math.min(1, level || 0))));
      mic.setAttribute("aria-label", on ? "Stop dictating" : "Dictate");
      mic.title = on ? "Stop and keep the words (Enter). Esc cancels." : "Dictate (Ctrl+Shift+D)";
    }
    if (session.target) session.target.classList.toggle("dict-listening", on);
  }

  async function startDictating(target, onProblem) {
    if (session.target) return false;
    const answer = await call({ cmd: "composerDictation", action: "start" }).catch((e) => ({ ok: false, error: String(e) }));
    if (!answer.ok) { onProblem(answer.error || "The microphone didn't start."); return false; }
    session.target = target;
    session.onProblem = onProblem;
    showListening(true, 0);
    session.timer = setInterval(async () => {
      const level = await call({ cmd: "composerDictation", action: "level" }).catch(() => null);
      if (level && level.ok && level.result.listening) showListening(true, level.result.level);
    }, 100);
    return true;
  }

  async function stopDictating() {
    const target = session.target;
    if (!target) return;
    clearInterval(session.timer);
    target.classList.add("dict-writing");
    showListening(false, 0);
    const answer = await call({ cmd: "composerDictation", action: "stop" }).catch((e) => ({ ok: false, error: String(e) }));
    target.classList.remove("dict-writing", "dict-listening");
    const onProblem = session.onProblem;
    session.target = null;
    // Never sent: the words wait in the box.
    if (answer.ok) insertAtCursor(target, answer.result.text);
    else if (onProblem) onProblem(answer.error);
  }

  async function cancelDictating() {
    if (!session.target) return;
    clearInterval(session.timer);
    showListening(false, 0);
    session.target.classList.remove("dict-listening");
    session.target = null;
    await call({ cmd: "composerDictation", action: "cancel" }).catch(() => {});
  }

  function composerProblem(message) {
    const input = document.getElementById("input");
    if (!input) return;
    const old = input.placeholder;
    input.placeholder = message;
    setTimeout(() => { input.placeholder = old; }, 5000);
  }

  function addComposerMic() {
    const composer = document.getElementById("composer");
    const send = document.getElementById("send");
    if (!composer || !send || document.getElementById("dict-mic-button")) return;
    const mic = document.createElement("button");
    mic.type = "button";
    mic.id = "dict-mic-button";
    mic.className = "dict-mic";
    mic.hidden = true;
    mic.setAttribute("aria-label", "Dictate");
    mic.title = "Dictate (Ctrl+Shift+D)";
    mic.innerHTML = '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><rect x="9" y="3" width="6" height="12" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/></svg>';
    composer.insertBefore(mic, send);
    mic.onclick = async () => {
      const input = document.getElementById("input");
      if (session.target === input) return stopDictating();
      if (session.target) return;
      await startDictating(input, composerProblem);
    };
    // While dictating: Enter keeps the words (never sends), Esc cancels. Ctrl+Shift+D starts and stops.
    document.addEventListener("keydown", (event) => {
      const input = document.getElementById("input");
      if (session.target && (session.target === document.activeElement || session.target === input)) {
        if (event.key === "Enter") { event.preventDefault(); event.stopImmediatePropagation(); stopDictating(); return; }
        if (event.key === "Escape") { event.preventDefault(); event.stopImmediatePropagation(); cancelDictating(); return; }
      }
      if (event.ctrlKey && event.shiftKey && (event.key === "D" || event.key === "d") && !mic.hidden && composer.style.display !== "none") {
        event.preventDefault();
        mic.click();
      }
    }, true);
  }

  function updateComposerMic() {
    const mic = document.getElementById("dict-mic-button");
    if (mic) mic.hidden = !(status && status.on);
  }

  function addStyles() {
    const style = document.createElement("style");
    style.textContent = `
      .dict-mic { width: 28px; height: 28px; border-radius: 14px; display: inline-flex; align-items: center; justify-content: center; color: var(--t2); flex: none; position: relative; }
      .dict-mic:hover { background: rgba(255,255,255,.07); color: var(--t1); }
      .on-light .dict-mic:hover { background: rgba(0,0,0,.05); }
      .dict-mic.on { color: var(--acc-ink); background: var(--acc); box-shadow: 0 0 0 calc(2px + var(--level, 0) * 6px) rgba(255,122,69,.28); transition: box-shadow .08s linear; }
      #input.dict-listening::placeholder, .dict-listening::placeholder { color: var(--acc); }
      .dict-writing { opacity: .7; }
      .dict-key { font: 500 11px/1 var(--mono); padding: 2px 5px; border: 1px solid var(--line2); border-radius: 5px; background: var(--card2); color: var(--t1); }
      .dict-keyrow input { width: 170px; background: var(--card2); color: var(--t1); border: 1px solid var(--line); border-radius: 8px; padding: 6px 8px; font: 13px var(--body); }
      .dict-words textarea, .dict-test textarea { display: block; width: 100%; margin-top: 8px; background: var(--card2); color: var(--t1); border: 1px solid var(--line); border-radius: 8px; padding: 8px 10px; font: 14px/1.5 var(--body); resize: vertical; box-sizing: border-box; }
      .dict-test .tx { display: flex; flex-direction: column; }
      .dict-test-bar { display: flex; align-items: center; gap: 10px; margin-top: 8px; }
      #settings-dictation select { background: var(--card2); color: var(--t1); border: 1px solid var(--line); border-radius: 8px; padding: 6px 8px; font: 13px var(--body); max-width: 260px; }
      @media (prefers-reduced-motion: reduce) { .dict-mic.on { transition: none; } }
    `;
    document.head.appendChild(style);
  }

  if (!window.__TAURI__) return;
  addStyles();
  addComposerMic();
  watchSettings();
  loadStatus(false);
  // Setup and Settings › Products may turn Dictation on or off: the mic follows within a few seconds.
  setInterval(() => { if (!session.target) loadStatus(false); }, 5000);
})();
