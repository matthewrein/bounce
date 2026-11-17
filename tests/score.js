// Score one clip's per-tick app readings against the ground truth.
"use strict";

const SETTLE = 0.5; // seconds after a lock before accuracy and jitter count
const GRACE = 0.5;  // seconds after the slab leaves view during which a held outline isn't a false lock

const v3 = { dot: (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2], norm: (a) => { const l = Math.hypot(...a) || 1; return a.map((x) => x / l); } };
const angDeg = (a, b) => Math.acos(Math.max(-1, Math.min(1, v3.dot(v3.norm(a), v3.norm(b))))) * 180 / Math.PI;
function quantile(a, q) { if (!a.length) return null; const s = a.slice().sort((x, y) => x - y), i = (s.length - 1) * q, lo = Math.floor(i); return s[lo] + (s[Math.min(s.length - 1, lo + 1)] - s[lo]) * (i - lo); }
const mean = (a) => a.length ? a.reduce((s, x) => s + x, 0) / a.length : null;
const r2 = (x, d = 2) => x == null ? null : +x.toFixed(d);

// mean corner distance between two quads, over every cyclic order and both directions
function cornerErr(q, g) {
  let best = Infinity;
  for (const dir of [1, -1]) for (let k = 0; k < 4; k++) {
    let s = 0; for (let i = 0; i < 4; i++) { const j = (k + dir * i + 8) % 4; s += Math.hypot(q[j][0] - g[i][0], q[j][1] - g[i][1]); }
    best = Math.min(best, s / 4);
  }
  return best;
}
function partlyInView(c) { return c && c.some(([x, y]) => x > -40 && y > -40 && x < 760 && y < 1320); }

function scoreClip(gt, ticks) {
  const F = gt.frames, fps = gt.fps, out = { name: gt.spec.name, tags: gt.spec.tags, ticks: ticks.length };
  let firstVis = null, firstLock = null, lockedSince = null, lastVis = -1e9, inFalse = false;
  let vis = 0, good = 0, falseTicks = 0, falseEvents = 0;
  const bErr = [], hitErr = [], gErr = [], cErr = [], nErr = [], tErr = [], jitN = [], jitT = [], jitC = [], msS = [], msT = [];
  let ballCount = 0, ballHit = 0, ballFP = 0, ballFPev = 0, inFP = false, ballStale = 0; const dropErr = [], recent = [];
  for (const k of ticks) {
    const g = F[k.fi], t = k.t;
    if (k.ms != null) (k.wasLocked ? msT : msS).push(k.ms);
    if (k.grav && g.grav && k.t > 0.5) gErr.push(angDeg(k.grav, g.grav));
    const visible = !!g.slabVisible;
    if (visible) { vis++; lastVis = t; if (firstVis == null) firstVis = t; }
    let err = null, correct = false;
    if (k.locked && k.quad && g.corners) { err = cornerErr(k.quad, g.corners); correct = visible && err < Math.max(6, 0.12 * g.side); }
    if (correct) { good++; if (firstLock == null) firstLock = t; if (lockedSince == null) lockedSince = t; } else lockedSince = null;
    // false lock: an outline shown when there's no slab in view (after a short hold), or an outline far from the slab
    let isFalse = false;
    if (k.locked && k.quad) {
      if (!visible) isFalse = t - lastVis > GRACE && !partlyInView(g.corners);
      else isFalse = err != null && err > Math.max(12, 0.25 * g.side);
    }
    if (isFalse) { falseTicks++; if (!inFalse) falseEvents++; }
    inFalse = isFalse;
    const settled = correct && t - lockedSince >= SETTLE;
    if (settled) {
      cErr.push(err);
      if (k.normal) { const e = angDeg(k.normal, g.normal); nErr.push(e); }
      if (k.tilt != null) tErr.push(k.tilt - g.tilt);
      if (g.still && k.normal) {
        // wobble not explained by the camera's real motion: spread of the error vector (app normal minus true normal)
        jitN.push(k.normal.map((x, i) => x - g.normal[i])); jitT.push(k.tilt);
        jitC.push(k.quad);
      }
    }
    // the ball
    // a held ball counts as in view when at least 60% of its rim shows (a pinch grip hides 20-25%)
    const gb = g.ball && { ...g.ball, visible: g.ball.rim != null ? g.ball.rim >= 0.6 : g.ball.visible };
    // bounce direction (ball clips only; without a ball it is the plane normal, already scored as tilt): the normal the
    // app launches the ball along, against the dish's own normal where the ball lands; and the landing point (in)
    if (settled && (k.bounceNormal || k.normal) && gb && gb.visible && gb.held && gb.onSlab && gb.hitNormal && k.ball && Math.hypot(k.ball.x - gb.x, k.ball.y - gb.y) < Math.max(4, 0.5 * gb.r)) {
      bErr.push(angDeg(k.bounceNormal || k.normal, gb.hitNormal));
      if (k.bounceAt && gb.hitLocal) hitErr.push(Math.hypot(k.bounceAt[0] - gb.hitLocal[0], k.bounceAt[1] - gb.hitLocal[1]) * (gt.spec.slab.size || 7) / 2);
    }
    const counts = gb && gb.visible && gb.held && gb.onSlab && correct;
    let hit = false;
    if (k.ball && gb && gb.visible && gb.x != null) hit = Math.hypot(k.ball.x - gb.x, k.ball.y - gb.y) < Math.max(4, 0.5 * gb.r) && Math.abs(k.ball.r - gb.r) < 0.3 * gb.r;
    if (counts) { ballCount++; if (hit) { ballHit++; if (k.ball.dropFt != null) dropErr.push(Math.abs(k.ball.dropFt - gb.drop) * 12); } }
    const near = k.ball && gb && gb.visible && gb.x != null && Math.hypot(k.ball.x - gb.x, k.ball.y - gb.y) < 2 * gb.r + 6;
    // a ball shown where the real ball was moments ago (it was just let go and is falling) is stale, not false
    if (gb && gb.x != null) { recent.push({ t, x: gb.x, y: gb.y, r: gb.r }); while (recent.length && recent[0].t < t - 0.3) recent.shift(); }
    const stale = !near && k.ball && gb && !gb.held && recent.some((p) => Math.hypot(k.ball.x - p.x, k.ball.y - p.y) < 2 * p.r + 6);
    if (stale) ballStale++;
    const fp = !!k.ball && !stale && !(near && (gb.held ? gb.onSlab : true));
    if (fp) { ballFP++; if (!inFP) ballFPev++; }
    inFP = fp;
  }
  const spread = (vs) => { if (vs.length < 10) return null; const m = [0, 1, 2].map((i) => mean(vs.map((v) => v[i]))); return Math.sqrt(mean(vs.map((v) => (v[0] - m[0]) ** 2 + (v[1] - m[1]) ** 2 + (v[2] - m[2]) ** 2))) * 180 / Math.PI; };
  const sd = (a) => { if (a.length < 10) return null; const m = mean(a); return Math.sqrt(mean(a.map((x) => (x - m) ** 2))); };
  const cornerJit = (qs) => { if (qs.length < 10) return null; let s = 0; for (let i = 0; i < 4; i++) for (const c of [0, 1]) s += sd(qs.map((q) => q[i][c])) ** 2; return Math.sqrt(s / 4); };
  Object.assign(out, {
    slabTicks: vis,
    lockRate: vis ? r2(100 * good / vis, 1) : null,
    timeToLock: firstVis == null ? null : firstLock == null ? "never" : r2(firstLock - firstVis, 2),
    falseLockTicks: falseTicks, falseLocks: falseEvents,
    cornerErr: r2(mean(cErr)), cornerErrP90: r2(quantile(cErr, 0.9)),
    tiltErr: r2(quantile(nErr, 0.5)), tiltErrP90: r2(quantile(nErr, 0.9)), tiltErrMax: r2(nErr.length ? Math.max(...nErr) : null),
    bounceErr: r2(quantile(bErr, 0.5)), bounceErrP90: r2(quantile(bErr, 0.9)), hitErrIn: r2(quantile(hitErr, 0.5)),
    gravErr: r2(quantile(gErr, 0.5)), gravErrP90: r2(quantile(gErr, 0.9)),
    tiltReadErr: r2(quantile(tErr.map(Math.abs), 0.5)), tiltBias: r2(mean(tErr)),
    jitter: r2(spread(jitN), 3), tiltJitter: r2(sd(jitT), 3), cornerJitter: r2(cornerJit(jitC), 3),
    ballTicks: ballCount, ballRate: ballCount ? r2(100 * ballHit / ballCount, 1) : null, ballFalseTicks: ballFP, ballFalse: ballFPev, ballStaleTicks: ballStale,
    dropErrIn: r2(quantile(dropErr, 0.5)),
    msSearch: r2(mean(msS), 1), msSearchP95: r2(quantile(msS, 0.95), 1), msTrack: r2(mean(msT), 1), msTrackP95: r2(quantile(msT, 0.95), 1),
  });
  return out;
}

// overall summary across clips
function summarize(results) {
  const pick = (k) => results.map((r) => r[k]).filter((x) => typeof x === "number");
  const withSlab = results.filter((r) => r.slabTicks > 0);
  const near = withSlab.filter((r) => !r.tags.includes("noslab"));
  return {
    clips: results.length,
    lockRate: r2(mean(pick("lockRate")), 1),
    neverLocked: withSlab.filter((r) => r.timeToLock === "never").map((r) => r.name),
    timeToLock: r2(mean(pick("timeToLock")), 2),
    falseLocks: results.reduce((s, r) => s + r.falseLocks, 0), falseLockClips: results.filter((r) => r.falseLocks).map((r) => r.name),
    cornerErr: r2(mean(pick("cornerErr"))),
    bounceErr: r2(quantile(pick("bounceErr"), 0.5)), bounceErrWorst: r2(Math.max(...pick("bounceErr"), 0)), hitErrIn: r2(quantile(pick("hitErrIn"), 0.5)),
    tiltErr: r2(quantile(pick("tiltErr"), 0.5)), tiltErrWorst: r2(Math.max(...pick("tiltErr"), 0)),
    tiltOver15: near.filter((r) => r.tiltErr != null && r.tiltErr >= 1.5).map((r) => `${r.name}:${r.tiltErr}`),
    jitter: r2(quantile(pick("jitter"), 0.5), 3), jitterWorst: r2(Math.max(...pick("jitter"), 0), 3),
    tiltJitter: r2(quantile(pick("tiltJitter"), 0.5), 3), tiltJitterWorst: r2(Math.max(...pick("tiltJitter"), 0), 3),
    jitterOver03: results.filter((r) => (r.jitter ?? 0) >= 0.3 || (r.tiltJitter ?? 0) >= 0.3).map((r) => `${r.name}:${r.jitter}/${r.tiltJitter}`),
    ballRate: r2(mean(pick("ballRate")), 1), ballFalse: results.reduce((s, r) => s + r.ballFalse, 0), ballFalseClips: results.filter((r) => r.ballFalse).map((r) => r.name),
    dropErrIn: r2(quantile(pick("dropErrIn"), 0.5)),
    msSearch: r2(mean(pick("msSearch")), 1), msTrack: r2(mean(pick("msTrack")), 1), msTrackP95: r2(Math.max(...pick("msTrackP95"), 0), 1),
  };
}
module.exports = { scoreClip, summarize, cornerErr, angDeg };
