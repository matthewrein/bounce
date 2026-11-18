import BounceCore
import Foundation

// bounce-bench: times each stage of the phone's per-frame path (ARController.handle and the BounceCore code it runs) on
// representative synthetic camera frames, models the 60 fps budget with the app's cadence and frame pacer, and estimates
// iPhone times from the CI Mac's. Build and run it optimised:
//
//     swift run -c release --package-path ios/BounceBench bounce-bench [options]
//
// Options:
//   --quick               few iterations and short runs (a smoke test; numbers rough)
//   --markdown FILE       write the Markdown report there (default: stdout)
//   --json FILE           write the JSON report there
//   --only TEXT           only the stages whose group, name or input contain TEXT (case-insensitive); with it the app
//                         loop and the budget model are skipped unless TEXT is "frames"
//   --iterations N        timed runs per stage (default: by stage, up to 60, capped by time)
//   --scenes LIST         which scenes to render: comma-separated feet among 2,4,6 and "empty" (default: all)
//   --no-extras           only the plain scenes (no hand, clutter, tiles or drop)
//   --locked-seconds S    camera seconds of each locked run (default 30; --quick 3)
//   --cache DIR           keep the rendered frames in DIR and read them back next time (never commit them)
//   --fixtures DIR        BounceCore's committed procedural fixtures, for a cross-check of the search's cost (default:
//                         ios/BounceCore/Tests/BounceCoreTests/Fixtures or ../BounceCore/Tests/BounceCoreTests/Fixtures
//                         from the current folder, if there)
//   --mac-calibration MS  the CI Mac's calibration (min ms, from its report): scales this host's times to the Mac's
//                         for the budget model and the iPhone estimate (default: 1 on an Apple-silicon Mac, else 1 with
//                         a warning)
//   --no-app-loop         skip the whole-frame runs and the budget model
//   --no-view-searches    skip the searches on the cluttered floor seen from other sides (an accuracy check of the
//                         app's sweep: does it still find the slab)
//   --skip-calibration    a token calibration only (for profiling runs under valgrind, where it would take minutes)
//   --render JSON         write the Markdown of an earlier run's JSON report (the CI Mac's, say) and stop: its budget
//                         model made again from its whole-frame runs (with --mac-calibration: scaled to that Mac)
//
// Built with -D BENCH_SWEEP_STATS against an instrumented copy of BounceCore (its SlabFinder logging each sweep's regions
// in `benchSweepLog`), it also reports the regions each search grew; the normal build cannot see them.

setvbuf(stdout, nil, _IOLBF, 0)
#if os(macOS)
// the app's processing queue runs at userInteractive QoS: so does the bench's thread
_ = pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
#endif
let startTime = nowNs()
var args = Array(CommandLine.arguments.dropFirst())
func take(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}
func has(_ flag: String) -> Bool {
    guard let i = args.firstIndex(of: flag) else { return false }
    args.remove(at: i)
    return true
}
let quick = has("--quick")
let noAppLoop = has("--no-app-loop")
let noExtras = has("--no-extras")
let noViewSearches = has("--no-view-searches")
let skipCalibration = has("--skip-calibration")
let markdownPath = take("--markdown")
let jsonPath = take("--json")
let only = take("--only")
let iterations = take("--iterations").flatMap { Int($0) }
let scenesArg = take("--scenes")
let lockedSecondsArg = take("--locked-seconds").flatMap { Double($0) }
let cacheDir = take("--cache").map { URL(fileURLWithPath: $0, isDirectory: true) }
let fixturesArg = take("--fixtures").map { URL(fileURLWithPath: $0, isDirectory: true) }
let macCal = take("--mac-calibration").flatMap { Double($0) }
let renderPath = take("--render")
if !args.isEmpty {
    FileHandle.standardError.write("bounce-bench: unknown arguments \(args)\n".data(using: .utf8)!)
    exit(2)
}
func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// --render JSON: the Markdown of an earlier run's JSON report (its budget model made again from its whole-frame runs,
// with --mac-calibration if given), nothing timed
if let rp = renderPath {
    let d = JSONDecoder()
    d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    var r = try d.decode(BenchReport.self, from: Data(contentsOf: URL(fileURLWithPath: rp)))
    if let old = r.budget {
        var k = old.hostToMac, basis = old.hostToMacBasis
        if let mc = macCal, mc > 0 { k = mc / r.calibration.cpuMs.min; basis = String(format: "the CI Mac's calibration %.2f ms / that host's %.2f ms", mc, r.calibration.cpuMs.min) }
        r.budget = BudgetModel.make(sessions: r.sessions, hostToMac: k, basis: basis)
    }
    let md = r.markdown()
    if let p = markdownPath { try md.write(toFile: p, atomically: true, encoding: .utf8) } else { print(md) }
    exit(0)
}

let host = HostInfo.current()
#if DEBUG
log("bounce-bench: this is a DEBUG build; build with -c release for meaningful times")
#endif
#if BENCH_SWEEP_STATS
log("bounce-bench: instrumented build (BENCH_SWEEP_STATS): regions grown per search are reported")
#endif
log("bounce-bench on \(host.os) \(host.arch) \(host.cpu), \(host.cores) cores, load \(host.loadAverage ?? "?")")

// calibration first (and again at the end: a machine whose load changed shows it), with short probes between groups
let cal = Calibration.run(quick: quick, iterations: skipCalibration ? 100_000 : 10_000_000)
log(String(format: "calibration: %.2f ms min, %.2f p50; memory %.1f GB/s", cal.cpuMs.min, cal.cpuMs.p50, cal.memoryGBps))
var probes: [Probe] = []
func probe(_ label: String) {
    let p = Probe.take(label, quickRun: skipCalibration)
    probes.append(p)
    log(String(format: "  probe %@: %.2f ms (the calibration's %.2f)", label, p.ms, cal.cpuMs.min))
}
probe("start")

// scenes
let feetList = scenesArg?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
let sceneSet = BenchScene.all(quick: quick, extras: !noExtras, keep: { f in
    guard let l = feetList else { return true }
    return l.contains { $0 == "empty" ? f == nil : Double($0) == f }
}, cache: cacheDir, log: log)
for s in sceneSet.scenes {
    let q = s.truthOutline.map { o in o.map { String(format: "(%.0f,%.0f)", $0.x, $0.y) }.joined(separator: " ") } ?? "-"
    log("  \(s.name): slab outline (processing px) \(q); ball at \(s.ballPixel.map { String(format: "(%.0f,%.0f)", $0.x, $0.y) } ?? "-") full px")
}
probe("after the scenes")

// the fixtures
var fixtures = fixturesArg
if fixtures == nil {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    for rel in ["ios/BounceCore/Tests/BounceCoreTests/Fixtures", "../BounceCore/Tests/BounceCoreTests/Fixtures", "BounceCore/Tests/BounceCoreTests/Fixtures"] {
        let u = cwd.appendingPathComponent(rel, isDirectory: true)
        if FileManager.default.fileExists(atPath: u.path) { fixtures = u; break }
    }
}

// stages
let bench = StageBench(scenes: sceneSet, quick: quick, only: only, iterations: iterations, fixtures: fixtures, log: log, probe: probe)
bench.runAll()

// the search on the cluttered floor seen from other sides: does the app's sweep still find the slab
var viewSearches: [ViewSearch]? = nil
if !noViewSearches && !noExtras && only == nil {
    log("view searches (the cluttered floor from other sides):")
    viewSearches = ViewSearches.run(quick: quick, log: log)
    probe("after the view searches")
}

// whole frames and the budget model
var sessions: [SessionResult] = []
var lockTimes: [LockTimeResult] = []
var budget: BudgetModel? = nil
let runLoop = !noAppLoop && (only == nil || only!.lowercased() == "frames")
var hostToMac = 1.0, basis = host.isAppleSiliconMac ? "this is an Apple-silicon Mac: taken as the CI Mac itself" : "NOT a Mac: this host's times used as they are"
if let mc = macCal, mc > 0 {
    hostToMac = mc / cal.cpuMs.min
    basis = String(format: "the CI Mac's calibration %.2f ms / this host's %.2f ms", mc, cal.cpuMs.min)
}
if runLoop {
    log("app loop (whole frames):")
    // 12 acquisitions: about 36 searches per scene, so a search's p95 is not just its slowest run
    let cfg = LoopConfig(quick: quick, lockedSeconds: lockedSecondsArg ?? (quick ? 3 : 30), acquisitions: quick ? 2 : 12,
                         pacedScales: [(hostToMac, "x1: the CI Mac (an A15)"), (hostToMac * 2, "x2: an A12, or a contended A15"),
                                       (hostToMac * 4, "x4: an A11 contended")],
                         pacedRuns: quick ? 1 : 3)
    (sessions, lockTimes) = runAppLoops(scenes: sceneSet, config: cfg, probe: probe, log: log)
    budget = BudgetModel.make(sessions: sessions, hostToMac: hostToMac, basis: basis)
}

let cal2 = Calibration.run(quick: true, iterations: skipCalibration ? 100_000 : 10_000_000)
probes.append(Probe(label: "end (calibration)", ms: cal2.cpuMs.min))
var notes: [String] = [
    "Inputs: SyntheticScene renders at 1920x1440 (fx 1450 px, ARKit's 4:3 wide format), one sample a pixel softened like a lens, sensor noise of 1.5 grey levels; the slab (7 in, 8 deg tilt) seen from 2, 4 and 6 ft along the line of sight, 50 deg above level; a 35 mm ball held over it (0.20, 0.30, 0.45 m) or none; and an empty view of the floor (a cutting mat with a grid). Harder frames painted into the render before the noise (ScenePaint): a hand over the slab's nearest corner (2 and 4 ft, ball held); floor clutter (about 40 planks, rugs, papers, shoes and slab-sized squares; 2 and 4 ft and the empty view); a floor of slab-sized tiles in seven colours (4 ft and the empty view; meant to make the search grow many regions, but the sweep starts only near dark pixels, so in an instrumented run (sweep-stats.sh) it is the cluttered floor that reaches the sweep's cap of 48 regions); and a drop (the ball every 0.05 s from held to the slab; no motion blur). Built once into the camera's bi-planar 4:2:0 buffer (luma plane, interleaved CbCr) and a 256x192 LiDAR map, outside the timing.",
    "Cold inputs: the conversions, crops and the kit's scale rotate among 8 copies of the camera buffer (33 MB, more than the L2 and system cache), and so do the whole-frame runs, so a frame's pixels come from memory as the camera's do (the cache-warm conversion is timed too, for comparison).",
    "The app's own helpers (FrameConversion.lumaCrop with vDSP, FrameConversion.depth, FrameConversion.scale with vImage) live in the app: they are replicated here on plain buffers. On a Mac the crop and the scale are the app's code verbatim; elsewhere the pure-Swift row-convert crop stands in for the crop, and a pure-Swift Lanczos-3 (several times slower than vImage) for the scale.",
    "The whole frames include the app's glue around the tracker that runs BounceCore code (the frame pacer, the video-format watch, the capture-lock gate, the overlay's projections, the HUD's strings, the developer line once a second). Not timed: ARKit itself (its tracking, the capture, delivering frames), reading the capture device's flags and the motion manager, publishing to the main thread, and the recorders' disk and video-encoder work.",
    "Allocations are not counted (no cheap portable allocation counter); the stages allocate their output images and scratch per call.",
    String(format: "Calibration at the end: %.2f ms min (at the start %.2f): a large difference means the machine's load changed during the run; the probes between stage groups show where.", cal2.cpuMs.min, cal.cpuMs.min),
]
if !host.isAppleSiliconMac && macCal == nil {
    notes.append("The budget model and the iPhone table treat this host as if it were the CI Mac (no --mac-calibration given): only the CI Mac's report is meant to be read for them.")
}
let report = BenchReport(host: host, quick: quick, calibration: cal, probes: probes, stages: bench.results, sessions: sessions, lockTimes: lockTimes,
                         budget: budget, notes: notes, seconds: Double(nowNs() &- startTime) / 1e9, viewSearches: viewSearches)
let md = report.markdown()
if let p = markdownPath { try md.write(toFile: p, atomically: true, encoding: .utf8) } else { print(md) }
if let p = jsonPath { try report.json().write(to: URL(fileURLWithPath: p)) }
log(String(format: "bounce-bench done in %.0f s", report.seconds))
