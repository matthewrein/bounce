#!/usr/bin/env node
// Compare two runs clip by clip:  node compare.js <before-label> <after-label>
// A change is acceptable only if no clip gets worse beyond the noise allowances below.
// Step-mode runs are frame-exact, so accuracy numbers only move when behaviour changes; frame times are
// wall-clock and noisy, so they get a looser allowance.
"use strict";
const fs = require("fs"), path = require("path");
const load1 = (l) => JSON.parse(fs.readFileSync(fs.existsSync(l) ? l : path.join(__dirname, "out/results", l + ".json"), "utf8"));
// "a+b" averages several runs of one build (e.g. two camera phases); each clip's spread between them is kept as its noise
function load(spec) {
  const runs = spec.split("+").map(load1); if (runs.length === 1) return runs[0];
  const out = { ...runs[0], label: spec, clips: [] }, by = runs.map((r) => Object.fromEntries(r.clips.map((c) => [c.name, c])));
  for (const c0 of runs[0].clips) {
    const cs = by.map((b) => b[c0.name]).filter(Boolean), c = { ...c0, spread: {} };
    for (const k of Object.keys(c0)) {
      const v = cs.map((x) => x[k]);
      if (v.every((x) => typeof x === "number")) { c[k] = +(v.reduce((a, b) => a + b, 0) / v.length).toFixed(3); c.spread[k] = Math.max(...v) - Math.min(...v); }
      else if (k === "timeToLock") { const n = v.map((x) => (x === "never" ? 99 : x)); if (n.every((x) => typeof x === "number")) { const m = n.reduce((a, b) => a + b, 0) / n.length; c[k] = m >= 99 ? "never" : +m.toFixed(2); c.spread[k] = Math.max(...n) - Math.min(...n); } }
    }
    out.clips.push(c);
  }
  const { summarize } = require("./score"); out.summary = summarize(out.clips.filter((x) => !x.failed));
  return out;
}
// [metric, direction (+1 higher is better), absolute allowance, relative allowance]
const RULES = [
  ["lockRate", +1, 1.0, 0], ["falseLocks", -1, 0, 0], ["falseLockTicks", -1, 0, 0],
  ["cornerErr", -1, 0.1, 0.05], ["tiltErr", -1, 0.05, 0.03], ["tiltErrP90", -1, 0.1, 0.05], ["tiltReadErr", -1, 0.05, 0.05],
  ["jitter", -1, 0.01, 0.05], ["tiltJitter", -1, 0.01, 0.05],
  ["ballRate", +1, 2.0, 0], ["ballFalse", -1, 0, 0], ["ballFalseTicks", -1, 0, 0], ["dropErrIn", -1, 0.1, 0.1],
  ["msTrack", -1, 0.6, 0.15], ["msSearch", -1, 2.0, 0.2],
];
function ttl(v) { return v === "never" ? 99 : v; }
function compare(A, B) {
  const a = Object.fromEntries(A.clips.map((c) => [c.name, c])), worse = [], better = [];
  for (const cb of B.clips) {
    const ca = a[cb.name]; if (!ca) continue;
    if (cb.failed && !ca.failed) { worse.push(`${cb.name}: run failed (${cb.failed.split("\n")[0]})`); continue; }
    for (const [k, dir, abs, rel] of RULES) {
      const x = ca[k], y = cb[k];
      if (x == null && y == null) continue;
      if (x == null || y == null) { // appeared or vanished (e.g. never locked before, now has a tilt error)
        if (k === "lockRate" || k === "ballRate") continue;
        continue;
      }
      const noise = Math.max((ca.spread && ca.spread[k]) || 0, (cb.spread && cb.spread[k]) || 0); // phase-to-phase spread
      const d = (y - x) * dir, tol = abs + rel * Math.abs(x) + noise;
      if (d < -tol) worse.push(`${cb.name}: ${k} ${x} -> ${y}`); else if (d > tol) better.push(`${cb.name}: ${k} ${x} -> ${y}`);
    }
    const t0 = ttl(ca.timeToLock), t1 = ttl(cb.timeToLock), tn = Math.max((ca.spread && ca.spread.timeToLock) || 0, (cb.spread && cb.spread.timeToLock) || 0);
    if (t0 != null && t1 != null) { if (t1 > t0 + 0.1 + tn) worse.push(`${cb.name}: timeToLock ${ca.timeToLock} -> ${cb.timeToLock}`); else if (t1 < t0 - 0.1) better.push(`${cb.name}: timeToLock ${ca.timeToLock} -> ${cb.timeToLock}`); }
  }
  return { worse, better };
}
if (require.main === module) {
  const [x, y] = process.argv.slice(2), A = load(x), B = load(y), { worse, better } = compare(A, B);
  console.log(`${A.label} (${A.build}) -> ${B.label} (${B.build})`);
  const sa = A.summary, sb = B.summary;
  for (const k of Object.keys(sb)) if (typeof sb[k] === "number" && sa[k] !== sb[k]) console.log(`  summary ${k}: ${sa[k]} -> ${sb[k]}`);
  console.log(`\nWORSE (${worse.length}):`); for (const w of worse) console.log("  " + w);
  console.log(`\nBETTER (${better.length}):`); for (const b of better) console.log("  " + b);
  process.exitCode = worse.length ? 1 : 0;
}
module.exports = { compare };
