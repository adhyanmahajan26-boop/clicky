// Theo, Clicky and Dictation: three products, each on or off (the Mac's Setup/TheoProductsView.swift; rules in theo-core
// products.rs). Setup's "Pick products" step and Settings › Products show the cards; a product that's off leaves the sidebar
// and its pages show a small "turned off" view. Other parts of the window read the choice with TheoProducts.isOn(id) and hear
// about changes through the "theo-products" event on document.
const Products = { list: null, on: { theo: true, clicky: false, dictation: false }, gateSig: null };

async function loadProducts() {
  try {
    const r = await invoke({ cmd: "products" });
    if (r && r.ok) { Products.list = r.result.products; Products.on = r.result.on; }
  } catch (e) { console.error(e); }
  applyProducts();
  return Products;
}

async function setProduct(id, on) {
  const r = await invoke({ cmd: "products", action: "set", product: id, on });
  if (r && r.ok) { Products.list = r.result.products; Products.on = r.result.on; }
  applyProducts();
  document.dispatchEvent(new CustomEvent("theo-products", { detail: Object.assign({}, Products.on) }));
  return r;
}

function productIsOn(id) { return !!Products.on[id]; }
function productTitle(id) { const p = (Products.list || []).find((x) => x.id === id); return p ? p.title : id.charAt(0).toUpperCase() + id.slice(1); }

// A product that's off leaves the sidebar: Theo's bots, groups, routines and usage go when Theo is off.
function applyProducts() {
  for (const id of ["theo", "clicky", "dictation"]) document.body.classList.toggle(`${id}-off`, !productIsOn(id));
  Products.gateSig = null;
  if (typeof view !== "undefined" && typeof open === "function" && productGateKinds(view)) open(view);
}

/* ---------------- the demos ---------------- */
// Short loops drawn with CSS (the Mac's ProductDemos.swift draws them in SwiftUI). They hold still with reduced motion.
function productDemoHTML(id) {
  if (id === "theo") {
    const crew = [["researcher", "Researcher", "Read 4 pages"], ["builder", "Builder", "Opened a draft PR"], ["editor", "Writer", "Drafted the post"]];
    return `<div class="demo demo-theo" aria-hidden="true">${crew.map(([who, name, done], i) => `<div class="dt-row dt-${i}">`
      + `<span class="dt-face">${TP.bot(TP.CREW[who], "awake", 26, { badge: false })}</span><span class="dt-tx"><b>${name}</b>`
      + `<span class="dt-st"><i class="dt-work">Working…</i><i class="dt-done">${done}</i></span></span><span class="dt-bar"><i></i></span></div>`).join("")}</div>`;
  }
  if (id === "clicky") {
    return `<div class="demo demo-clicky" aria-hidden="true"><div class="dc-win"><span class="dc-dots"><i></i><i></i><i></i></span>`
      + `<div class="dc-lines"><i></i><i></i><i></i></div><span class="dc-btn">Export</span><span class="dc-ring"></span></div>`
      + `<span class="dc-spark"></span><span class="dc-say">&ldquo;Click Export, top right.&rdquo;</span></div>`;
  }
  return `<div class="demo demo-dictation" aria-hidden="true"><div class="dd-field"><span class="dd-text">Lunch at one works, see you there.</span><span class="dd-caret"></span></div>`
    + `<div class="dd-mic"><span class="dd-dot"></span>Listening</div></div>`;
}

/* ---------------- the cards ---------------- */
function productSwitchHTML(id, on) {
  return `<button type="button" class="switch${on ? " on" : ""}" role="switch" aria-checked="${on}" data-product="${esc(id)}" aria-label="Use ${esc(productTitle(id))}"><i></i></button>`;
}

function productCardsHTML() {
  const list = Products.list || [];
  if (!list.length) return `<div class="pills">${TP.pill("checking", "Checking")}</div>`;
  return `<div class="product-cards">${list.map((p) => {
    const on = productIsOn(p.id);
    return `<div class="product-card${on ? " on" : ""}" data-card="${esc(p.id)}">${productDemoHTML(p.id)}<div class="pc-tx">`
      + `<div class="pc-head"><b>${esc(p.title)}</b>${productSwitchHTML(p.id, on)}</div>`
      + `<p>${esc(p.tagline)}</p><ul>${p.points.map((x) => `<li>${esc(x)}</li>`).join("")}</ul>`
      + (p.requirement ? `<small class="muted">${esc(p.requirement)}</small>` : "")
      + `<div class="pc-state">${on ? TP.pill("ok", "On") : TP.pill("none", "Off")}</div></div></div>`;
  }).join("")}</div>`;
}

// `after`: called once a switch has changed, to redraw what's around the cards.
function wireProductCards(root, after) {
  root.querySelectorAll("button.switch[data-product]").forEach((b) => b.onclick = async () => {
    b.disabled = true;
    await setProduct(b.dataset.product, !productIsOn(b.dataset.product));
    if (after) after(); else b.disabled = false;
  });
}

/* ---------------- while a product is off ---------------- */
function productOffHTML(id) {
  const p = (Products.list || []).find((x) => x.id === id) || { title: productTitle(id), tagline: "" };
  return `<div class="product-off">${productDemoHTML(id)}<h1>${esc(p.title)} is off</h1><p class="lead">${esc(p.tagline)}</p>`
    + `<div class="btns"><button class="btn pri" data-turn-on="${esc(id)}">Turn on ${esc(p.title)}</button><button class="btn ghost" data-all-products>See all products</button></div></div>`;
}

function wireProductOff(root) {
  root.querySelectorAll("[data-turn-on]").forEach((b) => b.onclick = () => setProduct(b.dataset.turnOn, true));
  root.querySelectorAll("[data-all-products]").forEach((b) => b.onclick = () => { open({ kind: "settings" }); setTimeout(() => settingsJump("products"), 50); });
}

// Home while Theo is off: the products, what's on, and their demos (the Mac's ProductsHomeView).
function productsHomeHTML() {
  const on = (Products.list || []).filter((p) => productIsOn(p.id)).map((p) => p.title);
  const line = on.length ? `On: ${on.join(", ")}. Turn on Vello for bots, teams and coding runs.` : "Nothing is on yet. Each product works without the others.";
  return `<div class="column"><h1>Your products</h1><p class="muted">${esc(line)}</p>${productCardsHTML()}</div>`;
}

// Which pages belong to Theo the product (connectors and settings serve every product).
function productGateKinds(v) { return !productIsOn("theo") && v && ["home", "bot", "group", "team", "routines", "usage"].includes(v.kind); }

// app.js asks before drawing a page: true means this file drew it.
window.productGate = function (v) {
  if (!productGateKinds(v)) { Products.gateSig = null; return false; }
  const sig = JSON.stringify([v, Products.on, (Products.list || []).length]);
  if (Products.gateSig === sig) return true;
  Products.gateSig = sig;
  const pane = $("#pane");
  pane.innerHTML = v.kind === "home" ? productsHomeHTML() : `<div class="column">${productOffHTML("theo")}</div>`;
  wireProductCards(pane, () => { Products.gateSig = null; window.productGate(view); });
  wireProductOff(pane);
  return true;
};

window.TheoProducts = { load: loadProducts, set: setProduct, isOn: productIsOn, cardsHTML: productCardsHTML, wireCards: wireProductCards, offHTML: productOffHTML, wireOff: wireProductOff, demoHTML: productDemoHTML };

loadProducts();
