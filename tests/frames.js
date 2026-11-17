#!/usr/bin/env node
// Dump still frames for offline experiments: the JPEG frames, what the app saw and estimated on each (from a run's
// traces), and the truth in a separate file, so a prototype can be scored without being able to read the answer.
//   node frames.js --label v3_b21 [--filter tag,name,...] [--every 0.5] [--out out/frames]
// Output: <out>/<clip>/f<NNN>.jpg, <out>/inputs.json (per frame: clip, fi, file, size, lens angle the app was using,
// its outline, normal, gravity, lock), <out>/truth.json (same keys: corners, normal, gravity, tilt, cradle sphere
// centre, base centre and outline, slab and base spec).
"use strict";
const fs = require("fs"), path = require("path");
const { clips } = require("./clips");
const args = process.argv.slice(2), opt = (k, d) => { const i = args.indexOf("--" + k); return i < 0 ? d : args[i + 1]; };
const LABEL = opt("label"), EVERY = +opt("every", 0.5), OUT = path.join(__dirname, opt("out", "out/frames"));
if (!LABEL) { console.error("--label required"); process.exit(1); }
const splitJpegs = (buf) => { const st = []; for (let i = 0; i + 2 < buf.length; i++) if (buf[i] === 0xff && buf[i + 1] === 0xd8 && buf[i + 2] === 0xff) st.push(i); return st.map((s, k) => buf.subarray(s, k + 1 < st.length ? st[k + 1] : buf.length)); };
const inputs = [], truth = [];
for (const spec of clips(opt("filter", null))) {
  const dir = path.join(__dirname, "out/clips", spec.name), tf = path.join(__dirname, "out/traces", LABEL, spec.name + ".json");
  if (!fs.existsSync(path.join(dir, "gt.json")) || !fs.existsSync(tf)) continue;
  const gt = JSON.parse(fs.readFileSync(path.join(dir, "gt.json"), "utf8")), ticks = JSON.parse(fs.readFileSync(tf, "utf8"));
  const jp = splitJpegs(fs.readFileSync(path.join(dir, "clip.mjpeg")));
  const step = Math.max(1, Math.round(EVERY * gt.fps)); fs.mkdirSync(path.join(OUT, spec.name), { recursive: true });
  for (let fi = Math.round(0.5 * gt.fps); fi < gt.frames.length; fi += step) {
    const g = gt.frames[fi], k = [...ticks].reverse().find((x) => x.fi === fi); if (!k || !jp[fi]) continue;
    const file = `${spec.name}/f${String(fi).padStart(3, "0")}.jpg`; fs.writeFileSync(path.join(OUT, file), jp[fi]);
    const id = `${spec.name}#${fi}`;
    inputs.push({ id, clip: spec.name, fi, t: g.t, file, size: [720, 1280], fovDeg: k.fov, locked: k.locked, quad: k.quad, normal: k.normal, tilt: k.tilt, gravity: k.grav });
    truth.push({ id, still: g.still, slabVisible: g.slabVisible, corners: g.corners, normal: g.normal, gravity: g.grav, tilt: g.tilt, dist: g.dist,
      cradleCentre: g.cradleCentre, baseCentre: g.baseCentre, baseFloorPx: g.baseFloorPx, baseRimPx: g.baseRimPx, fovDeg: spec.cam.fov || 72.5,
      slab: spec.slab, base: spec.base, tags: spec.tags });
  }
}
fs.mkdirSync(OUT, { recursive: true });
fs.writeFileSync(path.join(OUT, "inputs.json"), JSON.stringify(inputs));
fs.writeFileSync(path.join(OUT, "truth.json"), JSON.stringify(truth));
console.log(`${inputs.length} frames from ${new Set(inputs.map((x) => x.clip)).size} clips -> ${path.relative(__dirname, OUT)}`);
