// Shared by the p7 pages (Tools/eval/p7/*.html).
//
// Each page publishes its ground truth as window.__truth (and a
// <script id="truth"> element), then sets window.__ready = true. The harness
// reads that over DevTools. Nothing here changes what is drawn on screen.
(function () {
  "use strict";

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

  window.P7 = { publish: publish, fail: fail };
})();
