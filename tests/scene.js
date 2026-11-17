// Synthetic phone-camera clips of the cement slab on its black base, rendered with three.js.
// Units: feet. World: y up, ground at y=0. The slab's top-centre sits near the origin.
// Exposes window.renderClipFrame(spec, i) -> {jpeg, gt} and window.sensorSamples(spec, times).
import * as THREE from "./node_modules/three/build/three.module.js";

// bump when a change alters how existing clips look (the renderer caches clips by spec + this version)
export const SCENE_VERSION = "1";
const W = 720, H = 1280, G_FT = 32.174, M_PER_FT = 0.3048, IN = 1 / 12;

/* ---------------- small utilities ---------------- */
function rng(seed) { let a = seed >>> 0; return () => { a = (a + 0x6D2B79F5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }
function gauss(r) { let u = 0; while (!u) u = r(); return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * r()); }
const rad = (d) => d * Math.PI / 180, deg = (r) => r * 180 / Math.PI;
const smooth = (x) => x <= 0 ? 0 : x >= 1 ? 1 : x * x * (3 - 2 * x);
function cnv(w, h) { const c = document.createElement("canvas"); c.width = w; c.height = h; return c; }

// band-limited random signal: a sum of sinusoids with random frequencies in [f0,f1]; unit RMS
function bandSignal(r, f0, f1, n = 8) {
  const parts = []; for (let i = 0; i < n; i++) parts.push({ f: f0 + (f1 - f0) * r(), p: r() * 2 * Math.PI, a: 0.5 + r() });
  const norm = Math.sqrt(parts.reduce((s, q) => s + q.a * q.a / 2, 0));
  return (t) => parts.reduce((s, q) => s + q.a * Math.sin(2 * Math.PI * q.f * t + q.p), 0) / norm;
}

/* ---------------- procedural textures (stand-ins for the private photo crops) ---------------- */
function mottle(x, w, h, r, octaves) {
  x.save(); x.globalCompositeOperation = "overlay"; x.imageSmoothingEnabled = true; x.imageSmoothingQuality = "high";
  for (const [n, a] of octaves) {
    const s = cnv(n, n), sx = s.getContext("2d"), id = sx.createImageData(n, n);
    for (let i = 0; i < n * n; i++) { const v = 128 + (r() - 0.5) * 255; id.data[i * 4] = id.data[i * 4 + 1] = id.data[i * 4 + 2] = v; id.data[i * 4 + 3] = 255; }
    sx.putImageData(id, 0, 0); x.globalAlpha = a; x.drawImage(s, 0, 0, w, h);
  }
  x.restore();
}
function speckleFill(w, h, rgb, r, sd) {
  const c = cnv(w, h), x = c.getContext("2d"), id = x.createImageData(w, h), d = id.data;
  for (let i = 0; i < w * h; i++) { const v = 1 + gauss(r) * sd; d[i * 4] = rgb[0] * v; d[i * 4 + 1] = rgb[1] * v; d[i * 4 + 2] = rgb[2] * v; d[i * 4 + 3] = 255; }
  x.putImageData(id, 0, 0); return { c, x };
}
function dots(x, w, h, r, n, rmin, rmax, col) {
  for (let i = 0; i < n; i++) { const s = rmin + (rmax - rmin) * r() * r(); x.fillStyle = col(r); x.beginPath(); x.arc(r() * w, r() * h, s, 0, 6.283); x.fill(); }
}
const TEX = {
  cementTop(r) { // greenish grey, smooth trowelled face with fine light aggregate specks and small pores
    const w = 1024, { c, x } = speckleFill(w, w, [96, 99, 90], r, 0.045);
    mottle(x, w, w, r, [[5, 0.12], [17, 0.08], [70, 0.06]]);
    dots(x, w, w, r, 9000, 0.6, 2.4, (r) => `rgba(${200 + r() * 55 | 0},${200 + r() * 55 | 0},${190 + r() * 50 | 0},${0.35 + r() * 0.5})`);
    dots(x, w, w, r, 7000, 0.6, 2.0, () => "rgba(20,22,20,0.45)");
    return c;
  },
  cementSide(r) { // cut edge: lighter, coarse and porous
    const w = 1024, h = 160, { c, x } = speckleFill(w, h, [138, 138, 134], r, 0.08);
    mottle(x, w, h, r, [[9, 0.25], [40, 0.2]]);
    dots(x, w, h, r, 9000, 0.6, 2.6, () => "rgba(25,25,25,0.6)");
    dots(x, w, h, r, 2500, 0.6, 1.8, () => "rgba(235,235,230,0.6)");
    return c;
  },
  baseBlack(r) {
    const w = 512, { c, x } = speckleFill(w, w, [17, 17, 18], r, 0.06);
    x.lineWidth = 1;
    for (let i = 0; i < 70; i++) { x.strokeStyle = `rgba(110,110,110,${0.08 + r() * 0.2})`; x.beginPath(); const a = r() * 6.28, l = 10 + r() * 120, px = r() * w, py = r() * w; x.moveTo(px, py); x.quadraticCurveTo(px + Math.cos(a) * l / 2 + r() * 10, py + Math.sin(a) * l / 2, px + Math.cos(a) * l, py + Math.sin(a) * l); x.stroke(); }
    return c;
  },
  // floors: [canvas, tile size in ft]
  mat(r, tint) { // grey cutting mat: 1 in squares with a dotted sub-grid, heavier lines every 6 in, a few diagonals
    const w = 1024, ppi = w / 12, { c, x } = speckleFill(w, w, tint || [150, 152, 150], r, 0.02);
    x.fillStyle = "rgba(40,42,44,0.85)";
    for (let i = 0; i < 12; i++) for (let j = 0; j < 12; j++) for (let a = 1; a < 4; a++) for (let b = 1; b < 4; b++) x.fillRect(i * ppi + a * ppi / 4 - 1.5, j * ppi + b * ppi / 4 - 1.5, 3, 3);
    for (let i = 0; i <= 12; i++) { const lw = i % 6 === 0 ? 4 : 2.2; x.fillStyle = "rgba(25,27,30,0.9)"; x.fillRect(i * ppi - lw / 2, 0, lw, w); x.fillRect(0, i * ppi - lw / 2, w, lw); }
    x.strokeStyle = "rgba(25,27,30,0.8)"; x.lineWidth = 2; x.beginPath(); x.moveTo(0, 0); x.lineTo(w, w); x.stroke();
    return [c, 1];
  },
  wood(r) {
    const w = 1024, c = cnv(w, w), x = c.getContext("2d"), pw = w / (24 / 5);
    for (let p = 0; p * pw < w; p++) {
      const base = [150 + r() * 40, 100 + r() * 30, 60 + r() * 20];
      for (let y = 0; y < w; y++) { const g = Math.sin(y * 0.05 + p * 3 + Math.sin(y * 0.011 + p) * 4) * 0.08 + Math.sin(y * 0.31 + p) * 0.03; x.fillStyle = `rgb(${base[0] * (1 + g) | 0},${base[1] * (1 + g) | 0},${base[2] * (1 + g) | 0})`; x.fillRect(p * pw, y, pw, 1); }
      x.fillStyle = "rgba(40,25,10,0.7)"; x.fillRect(p * pw, 0, 2, w);
      const cut = r() * w; x.fillRect(p * pw, cut, pw, 2);
    }
    mottle(x, w, w, r, [[8, 0.15]]);
    return [c, 2];
  },
  concrete(r, tint) {
    const w = 1024, { c, x } = speckleFill(w, w, tint || [146, 145, 140], r, 0.06);
    mottle(x, w, w, r, [[4, 0.3], [16, 0.25], [64, 0.2], [256, 0.1]]);
    dots(x, w, w, r, 4000, 0.5, 2, () => "rgba(60,60,60,0.35)");
    x.strokeStyle = "rgba(50,50,50,0.5)"; x.lineWidth = 1.5; x.beginPath(); let px = r() * w, py = 0; x.moveTo(px, py); while (py < w) { px += (r() - 0.5) * 40; py += 10 + r() * 30; x.lineTo(px, py); } x.stroke();
    return [c, 4];
  },
  plain(r, tint) {
    const w = 512, { c, x } = speckleFill(w, w, tint || [180, 172, 160], r, 0.015);
    mottle(x, w, w, r, [[3, 0.15], [12, 0.08]]);
    return [c, 4];
  },
  carpet(r) {
    const w = 1024, { c, x } = speckleFill(w, w, [70, 74, 86], r, 0.22);
    mottle(x, w, w, r, [[6, 0.2], [40, 0.15]]);
    return [c, 2];
  },
  dark(r) {
    const w = 512, { c, x } = speckleFill(w, w, [32, 32, 34], r, 0.05);
    mottle(x, w, w, r, [[4, 0.2], [20, 0.1]]);
    return [c, 4];
  },
};
function canvasTex(c, repeat) {
  const t = new THREE.CanvasTexture(c); t.colorSpace = THREE.SRGBColorSpace; t.anisotropy = 8;
  t.wrapS = t.wrapT = THREE.RepeatWrapping; if (repeat) t.repeat.set(repeat, repeat); return t;
}
async function photoTex(name) { // optional private photo crops; only used when the renderer is told to
  return new Promise((res) => new THREE.TextureLoader().load("/tests/private/textures/" + name, (t) => { t.colorSpace = THREE.SRGBColorSpace; t.anisotropy = 8; t.wrapS = t.wrapT = THREE.RepeatWrapping; res(t); }, undefined, () => res(null)));
}
// mean albedo of a texture image, so photo textures can be scaled to the procedural brightness
function meanRGB(img) { const c = cnv(64, 64), x = c.getContext("2d"); x.drawImage(img, 0, 0, 64, 64); const d = x.getImageData(0, 0, 64, 64).data; let s = [0, 0, 0]; for (let i = 0; i < d.length; i += 4) { s[0] += d[i]; s[1] += d[i + 1]; s[2] += d[i + 2]; } return s.map((v) => v / 4096); }

/* ---------------- geometry ---------------- */
// Slab in its own frame: bottom face on y=0, top corners at y=t. The top is gently curved along x (sag at the middle),
// with an optional small chamfer around the top edge. Returns meshes plus the four top corners (virtual sharp corners).
function slabMeshes(o, matTop, matSide) {
  const hx = o.hx, hz = o.hz, t = o.t, sag = o.sag, c = o.bevel;
  const ht = (u) => t + sag * (1 - (u / hx) ** 2);
  const N = 28, us = [-hx], vs = [-hz];
  for (let i = 0; i <= N; i++) { us.push(-hx + c + (2 * hx - 2 * c) * i / N); vs.push(-hz + c + (2 * hz - 2 * c) * i / N); }
  us.push(hx); vs.push(hz);
  const M = us.length, pos = [], uv = [], idx = [];
  for (let j = 0; j < M; j++) for (let i = 0; i < M; i++) {
    const edge = i === 0 || j === 0 || i === M - 1 || j === M - 1;
    pos.push(us[i], ht(us[i]) - (edge ? c : 0), vs[j]); uv.push((us[i] + hx) / (2 * hx), 1 - (vs[j] + hz) / (2 * hz));
  }
  for (let j = 0; j < M - 1; j++) for (let i = 0; i < M - 1; i++) { const a = j * M + i, b = a + 1, d = a + M, e = d + 1; idx.push(a, d, b, b, d, e); }
  const gTop = new THREE.BufferGeometry(); gTop.setAttribute("position", new THREE.Float32BufferAttribute(pos, 3)); gTop.setAttribute("uv", new THREE.Float32BufferAttribute(uv, 2)); gTop.setIndex(idx); gTop.computeVertexNormals();
  const meshes = [new THREE.Mesh(gTop, matTop)];
  // four side walls following the top edge's height profile
  const sides = [[[-hx, -hz], [hx, -hz]], [[hx, -hz], [hx, hz]], [[hx, hz], [-hx, hz]], [[-hx, hz], [-hx, -hz]]];
  for (const [A, B] of sides) {
    const p = [], q = [], id = [], L = Math.hypot(B[0] - A[0], B[1] - A[1]);
    for (let k = 0; k <= N; k++) { const s = k / N, x = A[0] + (B[0] - A[0]) * s, z = A[1] + (B[1] - A[1]) * s, top = ht(x) - c;
      p.push(x, 0, z, x, top, z); q.push(s * L / (7 * IN), 0, s * L / (7 * IN), top / (1.1 * IN)); }
    for (let k = 0; k < N; k++) { const a = 2 * k; id.push(a, a + 1, a + 2, a + 1, a + 3, a + 2); }
    const g = new THREE.BufferGeometry(); g.setAttribute("position", new THREE.Float32BufferAttribute(p, 3)); g.setAttribute("uv", new THREE.Float32BufferAttribute(q, 2)); g.setIndex(id); g.computeVertexNormals();
    meshes.push(new THREE.Mesh(g, matSide));
  }
  for (const m of meshes) { m.castShadow = true; m.receiveShadow = true; }
  return { meshes, corners: [[-hx, t, -hz], [hx, t, -hz], [hx, t, hz], [-hx, t, hz]].map((a) => new THREE.Vector3(...a)) };
}
// prism with a horizontal polygon footprint (x,z list) from y=0 up to a plane given by topY(x,z)
function prism(foot, topY, mat) {
  const p = [], id = [], n = foot.length;
  for (let i = 0; i < n; i++) { const [x0, z0] = foot[i], [x1, z1] = foot[(i + 1) % n], b = p.length / 3;
    p.push(x0, 0, z0, x1, 0, z1, x0, topY(x0, z0), z0, x1, topY(x1, z1), z1); id.push(b, b + 2, b + 1, b + 1, b + 2, b + 3); }
  const b = p.length / 3; for (const [x, z] of foot) p.push(x, topY(x, z), z);
  for (let i = 1; i < n - 1; i++) id.push(b, b + i + 1, b + i);
  const g = new THREE.BufferGeometry(); g.setAttribute("position", new THREE.Float32BufferAttribute(p, 3)); g.setIndex(id);
  const ng = g.toNonIndexed(); ng.computeVertexNormals();
  const uv = []; const pa = ng.getAttribute("position"); for (let i = 0; i < pa.count; i++) uv.push(pa.getX(i) * 3 + pa.getY(i) * 3, pa.getZ(i) * 3 + pa.getY(i) * 2);
  ng.setAttribute("uv", new THREE.Float32BufferAttribute(uv, 2));
  // make every face point outward (footprint winding may vary)
  const m = new THREE.Mesh(ng, mat); m.castShadow = true; m.receiveShadow = true; return m;
}
function chamferRect(hw, hd, ch, rot, cx, cz) {
  const pts = [[-hw + ch, -hd], [hw - ch, -hd], [hw, -hd + ch], [hw, hd - ch], [hw - ch, hd], [-hw + ch, hd], [-hw, hd - ch], [-hw, -hd + ch]];
  const c = Math.cos(rot), s = Math.sin(rot);
  return pts.map(([x, z]) => [cx + x * c + z * s, cz - x * s + z * c]);
}

/* ---------------- scene ---------------- */
let R = null; // renderer, shared
const cache = { key: null };
async function build(spec) {
  if (!R) {
    // everything is rendered into an off-screen target; the canvas itself is never shown (compositing it is slow)
    R = new THREE.WebGLRenderer({ antialias: false });
    R.setPixelRatio(1); R.setSize(W, H, false);
    R.outputColorSpace = THREE.SRGBColorSpace; R.toneMapping = THREE.LinearToneMapping;
    R.shadowMap.enabled = true; R.shadowMap.type = THREE.PCFSoftShadowMap;
  }
  const r = rng(spec.seed), scene = new THREE.Scene(), out = { scene, spec };
  const L = spec.light;
  // surroundings for the chrome ball to reflect: a big dome, bright above, with a window-like patch
  {
    const c = cnv(512, 256), x = c.getContext("2d"), g = x.createLinearGradient(0, 0, 0, 256);
    g.addColorStop(0, L.type === "outdoor" ? "#9cc4f0" : "#f4efe6"); g.addColorStop(0.45, L.type === "outdoor" ? "#d8e6f2" : "#b9b2a6"); g.addColorStop(0.55, "#6d665c"); g.addColorStop(1, "#3a3530");
    x.fillStyle = g; x.fillRect(0, 0, 512, 256);
    const wx = ((L.az || 0) / 360 + 0.25) % 1 * 512; x.fillStyle = "#ffffff"; x.fillRect(wx - 30, 50, 60, 60);
    for (let i = 0; i < 6; i++) { x.fillStyle = `rgba(${40 + r() * 80 | 0},${40 + r() * 60 | 0},${40 + r() * 40 | 0},0.8)`; x.fillRect(r() * 512, 100 + r() * 40, 20 + r() * 60, 20 + r() * 40); }
    const t = new THREE.CanvasTexture(c); t.colorSpace = THREE.SRGBColorSpace; t.mapping = THREE.EquirectangularReflectionMapping;
    const dome = new THREE.Mesh(new THREE.SphereGeometry(80, 32, 16), new THREE.MeshBasicMaterial({ map: t, side: THREE.BackSide }));
    out.roomTex = t; // metal distractors reflect this
    dome.material.color.setScalar(L.domeGain || 1.0); scene.add(dome);
  }
  // floor
  let ft;
  ft = TEX[spec.floor](r, spec.floorTint);
  const floorMat = new THREE.MeshStandardMaterial({ map: canvasTex(ft[0], 60 / ft[1]), roughness: 0.85 });
  const floor = new THREE.Mesh(new THREE.PlaneGeometry(60, 60), floorMat); floor.rotation.x = -Math.PI / 2;
  floor.rotation.z = rad(spec.floorRot || 0); floor.receiveShadow = true; scene.add(floor);

  // slab orientation: yaw about up, then tilt by `tilt` toward compass heading `heading` (0 = toward +z)
  const S = spec.slab || {}, hx = (S.size || 7) * (S.aspect || 1) / 24, hz = (S.size || 7) / 24;
  const tl = rad(S.tilt || 0), hd = rad(S.heading || 0);
  const n = new THREE.Vector3(Math.sin(tl) * Math.sin(hd), Math.cos(tl), Math.sin(tl) * Math.cos(hd)).normalize();
  const qT = new THREE.Quaternion().setFromUnitVectors(new THREE.Vector3(0, 1, 0), n), qY = new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0, 1, 0), rad(S.yaw || 0));
  const q = qT.clone().multiply(qY);
  const B = spec.base || {};
  const foot = chamferRect(hx * (B.sx || 1.1), hz * (B.sz || 1.05), (B.chamfer || 1.0) * IN, rad((S.yaw || 0) + (B.yawOff || 0)), (B.ox || 0) * IN, (B.oz || 0) * IN);
  // the slab's bottom plane passes through P0 with normal n; lift P0 so the base is at least `minH` tall and the slab clears the ground
  const t = (S.thick || 0.9) * IN, minH = (B.minH || 1.3) * IN;
  const below = (x, z) => -(n.x * x + n.z * z) / n.y; // plane height offset relative to P0.y at (x,z)
  let P0y = 0; for (const [x, z] of foot) P0y = Math.max(P0y, minH - below(x, z));
  const slabFoot = [[-hx, -hz], [hx, -hz], [hx, hz], [-hx, hz]].map(([x, z]) => new THREE.Vector3(x, 0, z).applyQuaternion(q));
  for (const v of slabFoot) P0y = Math.max(P0y, 0.25 * IN - v.y);
  const P0 = new THREE.Vector3(0, P0y, 0);
  out.n = n; out.q = q; out.P0 = P0; out.hx = hx; out.hz = hz; out.t = t;
  // material set-up (procedural by default, photo crops when asked and available)
  const tex = { top: canvasTex(TEX.cementTop(r)), side: canvasTex(TEX.cementSide(r)), base: canvasTex(TEX.baseBlack(r)) };
  if (spec.photoTextures) {
    for (const [k, f] of [["top", "cement_top.jpg"], ["side", "cement_side.jpg"], ["base", "base_black.jpg"]]) {
      const pt = await photoTex(f); if (pt) { pt.userData.photo = true; tex[k] = pt; }
    }
  }
  const albedo = { top: [96, 99, 90], side: [138, 138, 134], base: [17, 17, 18] };
  const mk = (k, rough) => {
    const m = new THREE.MeshStandardMaterial({ map: tex[k], roughness: rough });
    if (tex[k].userData.photo) { const mr = meanRGB(tex[k].image); m.color.setRGB(...albedo[k].map((a, i) => Math.min(4, a / Math.max(4, mr[i]))), THREE.SRGBColorSpace); }
    return m;
  };
  const tint = S.tint || [1, 1, 1];
  const matTop = mk("top", 0.92), matSide = mk("side", 0.95), matBase = mk("base", B.rough || 0.45);
  matTop.color.multiply(new THREE.Color(...tint)); matSide.color.multiply(new THREE.Color(...(S.sideTint || tint)));
  if (spec.slabPresent !== false) {
    const sl = slabMeshes({ hx, hz, t, sag: (S.sag ?? 0.1) * IN, bevel: (S.bevel ?? 0.05) * IN }, matTop, matSide);
    const grp = new THREE.Group(); for (const m of sl.meshes) grp.add(m); grp.position.copy(P0); grp.quaternion.copy(q); scene.add(grp);
    grp.updateMatrixWorld(true); out.corners = sl.corners.map((c) => c.clone().applyMatrix4(grp.matrixWorld));
    out.slabGroup = grp;
  } else out.corners = null;
  if (spec.slabPresent !== false || spec.baseOnly) scene.add(prism(foot, (x, z) => P0.y + below(x, z), matBase));
  // top-centre of the slab plane through its corners (world)
  out.C = new THREE.Vector3(0, t, 0).applyQuaternion(q).add(P0);

  // lights
  const amb = L.amb ?? 0.8, sun = L.sun ?? 2.2;
  scene.add(new THREE.HemisphereLight(L.type === "outdoor" ? 0xbfd8ff : 0xfff4e6, 0x5a5048, amb * Math.PI * 0.35));
  const dl = new THREE.DirectionalLight(L.type === "outdoor" ? 0xfff2dc : 0xfff6ea, sun * Math.PI * 0.35);
  const lel = rad(L.el ?? 50), laz = rad(L.az ?? 30);
  dl.position.set(Math.cos(lel) * Math.sin(laz) * 10, Math.sin(lel) * 10, Math.cos(lel) * Math.cos(laz) * 10).add(out.C);
  dl.target.position.copy(out.C); scene.add(dl.target);
  dl.castShadow = true; dl.shadow.mapSize.set(2048, 2048); Object.assign(dl.shadow.camera, { left: -3, right: 3, top: 3, bottom: -3, near: 1, far: 30 });
  dl.shadow.bias = -0.0004; dl.shadow.normalBias = 0.01; dl.shadow.radius = L.softShadow ?? 3; scene.add(dl);
  if (L.fill) { const f2 = new THREE.PointLight(0xffffff, L.fill * 4, 0, 2); f2.position.set(-2, 4, 2).add(out.C); scene.add(f2); }

  // extras: things that might fool the slab or ball detectors
  for (const e of spec.extras || []) addExtra(scene, e, out, r);

  // ball and hand
  if (spec.ball) {
    out.crt = new THREE.WebGLCubeRenderTarget(128, { type: THREE.HalfFloatType });
    out.cube = new THREE.CubeCamera(0.02, 100, out.crt); scene.add(out.cube);
    const bm = new THREE.MeshStandardMaterial({ color: 0xf2f2f2, metalness: 1, roughness: 0.06, envMap: out.crt.texture });
    out.ball = new THREE.Mesh(new THREE.SphereGeometry(35 / 1000 / M_PER_FT / 2, 48, 32), bm); out.ball.castShadow = true; scene.add(out.ball);
    if (spec.ball.hand !== false) {
      // a pinch grip: two fingertips on either side of the ball's top, a palm, and a forearm running to the shoulder.
      // arm "self": the person holding the phone reaches out with the other hand (arm comes from the camera side);
      // arm "other": someone across the slab holds it (arm rises away from the camera).
      const skin = new THREE.MeshStandardMaterial({ color: new THREE.Color(0.78, 0.55, 0.43), roughness: 0.6 });
      const mesh = (g) => { const m = new THREE.Mesh(g, skin); m.castShadow = true; scene.add(m); return m; };
      out.hand = { fingers: [mesh(new THREE.CapsuleGeometry(0.026, 0.13, 4, 12)), mesh(new THREE.CapsuleGeometry(0.03, 0.1, 4, 12))],
        palm: mesh(new THREE.SphereGeometry(0.15, 20, 14)), arm: mesh(new THREE.CylinderGeometry(0.1, 0.13, 1, 16)), mode: spec.ball.arm || "other" };
    }
  }
  out.camera = new THREE.PerspectiveCamera(spec.cam.fov || 72.5, W / H, 0.05, 200);
  // sensor-model constants for this clip
  const sr = rng(spec.seed * 7 + 3);
  const ax = new THREE.Vector3(gauss(sr), gauss(sr), gauss(sr)).normalize();
  out.sensorBias = new THREE.Quaternion().setFromAxisAngle(ax, rad(spec.sensor?.bias ?? 0.3));
  out.shake = makeShake(rng(spec.seed * 13 + 5), spec.cam.shake ?? 1);
  out.handSway = [bandSignal(r, 0.2, 1.2), bandSignal(r, 0.2, 1.2), bandSignal(r, 0.2, 1.2)];
  out.ae = null; out.rn = rng(spec.seed * 31 + 7);
  return out;
}
function addExtra(scene, e, ctx, r) {
  const at = (x, z) => new THREE.Vector3(x, 0, z).add(new THREE.Vector3(ctx.C.x, 0, ctx.C.z));
  const std = (o) => new THREE.MeshStandardMaterial(o);
  let m;
  if (e.type === "tin") { // round tin with a lid: silver or black
    m = new THREE.Mesh(new THREE.CylinderGeometry(e.r || 0.11, e.r || 0.11, e.h || 0.12, 48), std({ color: e.lid === "black" ? 0x111111 : 0xd8d8d8, metalness: e.lid === "black" ? 0.2 : 1, roughness: e.lid === "black" ? 0.4 : 0.18, envMap: ctx.roomTex, envMapIntensity: 1 }));
    m.position.copy(at(e.x, e.z)).setY((e.h || 0.12) / 2);
  } else if (e.type === "coin" || e.type === "sticker") {
    const col = e.type === "coin" ? 0xb87333 : 0xf4f4f0;
    m = new THREE.Mesh(new THREE.CylinderGeometry(e.r || (e.type === "coin" ? 0.04 : 0.06), e.r || (e.type === "coin" ? 0.04 : 0.06), 0.006, 40), std({ color: col, metalness: e.type === "coin" ? 0.8 : 0, roughness: e.type === "coin" ? 0.35 : 0.7, envMap: e.type === "coin" ? ctx.roomTex : null }));
    if (e.onSlab) { const p = new THREE.Vector3(e.x, ctx.t + 0.003, e.z).applyQuaternion(ctx.q).add(ctx.P0); m.position.copy(p); m.quaternion.copy(ctx.q); }
    else m.position.copy(at(e.x, e.z)).setY(0.003);
  } else if (e.type === "floorball") {
    const Rb = 35 / 1000 / M_PER_FT / 2;
    m = new THREE.Mesh(new THREE.SphereGeometry(Rb, 48, 32), std({ color: 0xf2f2f2, metalness: 1, roughness: 0.06 })); m.position.copy(at(e.x, e.z)).setY(Rb);
    // a floor ball reflects a generic room (static); good enough to look like chrome
    const crt = new THREE.WebGLCubeRenderTarget(64, { type: THREE.HalfFloatType }); const cc = new THREE.CubeCamera(0.02, 100, crt); cc.position.copy(m.position); scene.add(cc); m.material.envMap = crt.texture; ctx.staticCubes = (ctx.staticCubes || []).concat([[cc, m]]);
  } else if (e.type === "box") {
    m = new THREE.Mesh(new THREE.BoxGeometry(e.w, e.h, e.d), std({ color: e.color || 0xa07a52, roughness: 0.9 })); m.position.copy(at(e.x, e.z)).setY(e.h / 2); m.rotation.y = rad(e.rot || 0);
  } else if (e.type === "paper" || e.type === "rect") { // flat sheet / tile lying on the floor (optionally on a black pad)
    if (e.pad) { const p = new THREE.Mesh(new THREE.BoxGeometry(e.w * 1.3, 0.08, e.d * 1.25), std({ color: 0x0c0c0c, roughness: 0.5 })); p.position.copy(at(e.x, e.z)).setY(0.04); p.rotation.y = rad(e.rot || 0); p.castShadow = p.receiveShadow = true; scene.add(p); }
    const col = e.type === "paper" ? 0xf2f2ee : (e.color || 0x6f716a);
    m = new THREE.Mesh(new THREE.BoxGeometry(e.w, e.th || 0.01, e.d), std({ color: col, roughness: 0.9, map: e.type === "rect" ? canvasTex(TEX.cementTop(r)) : null }));
    m.position.copy(at(e.x, e.z)).setY((e.pad ? 0.08 : 0) + (e.th || 0.01) / 2); m.rotation.y = rad(e.rot || 0);
  } else if (e.type === "stick") {
    m = new THREE.Mesh(new THREE.CylinderGeometry(0.012, 0.012, e.l || 0.8, 10), std({ color: 0xd9b48a, roughness: 0.7 })); m.position.copy(at(e.x, e.z)).setY(0.012); m.rotation.set(Math.PI / 2, 0, rad(e.rot || 0));
  }
  if (m) { m.castShadow = true; m.receiveShadow = true; scene.add(m); }
}

/* ---------------- camera motion: keyframes + hand shake ---------------- */
function makeShake(r, k) {
  // slow sway plus physiological tremor, in rotation (deg) and translation (ft)
  const s = (f0, f1) => bandSignal(r, f0, f1);
  const rot = [s(0.2, 1.5), s(0.2, 1.5), s(0.2, 1.5)], trem = [s(6, 11), s(6, 11), s(6, 11)], tr = [s(0.2, 1.5), s(0.2, 1.5), s(0.2, 1.5)];
  return (t) => ({
    rot: rot.map((f, i) => k * (0.35 * f(t) + 0.04 * trem[i](t))), // degrees
    tr: tr.map((f) => k * 0.009 * f(t)), // ~3 mm rms per axis at k=1
  });
}
function basePose(spec, t) {
  const keys = spec.cam.keys; let a = keys[0], b = keys[0];
  for (let i = 0; i < keys.length; i++) { if (keys[i].t <= t) { a = keys[i]; b = keys[i + 1] || keys[i]; } }
  const s = b === a ? 0 : smooth((t - a.t) / (b.t - a.t)), lerp = (k, d = 0) => (a[k] ?? d) + ((b[k] ?? d) - (a[k] ?? d)) * s;
  return { D: lerp("D"), el: lerp("el"), az: lerp("az"), yaw: lerp("yaw"), pitch: lerp("pitch"), roll: lerp("roll") };
}
function cameraAt(ctx, t, withShake = true) {
  const spec = ctx.spec, p = basePose(spec, t), C = ctx.C;
  const el = rad(p.el), az = rad(p.az);
  const pos = new THREE.Vector3(Math.cos(el) * Math.sin(az), Math.sin(el), Math.cos(el) * Math.cos(az)).multiplyScalar(p.D * 1).add(C);
  const m = new THREE.Matrix4().lookAt(pos, C, new THREE.Vector3(0, 1, 0)), q = new THREE.Quaternion().setFromRotationMatrix(m);
  q.multiply(new THREE.Quaternion().setFromEuler(new THREE.Euler(rad(p.pitch), rad(p.yaw), rad(p.roll), "YXZ")));
  if (withShake) {
    const sh = ctx.shake(t);
    q.multiply(new THREE.Quaternion().setFromEuler(new THREE.Euler(rad(sh.rot[0]), rad(sh.rot[1]), rad(sh.rot[2]), "XYZ")));
    pos.add(new THREE.Vector3(...sh.tr).applyQuaternion(q));
  }
  return { pos, q };
}
function isStill(spec, t) {
  const a = basePose(spec, t - 0.15), b = basePose(spec, t + 0.15);
  return Object.keys(a).every((k) => Math.abs(a[k] - b[k]) < 1e-6);
}

/* ---------------- ball motion ---------------- */
const RB = 35 / 1000 / M_PER_FT / 2;
function ballAt(ctx, t) {
  const b = ctx.spec.ball, C = ctx.C, n = ctx.n;
  const sway = ctx.handSway.map((f) => f(t) * 0.006 * (b.sway ?? 1));
  const p0 = new THREE.Vector3(C.x + (b.dx || 0) + sway[0], C.y + (b.h || 2) + RB + sway[1], C.z + (b.dz || 0) + sway[2]);
  const hold = { pos: p0, held: true };
  if (b.drop == null || t < b.drop) return hold;
  const d0 = b.drop, ps = ballAt(ctx, d0 - 1e-6).pos; // release point
  const hPlane = n.dot(ps.clone().sub(C)); // distance from the plane along its normal
  const tau = Math.sqrt(Math.max(0, 2 * (hPlane - RB) / (n.y * G_FT))), dt = t - d0;
  if (dt <= tau) return { pos: ps.clone().add(new THREE.Vector3(0, -0.5 * G_FT * dt * dt, 0)), held: false };
  const vin = new THREE.Vector3(0, -G_FT * tau, 0), vout = vin.clone().sub(n.clone().multiplyScalar(2 * vin.dot(n))).multiplyScalar(0.7);
  const pi = ps.clone().add(new THREE.Vector3(0, -0.5 * G_FT * tau * tau, 0)), u = dt - tau;
  const p = pi.add(vout.multiplyScalar(u)).add(new THREE.Vector3(0, -0.5 * G_FT * u * u, 0));
  if (p.y < RB) p.y = RB;
  return { pos: p, held: false };
}

/* ---------------- projection + ground truth ---------------- */
function focalPx(spec) { return (H / 2) / Math.tan(rad(spec.cam.fov || 72.5) / 2); }
// world point -> app camera coords (x right, y down, z forward)
function toApp(cam, v) { const p = v.clone().sub(cam.pos).applyQuaternion(cam.q.clone().invert()); return [p.x, -p.y, -p.z]; }
function dirToApp(cam, v) { const p = v.clone().applyQuaternion(cam.q.clone().invert()); return [p.x, -p.y, -p.z]; }
function project(spec, P) {
  const f = focalPx(spec); if (P[2] <= 0.01) return null;
  let x = f * P[0] / P[2], y = f * P[1] / P[2];
  const k1 = spec.cam.k1 || 0; if (k1) { const r2 = (x * x + y * y) / (f * f), s = 1 + k1 * r2; x *= s; y *= s; }
  return [W / 2 + x, H / 2 + y];
}
function groundTruth(ctx, t) {
  const spec = ctx.spec, cam = cameraAt(ctx, t), f = focalPx(spec), gt = { t: +t.toFixed(4), still: isStill(spec, t) };
  const up = new THREE.Vector3(0, 1, 0);
  gt.grav = dirToApp(cam, up.clone().negate());
  if (ctx.corners) {
    const pc = ctx.corners.map((c) => project(spec, toApp(cam, c)));
    gt.corners = pc.every(Boolean) ? pc.map((p) => [+p[0].toFixed(2), +p[1].toFixed(2)]) : null;
    gt.slabVisible = !!gt.corners && gt.corners.every(([x, y]) => x >= 3 && y >= 3 && x <= W - 3 && y <= H - 3);
    gt.normal = dirToApp(cam, ctx.n).map((v) => +v.toFixed(5));
    gt.tilt = +deg(Math.acos(ctx.n.y)).toFixed(3);
    gt.dist = +toApp(cam, ctx.C)[2].toFixed(3);
    gt.side = +(gt.corners ? [0, 1, 2, 3].reduce((s, i) => s + Math.hypot(gt.corners[(i + 1) % 4][0] - gt.corners[i][0], gt.corners[(i + 1) % 4][1] - gt.corners[i][1]), 0) / 4 : 0).toFixed(1);
  } else { gt.slabVisible = false; gt.corners = null; }
  if (ctx.ball) {
    const b = ballAt(ctx, t), P = toApp(cam, b.pos), c = project(spec, P), dist = Math.hypot(...P);
    const rr = f * RB / Math.sqrt(Math.max(1e-6, dist * dist - RB * RB));
    // drop height: straight down from the ball's centre to the plane through the slab corners, minus the radius
    const n = ctx.n, s = n.dot(b.pos.clone().sub(ctx.C)) / n.y, hit = b.pos.clone().sub(up.clone().multiplyScalar(s));
    const loc = hit.clone().sub(ctx.C).applyQuaternion(ctx.q.clone().invert());
    const on = Math.abs(loc.x) <= ctx.hx && Math.abs(loc.z) <= ctx.hz;
    let rim = 0;
    if (c) {
      if (ctx.hand) poseHand(ctx, ballAt(ctx, Math.min(t, spec.ball.drop ?? t)).pos, cam);
      const hm = ctx.hand ? [...ctx.hand.fingers, ctx.hand.palm, ctx.hand.arm] : []; for (const m of hm) m.updateMatrixWorld(true);
      const v = b.pos.clone().sub(cam.pos), d2 = v.lengthSq(), k = 1 - RB * RB / d2, a = v.clone().normalize();
      const u1 = new THREE.Vector3().crossVectors(a, new THREE.Vector3(0, 1, 0)).normalize(), u2 = new THREE.Vector3().crossVectors(a, u1);
      const rc = new THREE.Raycaster(); let ok = 0;
      for (let j = 0; j < 48; j++) {
        const th = j * Math.PI / 24, u = u1.clone().multiplyScalar(Math.cos(th)).add(u2.clone().multiplyScalar(Math.sin(th)));
        const ps = cam.pos.clone().add(v.clone().multiplyScalar(k)).add(u.multiplyScalar(RB * Math.sqrt(k) * 0.97)); // just inside the silhouette
        const pp = project(spec, toApp(cam, ps)); if (!pp || pp[0] < 1 || pp[1] < 1 || pp[0] > W - 1 || pp[1] > H - 1) continue;
        rc.set(cam.pos, ps.clone().sub(cam.pos).normalize()); rc.far = ps.distanceTo(cam.pos) - 0.002;
        if (!hm.length || !rc.intersectObjects(hm, false).length) ok++;
      }
      rim = ok / 48;
    }
    const vis = rim >= 0.8;
    gt.ball = { x: c ? +c[0].toFixed(2) : null, y: c ? +c[1].toFixed(2) : null, r: +rr.toFixed(2), visible: vis, rim: +rim.toFixed(2), held: b.held, onSlab: on, drop: +(s - RB).toFixed(4) };
  }
  return gt;
}

/* ---------------- sensors (W3C DeviceMotionEvent convention; device axes = three camera axes) ---------------- */
function sensorAt(ctx, t) {
  const h = 1 / 240, c0 = cameraAt(ctx, t - h), c1 = cameraAt(ctx, t), c2 = cameraAt(ctx, t + h);
  const acc = c2.pos.clone().add(c0.pos).sub(c1.pos.clone().multiplyScalar(2)).multiplyScalar(1 / (h * h) * M_PER_FT); // m/s^2 world
  const dq = c1.q.clone().invert().multiply(c2.q); // rotation over h in the device frame
  const ang = 2 * Math.acos(Math.min(1, Math.abs(dq.w))), ax = new THREE.Vector3(dq.x, dq.y, dq.z);
  const w = ax.lengthSq() > 1e-18 ? ax.normalize().multiplyScalar(ang / h * Math.sign(dq.w || 1)) : new THREE.Vector3();
  const inv = c1.q.clone().invert(), rn = ctx.rn, sn = ctx.spec.sensor || {}, an = 0.02 * (sn.noise ?? 1), gn = 0.25 * (sn.noise ?? 1);
  const user = acc.clone().applyQuaternion(inv);
  const fWorld = acc.clone().add(new THREE.Vector3(0, 9.81, 0)).applyQuaternion(ctx.sensorBias); // specific force, with a small mounting/calibration error
  const aig = fWorld.applyQuaternion(inv);
  const noisy = (v, s) => [v.x + gauss(rn) * s, v.y + gauss(rn) * s, v.z + gauss(rn) * s];
  let A = noisy(aig, an), U = noisy(user, an);
  if (sn.iosSign) { A = A.map((v) => -v); U = U.map((v) => -v); }
  const wd = [deg(w.x) + gauss(rn) * gn, deg(w.y) + gauss(rn) * gn, deg(w.z) + gauss(rn) * gn];
  return { t: +t.toFixed(4), aig: A.map((v) => +v.toFixed(4)), acc: sn.noAcc ? null : U.map((v) => +v.toFixed(4)), rot: { alpha: +wd[2].toFixed(3), beta: +wd[0].toFixed(3), gamma: +wd[1].toFixed(3) } };
}

/* ---------------- rendering with exposure, blur, distortion and noise ---------------- */
let CTX = null, OUTC = null, OUTX = null, OUTI = null; // one software 2D canvas for encoding (a GPU canvas stalls WebGL)
async function prepareClip(spec) { const key = JSON.stringify(spec); if (!CTX || CTX.key !== key) { if (CTX) disposeScene(CTX.scene); CTX = await build(spec); CTX.key = key; } window.__ctx = CTX; window.__R = R; window.__renderOnce = renderOnce; return CTX; }
function disposeScene(s) { s.traverse((o) => { if (o.geometry) o.geometry.dispose(); if (o.material) { for (const k in o.material) { const v = o.material[k]; if (v && v.isTexture) v.dispose(); } o.material.dispose(); } }); }
function place(ctx, t) {
  const cam = cameraAt(ctx, t); ctx.camera.position.copy(cam.pos); ctx.camera.quaternion.copy(cam.q); ctx.camera.updateMatrixWorld(true);
  if (ctx.ball) {
    const b = ballAt(ctx, t); ctx.ball.position.copy(b.pos);
    if (ctx.hand) poseHand(ctx, ballAt(ctx, Math.min(t, ctx.spec.ball.drop ?? t)).pos, cam);
  }
}
function poseHand(ctx, bp, cam) {
  const h = ctx.hand, up = new THREE.Vector3(0, 1, 0);
  let sh;
  let hd;
  if (h.mode === "self") {
    // the phone holder reaches out with the other hand: shoulder below and to the right of the phone, and the hand
    // pinches the ball from the upper right so the forearm doesn't cross in front of it
    const right = new THREE.Vector3(1, 0, 0).applyQuaternion(cam.q).setY(0).normalize();
    sh = cam.pos.clone().add(right.clone().multiplyScalar(1.0)).add(new THREE.Vector3(0, -1.1, 0));
    hd = up.clone().multiplyScalar(0.6).add(right.multiplyScalar(0.8)).normalize();
  } else { const away = bp.clone().sub(cam.pos).setY(0).normalize(); sh = bp.clone().add(away.multiplyScalar(1.2)).add(new THREE.Vector3(0, 1.6, 0)); }
  // the hand pinches the ball from above; the forearm runs from the wrist to the shoulder
  const toSh = sh.clone().sub(bp); if (!hd) hd = up.clone().add(toSh.clone().setY(0).normalize().multiplyScalar(0.3)).normalize();
  const side = new THREE.Vector3().crossVectors(hd, toSh).normalize(); if (!isFinite(side.x)) side.set(1, 0, 0);
  const qh = new THREE.Quaternion().setFromUnitVectors(up, hd);
  h.fingers.forEach((f, k) => { const s = k ? -1 : 1; f.position.copy(bp).add(side.clone().multiplyScalar(s * RB * 1.2)).add(hd.clone().multiplyScalar(RB * 1.5)); f.quaternion.copy(qh); });
  h.palm.position.copy(bp).add(hd.clone().multiplyScalar(RB + 0.17)); h.palm.quaternion.copy(qh); h.palm.scale.set(0.75, 0.5, 0.45);
  const wrist = bp.clone().add(hd.clone().multiplyScalar(RB + 0.25)), dir = sh.clone().sub(wrist).normalize(), len = Math.min(2.4, Math.max(0.3, sh.distanceTo(wrist) - 0.2));
  const qd = new THREE.Quaternion().setFromUnitVectors(up, dir);
  h.arm.position.copy(wrist).add(dir.clone().multiplyScalar(len / 2)); h.arm.quaternion.copy(qd); h.arm.scale.set(1, len, 1);
}
const readBuf = new Float32Array(W * H * 4);
const PROF = (window.__prof = {});
const tm = (k, t0) => { PROF[k] = (PROF[k] || 0) + performance.now() - t0; };
let RT = null;
// render off-screen in linear float (reading back the on-screen canvas is very slow in SwiftShader);
// exposure, clipping and the sRGB curve are applied in software afterwards
function renderOnce(ctx) {
  if (!RT) RT = new THREE.WebGLRenderTarget(W, H, { type: THREE.FloatType, samples: 4 });
  let t0 = performance.now(); R.setRenderTarget(RT); R.render(ctx.scene, ctx.camera); tm("render", t0); t0 = performance.now();
  R.readRenderTargetPixels(RT, 0, 0, W, H, readBuf); R.setRenderTarget(null); tm("read", t0);
  return readBuf;
}
// linear radiance * exposure -> display value 0..255 (sRGB curve with a soft shoulder)
const encF = (v) => { v = v <= 0 ? 0 : v < 0.8 ? v : 0.8 + 0.2 * (1 - Math.exp(-(v - 0.8) / 0.2)); return 255 * (v <= 0.0031308 ? 12.92 * v : 1.055 * Math.pow(v, 1 / 2.4) - 0.055); };
const LUTN = 1024, LUTMAX = 6, LUT = new Float32Array(LUTN * LUTMAX + 2); for (let i = 0; i < LUT.length; i++) LUT[i] = encF(i / LUTN);
const enc = (v) => { if (v <= 0) return 0; const x = v * LUTN; if (x >= LUTN * LUTMAX) return 255; const i = x | 0, f = x - i; return LUT[i] + (LUT[i + 1] - LUT[i]) * f; };
function meanLuma(buf, e) { let s = 0, n = 0; for (let y = H * 0.2 | 0; y < H * 0.8; y += 4) for (let x = W * 0.15 | 0; x < W * 0.85; x += 4) { const i = (y * W + x) * 4; s += 0.299 * enc(buf[i] * e) + 0.587 * enc(buf[i + 1] * e) + 0.114 * enc(buf[i + 2] * e); n++; } return s / n / 255; }

window.renderClipFrame = async (spec, i) => {
  const ctx = await prepareClip(spec), fps = spec.fps || 30, t = i / fps, L = spec.light, lev = L.level ?? 1;
  const ex = spec.expo || {};
  // exposure time: bright scenes are short, dim ones long (more motion blur); capped by the frame interval
  const expT = Math.min(1 / fps, (ex.time || 1 / 250) / Math.min(1, lev));
  if (ctx.staticCubes) for (const [cc, m] of ctx.staticCubes) { m.visible = false; cc.update(R, ctx.scene); m.visible = true; }
  // auto exposure: settle on the first frame, then follow slowly (like a phone), plus optional deliberate drift
  const target = ex.target ?? 0.42;
  if (ctx.ae == null) { ctx.ae = 1; place(ctx, t); const b0 = renderOnce(ctx); for (let k = 0; k < 12; k++) { const m = meanLuma(b0, ctx.ae); ctx.ae *= Math.pow(target / Math.max(0.02, m), 1.6); } }
  const drift = 1 + (ex.drift || 0) * Math.sin(2 * Math.PI * t / (ex.period || 2.5));
  const expo = ctx.ae * drift;
  // motion blur: enough sub-frames that nothing moves more than ~1.5 px between them
  const span = (tt) => { const g = groundTruth(ctx, tt); const pts = []; if (g.corners) pts.push(...g.corners); if (g.ball && g.ball.x != null) pts.push([g.ball.x, g.ball.y]); return pts; };
  const a = span(t - expT / 2), b = span(t + expT / 2); let mv = 0; for (let k = 0; k < Math.min(a.length, b.length); k++) mv = Math.max(mv, Math.hypot(a[k][0] - b[k][0], a[k][1] - b[k][1]));
  const K = Math.max(1, Math.min(8, Math.ceil(mv / 1.5))); let tq = performance.now();
  const acc = new Float32Array(W * H * 3);
  for (let s = 0; s < K; s++) {
    const ts = t + expT * ((s + 0.5) / K - 0.5); place(ctx, ts);
    if (ctx.cube && s === 0) { ctx.ball.visible = false; ctx.cube.position.copy(ctx.ball.position); ctx.cube.update(R, ctx.scene); ctx.ball.visible = true; }
    const buf = renderOnce(ctx);
    for (let y = 0; y < H; y++) { const src = (H - 1 - y) * W * 4, dst = y * W * 3; for (let x = 0; x < W; x++) { acc[dst + x * 3] += enc(buf[src + x * 4] * expo); acc[dst + x * 3 + 1] += enc(buf[src + x * 4 + 1] * expo); acc[dst + x * 3 + 2] += enc(buf[src + x * 4 + 2] * expo); } }
  }
  tm("subframes", tq); tq = performance.now();
  // AE follows this frame's brightness for the next one
  { let s = 0, n = 0; for (let y = H * 0.2 | 0; y < H * 0.8; y += 4) for (let x = W * 0.15 | 0; x < W * 0.85; x += 4) { const j = (y * W + x) * 3; s += (0.299 * acc[j] + 0.587 * acc[j + 1] + 0.114 * acc[j + 2]) / K; n++; }
    ctx.ae *= Math.pow(target / Math.max(0.02, s / n / 255 / drift), 0.12); }
  let img = acc; for (let j = 0; j < img.length; j++) img[j] /= K;
  // lens distortion (radial), so the pinhole assumption is only approximately right
  const k1 = spec.cam.k1 || 0;
  if (k1) {
    const f = focalPx(spec), o = new Float32Array(img.length);
    for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
      let ux = x + 0.5 - W / 2, uy = y + 0.5 - H / 2; const dx = ux, dy = uy;
      for (let it = 0; it < 3; it++) { const s = 1 + k1 * (ux * ux + uy * uy) / (f * f); ux = dx / s; uy = dy / s; }
      const sx = Math.min(W - 1.001, Math.max(0, ux + W / 2 - 0.5)), sy = Math.min(H - 1.001, Math.max(0, uy + H / 2 - 0.5)), xi = sx | 0, yi = sy | 0, fx = sx - xi, fy = sy - yi;
      for (let c = 0; c < 3; c++) { const p = (yi * W + xi) * 3 + c; o[(y * W + x) * 3 + c] = (img[p] * (1 - fx) + img[p + 3] * fx) * (1 - fy) + (img[p + W * 3] * (1 - fx) + img[p + W * 3 + 3] * fx) * fy; }
    }
    img = o;
  }
  // sensor noise after the phone's own denoising: blotchy low-frequency grain plus fine grain, both stronger in dim light
  const rn = ctx.rn, nz = (spec.noise ?? 1) * 1.6 / Math.sqrt(Math.min(1, lev));
  const hw = W >> 1, hh = H >> 1, low = new Float32Array(hw * hh * 3);
  for (let j = 0; j < low.length; j++) low[j] = gauss(rn);
  if (!OUTC) { OUTC = cnv(W, H); OUTX = OUTC.getContext("2d", { willReadFrequently: true }); OUTI = OUTX.createImageData(W, H); }
  const c2 = OUTC, x2 = OUTX, id = OUTI, d = id.data;
  const soft = lev < 0.3 ? 0.5 : 0; // heavy in-camera noise reduction smears fine detail in low light
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    const j = (y * W + x) * 3, l = (((y >> 1) * hw) + (x >> 1)) * 3, Y = 0.299 * img[j] + 0.587 * img[j + 1] + 0.114 * img[j + 2];
    const sd = nz * (0.5 + 0.5 * Math.sqrt(Math.max(0, Y) / 128)), lum = gauss(rn) * sd * 0.6 + low[l] * sd;
    for (let c = 0; c < 3; c++) {
      let v = img[j + c];
      if (soft && x > 0 && y > 0 && x < W - 1 && y < H - 1) v = v * (1 - soft) + soft * 0.25 * (img[j + c - 3] + img[j + c + 3] + img[j + c - W * 3] + img[j + c + W * 3]);
      d[(y * W + x) * 4 + c] = v + lum + low[l + c] * sd * 0.35;
    }
    d[(y * W + x) * 4 + 3] = 255;
  }
  tm("post", tq); tq = performance.now();
  x2.putImageData(id, 0, 0);
  const jpeg = c2.toDataURL("image/jpeg", spec.jpegQ || 0.88);
  tm("jpeg", tq);
  const gt = groundTruth(ctx, t); gt.subframes = K; gt.exposure = +expo.toFixed(4);
  return { jpeg, gt };
};
window.sensorSamples = async (spec, times) => { const ctx = await prepareClip(spec); return times.map((t) => sensorAt(ctx, t)); };
window.sceneReady = true;
