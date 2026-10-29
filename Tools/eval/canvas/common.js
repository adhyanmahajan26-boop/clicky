// Shared helpers for the P6.11 canvas pages (Tools/eval/canvas/*.html).
//
// Every page reads manifest.json (labels, colours, keys), lays its items out
// from a seeded RNG (?seed=N, default 1) and publishes the ground truth as
// viewport CSS-pixel rects [x, y, w, h]:
//   window.__truth = {page, seed, variant, items: {key: rect}, texts: [rect], ...}
//   <script id="truth" type="application/json"> holds the same JSON
//   window.__ready = true once drawn
// final_eval.py reads it over the DevTools protocol and converts it to CG
// points with the window's position. Nothing here shows the truth on screen.
(function () {
  "use strict";

  function mulberry32(seed) {
    let state = seed >>> 0;
    return function () {
      state = (state + 0x6D2B79F5) >>> 0;
      let t = state;
      t = Math.imul(t ^ (t >>> 15), t | 1);
      t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }

  const params = new URLSearchParams(location.search);
  const seed = parseInt(params.get("seed") || "1", 10) || 1;
  const variant = params.get("variant") || "default";

  function intersects(a, b, gap) {
    return !(a[0] + a[2] + gap <= b[0] || b[0] + b[2] + gap <= a[0] || a[1] + a[3] + gap <= b[1] || b[1] + b[3] + gap <= a[1]);
  }

  /// Places boxes of the given sizes inside [margin, width - margin] without
  /// overlapping each other (or `taken`), with at least `gap` px between them.
  function place(rng, width, height, sizes, options) {
    const margin = (options && options.margin) || 48;
    const gap = (options && options.gap) || 28;
    const taken = ((options && options.taken) || []).slice();
    const placed = [];
    for (const size of sizes) {
      let rect = null;
      for (let attempt = 0; attempt < 4000 && !rect; attempt++) {
        const x = margin + rng() * Math.max(1, width - 2 * margin - size[0]);
        const y = margin + rng() * Math.max(1, height - 2 * margin - size[1]);
        const candidate = [Math.round(x), Math.round(y), size[0], size[1]];
        if (!taken.some((other) => intersects(candidate, other, gap))) rect = candidate;
      }
      if (!rect) throw new Error("could not place an item; window too small");
      taken.push(rect);
      placed.push(rect);
    }
    return placed;
  }

  /// A full-viewport canvas drawn in CSS px (sharp on Retina).
  function fullCanvas(background) {
    const canvas = document.createElement("canvas");
    const ratio = window.devicePixelRatio || 1;
    const width = window.innerWidth;
    const height = window.innerHeight;
    canvas.width = Math.round(width * ratio);
    canvas.height = Math.round(height * ratio);
    canvas.style.width = width + "px";
    canvas.style.height = height + "px";
    canvas.style.position = "fixed";
    canvas.style.left = "0";
    canvas.style.top = "0";
    document.body.appendChild(canvas);
    const context = canvas.getContext("2d");
    context.scale(ratio, ratio);
    context.fillStyle = background || "#f7f7f8";
    context.fillRect(0, 0, width, height);
    return { canvas, context, width, height };
  }

  /// Canvas-local rect -> viewport rect.
  function toViewport(canvas, rect) {
    const bounds = canvas.getBoundingClientRect();
    return [bounds.left + rect[0], bounds.top + rect[1], rect[2], rect[3]].map((v) => Math.round(v * 100) / 100);
  }

  function domRect(element) {
    const bounds = element.getBoundingClientRect();
    return [bounds.left, bounds.top, bounds.width, bounds.height].map((v) => Math.round(v * 100) / 100);
  }

  function publish(page, items, extra) {
    const truth = Object.assign({ page, seed, variant, items, innerWidth: window.innerWidth, innerHeight: window.innerHeight }, extra || {});
    window.__truth = truth;
    let script = document.getElementById("truth");
    if (!script) {
      script = document.createElement("script");
      script.id = "truth";
      script.type = "application/json";
      document.head.appendChild(script);
    }
    script.textContent = JSON.stringify(truth);
    window.__ready = true;
  }

  function fail(error) {
    window.__error = String(error && error.message ? error.message : error);
    window.__ready = true;
  }

  async function manifest(page) {
    const response = await fetch("manifest.json", { cache: "no-store" });
    const all = await response.json();
    return all.pages[page];
  }

  window.Fixture = { params, seed, variant, rng: mulberry32(seed * 7919 + variant.length), mulberry32, place, fullCanvas, toViewport, domRect, publish, fail, manifest };
})();
