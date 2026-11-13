/* Theo Pixel: the bot faces, badges and status pills.
   A bot is a small screen with a face made of lights. Everything is data (grids of lights, timings, colours)
   plus one small renderer, so the Mac app (SwiftUI) and the Windows/Linux app (web) draw the same thing. */
const TP = (() => {
  const COLS = 13, ROWS = 9;

  /* ---------- status ---------- */
  // Green, yellow and red belong to status alone. Each state also has its own eyes, badge shape, word and motion.
  const STATES = {
    working:   { c: '#22D391', ink: '#04150E', label: 'Working',   badge: 'spin', tone: 'ok' },
    thinking:  { c: '#22D391', ink: '#04150E', label: 'Thinking',  badge: 'spin', tone: 'ok' },
    needs:     { c: '#FFD938', ink: '#221A00', label: 'Needs you', badge: 'ask',  tone: 'ask' },
    failed:    { c: '#FF4A5E', ink: '#2B050A', label: 'Failed',    badge: 'x',    tone: 'bad' },
    done:      { c: '#F4F4F5', ink: '#0B0B0C', label: 'Done',      badge: 'tick', tone: 'done' },
    awake:     { c: '#C6C7D1', ink: '#0B0B0C', label: 'Ready',     badge: null,   tone: 'quiet' },
    talking:   { c: '#F4F4F5', ink: '#0B0B0C', label: 'Talking',   badge: null,   tone: 'quiet' },
    listening: { c: '#F4F4F5', ink: '#0B0B0C', label: 'Listening', badge: null,   tone: 'quiet' },
    idle:      { c: '#6E6E78', ink: '#0B0B0C', label: 'Asleep',    badge: null,   tone: 'quiet' },
    off:       { c: '#3A3A41', ink: '#0B0B0C', label: 'Off',       badge: null,   tone: 'quiet' },
  };
  const ORDER = ['working', 'needs', 'failed', 'done', 'idle'];
  const ALL = ['working', 'thinking', 'needs', 'failed', 'done', 'awake', 'talking', 'listening', 'idle', 'off'];
  // When several things are true at once, the first one in this list is the face that shows.
  const PRIORITY = ['off', 'needs', 'failed', 'talking', 'listening', 'working', 'thinking', 'done', 'awake', 'idle'];

  /* ---------- looks ---------- */
  const FIN = {
    bone:     { a: '#FFFFFF', b: '#CDCDC9', d: '#A5A5A2', rim: .2 },
    graphite: { a: '#6C6D76', b: '#2E2F36', d: '#1F2025', rim: .34 },
    onyx:     { a: '#4B4B54', b: '#17171A', d: '#0E0E10', rim: .4 },
    sand:     { a: '#F8ECD7', b: '#D3B68D', d: '#B3936A', rim: .2 },
    sky:      { a: '#E0EDFF', b: '#8DB3E8', d: '#6990CB', rim: .2 },
    lilac:    { a: '#EEE6FF', b: '#AA97E6', d: '#8A76CB', rim: .2 },
    blush:    { a: '#FFE9EF', b: '#EAB1C2', d: '#C98E9F', rim: .2 },
    slate:    { a: '#D2DBE4', b: '#7D8C9C', d: '#5E6D7D', rim: .2 },
    cocoa:    { a: '#B08B78', b: '#614437', d: '#432D23', rim: .28 },
  };
  const TRIMS = { ember: '#FF7A45', pink: '#F06FB0', cyan: '#45C8E6', blue: '#5B8DEF', violet: '#9B7BF0', white: '#F4F4F5', peach: '#F4D7C4' };
  const TOPS = ['none', 'ball', 'twin', 'handle', 'dish', 'flag', 'bolt', 'heart'];
  const HATS = ['hardhat', 'cap', 'beanie', 'beret', 'tophat', 'crown', 'headset'];
  const EXTRAS = ['none', 'bowtie', 'tie', 'scarf', 'bezel', 'pencil', 'star'];

  const CREW = {
    theo:       { name: 'Theo', role: 'CEO', fin: 'onyx', trim: '#FF7A45', eye: 'block', top: 'ball', extra: 'tie' },
    clicky:     { name: 'Clicky', role: 'Screen companion', fin: 'bone', trim: '#FF9A5C', eye: 'round', top: 'cursor', extra: 'none' },
    builder:    { name: 'Builder', role: 'Engineering', fin: 'bone', trim: '#5B8DEF', eye: 'wide', top: 'handle', extra: 'none' },
    researcher: { name: 'Researcher', role: 'Growth', fin: 'sky', trim: '#F4F4F5', eye: 'round', top: 'twin', extra: 'none' },
    designer:   { name: 'Designer', role: 'Engineering', fin: 'lilac', trim: '#F06FB0', eye: 'tall', top: 'beret', extra: 'none' },
    reviewer:   { name: 'Code Reviewer', role: 'Engineering', fin: 'graphite', trim: '#9B7BF0', eye: 'block', top: 'twin', extra: 'star' },
    inbox:      { name: 'Inbox Triage', role: 'Growth', fin: 'sand', trim: '#45C8E6', eye: 'round', top: 'headset', extra: 'none' },
    editor:     { name: 'Copy Editor', role: 'Growth', fin: 'slate', trim: '#F4F4F5', eye: 'tall', top: 'handle', extra: 'pencil' },
    release:    { name: 'Release Mgr', role: 'Engineering', fin: 'cocoa', trim: '#F4D7C4', eye: 'wide', top: 'flag', extra: 'none' },
    manager:    { name: 'Manager', role: 'Planning', fin: 'graphite', trim: '#F4D7C4', eye: 'tall', top: 'tophat', extra: 'bowtie' },
    accountant: { name: 'Accountant', role: 'Finance', fin: 'bone', trim: '#45C8E6', eye: 'round', top: 'none', extra: 'bezel' },
  };

  /* ---------- the lights ---------- */
  // A bot's own eyes, used whenever it is calm or working.
  const EYES = {
    block: ['###', '###', '###', '###'],
    round: ['.#.', '###', '###', '.#.'],
    tall:  ['##', '##', '##', '##', '##'],
    wide:  ['####', '####', '####'],
    heart: ['.#.#.', '#####', '.###.', '..#..'],
  };
  // The shared signs, the same on every bot, so the states that matter read the same everywhere.
  const SIGN = {
    big:   ['.##.', '####', '####', '.##.'],
    x:     ['#.#', '.#.', '#.#'],
    happy: ['.#.', '#.#'],
    dash:  ['###'],
    q:     ['.###.', '#...#', '....#', '...#.', '..#..', '.....', '..#..'],
    z:     ['###', '.#.', '###'],
  };
  // Below 22 px the 13 x 9 grid is too fine to read, so the screen shows one big sign on a 7 x 5 grid.
  const MICRO = {
    working:   ['.......', '.##.##.', '.##.##.', '.##.##.', '.......'],
    thinking:  ['.......', '.##.##.', '.##.##.', '.......', '.#.#.#.'],
    needs:     ['..###..', '....#..', '...#...', '.......', '...#...'],
    failed:    ['.#...#.', '..#.#..', '...#...', '..#.#..', '.#...#.'],
    done:      ['......#', '.....#.', '#...#..', '.#.#...', '..#....'],
    awake:     ['.......', '.##.##.', '.##.##.', '.##.##.', '.......'],
    talking:   ['.##.##.', '.##.##.', '.......', '.#.#.#.', '.#####.'],
    listening: ['.##.##.', '.##.##.', '.......', '.......', '#.#.#.#'],
    idle:      ['.......', '.......', '.##.##.', '.......', '.......'],
    off:       ['.......', '.......', '.......', '.......', '.......'],
  };

  const blank = () => Array.from({ length: ROWS }, () => new Array(COLS).fill(0));
  function put(g, glyph, col, row, a = 1) {
    glyph.forEach((line, y) => [...line].forEach((ch, x) => {
      const cc = col + x, rr = row + y;
      if (ch === '#' && cc >= 0 && cc < COLS && rr >= 0 && rr < ROWS) g[rr][cc] = a;
    }));
  }
  function putEyes(g, glyph, dx = 0, dy = 0, a = 1) {
    const w = glyph[0].length, h = glyph.length;
    if (w >= 5) dx = 0;
    const row = 2 + Math.floor((4 - h) / 2) + dy;
    put(g, glyph, 5 - w + dx, row, a);
    put(g, glyph, 8 + dx, row, a);
  }
  const lidsOf = (glyph) => [glyph[0].replace(/./g, '#')];

  // Every state is a short loop of frames. Each frame is a grid of lights (0, .5 or 1) and how long it stays up.
  function frames(eye, st) {
    const own = EYES[eye] || EYES.block, F = [];
    const add = (ms, draw) => { const g = blank(); draw(g); F.push({ g, ms }); };
    switch (st) {
      case 'working': { // eyes glance about, a runner marches along the bottom row
        const dxs = [0, 0, 1, 1, 0, 0, -1, -1];
        for (let i = 0; i < 8; i++) add(190, (g) => {
          putEyes(g, own, dxs[i], 1);
          for (let j = 0; j < 3; j++) { const cc = (i * 2 + j) % (COLS + 2) - 1; if (cc >= 0 && cc < COLS) g[8][cc] = j === 2 ? 1 : .5; }
        });
        break;
      }
      case 'thinking': { // eyes look up, three dots fill in
        for (let i = 0; i < 6; i++) add(300, (g) => {
          putEyes(g, own, i < 3 ? 1 : -1, -1);
          for (let j = 0; j <= i % 3; j++) g[7][4 + j * 2] = 1;
        });
        break;
      }
      case 'needs': { // wide eyes and a small "o" mouth, then the whole screen says "?"
        const face = (mouth) => (g) => { putEyes(g, SIGN.big, 0, -1); if (mouth) { g[7][5] = 1; g[7][6] = 1; g[7][7] = 1; } else g[7][6] = 1; };
        add(500, face(false)); add(400, face(true)); add(500, face(false)); add(400, face(true));
        add(900, (g) => put(g, SIGN.q, 4, 1));
        break;
      }
      case 'failed': { // crosses and a jagged mouth, with a glitch now and then
        const face = (glitch) => (g) => {
          putEyes(g, SIGN.x, 0, 0);
          [4, 6, 8].forEach((cc) => (g[7][cc] = 1)); [5, 7].forEach((cc) => (g[6][cc] = 1));
          if (glitch) { g[3] = [0].concat(g[3].slice(0, COLS - 1)); [[0, 11], [8, 1], [5, 12], [1, 0]].forEach(([rr, cc]) => (g[rr][cc] = .5)); }
        };
        add(700, face(false)); add(110, face(true)); add(900, face(false)); add(110, face(true));
        break;
      }
      case 'done': { // a smile, and a few lights sparkle
        const face = (spark) => (g) => {
          putEyes(g, SIGN.happy, 0, 0);
          g[6][4] = 1; g[6][8] = 1; [5, 6, 7].forEach((cc) => (g[7][cc] = 1));
          if (spark) { g[0][0] = .5; g[1][12] = .5; g[8][1] = .5; }
        };
        add(900, face(false)); add(500, face(true));
        break;
      }
      case 'awake': { // its own eyes, a glance each way and a blink
        const open = (dx) => (g) => putEyes(g, own, dx, 0);
        const shut = (g) => putEyes(g, lidsOf(own), 0, 1);
        add(2200, open(0)); add(700, open(1)); add(900, open(0)); add(120, shut);
        add(1400, open(0)); add(700, open(-1)); add(600, open(0)); add(120, shut);
        break;
      }
      case 'talking': { // its own eyes, and a mouth of bars that moves like a level meter
        const H = [[1, 2, 3, 2, 1], [2, 3, 1, 3, 2], [1, 1, 2, 1, 1], [3, 2, 3, 2, 3], [2, 1, 2, 1, 2], [1, 3, 2, 3, 1]];
        H.forEach((hs) => add(130, (g) => { putEyes(g, own, 0, -1); hs.forEach((h, j) => { for (let k = 0; k < h; k++) g[8 - k][4 + j] = 1; }); }));
        break;
      }
      case 'listening': { // its own eyes, and a ripple that runs along the bottom row
        for (let i = 0; i < 6; i++) add(140, (g) => {
          putEyes(g, own, 0, 0);
          for (let cc = 2; cc <= 10; cc++) { const p = (cc + i) % 3; g[8][cc] = p === 0 ? 1 : p === 1 ? .5 : 0; }
        });
        break;
      }
      case 'idle': // two dashes, and a "z" that comes and goes
        add(1600, (g) => putEyes(g, SIGN.dash, 0, 1));
        add(1600, (g) => { putEyes(g, SIGN.dash, 0, 1); put(g, SIGN.z, 9, 0, .5); });
        break;
      default: // off: a dark screen
        add(1000, () => {});
    }
    return F;
  }
  const PERSONAL = ['working', 'thinking', 'awake', 'talking', 'listening'];
  const rowsOf = (g) => g.map((row) => row.map((a) => (a >= .75 ? '#' : a > 0 ? 'o' : '.')).join(''));

  /* ---------- geometry (a 96 x 96 box) ---------- */
  const GEO = {
    box: 96,
    shell: { x: 8, y: 13, w: 80, h: 68, r: 21 },
    screen: { x: 15, y: 21, w: 66, h: 50, r: 13 },
    grid: { cols: COLS, rows: ROWS, pitch: 4.6, cell: 3.5, cellLite: 4.2, cx: 48, cy: 46, radius: .9 },
    micro: { cols: 7, rows: 5, pitch: 8.6, cell: 7.2, cx: 48, cy: 46, radius: 1.6 },
    led: { cx: 48, cy: 76.3, r: 1.7 },
    feet: [{ x: 24, y: 78, w: 15, h: 10, r: 4 }, { x: 57, y: 78, w: 15, h: 10, r: 4 }],
    ears: [{ x: 3.5, y: 38, w: 8, h: 18, r: 4 }, { x: 84.5, y: 38, w: 8, h: 18, r: 4 }],
    tiers: { micro: 22, lite: 31 }, // below 22 px: micro. 22 to 30 px: lite. 31 px and up: full.
  };
  const r2 = (n) => Math.round(n * 100) / 100;
  const rect = (o, extra = '') => `<rect x="${r2(o.x)}" y="${r2(o.y)}" width="${r2(o.w)}" height="${r2(o.h)}" rx="${r2(o.r)}" ${extra}/>`;
  const tier = (size) => (size < GEO.tiers.micro ? 'micro' : size < GEO.tiers.lite ? 'lite' : 'full');

  function gradients(prefix = 'tp') {
    let d = '';
    for (const [k, f] of Object.entries(FIN)) d += `<linearGradient id="${prefix}-lf-${k}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${f.a}"/><stop offset="1" stop-color="${f.b}"/></linearGradient>`;
    d += `<radialGradient id="${prefix}-hl" cx=".3" cy=".08" r=".75"><stop offset="0" stop-color="#fff" stop-opacity=".55"/><stop offset=".6" stop-color="#fff" stop-opacity="0"/></radialGradient>`;
    d += `<linearGradient id="${prefix}-shade" x1="0" y1="0" x2="0" y2="1"><stop offset=".55" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity=".28"/></linearGradient>`;
    d += `<clipPath id="${prefix}-cv"><rect x="15" y="21" width="66" height="50" rx="13"/></clipPath>`;
    return d;
  }
  // Red-green colour blindness (deuteranopia), Machado et al. 2009, for the proof row.
  const DEUT = `<filter id="tp-deut" color-interpolation-filters="linearRGB"><feColorMatrix type="matrix" values="0.367 0.861 -0.228 0 0  0.280 0.673 0.047 0 0  -0.012 0.043 0.969 0 0  0 0 0 1 0"/></filter>`;
  const defs = () => `<svg width="0" height="0" style="position:absolute" aria-hidden="true" focusable="false"><defs>${gradients()}${DEUT}</defs></svg>`;

  /* ---------- what a bot wears ---------- */
  // Markup in the 96-unit box, in the same form the Mac app already keeps its parts: only path, rect, circle, ellipse
  // and g, with colours written as "C" (the bot's trim), "D" (the shell's dark tone) or a literal.
  const STEM = (y) => `<path d="M48 15V${y}" stroke="D" stroke-width="2.6" stroke-linecap="round"/>`;
  const PARTS = {
    // Antennas sit behind the shell.
    top: {
      none: '',
      ball: STEM(7) + `<circle cx="48" cy="5.4" r="3.7" fill="C"/>`,
      twin: `<path d="M33 15l-3-7M63 15l3-7" stroke="D" stroke-width="2.4" stroke-linecap="round"/><circle cx="29.6" cy="6.6" r="2.9" fill="C"/><circle cx="66.4" cy="6.6" r="2.9" fill="C"/>`,
      handle: `<path d="M34 15V11a6 6 0 0 1 6-6h16a6 6 0 0 1 6 6v4" stroke="C" stroke-width="3.2" fill="none" stroke-linecap="round"/>`,
      dish: STEM(9) + `<g transform="rotate(-22 48 7)"><path d="M39.5 4a8.5 8.5 0 0 0 17 0z" fill="C"/><path d="M48 4V.8" stroke="D" stroke-width="1.7" stroke-linecap="round"/></g>`,
      flag: `<path d="M46 15V1.6" stroke="D" stroke-width="2.4" stroke-linecap="round"/><path d="M46 2h12.5l-3.2 3.4 3.2 3.4H46z" fill="C"/>`,
      bolt: `<path d="M52 .6l-9 9.2h5.2L45.6 16l9.4-10.2h-5.3z" fill="C"/>`,
      heart: STEM(10) + `<path d="M48 11.2c-5.8-3.6-7.1-6.7-5.3-8.8 1.6-1.7 4.1-1.1 5.3.9 1.2-2 3.7-2.6 5.3-.9 1.8 2.1.5 5.2-5.3 8.800z" fill="C"/>`,
      cursor: STEM(10) + `<path d="M42.8.8l11.4 6-4.9 1.300 2.800 4.900-2.600 1.500-2.800-4.900-3.600 3.600z" fill="C" stroke="C" stroke-width=".8" stroke-linejoin="round"/>`,
    },
    // Hats sit on the shell.
    hat: {
      hardhat: `<path d="M27.5 15.5a20.5 14.5 0 0 1 41 0z" fill="C"/><rect x="45.3" y="1.3" width="5.4" height="14" rx="2.7" fill="rgba(255,255,255,.3)"/><rect x="21.5" y="13.8" width="53" height="4.8" rx="2.4" fill="C"/><rect x="21.5" y="16.2" width="53" height="2.4" rx="1.2" fill="rgba(0,0,0,.2)"/>`,
      cap: `<path d="M29 16a19 12.5 0 0 1 38 0z" fill="C"/><path d="M58 13.2h17.5a2.7 2.7 0 0 1 0 5.4H56z" fill="C"/><path d="M57 15.900h20.800a2.700 2.700 0 0 1-2.300 2.700H56z" fill="rgba(0,0,0,.2)"/><circle cx="48" cy="3.9" r="1.7" fill="rgba(255,255,255,.45)"/>`,
      beanie: `<path d="M28.5 16c0-9.5 8.2-13.5 19.5-13.5S67.5 6.5 67.5 16z" fill="C"/><rect x="26.5" y="12.4" width="43" height="6.4" rx="3.2" fill="C"/><rect x="26.5" y="12.4" width="43" height="6.4" rx="3.2" fill="rgba(255,255,255,.28)"/><circle cx="48" cy="2.6" r="3.3" fill="rgba(255,255,255,.9)"/>`,
      beret: `<g transform="rotate(-9 48 12)"><ellipse cx="45" cy="10.5" rx="22.5" ry="7.6" fill="C"/><ellipse cx="45" cy="13.2" rx="15" ry="2.6" fill="rgba(0,0,0,.2)"/><path d="M50 3.6l2.2-3.2" stroke="C" stroke-width="2.2" stroke-linecap="round"/></g>`,
      tophat: `<rect x="33.5" y=".8" width="29" height="15" rx="3" fill="#1C1C20"/><rect x="33.5" y=".8" width="29" height="15" rx="3" fill="none" stroke="rgba(255,255,255,.22)" stroke-width=".8"/><rect x="33.5" y="9.8" width="29" height="3.4" fill="C"/><rect x="25.5" y="13.6" width="45" height="4.6" rx="2.3" fill="#1C1C20"/><rect x="26" y="14.1" width="44" height="3.6" rx="1.8" fill="none" stroke="rgba(255,255,255,.22)" stroke-width=".8"/>`,
      crown: `<path d="M31.5 17V4.5l8.2 6.2L48 1.8l8.3 8.900 8.200-6.200V17z" fill="C" stroke="C" stroke-width="1.2" stroke-linejoin="round"/><rect x="31" y="13.6" width="34" height="3.8" rx="1" fill="rgba(0,0,0,.2)"/><circle cx="48" cy="9.8" r="1.7" fill="rgba(255,255,255,.7)"/>`,
      headset: `<path d="M7.5 42V40a40.5 30.5 0 0 1 81 0v2" stroke="C" stroke-width="3.4" fill="none" stroke-linecap="round"/><rect x="1.5" y="36.5" width="10.5" height="21" rx="5.2" fill="C"/><rect x="84" y="36.5" width="10.5" height="21" rx="5.2" fill="C"/><path d="M6.8 57.5v9.500a11 11 0 0 0 11 11h4" stroke="C" stroke-width="2.4" fill="none" stroke-linecap="round"/><rect x="20.5" y="75.2" width="8" height="5.4" rx="2.7" fill="C"/>`,
    },
    // Extras are drawn last, over everything.
    extra: {
      none: '',
      bowtie: `<path d="M48 84.5l-9-5v10zM48 84.5l9-5v10z" fill="C"/><circle cx="48" cy="84.5" r="2.5" fill="C"/><circle cx="48" cy="84.5" r="2.5" fill="rgba(0,0,0,.22)"/>`,
      tie: `<path d="M45.2 81.5h5.6l-1.4 3.4 2.8 7.6L48 95.800l-4.200-3.300 2.800-7.600z" fill="C"/><path d="M45.2 81.5h5.6l-1.4 3.400h-2.800z" fill="rgba(0,0,0,.22)"/>`,
      scarf: `<rect x="19" y="79.2" width="58" height="6.6" rx="3.3" fill="C"/><path d="M59 84h8v10.5l-4-2.300-4 2.300z" fill="C"/><path d="M59 84h8v2.6h-8z" fill="rgba(0,0,0,.2)"/>`,
      bezel: `<rect x="14.2" y="20.2" width="67.6" height="51.6" rx="13.8" fill="none" stroke="C" stroke-width="2"/>`,
      pencil: `<g transform="rotate(24 88 30)"><rect x="85.8" y="17" width="4.4" height="17" rx="1" fill="C"/><path d="M85.8 34h4.4L88 39z" fill="#EBD5B3"/><path d="M87.2 37.2h1.6L88 39z" fill="#2A2A2E"/><rect x="85.8" y="17" width="4.4" height="3.2" rx="1" fill="rgba(0,0,0,.25)"/></g>`,
      star: `<path d="M19.5 71.3l1.5 3.1 3.4.5-2.500 2.400.600 3.400-3-1.600-3 1.600.600-3.400-2.500-2.400 3.400-.5z" fill="C" stroke="rgba(0,0,0,.25)" stroke-width=".5"/>`,
    },
  };
  const tint = (markup, look, F) => markup.replace(/"C"/g, `"${look.trim}"`).replace(/"D"/g, `"${F.d}"`);
  const antenna = (look, F) => tint(PARTS.top[look.top] || '', look, F);
  const hat = (look, F) => tint(PARTS.hat[look.top] || '', look, F);
  const extraOver = (look, F) => tint(PARTS.extra[look.extra] || '', look, F);

  /* ---------- drawing one face ---------- */
  const resolve = (who) => (typeof who === 'string' ? CREW[who] || CREW.builder : who);
  // frame: null animates (CSS). A number draws that one frame, for stills and exports.
  function drawing(who, st, t, frame = null, prefix = 'tp') {
    const look = resolve(who), F = FIN[look.fin] || FIN.bone, S = STATES[st] || STATES.awake, c = S.c;
    const lite = t !== 'full', micro = t === 'micro', G = micro ? GEO.micro : GEO.grid;
    const cell = micro ? G.cell : lite ? G.cellLite : G.cell, pitch = G.pitch;
    const x0 = G.cx - (G.cols * pitch) / 2 + (pitch - cell) / 2, y0 = G.cy - (G.rows * pitch) / 2 + (pitch - cell) / 2;
    const isHat = HATS.includes(look.top), headset = look.top === 'headset';
    let s = `<g class="hd">`;
    GEO.feet.forEach((f) => (s += rect(f, `fill="${F.d}"`)));
    if (!headset) GEO.ears.forEach((e) => (s += rect(e, `fill="${F.d}"`)));
    if (!isHat) s += antenna(look, F);
    s += rect(GEO.shell, `fill="url(#${prefix}-lf-${look.fin})"`) + rect(GEO.shell, `fill="url(#${prefix}-hl)"`) + rect(GEO.shell, `fill="url(#${prefix}-shade)"`);
    s += rect({ x: 8.5, y: 13.5, w: 79, h: 67, r: 20.5 }, `class="rim" fill="none" stroke="#fff" stroke-opacity="${F.rim}" stroke-width="1"`);
    s += rect({ x: 8.5, y: 13.5, w: 79, h: 67, r: 20.5 }, `class="edge" fill="none" stroke="#000" stroke-opacity="0" stroke-width="1"`);
    if (isHat) s += hat(look, F);
    s += `<rect x="13.2" y="19.2" width="69.6" height="53.6" rx="14.6" fill="#000" opacity=".3"/>`;
    s += rect(GEO.screen, `fill="${st === 'failed' ? '#12050A' : st === 'off' ? '#0C0C0E' : '#060607'}"`);
    if (t === 'full' && st !== 'off') {
      let dots = '';
      for (let rr = 0; rr < ROWS; rr++) for (let cc = 0; cc < COLS; cc++) dots += `<rect x="${r2(x0 + cc * pitch)}" y="${r2(y0 + rr * pitch)}" width="${cell}" height="${cell}" rx="${G.radius}"/>`;
      s += `<g fill="#fff" opacity=".06">${dots}</g>`;
    }
    const cells = (rows, bloomToo) => {
      let lit = '', bloom = '';
      rows.forEach((row, rr) => [...row].forEach((ch, cc) => {
        if (ch === '.') return;
        const x = r2(x0 + cc * pitch), y = r2(y0 + rr * pitch);
        lit += `<rect x="${x}" y="${y}" width="${cell}" height="${cell}" rx="${G.radius}"${ch === 'o' ? ' opacity=".5"' : ''}/>`;
        if (bloomToo) bloom += `<rect x="${r2(x - 1.6)}" y="${r2(y - 1.6)}" width="${r2(cell + 3.2)}" height="${r2(cell + 3.2)}" rx="2.4"/>`;
      }));
      return (bloom ? `<g fill="${c}" opacity=".2">${bloom}</g>` : '') + `<g fill="${c}">${lit}</g>`;
    };
    if (micro) s += cells(MICRO[st] || MICRO.awake, false);
    else {
      const fr = frames(look.eye, st), glow = t === 'full' && st !== 'idle' && st !== 'off';
      if (frame !== null) s += cells(rowsOf(fr[frame % fr.length].g), glow);
      else if (fr.length === 1) s += cells(rowsOf(fr[0].g), glow);
      else {
        const total = fr.reduce((a, f) => a + f.ms, 0);
        fr.forEach((f, i) => { s += `<g class="pf${i === 0 ? ' pf0' : ''}" style="animation:tp-${st}-${i} ${total}ms steps(1,end) infinite">${cells(rowsOf(f.g), glow)}</g>`; });
      }
    }
    s += `<g clip-path="url(#${prefix}-cv)"><path d="M21 21h20l-16 50H5z" fill="#fff" opacity=".045"/></g>`;
    s += rect(GEO.screen, `fill="none" stroke="#fff" stroke-opacity=".1" stroke-width=".8"`);
    if (!micro) s += `<circle class="led" cx="48" cy="76.3" r="1.7" fill="${st === 'idle' || st === 'off' ? '#3A3A41' : c}"/>`;
    if (!micro) s += extraOver(look, F);
    return s + `</g>`;
  }

  // The step animations, one per frame of each state. Generated from the timings so the two never drift apart.
  function keyframes() {
    let css = '';
    for (const st of ALL) {
      const fr = frames('block', st); if (fr.length < 2) continue;
      const total = fr.reduce((a, f) => a + f.ms, 0); let at = 0;
      fr.forEach((f, i) => {
        const a = r2((at / total) * 100), b = r2(((at + f.ms) / total) * 100); at += f.ms;
        const k = [];
        if (a > 0) k.push(`0%{opacity:0}`);
        k.push(`${a}%{opacity:1}`);
        if (b < 100) k.push(`${b}%{opacity:0}`, `100%{opacity:0}`); else k.push(`100%{opacity:1}`);
        css += `@keyframes tp-${st}-${i}{${k.join('')}}\n`;
      });
    }
    return css;
  }

  /* ---------- badges and pills ---------- */
  const BADGE = {
    spin: { shape: `<circle cx="12" cy="12" r="10.5"/>`, glyph: `<path class="spin" d="M12 5.800a6.200 6.200 0 1 0 6.200 6.200"/>` },
    ask:  { shape: `<path d="M12 1.500a10.500 10.500 0 1 1-6.300 18.900L1.300 22.800l1.600-5.500A10.500 10.500 0 0 1 12 1.500z"/>`, glyph: `<path d="M9.200 9a3 3 0 1 1 4.500 2.600c-1 .6-1.500 1.200-1.500 2.300"/><path d="M12.200 17.300v.1"/>` },
    x:    { shape: `<rect x="1.500" y="1.500" width="21" height="21" rx="6.500"/>`, glyph: `<path d="M8.200 8.200l7.600 7.600M15.800 8.200l-7.600 7.600"/>` },
    tick: { shape: `<circle cx="12" cy="12" r="10.500"/>`, glyph: `<path d="M7.300 12.500l3.300 3.300 6.300-7"/>` },
  };
  // kind: a state name, or one of the extra pill kinds below.
  const KIND = {
    ok:       { c: '#22D391', ink: '#04150E', badge: 'tick', tone: 'ok' },      // Connected, Signed in, Ready, On
    checking: { c: '#8C8C96', ink: '#0B0B0C', badge: 'spin', tone: 'quiet' },   // Checking
    none:     { c: '#6E6E78', ink: '#0B0B0C', badge: null,   tone: 'quiet' },   // Not connected, Off, Not installed
  };
  const kindOf = (k) => STATES[k] || KIND[k] || KIND.none;
  function badge(kind, cls = 'bdg') {
    const K = kindOf(kind); if (!K.badge) return '';
    const B = BADGE[K.badge];
    return `<i class="${cls} b-${K.badge} k-${K.tone}" aria-hidden="true"><svg viewBox="-2.500 -2.500 29 29"><g class="ring" style="stroke:var(--ring,#000)" stroke-width="4.600" stroke-linejoin="round" fill="none">${B.shape}</g><g fill="${K.c}">${B.shape}</g><g stroke="${K.ink}" stroke-width="2.700" stroke-linecap="round" stroke-linejoin="round" fill="none">${B.glyph}</g></svg></i>`;
  }
  function pill(kind, text) {
    const K = kindOf(kind), lead = K.badge ? badge(kind, 'pg') : kind === 'idle' ? '<i class="moon"></i>' : '<i class="dot"></i>';
    return `<span class="pill p-${K.tone}${K.badge ? '' : ' plain'}">${lead}${text || K.label || ''}</span>`;
  }

  /* ---------- one bot, as HTML ---------- */
  const hash = (s) => { let h = 2166136261; for (const ch of s) h = Math.imul(h ^ ch.charCodeAt(0), 16777619); return (h >>> 0) / 4294967295; };
  function bot(who, st, size, opt = {}) {
    const look = resolve(who), t = tier(size), S = STATES[st] || STATES.awake;
    const bd = opt.badge === false ? '' : badge(st);
    return `<span class="bot t-${t} s-${st}${size >= 88 ? ' big' : ''}" role="img" aria-label="${look.name || 'Bot'}: ${S.label}" style="width:${size}px;height:${size}px"><svg viewBox="0 0 96 96">${drawing(look, st, t, opt.frame ?? null)}</svg>${bd}</span>`;
  }
  // A self-contained SVG file of one face, for the asset export.
  function svg(who, st, t = 'full', frame = 0) {
    const look = resolve(who), id = 'f';
    let d = `<linearGradient id="${id}-lf-${look.fin}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${FIN[look.fin].a}"/><stop offset="1" stop-color="${FIN[look.fin].b}"/></linearGradient>`;
    d += gradients(id).replace(/<linearGradient id="f-lf-[\s\S]*?<\/linearGradient>/g, '');
    return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 96 96" width="96" height="96"><defs>${d}</defs>${drawing(look, st, t, frame, id)}</svg>`;
  }
  function badgeSvg(kind) {
    const K = kindOf(kind), B = BADGE[K.badge];
    return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24"><g fill="${K.c}">${B.shape}</g><g stroke="${K.ink}" stroke-width="2.700" stroke-linecap="round" stroke-linejoin="round" fill="none">${B.glyph.replace(' class="spin"', '')}</g></svg>`;
  }

  // <b-ot who st sz [nobadge] [frame]> and <p-ill st> placeholders, so page markup stays readable.
  function paint(root = document) {
    root.querySelectorAll('b-ot').forEach((el) => {
      let who = el.getAttribute('who') || 'builder';
      if (el.hasAttribute('look')) { try { who = JSON.parse(el.getAttribute('look')); } catch (e) {} }
      el.innerHTML = bot(who, el.getAttribute('st') || 'awake', +(el.getAttribute('sz') || 40), { badge: !el.hasAttribute('nobadge'), frame: el.hasAttribute('frame') ? +el.getAttribute('frame') : null });
    });
    root.querySelectorAll('p-ill').forEach((el) => { if (!el.dataset.done) { el.dataset.done = 1; el.innerHTML = pill(el.getAttribute('st'), el.textContent.trim()); } });
  }

  // Everything a second renderer needs, as plain data.
  function data() {
    const fr = {};
    for (const st of ALL) {
      fr[st] = {};
      for (const eye of PERSONAL.includes(st) ? Object.keys(EYES) : ['*']) fr[st][eye] = frames(eye === '*' ? 'block' : eye, st).map((f) => ({ ms: f.ms, rows: rowsOf(f.g) }));
    }
    return {
      about: 'Theo Pixel faces. rows: "#" is a light at full brightness, "o" at half, "." is off. frames[state][eye style], or "*" when every bot shows the same sign.',
      geometry: GEO, states: STATES, order: ORDER, priority: PRIORITY, finishes: FIN, trims: TRIMS,
      tops: TOPS.concat(['cursor']), hats: HATS, extras: EXTRAS, parts: PARTS, eyes: EYES, signs: SIGN, micro: MICRO, crew: CREW, frames: fr,
      badges: Object.fromEntries(Object.entries(BADGE).map(([k, b]) => [k, { viewBox: '0 0 24 24', shape: b.shape, glyph: b.glyph.replace(' class="spin"', '') }])),
      pillKinds: KIND,
    };
  }

  return { STATES, ORDER, ALL, PRIORITY, FIN, TRIMS, TOPS, HATS, EXTRAS, EYES, CREW, GEO, PARTS, PERSONAL, defs, bot, svg, badge, badgeSvg, pill, paint, keyframes, frames, data, tier };
})();
if (typeof module !== 'undefined') module.exports = TP;
