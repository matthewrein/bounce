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
async function launch(mjpeg) {
  return chromium.launch({ args: ["--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream", `--use-file-for-fake-video-capture=${mjpeg}`, "--autoplay-policy=no-user-gesture-required"] });
}
const PICK = (d) => ({ locked: d.locked, quad: d.quad, normal: d.normal, tilt: d.tilt, ball: d.ball, ms: d.ms, misfit: d.misfit, aspect: d.aspect, fov: d.set.fov, live: d.live, src: d.src, counts: d.counts, build: d.build });

async function runStep(srv, clip, gt) {
  const browser = await launch(path.join(clip.dir, "clip.mjpeg"));
  try {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 1 });
    await context.grantPermissions(["camera"], { origin: srv.url });
    await context.addInitScript({ content: HARNESS.replace("__CFG__", JSON.stringify({ mode: "step", fov: FOV })) });
    const page = await context.newPage(); const errs = []; page.on("pageerror", (e) => errs.push(e.message));
    await page.goto(`${srv.url}/${APP}`);
    const rel = "/" + path.relative(ROOT, path.join(clip.dir, "clip.mjpeg")).split(path.sep).join("/");
    const n = await page.evaluate((u) => window.__harness.load(u), rel);
    if (n !== gt.frames.length) throw new Error(`clip has ${n} frames, truth has ${gt.frames.length}`);
    // the motion sensor runs before the camera starts
    for (let k = 0; k < 30; k++) await page.evaluate((s) => window.__harness.motion(s), gt.sensors[k]);
    await page.evaluate(() => document.getElementById("live").click());
    await page.waitForFunction(() => window.slabDiagnostics().live === true, null, { timeout: 15000 });
    const ticks = [], nT = gt.frames.length * 2; let was = false;
    for (let k = 0; k < nT; k++) {
      const fi = Math.min(gt.frames.length - 1, Math.floor(k / 2)), s = gt.sensors[30 + k] || gt.sensors[gt.sensors.length - 1];
      const d = await page.evaluate(async ([fi, s, ts]) => { const H = window.__harness; await H.setFrame(fi); H.motion(s); H.tick(ts); return window.slabDiagnostics(); }, [fi, s, k * 1000 / 60]);
      const p = PICK(d); if (k === 0 && (p.src[0] !== 720 || p.src[1] !== 1280)) errs.push(`camera size ${p.src}`);
      ticks.push({ k, t: k / 60, fi, wasLocked: was, ...p }); was = p.locked;
    }
    return { ticks, errs };
  } finally { await browser.close(); }
}

async function runLive(srv, clip, gt) {
  // real time: the fake camera plays the file at 30 fps; each processed frame is identified by matching a tiny thumbnail
  const browser = await launch(path.join(clip.dir, "clip.mjpeg"));
  try {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 1 });
    await context.grantPermissions(["camera"], { origin: srv.url });
    await context.addInitScript({ content: HARNESS.replace("__CFG__", JSON.stringify({ mode: "live", fov: FOV })) });
    const page = await context.newPage(); const errs = []; page.on("pageerror", (e) => errs.push(e.message));
    await page.goto(`${srv.url}/${APP}`);
    const rel = "/" + path.relative(ROOT, path.join(clip.dir, "clip.mjpeg")).split(path.sep).join("/");
    await page.evaluate((u) => window.__harness.load(u), rel);
    await page.evaluate(async (sensors) => {
      const H = window.__harness, TW = 18, TH = 32, c = document.createElement("canvas"); c.width = TW; c.height = TH; const x = c.getContext("2d", { willReadFrequently: true });
      const thumb = (img) => { x.drawImage(img, 0, 0, TW, TH); const d = x.getImageData(0, 0, TW, TH).data, o = new Float32Array(TW * TH); for (let i = 0; i < o.length; i++) o[i] = d[i * 4] + d[i * 4 + 1] + d[i * 4 + 2]; return o; };
      H.thumbs = []; for (const f of H.frames) { const b = await createImageBitmap(new Blob([f], { type: "image/jpeg" })); H.thumbs.push(thumb(b)); b.close(); }
      H.rec = []; H.fi = 0; H.fiAt = performance.now();
      const raf = window.requestAnimationFrame.bind(window);
      // after each app frame: which clip frame did it see?
      const after = () => {
        const d = window.slabDiagnostics(); if (!d.live) return;
        const v = document.querySelector("#stage video"); if (!v || v.readyState < 2) return;
        const t = thumb(v); let bi = 0, bs = Infinity;
        for (let i = 0; i < H.thumbs.length; i++) { let s = 0; const a = H.thumbs[i]; for (let j = 0; j < a.length; j++) s += Math.abs(a[j] - t[j]); if (s < bs) { bs = s; bi = i; } }
        if (bi !== H.fi) { H.fi = bi; H.fiAt = performance.now(); }
        H.rec.push({ fi: bi, at: performance.now(), d });
      };
      window.requestAnimationFrame = (cb) => raf((ts) => { cb(ts); after(); });
      // motion samples follow the clip frame currently on screen
      setInterval(() => { const tt = H.fi / 30 + (performance.now() - H.fiAt) / 1000, k = Math.max(0, Math.min(sensors.length - 1, Math.round((tt + 0.5) * 60))); H.motion(sensors[k]); }, 1000 / 60);
    }, gt.sensors);
    await page.evaluate(() => document.getElementById("live").click());
    await page.waitForFunction(() => window.slabDiagnostics().live === true, null, { timeout: 15000 });
    await page.waitForTimeout(gt.frames.length / gt.fps * 1000 + 300);
    const rec = await page.evaluate(() => window.__harness.rec.map((r) => ({ fi: r.fi, at: r.at, d: r.d })));
    // keep the first pass through the file (it loops)
    const ticks = []; let was = false, last = -1;
    for (const r of rec) { if (r.fi + 20 < last) break; last = Math.max(last, r.fi); const p = PICK(r.d); ticks.push({ t: r.fi / gt.fps, fi: r.fi, wasLocked: was, ...p }); was = p.locked; }
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
      await context.addInitScript({ content: HARNESS.replace("__CFG__", JSON.stringify({ mode: "photo", fov: FOV })) });
      const page = await context.newPage(); await page.goto(`${srv.url}/${APP}`);
      await page.setInputFiles("#pick", path.join(__dirname, "private", s.file));
      await page.waitForFunction(() => window.slabDiagnostics().src[0] !== 900, null, { timeout: 15000 });
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
