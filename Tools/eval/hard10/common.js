// Shared by the hard10 pages (Tools/eval/hard10/*.html).
//
// Each page lays itself out, then publishes its ground truth as viewport
// CSS-pixel rects [x, y, w, h] in window.__truth and in a
// <script id="truth" type="application/json"> element, and sets
// window.__ready = true. hard10.py reads it over the DevTools protocol
// (final_eval.ChromeHarness.load) and converts it to CG points. Nothing here
// is drawn on screen beyond the page itself.
(function () {
  "use strict";

  function rectOf(element) {
    const box = element.getBoundingClientRect();
    return [box.left, box.top, box.width, box.height].map(function (value) {
      return Math.round(value * 100) / 100;
    });
  }

  function publish(page, items, extra) {
    const truth = Object.assign({ page: page, items: items }, extra || {});
    window.__truth = truth;
    const holder = document.createElement("script");
    holder.id = "truth";
    holder.type = "application/json";
    holder.textContent = JSON.stringify(truth);
    document.body.appendChild(holder);
    window.__ready = true;
  }

  function fail(error) {
    window.__error = String((error && error.message) || error);
    window.__ready = true;
  }

  window.Hard10 = { rectOf: rectOf, publish: publish, fail: fail };
})();
