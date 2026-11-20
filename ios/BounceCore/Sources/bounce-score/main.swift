// bounce-score: scores capture kits against their ground truth (ios/CaptureKit.md, "Scoring").
//
//   bounce-score <kit folder or a folder of kits> ... [--json out.json] [--markdown] [--compare old.json]
//                [--fail-on-regression] [--measured] [--positions s07=p4,s08=unmeasured,...]
//   bounce-score --synthetic [--frames N] [--markdown] [--json out.json]
//   bounce-score --drops [--drops-only ID,ID] [--drop-slab INCHES] [--drops-json out.json] [--drops-floor] [--truth-ball]
//                [--markdown]
//   bounce-score --taps <kit folder or a folder of kits> ... [--taps-truth FILE] [--taps-track FILE] [--taps-only ID,ID] [--taps-lanes L,L]
//                [--taps-json out.json] [--taps-trace]
//
// Kits are private: it prints kit ids, shot ids and numbers, never paths or anything from the pictures.
import BounceCore
import Foundation

#if os(macOS) || os(Linux)

let usage = """
usage: bounce-score <kit folder or a folder of kits> ... [options]
       bounce-score --synthetic [--frames N] [options]
       bounce-score --drops [options]

Scores every video shot of each kit with the app's detectors and tracker against the kit's ground truth.

options:
  --json FILE            write the scores as JSON (kit ids only, no paths)
  --markdown             print the scores as Markdown (default: a short summary per kit)
  --compare FILE         compare with an earlier --json file: every metric better / worse / same
  --fail-on-regression   exit with status 2 if any metric got worse than in --compare
  --measured             score with the kit's measured slab and ball instead of the app's own settings
  --positions SPEC       the slab position of shots kit.json has wrong: SHOT=POSITION pairs, comma-separated; SHOT is a
                         shot id or its start (s07 for both s07 shots), POSITION a position id (p4) or "unmeasured" (no
                         true tilt: the shots report the tilt they read, and when it was shown, with no error)
  --synthetic            also score the synthetic kit (rendered here, known truth)
  --frames N             synthetic kit: frames per ordinary shot (default 12)
  --video h264|hevc      synthetic kit: encode its frames with ffmpeg and decode them as a kit's video
  --truth-ball           synthetic kit and drops: a ball finder that knows where the ball is (tests the ball metrics)
  --drops                score the rendered drops (KitSyntheticDrops: physical bounces off the dish, centre and
                         off-centre, known truth) through the scorer's path and the drop analysis
  --drops-only IDS       only these drops (comma-separated ids, or prefixes such as d01)
  --drop-slab INCHES     the drops' slab side (default 7, the owner's; the drops' offsets stay in inches)
  --drop-shrink N        render the drops at 1/N of 1440x1080 (default 1)
  --drops-json FILE      write the drops' report as JSON
  --drops-floor          drops: give the analysis ARKit's floor, as on the phone (default: none, as in a kit)
  --taps                 instead of scoring: run the kits' shots with simulated taps (KitTapBench: none, slab, slabLate,
                         ball, dismiss, and stray taps floorSearch, floorConfirm, floor05..floor45 (at 0.5 to 4.5 s),
                         floorLocked, slabOnLock, ballOff; tap to set the ball: setTrue, setOff, setTrueAny, setOffAny,
                         slabFarOnLock) and print what each changed (Markdown)
  --taps-truth FILE      the balls' true places: {"<kit id>": {"<shot id>": {"frame": N, "x": X, "y": Y, "r": R}}} (video px)
  --taps-track FILE      the balls' circles on every frame they are seen (the setTrue, setOff, ...Any lanes):
                         {"<kit id>": {"<shot id>": {"<frame>": [X, Y, R]}}} (video px; frame: frames.jsonl line index)
  --taps-only IDS        only these shots (comma-separated ids, or prefixes such as s09)
  --taps-lanes LANES     only these lanes (comma-separated)
  --taps-json FILE       write the taps' reports as JSON (rewritten after every shot, so a stopped run keeps its shots)
  --taps-trace           log every lane's tracker events on the frames that have any
  --max-tilt-error DEG   exit with status 3 if the synthetic kit's median tilt error is above DEG, or missing
  --scorer LABEL         record who scored it (e.g. a git hash) in the JSON
  --quiet                no progress lines
"""

func fail(_ s: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("bounce-score: " + s + "\n").utf8))
    exit(code)
}

func progress(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

var paths: [String] = []
var jsonOut: String? = nil, compareWith: String? = nil, scorerLabel: String? = nil, videoCodec: String? = nil
var markdown = false, failOnRegression = false, measured = false, synthetic = false, truthBall = false, quiet = false
var drops = false, dropsOnly: [String]? = nil, dropSlab: Double? = nil, dropShrink = 1, dropsJson: String? = nil, dropsFloor = false
var frames = 12
var taps = false, tapsTruth: String? = nil, tapsTrack: String? = nil, tapsOnly: [String]? = nil, tapsLanes: [KitTapBench.Lane]? = nil, tapsJson: String? = nil
var tapsTrace = false
var maxTiltError: Double? = nil
var positions: [String: String] = [:]
var args = Array(CommandLine.arguments.dropFirst())
func value(_ name: String) -> String {
    guard !args.isEmpty else { fail("\(name) needs a value\n\n" + usage) }
    return args.removeFirst()
}
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--json": jsonOut = value(a)
    case "--markdown": markdown = true
    case "--compare": compareWith = value(a)
    case "--fail-on-regression": failOnRegression = true
    case "--measured": measured = true
    case "--positions":
        guard let p = KitScorer.parsePositions(value(a)) else { fail("--positions needs SHOT=POSITION pairs, e.g. s07=p4,s08=unmeasured") }
        positions.merge(p) { _, b in b }
    case "--synthetic": synthetic = true
    case "--frames": guard let n = Int(value(a)), n >= 2 else { fail("--frames needs a number of at least 2") }; frames = n
    case "--video": let v = value(a); guard v == "h264" || v == "hevc" else { fail("--video is h264 or hevc") }; videoCodec = v
    case "--truth-ball": truthBall = true
    case "--drops": drops = true
    case "--drops-only": dropsOnly = value(a).split(separator: ",").map { String($0) }; drops = true
    case "--drop-slab": guard let d = Double(value(a)), d > 4 else { fail("--drop-slab needs inches") }; dropSlab = d
    case "--drop-shrink": guard let n = Int(value(a)), n >= 1 else { fail("--drop-shrink needs a whole number") }; dropShrink = n
    case "--drops-json": dropsJson = value(a)
    case "--drops-floor": dropsFloor = true; drops = true
    case "--max-tilt-error": guard let d = Double(value(a)), d > 0 else { fail("--max-tilt-error needs degrees") }; maxTiltError = d
    case "--scorer": scorerLabel = value(a)
    case "--taps": taps = true
    case "--taps-truth": tapsTruth = value(a); taps = true
    case "--taps-track": tapsTrack = value(a); taps = true
    case "--taps-only": tapsOnly = value(a).split(separator: ",").map { String($0) }; taps = true
    case "--taps-lanes":
        let ls = value(a).split(separator: ",").map { KitTapBench.Lane(rawValue: String($0)) }
        guard !ls.isEmpty, ls.allSatisfy({ $0 != nil }) else {
            fail("--taps-lanes takes " + KitTapBench.Lane.allCases.map { $0.rawValue }.joined(separator: ", "))
        }
        tapsLanes = ls.compactMap { $0 }; taps = true
    case "--taps-json": tapsJson = value(a); taps = true
    case "--taps-trace": tapsTrace = true; taps = true
    case "--quiet": quiet = true
    case "-h", "--help": print(usage); exit(0)
    default:
        if a.hasPrefix("-") { fail("unknown option \(a)\n\n" + usage) }
        paths.append(a)
    }
}
if paths.isEmpty && !synthetic && !drops { fail("give a kit folder, a folder of kits, --synthetic or --drops\n\n" + usage) }
if failOnRegression && compareWith == nil { fail("--fail-on-regression needs --compare") }

let fm = FileManager.default
/// The kits in a folder: the folder itself, or the folders in it that hold a kit.json.
func kits(in path: String, number: Int) -> [URL] {
    let u = URL(fileURLWithPath: path)
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue else { fail("folder #\(number) given does not exist") }
    if fm.fileExists(atPath: u.appendingPathComponent(KitStore.manifestFile).path) { return [u] }
    let subs = ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? [])
        .filter { !$0.lastPathComponent.hasPrefix(".") && fm.fileExists(atPath: $0.appendingPathComponent(KitStore.manifestFile).path) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    if subs.isEmpty { fail("folder #\(number) given holds no kit (no kit.json in it or in its folders)") }
    return subs
}

var reports: [KitScoreReport] = []
let log: ((String) -> Void)? = quiet ? nil : progress

if taps {
    if paths.isEmpty { fail("--taps needs a kit folder or a folder of kits") }
    var truth: [String: [String: KitTapBench.BallTruth]] = [:]
    if let t = tapsTruth {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: t)),
              let x = try? JSONDecoder().decode([String: [String: KitTapBench.BallTruth]].self, from: d) else { fail("the --taps-truth file is not a truth file") }
        truth = x
    }
    var track: [String: [String: [Int: KitTapBench.BallTruth]]] = [:]
    if let t = tapsTrack {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: t)),
              let x = try? JSONDecoder().decode([String: [String: [String: [Double]]]].self, from: d) else { fail("the --taps-track file is not a track file") }
        for (kit, shots) in x {
            for (shot, frames) in shots {
                var m: [Int: KitTapBench.BallTruth] = [:]
                for (k, v) in frames { if let i = Int(k), v.count >= 3 { m[i] = KitTapBench.BallTruth(frame: i, x: v[0], y: v[1], r: v[2]) } }
                track[kit, default: [:]][shot] = m
            }
        }
    }
    var all: [KitTapBench.Report] = []
    func writeTaps(_ reports: [KitTapBench.Report]) {
        guard let j = tapsJson else { return }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try e.encode(reports).write(to: URL(fileURLWithPath: j), options: .atomic) } catch { fail("could not write the --taps-json file") }
    }
    for (i, p) in paths.enumerated() {
        for k in kits(in: p, number: i + 1) {
            var o = KitTapBench.Options()
            o.only = tapsOnly
            if let l = tapsLanes { o.lanes = l }
            o.log = log
            o.traceEvents = tapsTrace
            var partial: [KitTapBench.ShotResult] = []
            o.onShot = { kitId, shot in partial.append(shot); writeTaps(all + [KitTapBench.Report(kitId: kitId, shots: partial)]) }
            let id = (try? Data(contentsOf: k.appendingPathComponent(KitStore.manifestFile))).flatMap { try? KitJSON.decode(KitManifest.self, from: $0) }?.kitId
            o.ballTruth = id.flatMap { truth[$0] } ?? [:]
            o.ballTrack = id.flatMap { track[$0] } ?? [:]
            do {
                let r = try KitTapBench.run(kitFolder: k, options: o)
                all.append(r)
                print(r.markdown()); print("")
            } catch { fail("could not run the taps on a kit: \(KitScorer.describe(error))") }
        }
    }
    writeTaps(all)
    exit(0)
}
for (i, p) in paths.enumerated() {
    for k in kits(in: p, number: i + 1) {
        var o = KitScorer.Options()
        o.useMeasurements = measured
        o.positions = positions
        o.log = log
        do { reports.append(try KitScorer(kitFolder: k, options: o).score()) } catch {
            fail("could not score a kit: \(KitScorer.describe(error))")
        }
    }
}

if synthetic {
    if videoCodec != nil && !KitFFmpeg.isAvailable { fail("--video needs ffmpeg and ffprobe") }
    let root = fm.temporaryDirectory.appendingPathComponent("bounce-synthetic-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    var so = KitSyntheticKit.Options()
    so.framesPerShot = frames
    so.video = videoCodec
    if !quiet { progress("synthetic kit: making \(so.plan.shotCount) shots, \(frames) frames per ordinary shot") }
    do {
        let kit = try KitSyntheticKit.build(root: root, options: so)
        var o = kit.scorerOptions(truthBall: truthBall)
        o.useMeasurements = measured
        o.log = log
        let r = try KitScorer(kitFolder: kit.folder, options: o).score()
        reports.append(r)
        kit.remove()
    } catch {
        try? fm.removeItem(at: root)
        fail("the synthetic kit failed: \(KitScorer.describe(error))")
    }
}

var dropReport: KitDropBenchReport? = nil
if drops {
    var o = KitDropBench.Options()
    o.truthBall = truthBall
    o.floorKnown = dropsFloor
    o.log = log
    if let s = dropSlab { o.drops.spec.sideU = Units.inches(s); o.drops.spec.sideV = Units.inches(s) }
    o.drops.shrink = dropShrink
    if let ids = dropsOnly {
        o.drops.shots = o.drops.shots.filter { s in ids.contains { s.id == $0 || s.id.hasPrefix($0) } }
        if o.drops.shots.isEmpty { fail("--drops-only matches no drop") }
    }
    if !quiet { progress("drops: rendering and scoring \(o.drops.shots.count) drops") }
    do { dropReport = try KitDropBench.run(o) } catch { fail("the drops failed: \(KitScorer.describe(error))") }
    if let j = dropsJson, let r = dropReport {
        do { try r.json().write(to: URL(fileURLWithPath: j), options: .atomic) } catch { fail("could not write the --drops-json file") }
    }
}

var set = KitScoreSet(reports: reports, scoredAt: KitTime.iso(Date()), scorer: scorerLabel)
var comparison: KitScoreComparison? = nil
if let c = compareWith {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: c)), let previous = try? KitScoreSet.read(d) else {
        fail("the --compare file is not a scores file")
    }
    comparison = set.compare(previous: previous)
}
if let j = jsonOut {
    do { try set.json().write(to: URL(fileURLWithPath: j), options: .atomic) } catch { fail("could not write the --json file") }
}

if markdown {
    if !reports.isEmpty { print(set.markdown(comparison: comparison)) }
    if let d = dropReport { print(d.markdown()) }
} else {
    if let d = dropReport {
        let sm = d.summary
        func f(_ v: Double?, _ scale: Double, _ unit: String) -> String { v.map { String(format: "%.1f", $0 * scale) + unit } ?? "n/a" }
        print("drops: \(sm.analysed)/\(sm.drops) analysed; rebound error \(f(sm.reboundError, 100, " points")) median "
              + "(worst \(f(sm.reboundErrorMax, 100, " points"))), impact point \(f(sm.offsetError, 1000, " mm")), landing \(f(sm.landingError, 1000, " mm"))")
    }
    for r in reports {
        func v(_ id: String) -> String { r.aggregate(id)?.formatted ?? "n/a" }
        print("\(r.kitId) (\(r.source)): lock rate \(v("lockRate")), first lock \(v("timeToLock")), "
              + "tilt error \(v("tiltErrorMedian")) median, \(v("tiltErrorP90")) p90 (bias \(v("tiltBias"))), "
              + "normal \(v("normalErrorMedian")), settled \(v("settledRate")) of locked frames from \(v("timeToSettle")) "
              + "(tilt error shown \(v("settledTiltErrorMedian")) median, \(v("settledTiltErrorMax")) max; error in its sigma "
              + "\(v("honestRatioMedian")) median, \(v("honestRatioP95")) p95), "
              + "corners \(v("cornerRms")), false slab \(v("slabFoundRate")), "
              + "ball \(v("ballDetectionRate")), landing \(v("landingError")); \(r.reboundToBakeLine)")
    }
    if let c = comparison {
        print("compared: \(c.regressions.count) worse, \(c.improvements.count) better")
        for x in c.regressions {
            print("  worse: \(x.kitId) \(x.scope) \(x.metric): \(KitMetric.format(x.before, x.unit)) -> \(KitMetric.format(x.after, x.unit))")
        }
    }
}

var status: Int32 = 0
if failOnRegression, let c = comparison, c.hasRegressions {
    progress("bounce-score: \(c.regressions.count) metrics got worse")
    status = 2
}
if let maxErr = maxTiltError, synthetic {
    let r = reports.last { $0.source == "synthetic" }
    let e = r?.aggregate("tiltErrorMedian")?.value
    if e == nil || e! > maxErr {
        progress("bounce-score: the synthetic kit's median tilt error is \(e.map { String(format: "%.2f°", $0) } ?? "missing"), over \(maxErr)°")
        status = 3
    }
}
exit(status)

#else
print("bounce-score runs on macOS and Linux")
#endif
