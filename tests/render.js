#!/usr/bin/env node
// Render the synthetic clips in headless Chrome (three.js + SwiftShader).
//   node render.js [--filter name,tag,...] [--workers 3] [--frames N] [--force] [--preview]
//   node render.js --private   use the private photo crops in tests/private/textures/ as textures;
//                              output then goes to tests/private/clips/ (never committed, never uploaded)
// Output per clip: <out>/<name>/clip.mjpeg (concatenated JPEG frames, 30 fps) and gt.json (spec, per-frame truth,
// 60 Hz motion-sensor samples).
"use strict";
const fs = require("fs"), path = require("path"), crypto = require("crypto");
const { chromium } = require("playwright");
const { start } = require("./server");
const { clips } = require("./clips");

const args = process.argv.slice(2), opt = (k, d) => { const i = args.indexOf("--" + k); return i < 0 ? d : (args[i + 1] && !args[i + 1].startsWith("--") ? args[i + 1] : true); };
const PRIVATE = !!opt("private", false);
const OUT = path.join(__dirname, PRIVATE ? "private/clips" : "out/clips");
const WORKERS = +opt("workers", 3), FRAMES = opt("frames", null), FORCE = !!opt("force", false), PREVIEW = !!opt("preview", false);
const sceneHash = crypto.createHash("sha1").update(fs.readFileSync(path.join(__dirname, "scene.js"))).digest("hex").slice(0, 10);

async function renderClip(page, spec) {
  const dir = path.join(OUT, spec.name); fs.mkdirSync(dir, { recursive: true });
  const hash = crypto.createHash("sha1").update(JSON.stringify(spec) + sceneHash).digest("hex").slice(0, 12);
  const gtFile = path.join(dir, "gt.json");
  if (!FORCE && !PREVIEW && fs.existsSync(gtFile)) { try { if (JSON.parse(fs.readFileSync(gtFile)).hash === hash) return "cached"; } catch (_) {} }
  const n = PREVIEW ? 1 : spec.frames, frames = [], parts = [];
  const t0 = Date.now();
  for (let i = 0; i < n; i++) {
    const r = await page.evaluate(([s, i]) => window.renderClipFrame(s, i), [spec, i]);
    const buf = Buffer.from(r.jpeg.split(",")[1], "base64"); parts.push(buf); frames.push(r.gt);
    if (PREVIEW) fs.writeFileSync(path.join(OUT, spec.name + "_f0.jpg"), buf);
  }
  if (PREVIEW) return "preview";
  const T = n / spec.fps, times = []; for (let t = -0.5; t < T + 1e-9; t += 1 / 60) times.push(+t.toFixed(5));
  const sensors = await page.evaluate(([s, ts]) => window.sensorSamples(s, ts), [spec, times]);
  fs.writeFileSync(path.join(dir, "clip.mjpeg"), Buffer.concat(parts));
  fs.writeFileSync(gtFile, JSON.stringify({ hash, spec, private: PRIVATE, size: [720, 1280], fps: spec.fps, frames, sensors }));
  return `${n} frames in ${((Date.now() - t0) / 1000).toFixed(1)} s`;
}

(async () => {
  const list = clips(opt("filter", null) === true ? null : opt("filter", null)).map((c) => { if (FRAMES) c.frames = +FRAMES; if (PRIVATE) c.photoTextures = true; return c; });
  fs.mkdirSync(OUT, { recursive: true });
  const srv = await start();
  let next = 0;
  const worker = async () => {
    const browser = await chromium.launch({ args: ["--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist"] });
    const page = await browser.newPage({ viewport: { width: 720, height: 1280 } });
    page.on("pageerror", (e) => console.error("page error:", e.message));
    await page.goto(srv.url + "/tests/scene.html"); await page.waitForFunction(() => window.sceneReady === true);
    while (next < list.length) {
      const spec = list[next++];
      try { console.log(spec.name.padEnd(28), await renderClip(page, spec)); } catch (e) { console.error(spec.name, "FAILED", e.message); }
    }
    await browser.close();
  };
  await Promise.all(Array.from({ length: Math.min(WORKERS, list.length) }, worker));
  srv.srv.close();
})();
