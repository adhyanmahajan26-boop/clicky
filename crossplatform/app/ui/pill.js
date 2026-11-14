// Dictation's pill. The app sends its state as a "dictation-pill" event ({phase, levels, words, message, chord}); a pill
// that has just opened asks for the latest with dictationPillState. It never takes clicks or focus.
const BAR_COUNT = 18;
const pill = document.getElementById("pill");
const wave = document.getElementById("wave");
const icon = document.getElementById("icon");
const label = document.getElementById("label");
const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const ICONS = {
  listening: '<svg viewBox="0 0 24 24" fill="#FF8A5B"><rect x="9" y="3" width="6" height="12" rx="3"/><path d="M5 11a7 7 0 0 0 14 0" stroke="#FF8A5B" stroke-width="2" fill="none" stroke-linecap="round"/><path d="M12 18v3" stroke="#FF8A5B" stroke-width="2" stroke-linecap="round"/></svg>',
  transcribing: '<span class="spin"></span>',
  typed: '<svg viewBox="0 0 24 24" fill="none" stroke="#6EE7A0" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>',
  failed: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="10" fill="#FBBF24"/><path d="M12 7v6M12 16.5v.5" stroke="#17181C" stroke-width="2.4" stroke-linecap="round"/></svg>',
};

wave.innerHTML = "<i></i>".repeat(BAR_COUNT);
const bars = Array.from(wave.children);

function draw(state) {
  const phase = (state && state.phase) || "idle";
  pill.hidden = phase === "idle";
  pill.className = "pill " + phase;
  icon.innerHTML = ICONS[phase] || "";
  if (phase === "listening") {
    const levels = (state.levels || []).slice(-BAR_COUNT);
    bars.forEach((bar, index) => {
      const level = Math.max(0, Math.min(1, levels[index] || 0));
      bar.style.height = `${Math.round(3 + level * 19)}px`;
    });
  } else if (phase === "transcribing") {
    label.textContent = "Transcribing";
  } else if (phase === "typed") {
    label.innerHTML = state.words ? `Typed <span class="words">· ${esc(state.words)}</span>` : "Typed";
  } else if (phase === "failed") {
    label.textContent = state.message || "Didn't catch that";
  }
}

if (window.__TAURI__) {
  window.__TAURI__.event.listen("dictation-pill", (event) => draw(event.payload));
  window.__TAURI__.core.invoke("control", { cmd: { cmd: "dictationPillState" } }).then((answer) => answer && answer.ok && draw(answer.result)).catch(() => {});
}
