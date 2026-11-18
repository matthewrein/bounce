import Foundation

extension FrameKind: CodingKeyRepresentable {}

struct BenchReport: Codable {
    var tool = "bounce-bench"
    var version = 1
    var host: HostInfo
    var quick: Bool
    var calibration: Calibration
    var stages: [StageResult]
    var sessions: [SessionResult]
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
                 + "\(host.swiftOptimised ? "release (optimised) build" : "DEBUG build: timings meaningless")\(quick ? ", quick run (few iterations)" : ""); \(host.date); "
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
        if let b = budget { m.append("Host -> CI Mac time factor used below: \(f(b.hostToMac, 3)) (\(b.hostToMacBasis)).") }
        m.append("")
        m.append("Every time is one frame's work on one core (the app's processing queue is serial), from a warm-up then repeated runs: "
                 + "min / p50 / p95 / max in ms. Flags: over 8 ms (half a 60 fps frame, leaving room for ARKit's delivery and the UI) = *watch*; "
                 + "over 16.7 ms (a whole frame) = **THREAT**, judged on p95.")
        m.append("")

        // stages
        m.append("#### Stages")
        m.append("")
        m.append("| group | stage | input | min | p50 | p95 | max | n | flag | note |")
        m.append("|---|---|---|--:|--:|--:|--:|--:|---|---|")
        for r in stages {
            let fl = FrameBudget.flag(r.stats.p95)
            m.append("| \(r.group) | \(cell(r.name)) | \(cell(r.input)) | \(f(r.stats.min, 3)) | \(f(r.stats.p50, 3)) | \(f(r.stats.p95, 3)) | \(f(r.stats.max, 3)) | \(r.stats.n) | \(fl.isEmpty ? "" : "**\(fl)**") | \(cell(r.note ?? "")) |")
        }
        m.append("")

        // whole frames
        m.append("#### Whole frames: the app's per-frame work (ARController.handle's BounceCore part), frame kind by frame kind")
        m.append("")
        m.append("60 fps of camera time on a still camera, the app's tracker and cadence; parts (p50): image conversion / LiDAR copy / ball crop / "
                 + "slab crop / tracker.process (its detectors, ball finder, plane check).")
        m.append("")
        m.append("| scene | phase | frame kind | frames | min | p50 | p95 | max | parts p50 | flag |")
        m.append("|---|---|---|--:|--:|--:|--:|--:|---|---|")
        for s in sessions {
            if s.kinds.isEmpty { m.append("| \(s.scene) | \(s.phase) | - | \(s.frames) | | | | | \(cell(s.note ?? "")) | |"); continue }
            for k in s.kinds {
                let parts = "\(f(k.convertP50)) / \(f(k.depthP50)) / \(f(k.ballCropP50)) / \(f(k.slabCropP50)) / \(f(k.processP50))"
                    + (k.recordP50.map { " ; record \(f($0, 3))" } ?? "") + (k.encodeP50.map { " ; recorder queue \(f($0)) (p95 \(f(k.encodeP95 ?? .nan)))" } ?? "")
                let fl = FrameBudget.flag(k.total.p95)
                m.append("| \(s.scene) | \(s.phase) | \(k.kind.rawValue) | \(k.count) | \(f(k.total.min)) | \(f(k.total.p50)) | \(f(k.total.p95)) | \(f(k.total.max)) | \(parts) | \(fl.isEmpty ? "" : "**\(fl)**") |")
            }
        }
        let sessionNotes = sessions.compactMap { s in s.note.map { "\(s.scene), \(s.phase): \($0)" } }
        if !sessionNotes.isEmpty { m.append(""); for n in sessionNotes { m.append("- \(n)") } }
        m.append("")

        // budget
        if let b = budget {
            m.append("#### Budget at 60 fps (16.7 ms a frame)\(onMac ? " on this Mac" : " (this host's times x \(f(b.hostToMac, 3)))")")
            m.append("")
            m.append("Each state run for 30 s of camera time through the app's cadence (search every 0.12 s while searching; re-check every 0.3 s and "
                     + "ball scan every 0.1 s while locked; at least 0.05 s between detector runs) and BounceCore's FramePacer (frames reach the serial "
                     + "queue 30 ms after capture; a frame that waited behind slower work and is over a frame late is skipped), each frame costing its "
                     + "kind's whole-frame time measured above. Load = processing time per second of camera time (% of one core).")
            m.append("")
            func table(_ rs: [CadenceResult], _ title: String) {
                m.append(title)
                m.append("")
                m.append("| state | searches/s | re-checks/s | ball scans/s | load ms/s | % of a core | worst frame (kind) | processed/s | skipped/s | longest gap ms | mean queue wait ms |")
                m.append("|---|--:|--:|--:|--:|--:|---|--:|--:|--:|--:|")
                for r in rs {
                    let fl = FrameBudget.flag(r.worstFrameMs)
                    m.append("| \(r.scenario) | \(f(r.searches, 1)) | \(f(r.rechecks, 1)) | \(f(r.ballScans, 1)) | \(f(r.loadMsPerSecond, 0)) | \(f(r.loadPercent, 1)) | "
                             + "\(f(r.worstFrameMs, 1)) (\(r.worstFrameKind.rawValue))\(fl.isEmpty ? "" : " **\(fl)**") | \(f(r.framesProcessed, 1)) | \(f(r.framesSkipped, 1)) | "
                             + "\(f(r.longestGapMs, 0)) | \(f(r.meanQueueWaitMs, 1)) |")
                }
                m.append("")
            }
            table(b.onMac, "With each kind's p50:")
            table(b.onMacP95, "With each kind's p95 (every frame of a kind as slow as its slowest 5%):")

            // iPhones
            m.append("#### iPhone estimate (an estimate, not a measurement)")
            m.append("")
            m.append("The processing queue is serial, so a phone's single-core speed is what scales these times. CI's macos-15 runner is a virtual "
                     + "machine on an Apple M1 (Geekbench 6 single-core about \(f(Chip.ciMacGeekbench6Single, 0)) for a native M1; the VM taken as the same). "
                     + "Time on a phone = time on the CI Mac x (\(f(Chip.ciMacGeekbench6Single, 0)) / the phone's Geekbench 6 single-core score), "
                     + "uncertain by about +-\(f(Chip.uncertainty * 100, 0))% (Geekbench's mix is not this code's; scores spread a few % by iOS and run; "
                     + "the runner's VM and shared host). The A14 has the M1's own performance core (Firestorm) at 3.0 GHz against 3.2, so its factor "
                     + "is the best founded. Throttled: x\(f(Chip.thermal, 1)) for a phone warm from minutes of AR (camera, LiDAR and GPU busy; phones keep "
                     + "about 65-85% of peak under sustained load). ARKit's own tracking runs on other cores and is not in these numbers; the queue runs "
                     + "at userInteractive QoS, so it gets a performance core.")
            m.append("")
            m.append("| chip (phone) | GB6 single | time factor vs CI Mac | range (+-\(f(Chip.uncertainty * 100, 0))%) |")
            m.append("|---|--:|--:|---|")
            for p in b.phones {
                m.append("| \(p.chip.chip) (\(p.chip.phone)) | \(f(p.chip.geekbench6Single, 0)) | \(f(p.timeFactor)) | \(f(p.timeFactor * (1 - Chip.uncertainty))) - \(f(p.timeFactor * (1 + Chip.uncertainty))) |")
            }
            m.append("")
            func phoneTable(_ throttled: Bool) {
                m.append(throttled ? "Throttled (x\(f(Chip.thermal, 1))): % of a core / skipped frames per s / worst frame ms" :
                                     "Nominal: % of a core / skipped frames per s / worst frame ms (p50 costs)")
                m.append("")
                m.append("| state | " + b.phones.map { $0.chip.chip }.joined(separator: " | ") + " |")
                m.append("|---|" + b.phones.map { _ in "---" }.joined(separator: "|") + "|")
                for (i, sc) in b.scenarios.enumerated() {
                    var row = "| \(sc.name) |"
                    for p in b.phones {
                        let r = throttled ? p.throttled[i] : p.results[i]
                        let w = f(r.worstFrameMs, 1)
                        row += " \(f(r.loadPercent, 0))% / \(f(r.framesSkipped, 1)) / \(r.worstFrameMs > FrameBudget.interval ? "**\(w)**" : r.worstFrameMs > FrameBudget.comfortable ? "*\(w)*" : w) |"
                    }
                    m.append(row)
                }
                m.append("")
            }
            phoneTable(false)
            phoneTable(true)
            m.append("Bold worst frame: over 16.7 ms (the frames behind it wait, and are skipped if over a frame late); italic: over 8 ms.")
            m.append("")

            // threats
            m.append("#### What threatens 60 fps tracking")
            m.append("")
            var lines: [String] = []
            // stages over 8 ms at p95, one line per stage with the inputs that are
            var names: [String] = []
            for r in stages where r.stats.p95 > FrameBudget.comfortable && !names.contains(r.group + "|" + r.name) { names.append(r.group + "|" + r.name) }
            for key in names {
                let rs = stages.filter { $0.group + "|" + $0.name == key && $0.stats.p95 > FrameBudget.comfortable }
                let worst = rs.map(\.stats.p95).max() ?? 0
                let queue = rs.first?.group == "recording" ? " (on the session recorder's own queue, not the processing queue; only while Record session is on)" : ""
                lines.append("- \(worst > FrameBudget.interval ? "**THREAT**" : "*watch*") stage \(rs[0].group): **\(rs[0].name)**\(queue): p95 "
                             + rs.map { "\(f($0.stats.p95, 1)) ms (\($0.input))" }.joined(separator: ", "))
            }
            // whole frames over 8 ms at p95, by kind
            for kind in FrameKind.allCases {
                let hits = sessions.compactMap { s in s.kind(kind).flatMap { $0.total.p95 > FrameBudget.comfortable ? (s, $0) : nil } }
                guard !hits.isEmpty else { continue }
                let worst = hits.map { $0.1.total.p95 }.max() ?? 0
                lines.append("- \(worst > FrameBudget.interval ? "**THREAT**" : "*watch*") frame **\(kind.rawValue)**: p95 "
                             + hits.map { "\(f($0.1.total.p95, 1)) ms (\($0.0.scene), \($0.0.phase))" }.joined(separator: ", "))
            }
            if let a14 = b.phones.first {
                for (i, sc) in b.scenarios.enumerated() where a14.results[i].worstFrameMs > FrameBudget.comfortable {
                    let r = a14.results[i], t = a14.throttled[i]
                    lines.append("- on an \(a14.chip.chip) (estimate): \(sc.name): worst frame \(f(r.worstFrameMs, 1)) ms (\(r.worstFrameKind.rawValue)), "
                                 + "\(f(r.framesSkipped, 1)) skipped frames/s, \(f(r.loadPercent, 0))% of a core; throttled \(f(t.worstFrameMs, 1)) ms, "
                                 + "\(f(t.framesSkipped, 1)) skipped/s")
                }
            }
            m.append(contentsOf: lines.isEmpty ? ["- nothing over 8 ms"] : lines)
            m.append("")
        }
        if !notes.isEmpty {
            m.append("#### Notes")
            m.append("")
            for n in notes { m.append("- \(n)") }
            m.append("")
        }
        return m.joined(separator: "\n")
    }
}
