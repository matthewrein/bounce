#!/usr/bin/env node
// Feed the rendered clips to index.html as a fake camera and score what it reports.
//   node run.js --label base [--filter name,tag] [--mode step|live] [--workers 3] [--app index.html]
//               [--private]   also run clips rendered with the private photo textures (results stay in tests/private/)
//               [--stills]    also run the private photos as still images (needs tests/private/stills.json)
// Chrome gets the clip through --use-file-for-fake-video-capture. In step mode (default) the page's animation
// loop is advanced one tick at a time (60 Hz ticks, each 30 fps frame shown for two ticks, like a phone camera),
// with matching devicemotion events, and the app's diagnostics JSON is read after every tick.
"use strict";
const fs = require("fs"), path = require("path");
const { chromium } = require("playwright");
const { start, ROOT } = require("./server");
const { scoreClip, summarize, cornerErr } = require("./score");

const args = process.argv.slice(2), opt = (k, d) => { const i = args.indexOf("--" + k); return i < 0 ? d : (args[i + 1] && !args[i + 1].startsWith("--") ? args[i + 1] : true); };
const LABEL = opt("label", "run"), MODE = opt("mode", "step"), WORKERS = +opt("workers", 3), APP = opt("app", "index.html");
// --store key=value[,key=value]: localStorage entries set before the app loads (e.g. slabCutEdge=1 to test an option)
const STORE = Object.fromEntries(String(opt("store", "") || "").split(",").filter(Boolean).map((kv) => kv.split("=")));
const PHASE = +opt("phase", 0);
// rotation-rate naming presented to the page: "engines" (what WebKit/Chromium/Gecko report: alpha/beta/gamma about the
// device's x/y/z) or "2016" (the older spec: alpha about z, beta about x, gamma about y; how the clips were rendered)
const GYRO_NAMES = opt("gyroNames", "engines");
function presentSensors(gt) {
  if (GYRO_NAMES !== "engines" || (gt.spec.sensor && gt.spec.sensor.gyroOrder === "xyz")) return gt.sensors;
  return gt.sensors.map((s) => (s.rot ? { ...s, rot: { alpha: s.rot.beta, beta: s.rot.gamma, gamma: s.rot.alpha } } : s));
} // start the camera this many 60 Hz ticks later (a small, realistic perturbation)
const FILTER = opt("filter", null), PRIVATE = !!opt("private", false), STILLS = !!opt("stills", false), QUIET = !!opt("quiet", false);
const HARNESS = fs.readFileSync(path.join(__dirname, "harness.js"), "utf8");
const FOV = 72.5; // what the real phone's lens setting self-calibrated to

function clipDirs() {
  const dirs = [];
  const add = (root, prefix) => { if (!fs.existsSync(root)) return; for (const d of fs.readdirSync(root).sort()) if (fs.existsSync(path.join(root, d, "gt.json"))) dirs.push({ dir: path.join(root, d), name: prefix + d }); };
  add(path.join(__dirname, "out/clips"), "");
  if (PRIVATE) add(path.join(__dirname, "private/clips"), "photo/");
  if (!FILTER || FILTER === true) return dirs;
  const f = FILTER.split(",");
  return dirs.filter((c) => { const tags = JSON.parse(fs.readFileSync(path.join(c.dir, "gt.json"), "utf8")).spec.tags; const base = c.name.replace(/^photo\//, "");
    return f.some((x) => base === x || tags.includes(x) || (x.endsWith("*") && base.startsWith(x.slice(0, -1)))); });
}
// Which clip frame the page sees on each 60 Hz tick: normally each 30 fps frame for two ticks. With spec.cam.hiccup
// (a probability per frame) the camera now and then drops a frame: the previous one stays up two ticks longer and
// the dropped one is never seen, as when a phone's camera stutters.
function frameSchedule(gt) {
  const n = gt.frames.length, p = (gt.spec.cam && gt.spec.cam.hiccup) || 0, out = [];
  let a = (gt.spec.seed * 2654435761) >>> 0; const rnd = () => { a = (a + 0x6D2B79F5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
  let shown = 0;
  for (let f = 0; f < n; f++) { if (p && f > 0 && rnd() < p) { out.push(shown, shown); continue; } shown = f; out.push(f, f); }
  return out;
}
async function launch(mjpeg) {
  return chromium.launch({ args: ["--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream", `--use-file-for-fake-video-capture=${mjpeg}`, "--autoplay-policy=no-user-gesture-required"] });
}
const PICK = (d) => ({ bounceNormal: d.bounce ? d.bounce.normal : null, grav: d.sensor.gravityClean || d.sensor.gravity, locked: d.locked, quad: d.quad, normal: d.normal, tilt: d.tilt, ball: d.ball, ms: d.ms, misfit: d.misfit, aspect: d.aspect, fov: d.set.fov, live: d.live, src: d.src, counts: d.counts, build: d.build });

async function runStep(srv, clip, gt) {
  gt = { ...gt, sensors: presentSensors(gt) };
  const browser = await launch(path.join(clip.dir, "clip.mjpeg"));
  try {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 1 });
    await context.grantPermissions(["camera"], { origin: srv.url });
    await context.addInitScript({ content: HARNESS.replace("__CFG__", JSON.stringify({ mode: "step", fov: FOV, store: STORE })) });
    const page = await context.newPage(); const errs = []; page.on("pageerror", (e) => errs.push(e.message));
    await page.goto(`${srv.url}/${APP}`);
    const rel = "/" + path.relative(ROOT, path.join(clip.dir, "clip.mjpeg")).split(path.sep).join("/");
    const n = await page.evaluate((u) => window.__harness.load(u), rel);
    if (n !== gt.frames.length) throw new Error(`clip has ${n} frames, truth has ${gt.frames.length}`);
    // the motion sensor runs before the camera starts
    for (let k = 0; k < 30 + PHASE; k++) await page.evaluate((s) => window.__harness.motion(s), gt.sensors[k]);
    await page.evaluate(() => document.getElementById("live").click());
    await page.waitForFunction(() => window.slabDiagnostics().live === true, null, { timeout: 15000, polling: 50 });
    const ticks = [], nT = gt.frames.length * 2 - PHASE, sched = frameSchedule(gt); let was = false;
    for (let k = 0; k < nT; k++) {
      const kk = k + PHASE, fi = sched[Math.min(sched.length - 1, kk)], s = gt.sensors[30 + kk] || gt.sensors[gt.sensors.length - 1];
      const d = await page.evaluate(async ([fi, s, ts]) => { const H = window.__harness; await H.setFrame(fi); H.motion(s); H.tick(ts); return window.slabDiagnostics(); }, [fi, s, k * 1000 / 60]);
      const p = PICK(d); if (k === 0 && (p.src[0] !== 720 || p.src[1] !== 1280)) errs.push(`camera size ${p.src}`);
      ticks.push({ k, t: kk / 60, fi, wasLocked: was, ...p }); was = p.locked;
    }
    return { ticks, errs };
  } finally { await browser.close(); }
}

async function runLive(srv, clip, gt) {
  gt = { ...gt, sensors: presentSensors(gt) };
  // real time: the fake camera plays the file at 30 fps with the app's own animation loop; frames are identified by the video's clock
  const browser = await launch(path.join(clip.dir, "clip.mjpeg"));
  try {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 1 });
    await context.grantPermissions(["camera"], { origin: srv.url });
    await context.addInitScript({ content: HARNESS.replace("__CFG__", JSON.stringify({ mode: "live", fov: FOV, store: STORE })) });
    const page = await context.newPage(); const errs = []; page.on("pageerror", (e) => errs.push(e.message));
    await page.goto(`${srv.url}/${APP}`);
    const rel = "/" + path.relative(ROOT, path.join(clip.dir, "clip.mjpeg")).split(path.sep).join("/");
    await page.evaluate((u) => window.__harness.load(u), rel);
    await page.evaluate(async ([sensors, n, fps]) => {
      // The fake camera starts the file at frame 0 when the stream opens and plays it at the clip's frame rate, so the
      // video's own clock says which clip frame the app is looking at.
      const H = window.__harness; H.rec = []; H.fi = 0;
      const frameNow = () => { const v = document.querySelector("#stage video"); return v && v.readyState >= 2 ? Math.floor(v.currentTime * fps) : -1; };
      const raf = window.requestAnimationFrame.bind(window);
      const after = () => { const d = window.slabDiagnostics(); if (!d.live) return; const f = frameNow(); if (f < 0) return; H.fi = f; H.rec.push({ fi: f, at: performance.now(), d }); };
      window.requestAnimationFrame = (cb) => raf((ts) => { cb(ts); after(); });
      // motion samples follow the video's clock too
      setInterval(() => { const v = document.querySelector("#stage video"), tt = v ? v.currentTime : 0, k = Math.max(0, Math.min(sensors.length - 1, Math.round((tt + 0.5) * 60))); H.motion(sensors[k]); }, 1000 / 60);
    }, [gt.sensors, gt.frames.length, gt.fps]);
    await page.evaluate(() => document.getElementById("live").click());
    await page.waitForFunction(() => window.slabDiagnostics().live === true, null, { timeout: 15000, polling: 50 });
    await page.waitForTimeout(gt.frames.length / gt.fps * 1000 + 300);
    const rec = await page.evaluate(() => window.__harness.rec.map((r) => ({ fi: r.fi, at: r.at, d: r.d })));
    // keep the first pass through the file (it loops)
    const ticks = []; let was = false;
    for (const r of rec) { if (r.fi >= gt.frames.length) break; const p = PICK(r.d); ticks.push({ t: r.fi / gt.fps, fi: r.fi, wasLocked: was, ...p }); was = p.locked; }
    return { ticks, errs };
  } finally { await browser.close(); }
}

async function runStills(srv) {
  const file = path.join(__dirname, "private/stills.json"); if (!fs.existsSync(file)) return [];
  const list = JSON.parse(fs.readFileSync(file, "utf8")), out = [];
  const browser = await chromium.launch();
  try {
    for (const s of list) {
      const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
      await context.addInitScript({ content: HARNESS.replace("__CFG__", JSON.stringify({ mode: "photo", fov: FOV, store: STORE })) });
      const page = await context.newPage(); await page.goto(`${srv.url}/${APP}`);
      await page.setInputFiles("#pick", path.join(__dirname, "private", s.file));
      await page.waitForFunction(() => window.slabDiagnostics().src[0] !== 900, null, { timeout: 15000, polling: 50 });
      const d = await page.evaluate(() => window.slabDiagnostics());
      const k = d.src[0] / s.size[0], g = s.corners.map(([x, y]) => [x * k, y * k]);
      const side = [0, 1, 2, 3].reduce((a, i) => a + Math.hypot(g[(i + 1) % 4][0] - g[i][0], g[(i + 1) % 4][1] - g[i][1]), 0) / 4;
      const err = d.quad ? cornerErr(d.quad, g) : null;
      out.push({ name: s.name, found: !!d.quad, cornerErr: err == null ? null : +err.toFixed(1), cornerErrPct: err == null ? null : +(100 * err / side).toFixed(1), side: +side.toFixed(0), tilt: d.tilt, misfit: d.misfit, aspect: d.aspect, ball: !!d.ball });
      await context.close();
    }
  } finally { await browser.close(); }
  return out;
}

function table(rows) {
  const cols = [["name", 26], ["lockRate", 6, "lock%"], ["timeToLock", 6, "ttl"], ["falseLocks", 3, "FL"], ["cornerErr", 6, "cErr"], ["tiltErr", 5, "tilt"], ["tiltErrP90", 5, "p90"], ["tiltReadErr", 5, "tRd"],
    ["jitter", 6, "jit"], ["tiltJitter", 6, "tJit"], ["ballRate", 6, "ball%"], ["ballFalse", 3, "bFP"], ["dropErrIn", 5, "drop"], ["msSearch", 6, "msS"], ["msTrack", 6, "msT"]];
  const fmt = (v, w) => String(v == null ? "-" : v).slice(0, w).padStart(w);
  console.log(cols.map(([k, w, h]) => (k === "name" ? (h || k).padEnd(w) : fmt(h || k, w))).join(" "));
  for (const r of rows) console.log(cols.map(([k, w]) => (k === "name" ? r[k].slice(0, w).padEnd(w) : fmt(r[k], w))).join(" "));
}

(async () => {
  const srv = await start(), list = clipDirs(), results = [], traces = {};
  let next = 0;
  const worker = async () => {
    while (next < list.length) {
      const clip = list[next++], gt = JSON.parse(fs.readFileSync(path.join(clip.dir, "gt.json"), "utf8"));
      try {
        const t0 = Date.now(), { ticks, errs } = await (MODE === "live" ? runLive : runStep)(srv, clip, gt);
        const sc = scoreClip(gt, ticks); sc.name = clip.name; if (errs.length) sc.errors = errs.slice(0, 3);
        results.push(sc); traces[clip.name] = ticks.map((t) => ({ ...t, counts: undefined }));
        if (!QUIET) console.error(`${clip.name.padEnd(28)} ${((Date.now() - t0) / 1000).toFixed(1)}s${errs.length ? "  ERR " + errs[0] : ""}`);
      } catch (e) { console.error(clip.name, "FAILED", e.message); results.push({ name: clip.name, tags: gt.spec.tags, failed: e.message }); }
    }
  };
  await Promise.all(Array.from({ length: Math.min(WORKERS, list.length) }, worker));
  const stills = STILLS ? await runStills(srv) : [];
  srv.srv.close();
  results.sort((a, b) => a.name.localeCompare(b.name));
  const pub = results.filter((r) => !r.name.startsWith("photo/")), priv = results.filter((r) => r.name.startsWith("photo/"));
  const build = (() => { const m = fs.readFileSync(path.join(ROOT, APP), "utf8").match(/const BUILD="([^"]+)"/); return m ? m[1] : "?"; })();
  const save = (dir, rows, extra) => { fs.mkdirSync(dir, { recursive: true }); const f = path.join(dir, `${LABEL}.json`); fs.writeFileSync(f, JSON.stringify({ label: LABEL, build, mode: MODE, app: APP, when: new Date().toISOString(), summary: summarize(rows.filter((r) => !r.failed)), clips: rows, ...extra }, null, 1)); return f; };
  table(pub.filter((r) => !r.failed));
  const f = save(path.join(__dirname, "out/results"), pub, {});
  fs.mkdirSync(path.join(__dirname, "out/traces", LABEL), { recursive: true });
  for (const [k, v] of Object.entries(traces)) if (!k.startsWith("photo/")) fs.writeFileSync(path.join(__dirname, "out/traces", LABEL, k + ".json"), JSON.stringify(v));
  console.log("\nsummary", JSON.stringify(summarize(pub.filter((r) => !r.failed)), null, 1));
  console.log("saved", path.relative(process.cwd(), f));
  if (priv.length || stills.length) {
    console.log("\n-- private (photo textures / photos; results kept in tests/private/results) --");
    if (priv.length) table(priv.filter((r) => !r.failed));
    for (const s of stills) console.log("still", JSON.stringify(s));
    save(path.join(__dirname, "private/results"), priv, { stills });
  }
})();
