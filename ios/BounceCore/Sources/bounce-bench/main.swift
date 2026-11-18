import BounceCore
import Foundation

// bounce-bench: times each stage of the phone's per-frame path (ARController.handle and the BounceCore code it runs) on
// representative synthetic camera frames, models the 60 fps budget with the app's cadence and frame pacer, and estimates
// iPhone times from the CI Mac's. Build and run it optimised:
//
//     swift run -c release --package-path ios/BounceCore bounce-bench [options]
//
// Options:
//   --quick               few iterations (a smoke test; numbers rough)
//   --markdown FILE       write the Markdown report there (default: stdout)
//   --json FILE           write the JSON report there
//   --only TEXT           only the stages whose group, name or input contain TEXT (case-insensitive); with it the app
//                         loop and the budget model are skipped unless TEXT is "frames"
//   --iterations N        timed runs per stage (default: by stage, up to 60, capped by time)
//   --scenes LIST         which scenes to render: comma-separated feet among 2,4,6 and "empty" (default: all)
//   --cache DIR           keep the rendered frames in DIR and read them back next time (never commit them)
//   --mac-calibration MS  the CI Mac's calibration (min ms, from its report): scales this host's times to the Mac's
//                         for the budget model and the iPhone estimate (default: 1 on an Apple-silicon Mac, else 1 with
//                         a warning)
//   --no-app-loop         skip the whole-frame runs and the budget model
//   --skip-calibration    a token calibration only (for profiling runs under valgrind, where it would take minutes)

setvbuf(stdout, nil, _IOLBF, 0)
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
let skipCalibration = has("--skip-calibration")
let markdownPath = take("--markdown")
let jsonPath = take("--json")
let only = take("--only")
let iterations = take("--iterations").flatMap { Int($0) }
let scenesArg = take("--scenes")
let cacheDir = take("--cache").map { URL(fileURLWithPath: $0, isDirectory: true) }
let macCal = take("--mac-calibration").flatMap { Double($0) }
if !args.isEmpty {
    FileHandle.standardError.write("bounce-bench: unknown arguments \(args)\n".data(using: .utf8)!)
    exit(2)
}
func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

let host = HostInfo.current()
#if DEBUG
log("bounce-bench: this is a DEBUG build; build with -c release for meaningful times")
#endif
log("bounce-bench on \(host.os) \(host.arch) \(host.cpu), \(host.cores) cores, load \(host.loadAverage ?? "?")")

// calibration first (and again at the end: a machine whose load changed shows it)
let cal = Calibration.run(quick: quick, iterations: skipCalibration ? 100_000 : 10_000_000)
log(String(format: "calibration: %.2f ms min, %.2f p50; memory %.1f GB/s", cal.cpuMs.min, cal.cpuMs.p50, cal.memoryGBps))

// scenes
var scenes = BenchScene.all(quick: quick, cache: cacheDir, log: log)
if let list = scenesArg?.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
    scenes = scenes.filter { s in list.contains { $0 == "empty" ? s.kind == .nothing : Double($0) == s.feet } }
}
for s in scenes {
    let q = s.truthOutline.map { o in o.map { String(format: "(%.0f,%.0f)", $0.x, $0.y) }.joined(separator: " ") } ?? "-"
    log("  \(s.name): slab outline (processing px) \(q); ball at \(s.ballPixel.map { String(format: "(%.0f,%.0f)", $0.x, $0.y) } ?? "-") full px")
}

// stages
let bench = StageBench(scenes: scenes, quick: quick, only: only, iterations: iterations, log: log)
bench.runAll()

// whole frames and the budget model
var sessions: [SessionResult] = []
var budget: BudgetModel? = nil
let runLoop = !noAppLoop && (only == nil || only!.lowercased() == "frames")
var hostToMac = 1.0, basis = host.isAppleSiliconMac ? "this is an Apple-silicon Mac: taken as the CI Mac itself" : "NOT a Mac: this host's times used as they are"
if let mc = macCal, mc > 0 {
    hostToMac = mc / cal.cpuMs.min
    basis = String(format: "the CI Mac's calibration %.2f ms / this host's %.2f ms", mc, cal.cpuMs.min)
}
if runLoop {
    log("app loop (whole frames):")
    sessions = runAppLoops(scenes: scenes, quick: quick, log: log)
    budget = BudgetModel.make(sessions: sessions, hostToMac: hostToMac, basis: basis)
}

let cal2 = Calibration.run(quick: true, iterations: skipCalibration ? 100_000 : 10_000_000)
var notes: [String] = [
    "Inputs: SyntheticScene renders at 1920x1440 (fx 1450 px, ARKit's 4:3 wide format), one sample a pixel softened like a lens, sensor noise of 1.5 grey levels; the slab (7 in, 8 deg tilt) seen from 2, 4 and 6 ft along the line of sight, 50 deg above level; a 35 mm ball held over it (0.12, 0.3, 0.45 m) or none; and an empty view of the floor (a cutting mat with a grid). Built once into the camera's bi-planar 4:2:0 buffer (luma plane, interleaved CbCr) and a 256x192 LiDAR map, outside the timing. Real scenes have more clutter than this floor: a search there can take longer.",
    "The app's own helpers (FrameConversion.lumaCrop with vDSP, FrameConversion.depth) live in the app: they are replicated here on plain buffers. On a Mac the crop is the app's vDSP code verbatim; elsewhere the pure-Swift row-convert variant stands in for it in the whole-frame runs (the per-pixel loop is timed too).",
    "Not timed: ARKit itself (its tracking, the capture, delivering frames), the overlay's projection, the HUD and developer strings, the capture-lock gate and publishing to the main thread (app code with no BounceCore part; small), and the session recorder's and capture kit's disk and video-encoder work.",
    "Allocations are not counted (no cheap portable allocation counter); the stages allocate their output images and scratch per call.",
    String(format: "Calibration at the end: %.2f ms min (at the start %.2f): a large difference means the machine's load changed during the run.", cal2.cpuMs.min, cal.cpuMs.min),
]
if !host.isAppleSiliconMac && macCal == nil {
    notes.append("The budget model and the iPhone table treat this host as if it were the CI Mac (no --mac-calibration given): only the CI Mac's report is meant to be read for them.")
}
let report = BenchReport(host: host, quick: quick, calibration: cal, stages: bench.results, sessions: sessions, budget: budget, notes: notes,
                         seconds: Double(nowNs() &- startTime) / 1e9)
let md = report.markdown()
if let p = markdownPath { try md.write(toFile: p, atomically: true, encoding: .utf8) } else { print(md) }
if let p = jsonPath { try report.json().write(to: URL(fileURLWithPath: p)) }
log(String(format: "bounce-bench done in %.0f s", report.seconds))
