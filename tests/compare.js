#!/usr/bin/env node
// Compare two runs clip by clip:  node compare.js <before-label> <after-label>
// A change is acceptable only if no clip gets worse beyond the noise allowances below.
// Step-mode runs are frame-exact, so accuracy numbers only move when behaviour changes; frame times are
// wall-clock and noisy, so they get a looser allowance.
"use strict";
const fs = require("fs"), path = require("path");
const load = (l) => JSON.parse(fs.readFileSync(fs.existsSync(l) ? l : path.join(__dirname, "out/results", l + ".json"), "utf8"));
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
    for (const [k, dir, abs, rel] of RULES) {
      const x = ca[k], y = cb[k];
      if (x == null && y == null) continue;
      if (x == null || y == null) { // appeared or vanished (e.g. never locked before, now has a tilt error)
        if (k === "lockRate" || k === "ballRate") continue;
        continue;
      }
      const d = (y - x) * dir, tol = abs + rel * Math.abs(x);
      if (d < -tol) worse.push(`${cb.name}: ${k} ${x} -> ${y}`); else if (d > tol) better.push(`${cb.name}: ${k} ${x} -> ${y}`);
    }
    const t0 = ttl(ca.timeToLock), t1 = ttl(cb.timeToLock);
    if (t0 != null && t1 != null) { if (t1 > t0 + 0.1) worse.push(`${cb.name}: timeToLock ${ca.timeToLock} -> ${cb.timeToLock}`); else if (t1 < t0 - 0.1) better.push(`${cb.name}: timeToLock ${ca.timeToLock} -> ${cb.timeToLock}`); }
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
