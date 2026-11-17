#!/usr/bin/env node
// Re-score saved runs from their per-tick traces (after a change to score.js), without running the app again:
//   node rescore.js <label> [<label> ...]
"use strict";
const fs = require("fs"), path = require("path");
const { scoreClip, summarize } = require("./score");
for (const label of process.argv.slice(2)) {
  const f = path.join(__dirname, "out/results", label + ".json"), res = JSON.parse(fs.readFileSync(f, "utf8"));
  res.clips = res.clips.map((c) => {
    const tf = path.join(__dirname, "out/traces", label, c.name + ".json"), gf = path.join(__dirname, "out/clips", c.name, "gt.json");
    if (c.failed || !fs.existsSync(tf) || !fs.existsSync(gf)) return c;
    const sc = scoreClip(JSON.parse(fs.readFileSync(gf, "utf8")), JSON.parse(fs.readFileSync(tf, "utf8"))); sc.name = c.name; if (c.errors) sc.errors = c.errors; return sc;
  });
  res.summary = summarize(res.clips.filter((c) => !c.failed)); res.rescored = true;
  fs.writeFileSync(f, JSON.stringify(res, null, 1));
  console.log(label, "rescored:", res.clips.length, "clips; false ball events", res.summary.ballFalse);
}
