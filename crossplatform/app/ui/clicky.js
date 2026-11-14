// Settings › Clicky: on or off, the push-to-talk chord, when the spark shows, Clicky's brain and model, its voice, and a
// "Try it" box that runs a whole turn (screenshots, spark, bubble, voice) from typed words. It fills #settings-clicky, the place
// Settings (settings.js) keeps for it, each time the page is drawn ("theo-settings"). Everything goes through `control` (theo-core clicky/mod.rs).
(function () {
  "use strict";
  const call = (cmd) => window.__TAURI__.core.invoke("control", { cmd });
  const escape = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const set = (key, value) => call({ cmd: "setSetting", key, value });
  // The chords theo-voice's hook knows (hotkey.rs `Chord`), Clicky's default first.
  const CHORDS = [["ctrlAlt", "Ctrl + Alt"], ["ctrlShift", "Ctrl + Shift"], ["altShift", "Alt + Shift"], ["winAlt", "Win + Alt"], ["ctrlAltSpace", "Ctrl + Alt + Space"], ["ctrlShiftSpace", "Ctrl + Shift + Space"]];

  const style = document.createElement("style");
  style.textContent = "#settings-clicky select, #settings-clicky input[type=text] { background: var(--card2); color: var(--t1); border: 1px solid var(--line); border-radius: 8px; padding: 7px 9px; font: 14px var(--body); max-width: 260px; }"
    + "#settings-clicky .try { display: flex; gap: 8px; align-items: center; } #settings-clicky .try input { flex: 1; max-width: none; }"
    + "#settings-clicky .answer { white-space: pre-wrap; } #settings-clicky .crow .act select { width: 220px; }";
  document.head.appendChild(style);

  let voices = null;
  let drawing = false;

  function row(title, detail, action) {
    return `<div class="crow"><span class="tx"><b>${title}</b><small style="white-space:normal">${detail}</small></span><span class="act many">${action}</span></div>`;
  }

  async function brainOptions(current) {
    const r = await call({ cmd: "brains" });
    const b = r.ok ? r.result : { agents: [], apis: [] };
    const options = [`<option value="">Automatic (the first that works here)</option>`];
    for (const a of b.apis.filter((x) => x.hasKey || x.keyless)) options.push(`<option value="${escape(a.engine)}"${a.engine === current ? " selected" : ""}>${escape(a.label)}${a.keyless ? " (on this computer)" : " (API key)"}</option>`);
    for (const a of b.agents.filter((x) => x.installed)) options.push(`<option value="${escape(a.id)}"${a.id === current ? " selected" : ""}>${escape(a.label)}${a.ready ? "" : " (signed out)"}</option>`);
    return options.join("");
  }

  async function draw(box) {
    if (drawing) return;
    drawing = true;
    try {
      const r = await call({ cmd: "clickyState" });
      if (!r.ok) { box.innerHTML = `<p class="muted">${escape(r.error)}</p>`; return; }
      const s = r.result;
      const using = s.using;
      const sees = using ? (using.seesScreen ? "sees your screen" : "can't see your screen on this brain, so it answers from your words") : "";
      const usingLine = using ? `Thinking with ${escape(using.label)}${using.automatic ? " (automatic)" : ""}; ${sees}.` : "No brain yet: add an API key or sign in to an agent above.";
      const chordName = (CHORDS.find(([id]) => id === s.shortcut) || CHORDS[0])[1];
      const ptt = s.desktop && s.desktop.pushToTalk;
      const hookLine = !s.on ? "" : ptt && ptt.sameChordAsDictation ? ` Dictation uses ${escape(chordName)} too: pick other keys for one of them.` : ptt && ptt.listening ? ` Listening for ${escape(chordName)}.` : ptt && ptt.hook && ptt.hook.problem ? ` The keyboard hook isn't running: ${escape(ptt.hook.problem)}` : "";
      const brainSelect = `<select id="clicky-brain" aria-label="Clicky's brain">${await brainOptions(s.brain)}</select>`;
      const voiceOptions = (voices || []).map((v) => `<option value="${escape(v.name)}"${v.name === s.voice ? " selected" : ""}>${escape(v.name)}${v.language ? ` · ${escape(v.language)}` : ""}</option>`).join("");
      // Settings' own "Clicky is off · Turn on" line (settings.js) stands in for this switch while Clicky is off.
      const switchHere = s.on || typeof productIsOn !== "function";
      box.innerHTML = `<div class="list">`
        + row("Clicky", `Hold ${escape(chordName)} anywhere, ask about what's on your screen, and let go. Clicky answers in a bubble by the cursor, out loud, and points at things with its spark. Esc stops it.${hookLine}`,
          switchHere ? `${TP.pill(s.on ? "ok" : "none", s.on ? "On" : "Off")}<button class="btn sm" id="clicky-on">${s.on ? "Turn off" : "Turn on"}</button>` : "")
        + row("Shortcut", "Hold these keys to talk to Clicky. Dictation uses its own.", `<select id="clicky-shortcut" aria-label="Clicky's shortcut">${CHORDS.map(([id, name]) => `<option value="${id}"${id === s.shortcut ? " selected" : ""}>${name}</option>`).join("")}</select>`)
        + row("Spark", "The orange spark by your cursor.", `<select id="clicky-spark" aria-label="When the spark shows"><option value="always"${s.spark !== "talking" ? " selected" : ""}>Always show it</option><option value="talking"${s.spark === "talking" ? " selected" : ""}>Only while talking</option></select>`)
        + row("Brain", usingLine, brainSelect)
        + row("Model", "Empty: the brain's own pick for Clicky (Sonnet on Claude Code, a model that sees pictures on a key).", `<input type="text" id="clicky-model" value="${escape(s.model)}" placeholder="Automatic" spellcheck="false" autocomplete="off"><datalist id="clicky-models"></datalist>`)
        + row("Voice", voices ? (voices.length ? "Windows' own voices. Add more in Windows Settings › Time & language › Speech." : "No voices were found on this computer.") : "Looking for voices…",
          `<select id="clicky-voice" aria-label="Clicky's voice"><option value="">The computer's default</option>${voiceOptions}</select><button class="btn sm" id="clicky-hear">Hear it</button>`)
        + `<div class="crow"><span class="tx" style="flex:1"><b>Try it</b><small style="white-space:normal">Type what you'd say. Clicky looks at your screens and answers the way it does when you talk.</small>`
        + `<div class="try" style="margin-top:6px"><input type="text" id="clicky-try" placeholder="where's the search box?" autocomplete="off"><button class="btn pri sm" id="clicky-ask">Ask</button><button class="btn sm ghost" id="clicky-stop">Stop</button></div>`
        + `<small id="clicky-result" class="answer"></small></span></div>`
        + `</div>`;
      box.querySelector("#clicky-model").setAttribute("list", "clicky-models");
      // Through the products module (products.js) when it's there, so the sidebar and Settings › Products follow.
      if (switchHere) box.querySelector("#clicky-on").onclick = async () => {
        if (typeof setProduct === "function") await setProduct("clicky", !s.on); else await set("products.clicky", !s.on);
        if (typeof renderSettingsPage === "function" && document.getElementById("set-clicky")) renderSettingsPage(); else draw(box);
      };
      box.querySelector("#clicky-shortcut").onchange = async (e) => { await set("clicky.shortcut", e.target.value); setTimeout(() => draw(box), 1500); };
      box.querySelector("#clicky-spark").onchange = (e) => set("clicky.spark", e.target.value);
      box.querySelector("#clicky-brain").onchange = async (e) => { await set("clicky.brain", e.target.value || null); await set("clicky.model", null); draw(box); };
      box.querySelector("#clicky-model").onchange = (e) => set("clicky.model", e.target.value.trim() || null);
      box.querySelector("#clicky-voice").onchange = (e) => set("clicky.voice", e.target.value || null);
      box.querySelector("#clicky-hear").onclick = () => call({ cmd: "clickySpeak", text: "hi, i'm clicky. hold the keys and ask me anything about your screen." });
      const ask = async () => {
        const text = box.querySelector("#clicky-try").value.trim();
        if (!text) return;
        const result = box.querySelector("#clicky-result");
        result.textContent = "Asking…";
        const answer = await call({ cmd: "clickyAsk", text });
        if (!answer.ok) { result.textContent = answer.error; return; }
        if (answer.result.started === false) { result.textContent = answer.result.why; return; }
        // In the app the answer shows by the cursor; it's echoed here once it's in.
        for (let i = 0; i < 240; i++) {
          await new Promise((done) => setTimeout(done, 500));
          const st = await call({ cmd: "clickyOverlay" });
          const d = st.ok && st.result;
          if (!d) break;
          if (d.lastError && d.lastTranscript === text) { result.textContent = d.lastError; return; }
          if (d.lastPlan && d.lastTranscript === text && d.lastPlan.answer !== undefined && d.phase !== "thinking") { result.textContent = `${d.lastPlan.speech} (${d.lastPlan.brain}, ${d.lastPlan.seconds}s)`; return; }
        }
      };
      box.querySelector("#clicky-ask").onclick = ask;
      box.querySelector("#clicky-try").onkeydown = (e) => { if (e.key === "Enter") ask(); };
      box.querySelector("#clicky-stop").onclick = () => call({ cmd: "clickyStop" });
      // The model list for a key.
      const engine = s.brain || (using ? using.engine : "");
      if (engine.startsWith("api:")) {
        call({ cmd: "apiModels", provider: engine.slice(4) }).then((m) => {
          const list = box.querySelector("#clicky-models");
          if (m.ok && list) list.innerHTML = m.result.models.map((id) => `<option value="${escape(id)}">`).join("");
        });
      }
      if (voices === null) {
        call({ cmd: "clickyVoices" }).then((v) => { voices = v.ok ? v.result.voices : []; drawing = false; draw(box); });
      }
    } finally {
      drawing = false;
    }
  }

  // Settings (settings.js) draws the page whole each time and then fires "theo-settings" with where Clicky's part goes.
  function fill(selector) {
    const box = document.querySelector(selector || "#settings-clicky");
    if (!box || box.dataset.clickyDrawn) return;
    box.dataset.clickyDrawn = "1";
    drawing = false;
    draw(box);
  }
  document.addEventListener("theo-settings", (e) => fill(e.detail && e.detail.clicky));
  // Turned on or off from Settings › Products or Setup: redraw Clicky's part if it's showing.
  document.addEventListener("theo-products", () => {
    const box = document.getElementById("settings-clicky");
    if (box && box.dataset.clickyDrawn) draw(box);
  });
  fill();
})();
