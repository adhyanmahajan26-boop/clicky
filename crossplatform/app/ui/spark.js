// Clicky's overlay on one monitor (app/src-tauri/src/clicky.rs makes one transparent, click-through window per monitor and
// sends it "spark" events). It draws the orange spark beside the cursor, the answer's bubble, the flight to a [POINT] and the
// [MARK]s. Positions arrive in this window's CSS pixels.
(function () {
  "use strict";
  const spark = document.getElementById("spark");
  const bubble = document.getElementById("bubble");
  const label = document.getElementById("label");
  const marks = document.getElementById("marks");
  const SVG = "http://www.w3.org/2000/svg";
  // Where the spark sits relative to the pointer (right of and below the arrow, like the Mac's companion).
  const OFFSET_X = 22, OFFSET_Y = 20;

  // The spark: Claude's mark, ported from ClickyCore's ClaudeSparkShape (twelve tapered rays, clipped tips, a solid hub).
  const RAYS = [[15, 0.93, 0.104], [44, 0.95, 0.111], [60, 0.93, 0.098], [95, 0.96, 0.098], [123, 0.96, 0.104], [146, 0.92, 0.098],
    [179, 0.96, 0.078], [212, 0.95, 0.104], [242, 1.0, 0.111], [279, 0.87, 0.091], [311, 0.91, 0.104], [353, 0.9, 0.104]];
  function sparkPath() {
    const centre = 50, radius = 50, baseRadius = 0.1, baseHalf = 0.05, hub = 0.2, chamfer = 0.07;
    const at = (angle, along, across) => [centre + (Math.cos(angle) * along - Math.sin(angle) * across) * radius, centre + (Math.sin(angle) * along + Math.cos(angle) * across) * radius];
    let d = "";
    for (const [degrees, length, tip] of RAYS) {
      const a = degrees * Math.PI / 180;
      const outline = [[baseRadius, -baseHalf], [length - chamfer, -tip], [length, -tip * 0.45], [length, tip * 0.45], [length - chamfer, tip], [baseRadius, baseHalf]];
      d += outline.map(([along, across], i) => (i ? "L" : "M") + at(a, along, across).map((n) => n.toFixed(2)).join(" ")).join("") + "Z";
    }
    const corners = [];
    for (let i = 0; i < 24; i++) corners.push(at(i / 24 * Math.PI * 2, hub, 0));
    d += corners.map((p, i) => (i ? "L" : "M") + p.map((n) => n.toFixed(2)).join(" ")).join("") + "Z";
    return d;
  }
  spark.querySelector("path").setAttribute("d", sparkPath());

  let cursor = null;          // {x, y} of the pointer on this monitor, or null when it's elsewhere
  let position = null;        // where the spark is drawn
  let pointing = null;        // {x, y} while the spark is on a [POINT] here
  let elsewhere = false;      // the spark is pointing on another monitor
  let flight = null;
  let phase = "idle";
  let bubbleTimer = null;

  function place(x, y) {
    position = { x, y };
    spark.style.transform = `translate(${x}px, ${y}px)`;
    placeBubble();
  }
  function showSpark() {
    const visible = !elsewhere && (pointing || flight || cursor);
    spark.classList.toggle("shown", !!visible);
    if (!visible) bubble.classList.remove("shown");
    else if (bubble.textContent) bubble.classList.add("shown");
  }
  function placeBubble() {
    if (!position) return;
    const width = bubble.offsetWidth, height = bubble.offsetHeight;
    let left = position.x + 18, top = position.y + 16;
    if (left + width > window.innerWidth - 8) left = Math.max(8, position.x - 18 - width);
    if (top + height > window.innerHeight - 8) top = Math.max(8, position.y - 16 - height);
    bubble.style.transform = `translate(${left}px, ${top}px)`;
  }
  function setBubble(text, opts = {}) {
    clearTimeout(bubbleTimer);
    bubble.textContent = text || "";
    bubble.classList.toggle("error", !!opts.error);
    bubble.classList.toggle("shown", !!text && spark.classList.contains("shown"));
    placeBubble();
    if (opts.linger) bubbleTimer = setTimeout(() => setBubble(""), opts.linger);
  }
  function setPhase(next) {
    phase = next;
    spark.classList.remove("idle", "listening", "thinking", "speaking");
    spark.classList.add(next);
    if (next !== "listening") spark.querySelector(".ring").style.transform = "";
    if (next === "listening") setBubble("");
    // Once the answer is done, its words stay a few seconds to be read.
    if (next === "idle" && bubble.textContent && !bubbleTimer) bubbleTimer = setTimeout(() => setBubble(""), 6000);
  }

  // The flight to a target: a quadratic arc that rises above the straight line, eased, like the Mac's bezier flight.
  function fly(to, done) {
    const from = position || to;
    const distance = Math.hypot(to.x - from.x, to.y - from.y);
    const duration = Math.max(320, Math.min(900, distance / 1.6));
    const lift = Math.min(160, distance * 0.3);
    const control = { x: (from.x + to.x) / 2, y: Math.min(from.y, to.y) - lift };
    const started = performance.now();
    if (flight) cancelAnimationFrame(flight);
    const step = (now) => {
      const t = Math.min(1, (now - started) / duration);
      const e = t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2;
      const x = (1 - e) * (1 - e) * from.x + 2 * (1 - e) * e * control.x + e * e * to.x;
      const y = (1 - e) * (1 - e) * from.y + 2 * (1 - e) * e * control.y + e * e * to.y;
      place(x, y);
      if (t < 1) flight = requestAnimationFrame(step);
      else { flight = null; showSpark(); if (done) done(); }
    };
    flight = requestAnimationFrame(step);
    showSpark();
  }

  function releasePoint() {
    label.classList.remove("shown");
    if (!pointing && !elsewhere) return;
    pointing = null;
    elsewhere = false;
    if (cursor) fly({ x: cursor.x + OFFSET_X, y: cursor.y + OFFSET_Y });
    else showSpark();
  }

  // Marks, drawn one after another in the order the answer wrote them.
  function el(name, attrs, parent) {
    const node = document.createElementNS(SVG, name);
    for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v);
    (parent || marks).appendChild(node);
    return node;
  }
  function note(text, x, y, group) {
    if (!text) return;
    const node = el("text", { x, y, class: "note" }, group);
    node.textContent = text;
  }
  function drawMark(mark, index) {
    const group = el("g", { style: `animation-delay:${index * 160}ms`, class: "fade" });
    const box = mark.box;
    const x = mark.x, y = mark.y;
    const style = String(mark.style || "circle");
    const delay = `animation-delay:${index * 160}ms`;
    if (/^[1-9]$/.test(style)) {
      el("circle", { cx: x, cy: y, r: 13, class: "badge" }, group);
      el("text", { x, y: y + 0.5, class: "badge-number" }, group).textContent = style;
      note(mark.text, x + 20, y + 5, group);
      return;
    }
    if (style === "box") {
      const b = box || { x: x - 30, y: y - 18, width: 60, height: 36 };
      el("rect", { x: b.x - 4, y: b.y - 4, width: b.width + 8, height: b.height + 8, rx: 8, class: "stroke draw", style: delay }, group);
      note(mark.text, b.x, b.y - 10, group);
    } else if (style === "underline") {
      const b = box || { x: x - 40, y: y - 10, width: 80, height: 20 };
      el("path", { d: `M${b.x} ${b.y + b.height + 4} L${b.x + b.width} ${b.y + b.height + 4}`, class: "stroke draw", style: delay }, group);
      note(mark.text, b.x, b.y + b.height + 22, group);
    } else if (style === "highlight") {
      const b = box || { x: x - 40, y: y - 10, width: 80, height: 20 };
      el("rect", { x: b.x - 2, y: b.y - 2, width: b.width + 4, height: b.height + 4, rx: 4, class: "soft" }, group);
      note(mark.text, b.x, b.y - 8, group);
    } else if (style === "spot") {
      el("circle", { cx: x, cy: y, r: 9, class: "badge" }, group);
      note(mark.text, x + 16, y + 5, group);
    } else if (style === "arrow") {
      // From the upper left, ending just short of the target.
      const sx = x - 70, sy = y - 70, ex = x - 10, ey = y - 10;
      el("path", { d: `M${sx} ${sy} L${ex} ${ey} M${ex - 14} ${ey - 2} L${ex} ${ey} L${ex - 2} ${ey - 14}`, class: "stroke draw", style: delay }, group);
      note(mark.text, sx - 10, sy - 8, group);
    } else {
      const rx = box ? box.width / 2 + 10 : 30, ry = box ? box.height / 2 + 10 : 24;
      el("ellipse", { cx: x, cy: y, rx, ry, class: "stroke draw", style: delay }, group);
      note(mark.text, x + rx + 6, y + 5, group);
    }
  }
  function clearMarks() { marks.textContent = ""; }

  function handle(m) {
    switch (m.kind) {
      case "cursor":
        cursor = { x: m.x, y: m.y };
        if (!pointing && !flight && !elsewhere) place(m.x + OFFSET_X, m.y + OFFSET_Y);
        showSpark();
        break;
      case "away":
        cursor = null;
        if (!pointing && !flight) showSpark();
        break;
      case "state":
        setPhase(m.state);
        break;
      case "level":
        spark.querySelector(".ring").style.transform = `scale(${(1 + Math.min(1, m.level * 4) * 0.6).toFixed(3)})`;
        break;
      case "text":
        setBubble(m.text);
        break;
      case "say":
        setBubble(m.text, { error: m.error, linger: m.linger || 8000 });
        break;
      case "answer":
        if (m.clearFirst) clearMarks();
        setBubble(m.text);
        (m.marks || []).forEach(drawMark);
        if (m.point) {
          elsewhere = false;
          pointing = { x: m.point.x, y: m.point.y };
          if (!position) place(m.point.x - 120, m.point.y - 80);
          fly(pointing, () => {
            if (!m.point.label) return;
            label.textContent = m.point.label;
            label.style.transform = `translate(${m.point.x + 16}px, ${m.point.y - 30}px)`;
            label.classList.add("shown");
          });
        } else if (m.pointElsewhere) {
          elsewhere = true;
          showSpark();
        }
        break;
      case "release":
        releasePoint();
        break;
      case "clear":
        clearMarks();
        setBubble("");
        releasePoint();
        break;
    }
  }

  if (window.__TAURI__ && window.__TAURI__.event) window.__TAURI__.event.listen("spark", (event) => handle(event.payload || {}));
  // A page opened in a browser (the design check) shows the spark at rest.
  else { cursor = { x: 200, y: 200 }; place(222, 220); showSpark(); }
})();
