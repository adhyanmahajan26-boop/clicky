// Updates: the Update row that's always at the bottom of the sidebar, and Settings › Updates (the Mac's
// Setup/UpdateButton.swift and UpdatesSettingsContent). One click checks; when a newer build is out the row says so and the
// same click installs it: Theo downloads it, checks it against the release's SHA256SUMS, quits, updates itself and reopens,
// keeping bots, chats and settings. The engine half is theo-core update.rs, the install is the app's updater.rs.
const Updates = { state: null, busy: false, error: "" };

async function loadUpdates(action, extra) {
  let r = null;
  try { r = await invoke(Object.assign({ cmd: "updates", action: action || "state" }, extra || {})); } catch (e) { console.error(e); }
  if (r && r.ok) { Updates.state = r.result; Updates.error = ""; }
  else if (r && !r.ok) Updates.error = r.error;
  drawUpdateRow(); drawUpdatesSettings();
  return r;
}

function updateHas(u) { return !!(u && u.available && u.state !== "upToDate"); }
function updateBusy(u) { return Updates.busy || (u && (u.state === "checking" || u.state === "installing")); }

// The few words on the right of the sidebar row.
function updateShortStatus(u) {
  if (Updates.busy && u && u.state !== "installing") return "Checking…";
  switch (u && u.state) {
    case "checking": return "Checking…";
    case "upToDate": return "Up to date";
    case "available": return `Build ${u.available.build}`;
    case "installing": return "Installing…";
    case "failed": return updateHas(u) ? `Build ${u.available.build}` : "Try again";
    default: return "Check";
  }
}

function updateHelp(u) {
  if (!u) return "Check for a newer build of Theo";
  switch (u.state) {
    case "idle": return `Check for a newer build of Theo (${u.label})`;
    case "upToDate": return `You have the newest build (${u.label}). Click to check again.`;
    case "available": return "A newer build is ready. Theo quits, updates itself and reopens, keeping your bots, chats and settings.";
    default: return u.message || "";
  }
}

const UPDATE_ICON = `<svg class="ic" viewBox="0 0 24 24"><circle cx="12" cy="12" r="8.5"/><path d="M12 7.5v8M8.5 12.5l3.5 3.5 3.5-3.5"/></svg>`;

function drawUpdateRow() {
  const row = document.getElementById("update-row");
  if (!row) return;
  const u = Updates.state, has = updateHas(u);
  row.classList.toggle("has-update", has);
  row.disabled = !!updateBusy(u);
  row.title = updateHelp(u);
  row.innerHTML = `${UPDATE_ICON}<span class="ur-name">${has ? "Update Theo" : "Updates"}</span><span class="ur-st">${esc(updateShortStatus(u))}</span>`;
}

async function updateTapped() {
  const u = Updates.state;
  if (updateBusy(u)) return;
  if (updateHas(u)) return installUpdate();
  Updates.busy = true; drawUpdateRow();
  await loadUpdates("check");
  Updates.busy = false; drawUpdateRow();
}

// Hands over to the app: it downloads, checks the checksum, runs the installer and quits. A test profile records it instead.
async function installUpdate() {
  if (Updates.state) Updates.state = Object.assign({}, Updates.state, { state: "installing", message: `Downloading build ${Updates.state.available.build}…` });
  drawUpdateRow(); drawUpdatesSettings();
  try { await window.__TAURI__.core.invoke("install_update"); }
  catch (e) { Updates.error = String(e && e.message ? e.message : e); }
  await loadUpdates("state");
}

/* ---------------- Settings › Updates ---------------- */
// Words for where the token is kept, by platform.
function tokenStoreWords() { return /win/i.test(navigator.platform || navigator.userAgent) ? "the Credential Manager" : "a file only you can read"; }

function updatesSettingsHTML() {
  const u = Updates.state;
  if (!u) return `<div class="pills">${TP.pill("checking", "Checking")}</div>`;
  const has = updateHas(u);
  const busy = updateBusy(u);
  const action = has
    ? `<button class="btn pri sm" data-update-install${busy ? " disabled" : ""}>${u.state === "installing" ? "Installing…" : `Update to build ${u.available.build}`}</button>`
    : `<button class="btn sm" data-update-check${busy ? " disabled" : ""}>${u.state === "checking" || Updates.busy ? "Checking…" : "Check for updates"}</button>`;
  const statusLine = Updates.error || u.message;
  const tone = u.state === "failed" || Updates.error ? " w-bad" : "";
  const where = {
    windowsForEveryone: "This Theo was installed for everyone on this PC from the .msi, so updating it needs an administrator: Update opens the releases page.",
    elsewhere: /linux/i.test(navigator.userAgent) ? "This Theo came from the .deb package (or was built by hand), so Update opens the releases page instead of replacing it." : "This copy of Theo wasn't put here by its installer, so Update opens the releases page.",
  }[u.installKind] || "";
  const notes = has && u.available.notes ? `<div class="crow"><span class="tx"><b>What's new in build ${u.available.build}</b><small style="white-space:pre-wrap">${esc(u.available.notes)}</small></span></div>` : "";
  return `<div class="list"><div class="crow"><span class="tx"><b>This is Theo ${esc(u.label)}</b><small class="${tone}" style="white-space:normal">${esc(statusLine)}</small></span><span class="act many">${action}</span></div>${notes}`
    + `<div class="crow"><span class="tx"><b>GitHub token</b><small style="white-space:normal">${u.hasToken ? `Saved in ${tokenStoreWords()}. Paste a new one to replace it.` : "Only for private updates: a GitHub token that can read the updates repo. Public builds need nothing here."}</small></span>`
    + `<span class="act many"><input id="update-token" type="password" autocomplete="off" spellcheck="false" placeholder="${u.hasToken ? "Saved" : "Token"}" aria-label="GitHub token"><button class="btn sm" data-update-token disabled>Save</button>${u.hasToken ? `<button class="btn sm ghost" data-update-token-remove>Remove</button>` : ""}</span></div>`
    + `<div class="crow"><span class="tx"><b>Where builds come from</b><small style="white-space:normal">${u.repo ? esc(u.repo) + "." : "This build doesn't say."} Theo checks when it starts and every 6 hours, and never installs by itself.</small></span><span class="act many">${u.repo ? `<button class="btn sm ghost" data-update-page>Releases page</button>` : ""}</span></div></div>`
    + (where ? `<p class="muted">${esc(where)}</p>` : "");
}

function drawUpdatesSettings() {
  const box = document.getElementById("settings-updates-body");
  if (!box) return;
  // Not while the token is being typed: the field would be wiped.
  if (box.contains(document.activeElement) && document.activeElement.id === "update-token") return;
  box.innerHTML = updatesSettingsHTML();
  const q = (s) => box.querySelector(s);
  if (q("[data-update-check]")) q("[data-update-check]").onclick = updateTapped;
  if (q("[data-update-install]")) q("[data-update-install]").onclick = installUpdate;
  if (q("[data-update-page]")) q("[data-update-page]").onclick = () => invoke({ cmd: "updates", action: "openPage" });
  if (q("[data-update-token-remove]")) q("[data-update-token-remove]").onclick = () => loadUpdates("removeToken");
  const field = q("#update-token"), save = q("[data-update-token]");
  field.oninput = () => (save.disabled = !field.value.trim());
  const saveToken = async () => {
    const token = field.value.trim();
    if (!token) return;
    field.value = ""; save.disabled = true; field.blur();
    Updates.busy = true; drawUpdatesSettings();
    await loadUpdates("token", { token });
    Updates.busy = false; drawUpdatesSettings(); drawUpdateRow();
  };
  save.onclick = saveToken;
  field.onkeydown = (e) => { if (e.key === "Enter") { e.preventDefault(); saveToken(); } };
}

window.TheoUpdates = { load: loadUpdates, html: updatesSettingsHTML, draw: drawUpdatesSettings };

(function () {
  const row = document.getElementById("update-row");
  if (row) row.onclick = updateTapped;
  loadUpdates("state");
  // The app checks by itself 20 seconds after it starts and every 6 hours; this only reads what it found.
  setInterval(() => { if (!Updates.busy) loadUpdates("state"); }, 15000);
})();
