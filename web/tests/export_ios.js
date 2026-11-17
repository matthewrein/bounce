#!/usr/bin/env node
// Export ground truth and short recordings from the rendered clips for the native app's tests (ios/BounceCore).
//   node export_ios.js [--out ../../ios/BounceCore/Tests/BounceCoreTests/Fixtures]
// Writes (procedural textures only; never run on clips rendered with --private):
//   gt_poses.json   per frame of many clips: true top-corner pixels, lens, true normal and gravity (camera axes), slab size
//   gt_balls.json   frames with a held ball over the slab: its circle, true drop height and landing normal
//   rec_<clip>/     a recording in BounceCore's format (session.json, frames.jsonl, f<NNNNNN>.byc) plus truth.json
// Recording frames are 270x480 (the web app's processing size), luma and half-size chroma (BYC1, see Recording.swift).
"use strict";
const fs = require("fs"), path = require("path");
const { chromium } = require("playwright");
const { start } = require("./server");
const { clips } = require("./clips");

const args = process.argv.slice(2), opt = (k, d) => { const i = args.indexOf("--" + k); return i < 0 ? d : args[i + 1]; };
const OUT = path.resolve(__dirname, opt("out", "../../ios/BounceCore/Tests/BounceCoreTests/Fixtures"));
const FT = 0.3048, PW = 270, PH = 480;
const all = clips();
const byName = Object.fromEntries(all.map((c) => [c.name, c]));
const gtOf = (name) => { const f = path.join(__dirname, "out/clips", name, "gt.json"); return fs.existsSync(f) ? JSON.parse(fs.readFileSync(f, "utf8")) : null; };
const splitJpegs = (buf) => { const st = []; for (let i = 0; i + 2 < buf.length; i++) if (buf[i] === 0xff && buf[i + 1] === 0xd8 && buf[i + 2] === 0xff) st.push(i); return st.map((s, k) => buf.subarray(s, k + 1 < st.length ? st[k + 1] : buf.length)); };
const r = (v, n = 5) => +v.toFixed(n);
const slabSides = (spec) => { const S = spec.slab || {}; return { sideUInches: (S.size || 7) * (S.aspect || 1), sideVInches: S.size || 7, thicknessInches: S.thick ?? 1, dishInches: S.dish ?? 0.125 }; };
const exact = (spec) => !(spec.cam.k1 || spec.cam.rs || spec.private);

function exportPoses() {
  const out = [];
  for (const spec of all) {
    if (spec.tags.includes("noslab") || !exact(spec)) continue;
    const gt = gtOf(spec.name); if (!gt || gt.private) continue;
    for (const t of [1.0, 2.0, 3.0]) {
      const fi = Math.round(t * gt.fps), g = gt.frames[fi]; if (!g || !g.corners || !g.slabVisible) continue;
      out.push({ clip: spec.name, fi, fovDeg: spec.cam.fov || 72.5, width: 720, height: 1280, corners: g.corners, normal: g.normal, down: g.grav, tiltDeg: g.tilt, still: g.still, ...slabSides(spec) });
    }
  }
  fs.writeFileSync(path.join(OUT, "gt_poses.json"), JSON.stringify(out));
  return out.length;
}

function exportBalls() {
  const out = [];
  for (const spec of all) {
    if (!spec.ball || !exact(spec)) continue;
    const gt = gtOf(spec.name); if (!gt || gt.private) continue;
    for (let fi = 15; fi < gt.frames.length; fi += 10) {
      const g = gt.frames[fi], b = g.ball; if (!g.corners || !g.slabVisible || !b || !b.held || !b.onSlab || b.x == null || !(b.rim >= 0.6)) continue;
      out.push({ clip: spec.name, fi, fovDeg: spec.cam.fov || 72.5, width: 720, height: 1280, corners: g.corners, normal: g.normal, down: g.grav,
        ball: { x: b.x, y: b.y, r: b.r, dropMetres: r(b.drop * FT, 5), dropPlaneMetres: r(b.dropPlane * FT, 5), hitNormal: b.hitNormal, hitLocal: b.hitLocal },
        ballDiameterMm: 35, ...slabSides(spec) });
    }
  }
  fs.writeFileSync(path.join(OUT, "gt_balls.json"), JSON.stringify(out));
  return out.length;
}

async function exportRecording(page, name, frameIdx, label) {
  const spec = byName[name], gt = gtOf(name); if (!spec || !gt || gt.private) throw new Error("missing clip " + name);
  const jp = splitJpegs(fs.readFileSync(path.join(__dirname, "out/clips", name, "clip.mjpeg")));
  const dir = path.join(OUT, "rec_" + (label || name)); fs.rmSync(dir, { recursive: true, force: true }); fs.mkdirSync(dir, { recursive: true });
  const times = frameIdx.map((i) => i / gt.fps), poses = await page.evaluate(([s, ts]) => window.cameraPoses(s, ts), [spec, times]);
  const f = (PH / 2) / Math.tan(((spec.cam.fov || 72.5) * Math.PI / 180) / 2);
  const intr = { fx: r(f, 4), fy: r(f, 4), cx: PW / 2, cy: PH / 2, width: PW, height: PH };
  const lines = [], truth = [];
  for (let k = 0; k < frameIdx.length; k++) {
    const fi = frameIdx[k];
    const bytes = await page.evaluate(async ([b64, W, H]) => {
      const img = new Image(); img.src = "data:image/jpeg;base64," + b64; await img.decode();
      const c = document.createElement("canvas"); c.width = W; c.height = H; const x = c.getContext("2d"); x.imageSmoothingQuality = "high"; x.drawImage(img, 0, 0, W, H);
      const d = x.getImageData(0, 0, W, H).data, cw = (W + 1) >> 1, ch = (H + 1) >> 1, out = new Uint8Array(8 + W * H + 2 * cw * ch);
      out.set([66, 89, 67, 49, W & 255, W >> 8, H & 255, H >> 8]);
      for (let i = 0; i < W * H; i++) out[8 + i] = Math.round(0.299 * d[i * 4] + 0.587 * d[i * 4 + 1] + 0.114 * d[i * 4 + 2]);
      for (let yy = 0; yy < ch; yy++) for (let xx = 0; xx < cw; xx++) {
        let R = 0, G = 0, B = 0, n = 0;
        for (let dy = 0; dy < 2; dy++) for (let dx = 0; dx < 2; dx++) { const X = xx * 2 + dx, Y = yy * 2 + dy; if (X >= W || Y >= H) continue; const j = (Y * W + X) * 4; R += d[j]; G += d[j + 1]; B += d[j + 2]; n++; }
        R /= n; G /= n; B /= n; const L = 0.299 * R + 0.587 * G + 0.114 * B;
        out[8 + W * H + yy * cw + xx] = Math.max(0, Math.min(255, Math.round(128 + (B - L) * 0.564)));
        out[8 + W * H + cw * ch + yy * cw + xx] = Math.max(0, Math.min(255, Math.round(128 + (R - L) * 0.713))); }
      return Array.from(out);
    }, [jp[fi].toString("base64"), PW, PH]);
    const file = `f${String(fi).padStart(6, "0")}.byc`; fs.writeFileSync(path.join(dir, file), Buffer.from(bytes));
    const g = gt.frames[fi], p = poses[k];
    // the phone's gravity reading in device (CV camera) axes, as the motion sensor gives it
    lines.push(JSON.stringify({ index: k, timestamp: r(times[k], 4), file, worldFromCamera: p.worldFromCamera.map((v) => r(v, 6)), intrinsics: intr, trackingNormal: true,
      gravityCamera: g.grav }));
    truth.push({ index: k, fi, slabCornersWorld: p.slabCorners && p.slabCorners.map((c) => c.map((v) => r(v, 5))), slabNormalWorld: p.slabNormal && p.slabNormal.map((v) => r(v, 6)),
      ball: p.ball ? { center: p.ball.center.map((v) => r(v, 5)), held: p.ball.held, imageCircle: g.ball && g.ball.x != null ? [g.ball.x * PW / 720, g.ball.y * PH / 1280, g.ball.r * PW / 720] : null, dropMetres: g.ball ? r(g.ball.drop * FT, 5) : null } : null,
      baseCentreWorld: p.baseCentre && p.baseCentre.map((v) => r(v, 5)), floorY: 0, tiltDeg: g.tilt, cornersPixels: g.corners && g.corners.map((c) => [r(c[0] * PW / 720, 3), r(c[1] * PH / 1280, 3)]) });
  }
  fs.writeFileSync(path.join(dir, "frames.jsonl"), lines.join("\n") + "\n");
  fs.writeFileSync(path.join(dir, "session.json"), JSON.stringify({ format: "bouncerec", version: 1, build: "web-testbed", device: "synthetic (three.js, web/tests " + name + ")",
    frameWidth: PW, frameHeight: PH, settings: { ...slabSides(spec), ballDiameterMm: 35, dropHeightFeet: 3, reboundPercent: 70 }, notes: "frames at the web app's processing size; camera poses in metres, world y up" }, null, 1));
  fs.writeFileSync(path.join(dir, "truth.json"), JSON.stringify({ clip: name, spec: { slab: spec.slab, base: spec.base, ball: spec.ball || null, cam: { fov: spec.cam.fov || 72.5 } }, frames: truth }));
  return frameIdx.length;
}

// Full-resolution luma crops (300x720) around the slab and the space above it (where a held ball is), as PGM, for the ball
// finder's tests: ball_<clip>_<fi>.pgm plus ball_crops.json (crop origin, lens, true circle and corners in crop pixels).
async function exportBallCrops(page) {
  const items = [["ball_held_d4", [30, 90]], ["ball_held_offcenter_d4", [60]], ["ball_held_satin_d4", [60]], ["ball_held_d5_high", [60]],
    ["ball_held_d3_other", [60]], ["ball_held_dim", [60]], ["d4_t10_h90_mat", [60]], ["distract_floorball", [60]], ["distract_mat_circles", [60]]];
  const dir = path.join(OUT, "balls"); fs.rmSync(dir, { recursive: true, force: true }); fs.mkdirSync(dir, { recursive: true });
  const meta = [];
  for (const [name, fis] of items) {
    const spec = byName[name], gt = gtOf(name); if (!spec || !gt || gt.private) continue;
    const jp = splitJpegs(fs.readFileSync(path.join(__dirname, "out/clips", name, "clip.mjpeg")));
    for (const fi of fis) {
      const g = gt.frames[fi]; if (!g.corners) continue;
      const xs = g.corners.map((c) => c[0]), ys = g.corners.map((c) => c[1]), side = Math.max(...xs) - Math.min(...xs);
      const cx = (Math.max(...xs) + Math.min(...xs)) / 2, CW = 300, CH = 720, x0 = Math.max(0, Math.min(720 - CW, Math.round(cx - CW / 2)));
      const y1 = Math.min(1280, Math.round(Math.max(...ys) + side * 0.4)), y0 = Math.max(0, y1 - CH);
      const bytes = await page.evaluate(async ([b64, x0, y0, CW, CH]) => {
        const img = new Image(); img.src = "data:image/jpeg;base64," + b64; await img.decode();
        const c = document.createElement("canvas"); c.width = CW; c.height = CH; const x = c.getContext("2d"); x.drawImage(img, x0, y0, CW, CH, 0, 0, CW, CH);
        const d = x.getImageData(0, 0, CW, CH).data, out = new Uint8Array(CW * CH);
        for (let i = 0; i < out.length; i++) out[i] = Math.round(0.299 * d[i * 4] + 0.587 * d[i * 4 + 1] + 0.114 * d[i * 4 + 2]);
        return Array.from(out);
      }, [jp[fi].toString("base64"), x0, y0, CW, CH]);
      const file = `ball_${name}_${fi}.pgm`;
      fs.writeFileSync(path.join(dir, file), Buffer.concat([Buffer.from(`P5\n${CW} ${CH}\n255\n`), Buffer.from(bytes)]));
      const b = g.ball;
      meta.push({ file, clip: name, fi, cropOrigin: [x0, y0], fovDeg: spec.cam.fov || 72.5, fullWidth: 720, fullHeight: 1280,
        corners: g.corners.map((c) => [r(c[0] - x0, 3), r(c[1] - y0, 3)]), normal: g.normal, down: g.grav, ...slabSides(spec), ballDiameterMm: 35,
        ball: b && b.x != null ? { x: r(b.x - x0, 3), y: r(b.y - y0, 3), rOnAxis: b.r, rim: b.rim, held: b.held, onSlab: b.onSlab, visible: b.visible, dropMetres: r(b.drop * FT, 5) } : null,
        floorBall: !!(spec.extras || []).find((e) => e.type === "floorball") });
    }
  }
  fs.writeFileSync(path.join(dir, "ball_crops.json"), JSON.stringify(meta, null, 1));
  return meta.length;
}

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  console.log("poses:", exportPoses(), "balls:", exportBalls());
  const srv = await start(), browser = await chromium.launch({ args: ["--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist"] });
  const page = await browser.newPage(); await page.goto(srv.url + "/tests/scene.html"); await page.waitForFunction(() => window.sceneReady === true);
  const recs = [
    ["d4_t10_h90_mat", [15, 30, 45, 60, 75, 90, 105, 118], "replay_still"],
    ["ball_held_d4", [30, 60, 90], "ball_held"],
    ["noslab_clutter", [60], "noslab_clutter"], ["noslab_base_only", [60], "noslab_base_only"],
  ];
  for (const n of ["d3_t10_h0_mat", "d5_t15_h45_wood", "warm_lamp_d4", "level_lined_up_d4", "cradle_r14_d4", "two_lights_d4", "matchtone_concrete_d4", "d5_t8_h315_darkfloor"]) recs.push([n, [60], "single_" + n]);
  for (const [n, f, label] of recs) console.log(label, await exportRecording(page, n, f, label), "frames");
  console.log("ball crops:", await exportBallCrops(page));
  await browser.close(); srv.srv.close();
})();
