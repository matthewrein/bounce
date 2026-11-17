#!/usr/bin/env python3
"""Score a prototype's per-frame slab normals against the truth dumped by frames.js.

    python3 frames_score.py <estimates.json> <inputs.json> <truth.json> [--per-clip]

estimates.json: {"<frame id>": [nx, ny, nz] or null, ...} in the app's camera axes (x right, y down, z forward), the
normal pointing out of the slab's top. A missing or null entry means "no opinion": the app's own normal is used.
Only frames where the slab is fully in view and the app has a lock are scored. Prints the median and 90th-percentile
angle (deg) between the normal and the truth, for the estimate and for the app on the same frames, overall and for
still frames, plus how many frames the estimate made better or worse by more than 0.3 deg, and the spread of the error
within each clip's still frames (a noisy estimator shows up there even when its median is good).
"""
import json, math, sys
from collections import defaultdict


def ang(a, b):
    na = math.sqrt(sum(x * x for x in a)); nb = math.sqrt(sum(x * x for x in b))
    d = sum(x * y for x, y in zip(a, b)) / (na * nb)
    return math.degrees(math.acos(max(-1.0, min(1.0, d))))


def q(v, p):
    if not v: return None
    v = sorted(v); return v[min(len(v) - 1, int(p * len(v)))]


def main():
    est = json.load(open(sys.argv[1])); inp = {r["id"]: r for r in json.load(open(sys.argv[2]))}
    tru = {r["id"]: r for r in json.load(open(sys.argv[3]))}
    rows = []
    for fid, t in tru.items():
        i = inp.get(fid)
        if not i or not t.get("slabVisible") or not i.get("locked") or not i.get("normal"): continue
        e = est.get(fid) or i["normal"]
        un = lambda v: [x / math.sqrt(sum(y * y for y in v)) for x in v]
        rows.append(dict(id=fid, clip=i["clip"], still=t["still"], app=ang(i["normal"], t["normal"]), est=ang(e, t["normal"]), used=bool(est.get(fid)),
                         app_v=[a - b for a, b in zip(un(i["normal"]), un(t["normal"]))], est_v=[a - b for a, b in zip(un(e), un(t["normal"]))]))
    if not rows: print("no scorable frames"); return
    def line(name, rs):
        a = [r["app"] for r in rs]; e = [r["est"] for r in rs]
        better = sum(1 for r in rs if r["est"] < r["app"] - 0.3); worse = sum(1 for r in rs if r["est"] > r["app"] + 0.3)
        print(f"{name:28s} n={len(rs):4d} used={sum(r['used'] for r in rs):4d}  app med {q(a,.5):5.2f} p90 {q(a,.9):5.2f}  |  est med {q(e,.5):5.2f} p90 {q(e,.9):5.2f}  better {better} worse {worse}")
    line("all frames", rows); line("still frames", [r for r in rows if r["still"]])
    by = defaultdict(list)
    for r in rows: by[r["clip"]].append(r)
    cm_a = [q([r["app"] for r in rs], .5) for rs in by.values()]; cm_e = [q([r["est"] for r in rs], .5) for rs in by.values()]
    print(f"{'clip medians':28s} n={len(by):4d}  app med {q(cm_a,.5):5.2f} worst {max(cm_a):5.2f}  |  est med {q(cm_e,.5):5.2f} worst {max(cm_e):5.2f}  "
          f"clips better {sum(1 for a, e in zip(cm_a, cm_e) if e < a - 0.3)} worse {sum(1 for a, e in zip(cm_a, cm_e) if e > a + 0.3)}")
    # frame-to-frame spread within each clip (still frames): std of the error vector (estimate - truth), deg
    def spread(rs, key):
        v = [r[key + "_v"] for r in rs if r["still"]]
        if len(v) < 3: return None
        m = [sum(x[k] for x in v) / len(v) for k in range(3)]
        return math.degrees(math.sqrt(sum(sum((x[k] - m[k]) ** 2 for k in range(3)) for x in v) / len(v)))
    sa = [x for x in (spread(rs, "app") for rs in by.values()) if x is not None]; se = [x for x in (spread(rs, "est") for rs in by.values()) if x is not None]
    if sa: print(f"{'spread within clips (still)':28s} n={len(sa):4d}  app med {q(sa,.5):5.2f} worst {max(sa):5.2f}  |  est med {q(se,.5):5.2f} worst {max(se):5.2f}")
    if "--per-clip" in sys.argv:
        for c, rs in sorted(by.items()):
            line(c, rs)


if __name__ == "__main__":
    main()
