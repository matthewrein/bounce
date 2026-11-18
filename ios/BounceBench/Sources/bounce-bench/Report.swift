import Foundation

extension FrameKind: CodingKeyRepresentable {}

struct BenchReport: Codable {
    var tool = "bounce-bench"
    var version = 2
    var host: HostInfo
    var quick: Bool
    var calibration: Calibration
    var probes: [Probe]
    var stages: [StageResult]
    var sessions: [SessionResult]
    var lockTimes: [LockTimeResult]
    var budget: BudgetModel?
    var notes: [String]
    var seconds: Double

    func json() -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return (try? e.encode(self)) ?? Data()
    }

    // MARK: Markdown

    func markdown() -> String {
        var m: [String] = []
        func f(_ v: Double, _ d: Int = 2) -> String { v.isFinite ? String(format: "%.\(d)f", v) : "-" }
        func cell(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "/") }
        let onMac = host.isAppleSiliconMac
        m.append("### Device budget: per-frame time of each stage (bounce-bench)")
        m.append("")
        m.append("Host: \(host.os), \(host.arch), \(host.cpu), \(host.cores) cores\(host.loadAverage.map { ", load average \($0)" } ?? ""); "
                 + "\(host.swiftOptimised ? "release (optimised) build" : "DEBUG build: timings meaningless")\(quick ? ", quick run (few iterations, short runs)" : ""); \(host.date); "
                 + "bench took \(f(seconds, 0)) s.")
        m.append("")
        if !onMac {
            m.append("> **Not the CI Mac.** This host is not an Apple-silicon Mac: its times are not the phone's or the Mac's, and on a shared,"
                     + " loaded machine they are noisy and slower than idle (min is the best guide to the uncontended cost). The authoritative"
                     + " numbers are the macOS CI job's. Ratios between stages carry over better than absolute times.")
            m.append("")
        }
        m.append("Calibration (a fixed CPU loop, the same work every run, to compare machines): **\(f(calibration.cpuMs.min)) ms** min "
                 + "(p50 \(f(calibration.cpuMs.p50)) ms; \(f(calibration.nsPerIteration, 3)) ns per iteration of \(calibration.iterations)); "
                 + "memory streaming \(f(calibration.memoryGBps, 1)) GB/s.")
        if !probes.isEmpty {
            let lo = probes.map(\.ms).min() ?? .nan, hi = probes.map(\.ms).max() ?? .nan
            m.append("Calibration probes through the run (ms, scaled to the calibration's work): "
                     + probes.map { "\($0.label) \(f($0.ms))" }.joined(separator: "; ")
                     + ". Drift: the slowest probe is \(f(hi / lo, 2))x the fastest\(hi / lo > 1.15 ? " (**the machine's load changed during the run: compare stages measured near each other**)" : "").")
        }
        if let b = budget { m.append("Host -> CI Mac time factor used below: \(f(b.hostToMac, 3)) (\(b.hostToMacBasis)).") }
        m.append("")
        m.append("Every time is one frame's work on one core (the app's processing queue is serial), from a warm-up then repeated runs: "
                 + "min / p50 / p95 / max in ms. A single time on the processing queue is flagged *watch* over 8 ms (half a 60 fps frame) and "
                 + "**THREAT** over 16.7 ms (a whole frame), judged on p95; comparison-only stages and the recorder's own queue are not flagged. "
                 + "Whether a state threatens 60 fps tracking is judged in the budget model below (skipped frames, frames held).")
        m.append("")

        // stages
        m.append("#### Stages")
        m.append("")
        let anyRegions = stages.contains { $0.regionsGrown != nil }
        m.append("| group | stage | input | runs on | min | p50 | p95 | max | n |" + (anyRegions ? " regions grown |" : "") + " flag | note |")
        m.append("|---|---|---|---|--:|--:|--:|--:|--:|" + (anyRegions ? "--:|" : "") + "---|---|")
        for r in stages {
            let fl: String
            switch r.role {
            case .app: fl = FrameBudget.flag(r.stats.p95).isEmpty ? "" : "**\(FrameBudget.flag(r.stats.p95))**"
            case .comparison: fl = "(comparison)"
            case .recorderQueue: fl = "(own queue)"
            case .candidate: fl = "(before the cut)"
            }
            let role = r.role == .app ? "processing queue" : r.role.rawValue
            m.append("| \(r.group) | \(cell(r.name)) | \(cell(r.input)) | \(role) | \(f(r.stats.min, 3)) | \(f(r.stats.p50, 3)) | \(f(r.stats.p95, 3)) | \(f(r.stats.max, 3)) | \(r.stats.n) |"
                     + (anyRegions ? " \(r.regionsGrown.map(String.init) ?? "") |" : "") + " \(fl) | \(cell(r.note ?? "")) |")
        }
        m.append("")
        if !anyRegions {
            m.append("Regions grown per search: not visible to this build (BounceCore keeps the count internal); an instrumented build "
                     + "(ios/BounceBench/sweep-stats.sh: -D BENCH_SWEEP_STATS against a scratch copy of BounceCore whose SlabFinder logs it) "
                     + "reports them. The search stops growing at maxSweepRegions = 48.")
            m.append("")
        }

        // whole frames
        m.append("#### Whole frames: the app's per-frame work (ARController.handle's BounceCore part), frame kind by frame kind")
        m.append("")
        m.append("60 fps of camera time, the app's tracker and cadence, every frame processed; n = frames of that kind measured. Parts (p50): "
                 + "image conversion (of it ycc.colorFrame) / LiDAR copy / ball crop / slab crop / tracker.process (its detectors, ball finder, plane "
                 + "check) / the app's glue (pacer, overlay, HUD, gate). Kinds: a re-check follows the lock's outline and finds the slab, or misses; "
                 + "\"over the whole view\" sweeps the view (and refines a find), as an unconfirmed lock does every second re-check and an "
                 + "out-of-view one every time. With the capture kit recording, the kit's per-frame work is kept apart (kit p50).")
        m.append("")
        m.append("| scene | phase | frame kind | n | min | p50 | p95 | max | parts p50 | flag |")
        m.append("|---|---|---|--:|--:|--:|--:|--:|---|---|")
        for s in sessions {
            if s.kinds.isEmpty { m.append("| \(s.scene) | \(s.phase) | - | \(s.frames) | | | | | \(cell(s.note ?? "")) | |"); continue }
            for k in s.kinds {
                let parts = "\(f(k.convertP50))\(k.colorFrameP50.map { " (\(f($0)))" } ?? "") / \(f(k.depthP50)) / \(f(k.ballCropP50)) / \(f(k.slabCropP50)) / \(f(k.processP50)) / \(f(k.glueP50, 3))"
                    + (k.kitP50.map { " ; kit \(f($0))" } ?? "")
                    + (k.recordP50.map { " ; record \(f($0, 3))" } ?? "") + (k.encodeP50.map { " ; recorder queue \(f($0)) (p95 \(f(k.encodeP95 ?? .nan)))" } ?? "")
                let fl = FrameBudget.flag(k.total.p95)
                m.append("| \(s.scene) | \(s.phase) | \(k.kind.rawValue) | \(k.count) | \(f(k.total.min)) | \(f(k.total.p50)) | \(f(k.total.p95)) | \(f(k.total.max)) | \(parts) | \(fl.isEmpty ? "" : "**\(fl)**") |")
            }
        }
        let sessionNotes = sessions.compactMap { s -> String? in
            var parts: [String] = []
            if let n = s.note { parts.append(n) }
            if let a = s.kitP50 { parts.append("kit recorder \(f(a)) ms a frame (p95 \(f(s.kitP95 ?? .nan)))") }
            if let g = s.regionsGrownMean { parts.append("regions grown per sweep \(f(g, 1)) (most \(s.regionsGrownMax ?? 0))") }
            return parts.isEmpty ? nil : "\(s.scene), \(s.phase): " + parts.joined(separator: "; ")
        }
        if !sessionNotes.isEmpty { m.append(""); for n in sessionNotes { m.append("- \(n)") } }
        m.append("")

        // time to lock
        if !lockTimes.isEmpty {
            m.append("#### Time to lock (camera time), with the app's hand-off deciding which frames the tracker sees")
            m.append("")
            m.append("Every frame processed (the whole-frame runs above) is a lower bound. Paced: frames reach ARKit's delegate 30 ms after "
                     + "capture and are handed to processing (FrameHandoff): taken at once when it is idle, else they wait, the latest "
                     + "replacing the others (dropped), so a slow search delays the next. Each frame takes its "
                     + "measured time x the factor (x1 = this host taken as the CI Mac\(onMac ? "" : ", here this host itself")). Median (max) seconds over the runs; frames "
                     + "processed / dropped before the lock per run. The time runs to the end of the locking frame's handling.")
            m.append("")
            let labels = Array(Set(lockTimes.map(\.label))).sorted { a, b in
                (lockTimes.first { $0.label == a }?.scale ?? 0) < (lockTimes.first { $0.label == b }?.scale ?? 0)
            }
            m.append("| scene | every frame processed | " + labels.joined(separator: " | ") + " |")
            m.append("|---|--:|" + labels.map { _ in "---" }.joined(separator: "|") + "|")
            var scenesSeen: [String] = []
            for l in lockTimes where !scenesSeen.contains(l.scene) { scenesSeen.append(l.scene) }
            for sc in scenesSeen {
                let unpaced = sessions.first { $0.scene == sc && $0.phase == "acquiring" }?.lockSeconds
                var row = "| \(sc) | \(unpaced.map { f($0) + " s" } ?? "-") |"
                for lb in labels {
                    guard let r = lockTimes.first(where: { $0.scene == sc && $0.label == lb }) else { row += " |"; continue }
                    row += r.locked == 0 ? " no lock in 8 s (\(r.runs) runs) |"
                        : " \(f(r.medianSeconds ?? .nan)) s (\(f(r.maxSeconds ?? .nan))); \(r.locked)/\(r.runs) locked; \(f(r.processed, 0)) / \(f(r.skipped, 0)) |"
                }
                m.append(row)
            }
            m.append("")
        }

        // budget
        if let b = budget {
            m.append("#### Budget at 60 fps (16.7 ms a frame)\(onMac ? " on this Mac" : " (this host's times x \(f(b.hostToMac, 3)))")")
            m.append("")
            m.append("Each state run for 30 s of camera time through the app's cadence (search every 0.12 s while searching; re-check every 0.3 s and "
                     + "ball scan every 0.1 s while locked; at least 0.05 s between detector runs) and the app's pipeline (frames reach ARKit's "
                     + "delegate queue 30 ms after capture, which hands each to the processing queue through BounceCore's FrameHandoff: taken at once "
                     + "when processing is idle, else it waits, the latest replacing and dropping any frame already waiting), each frame costing its "
                     + "kind's whole-frame time measured above (n per kind: the frames behind each cost), the detector runs' kinds taken in the order "
                     + "the app loop saw them. At 60 fps the 0.1 s and 0.3 s intervals come out as 6 or 7 and 18 or 19 frames apart (the frame "
                     + "times' rounding; ARKit's jittered timestamps give the same rates): about 9.2 ball scans and 3.2 re-checks a second. "
                     + "Load = processing time per second of camera time (% of one core: the processing queue's). **Skipped/s**: frames "
                     + "not processed, dropped from the hand-off because processing was busy (the overlay updates that many fewer times a "
                     + "second). **Frames held**: ARKit's frames the app holds when one arrives (the new one, any still in the delegate's "
                     + "queue, the one being processed and the one waiting): each is an ARFrame with its camera buffer, and ARKit warns when "
                     + "the delegate retains about a dozen and then stops delivering camera frames. Through the hand-off at most one frame is "
                     + "processed and one waits, so it stays at 3 at most whatever a search costs, unless the delegate's own work (the kit's "
                     + "scale) outruns the camera. Flag: THREAT at \(f(FrameBudget.skippedThreat, 0)) skipped frames/s or more than "
                     + "\(FrameBudget.heldThreat) frames held; watch at \(f(FrameBudget.skippedWatch, 1)) skipped/s or more than \(FrameBudget.heldWatch) held. "
                     + "With the capture kit recording, its work is on the delegate's queue, on every kept frame, processed or not. The "
                     + "ranked table further down also shows, for comparison, the frames held through one queue as before the hand-off (ARKit's "
                     + "delegate queue = the processing queue, the FramePacer skipping late frames), where they grew without bound once the "
                     + "load passed 100%.")
            m.append("")
            func table(_ rs: [CadenceResult], _ scs: [Scenario], _ title: String) {
                m.append(title)
                m.append("")
                m.append("| state | n per kind | searches/s | re-checks/s | ball scans/s | load ms/s | % of a core | worst frame (kind) | processed/s | skipped/s | longest gap ms | mean queue wait ms | frames held, most (mean) | flag |")
                m.append("|---|---|--:|--:|--:|--:|--:|---|--:|--:|--:|--:|--:|---|")
                for (r, sc) in zip(rs, scs) {
                    let fl = FrameBudget.flag(r)
                    m.append("| \(r.scenario) | \(sc.countsLine) | \(f(r.searches, 1)) | \(f(r.rechecks, 1)) | \(f(r.ballScans, 1)) | \(f(r.loadMsPerSecond, 0)) | \(f(r.loadPercent, 1)) | "
                             + "\(f(r.worstFrameMs, 1)) (\(r.worstFrameKind.rawValue)) | \(f(r.framesProcessed, 1)) | \(f(r.framesSkipped, 1)) | "
                             + "\(f(r.longestGapMs, 0)) | \(f(r.meanQueueWaitMs, 1)) | \(r.maxFramesHeld) (\(f(r.meanFramesHeld, 1))) | \(fl.isEmpty ? "" : "**\(fl)**") |")
                }
                m.append("")
            }
            table(b.onMac, b.scenarios, "With each kind's p50:")
            table(b.onMacP95, b.scenarios, "With each kind's p95 (every frame of a kind as slow as its slowest 5%):")

            // iPhones
            m.append("#### iPhone estimate (an estimate, not a measurement)")
            m.append("")
            m.append("Assumptions. The processing queue is serial, so the speed of the one core it runs on is what scales these times. CI's "
                     + "macos-15 runner is a virtual machine on an Apple M1 (Geekbench 6 single-core about \(f(Chip.ciMacGeekbench6Single, 0)) for a native "
                     + "M1; the VM taken as the same). Time on a phone = time on the CI Mac x (\(f(Chip.ciMacGeekbench6Single, 0)) / the phone's Geekbench 6 "
                     + "single-core score), uncertain by about +-\(f(Chip.uncertainty * 100, 0))% (Geekbench's mix is not this code's; scores spread a few % "
                     + "by iOS and run; the runner's VM and shared host). The queue runs at userInteractive QoS, which asks for a performance core "
                     + "but does not guarantee one: these phones have two, shared with ARKit's tracking and scene depth, the main thread's 60 Hz "
                     + "SwiftUI updates and the recorders. **Nominal** assumes the queue has a performance core to itself; **throttled** x\(f(Chip.thermal, 1)) "
                     + "is a phone warm from minutes of AR (phones keep about 65-85% of peak under sustained load); **contended** x\(f(Chip.contended, 0)) "
                     + "is the queue sharing a core or put on an efficiency core (several times slower) for part of the time: an assumption, not a "
                     + "measurement. ARKit's own CPU and GPU work is not in these numbers. iOS 16 (the deployment target) runs on the A11 and later, "
                     + "and LiDAR is optional, so the phones without it are listed too.")
            m.append("")
            m.append("| chip | phones | LiDAR | GB6 single | source | time factor vs CI Mac | range (+-\(f(Chip.uncertainty * 100, 0))%) |")
            m.append("|---|---|---|--:|---|--:|---|")
            for p in b.phones {
                m.append("| \(p.chip.chip) | \(p.chip.phones) | \(p.chip.lidar ? "yes (Pro)" : "no") | \(f(p.chip.geekbench6Single, 0)) | \(p.chip.source) | \(f(p.timeFactor)) | \(f(p.timeFactor * (1 - Chip.uncertainty))) - \(f(p.timeFactor * (1 + Chip.uncertainty))) |")
            }
            m.append("")
            func phoneTable(_ which: Int) {
                let title = ["Nominal (p50 costs)", "Throttled (x\(f(Chip.thermal, 1)))", "Contended (x\(f(Chip.contended, 0)))"][which]
                m.append("\(title): % of a core / skipped frames per s / worst frame ms / most frames held")
                m.append("")
                m.append("| state | " + b.phones.map { $0.chip.chip }.joined(separator: " | ") + " |")
                m.append("|---|" + b.phones.map { _ in "---" }.joined(separator: "|") + "|")
                for (i, sc) in b.scenarios.enumerated() {
                    var row = "| \(sc.name) |"
                    for p in b.phones {
                        let r = [p.results, p.throttled, p.contended][which][i]
                        let w = f(r.worstFrameMs, 0)
                        let ws = r.worstFrameMs > FrameBudget.interval ? "**\(w)**" : r.worstFrameMs > FrameBudget.comfortable ? "*\(w)*" : w
                        let hs = r.maxFramesHeld > FrameBudget.heldThreat ? "**\(r.maxFramesHeld)**" : "\(r.maxFramesHeld)"
                        let sk = r.framesSkipped >= FrameBudget.skippedThreat ? "**\(f(r.framesSkipped, 1))**" : f(r.framesSkipped, 1)
                        row += " \(f(r.loadPercent, 0))% / \(sk) / \(ws) / \(hs) |"
                    }
                    m.append(row)
                }
                m.append("")
            }
            phoneTable(0)
            phoneTable(1)
            phoneTable(2)
            m.append("Bold: skipped frames at the THREAT rate, a worst frame over 16.7 ms (the frames behind it wait, and are skipped if over a "
                     + "frame late), more than \(FrameBudget.heldThreat) frames held; italic: a worst frame over 8 ms.")
            m.append("")
            m.append("**Check the factor on the phone.** The app measures the same thing: Developer > Copy diagnostics gives `device` and "
                     + "`framePacing.recent.processingByKind` (and `framePacing.total.processingByKind`): `plain`, `ball`, `search` and `recheck`, "
                     + "each `p50` / `p95` / `max` in ms. Compare each with this report's CI Mac p50 / p95 for the same kind (plain: plain; ball: ball "
                     + "scan; search: search + refine while acquiring, or search while nothing is in view; recheck: re-check and re-check + ball "
                     + "scan, locked) under the same conditions (the slab at a similar distance, still): the ratio phone / Mac is the phone's own "
                     + "factor. Replace the table's for that chip with it, and read the nominal and contended columns against it.")
            m.append("")

            // threats
            m.append("#### What threatens 60 fps tracking, ranked")
            m.append("")
            m.append("States ranked by skipped frames per second at the CI Mac's p95 costs, then by frames held; the phone columns use p50 costs "
                     + "(throttled A14: the oldest LiDAR phone, warm; contended A11: the oldest phone the app supports, sharing its core). "
                     + "The last column: the frames held at the same p95 costs through one queue, as before the hand-off.")
            m.append("")
            let a14 = b.phones.first { $0.chip.chip.hasPrefix("A14") }, a11 = b.phones.first
            var order = Array(b.scenarios.indices)
            order.sort { i, j in
                let x = b.onMacP95[i], y = b.onMacP95[j]
                return x.framesSkipped != y.framesSkipped ? x.framesSkipped > y.framesSkipped : x.maxFramesHeld > y.maxFramesHeld
            }
            m.append("| # | state | skipped/s CI Mac p50 | CI Mac p95 | A14 throttled | A11 contended | frames held: Mac p95 / A14 thr. / A11 cont. | worst frame Mac p95 | flag (Mac p95) | one queue (before): held / skipped/s, Mac p95 |")
            m.append("|--:|---|--:|--:|--:|--:|---|---|---|---|")
            for (rank, i) in order.enumerated() {
                let p50 = b.onMac[i], p95 = b.onMacP95[i]
                let t14 = a14?.throttled[i], c11 = a11?.contended[i]
                let fl = FrameBudget.flag(p95)
                m.append("| \(rank + 1) | \(b.scenarios[i].name) | \(f(p50.framesSkipped, 1)) | \(f(p95.framesSkipped, 1)) | \(t14.map { f($0.framesSkipped, 1) } ?? "-") | "
                         + "\(c11.map { f($0.framesSkipped, 1) } ?? "-") | \(p95.maxFramesHeld) / \(t14.map { "\($0.maxFramesHeld)" } ?? "-") / \(c11.map { "\($0.maxFramesHeld)" } ?? "-") | "
                         + "\(f(p95.worstFrameMs, 0)) ms (\(p95.worstFrameKind.rawValue)) | \(fl.isEmpty ? "" : "**\(fl)**") | "
                         + "\(b.onMacP95Queue.map { q in i < q.count ? "\(q[i].maxFramesHeld) / \(f(q[i].framesSkipped, 1))" : "-" } ?? "-") |")
            }
            m.append("")
            var lines: [String] = []
            for i in order where FrameBudget.flag(b.onMacP95[i]).hasPrefix("THREAT") {
                let r = b.onMacP95[i]
                lines.append("- \(b.scenarios[i].name): worst frame \(f(r.worstFrameMs, 0)) ms (\(r.worstFrameKind.rawValue)); "
                             + "\(f(r.framesSkipped, 1)) skipped/s, up to \(r.maxFramesHeld) frames held"
                             + (a14.map { "; on a throttled A14 \(f($0.throttled[i].framesSkipped, 1)) skipped/s, up to \($0.throttled[i].maxFramesHeld) held" } ?? ""))
            }
            let a11Only = order.filter { i in !FrameBudget.flag(b.onMacP95[i]).hasPrefix("THREAT") && (a11.map { FrameBudget.flag($0.contended[i]).hasPrefix("THREAT") } ?? false) }
            if lines.isEmpty { m.append("Nothing reaches the THREAT rate on the CI Mac at p95.") } else {
                m.append("THREAT on the CI Mac at p95:")
                m.append("")
                m.append(contentsOf: lines)
            }
            if !a11Only.isEmpty {
                m.append("")
                m.append("THREAT only on a contended A11 (the oldest phone, sharing its core): " + a11Only.map { b.scenarios[$0].name }.joined(separator: "; ") + ".")
            }
            m.append("")
            m.append("Every slow frame here is a slab detector run (a search, a re-check over the whole view, a refine). Through the hand-off "
                     + "they no longer hold ARKit's frames (at most 3 at a delivery, the arriving one included); what they still cost is the "
                     + "frames dropped while they run (the overlay's updates), which only making the detector cheaper or rarer reduces.")
            m.append("")
        }

        // the behaviour-preserving cuts
        m.append("#### Behaviour-preserving cuts in BounceCore (the code before them, timed here next to BounceCore's own)")
        m.append("")
        func ref(_ c: StageResult) -> StageResult? {
            if c.name.hasPrefix("bi-planar") { return stages.first { $0.group == "convert" && $0.name.hasPrefix("bi-planar") && $0.role == .app } }
            if c.name.hasPrefix("YCCImage -> ColorFrame") { return stages.first { $0.group == "convert" && $0.name.hasPrefix("YCCImage -> ColorFrame") } }
            if c.name.hasPrefix("ball crop -> exact PGM") { return stages.first { $0.group == "recording" && $0.name.hasPrefix("ball crop -> exact PGM") && $0.input.hasPrefix("4 ft") } }
            if c.name.hasPrefix("depth map -> BDP1") { return stages.first { $0.group == "recording" && $0.name.hasPrefix("whole depth map") } }
            return nil
        }
        m.append("| cut | before min / p50 | BounceCore now min / p50 | saved, min to min | check |")
        m.append("|---|--:|--:|--:|---|")
        for c in stages where c.role == .candidate {
            guard let r = ref(c) else { continue }
            m.append("| \(cell(c.name)) | \(f(c.stats.min, 3)) / \(f(c.stats.p50, 3)) | \(f(r.stats.min, 3)) / \(f(r.stats.p50, 3)) | \(f(c.stats.min - r.stats.min, 3)) ms (\(f(100 * (1 - r.stats.min / c.stats.min), 0))%) | \(cell(c.note ?? "")) |")
        }
        if let rec = sessions.first(where: { $0.recording }) {
            if let pi = rec.kind(.plainImage), let cfp = pi.colorFrameP50 {
                let perSecond = Double(pi.count) / max(rec.seconds, 1e-9)
                m.append("| skip ycc.colorFrame unless the detector will run | \(f(cfp, 3)) (colorFrame p50 on a plain + image frame) | - | "
                         + "\(f(cfp, 3)) ms on each of \(f(perSecond, 1)) frames/s while recording (\(f(cfp * perSecond, 1)) ms/s) | NOT applied in this build |")
            } else {
                m.append("| skip ycc.colorFrame unless the detector will run (SlabTracker.detectorWillRun) | about 2.6 ms on each plain + image frame (2.6 a second while recording) | 0 | all of it | applied: the tracker reads the colour frame only in its detector (SpeedupIdentityTests) |")
            }
        }
        m.append("")

        if !notes.isEmpty {
            m.append("#### Notes")
            m.append("")
            for n in notes { m.append("- \(n)") }
            m.append("")
        }
        return m.joined(separator: "\n")
    }
}
