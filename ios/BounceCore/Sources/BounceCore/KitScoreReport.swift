import Foundation

// The capture kit scorer's report (CaptureKit.md, "Scoring"): per shot, per slab position and for the whole kit, as
// JSON (Codable, no paths: kit and shot ids only) and as Markdown, and the comparison with an earlier report.

/// Which way a metric gets better.
public enum KitMetricDirection: String, Codable {
    /// smaller is better
    case lower
    /// larger is better
    case higher
    /// closer to zero is better (a signed error)
    case towardZero
    /// a measurement of the scene, not of the app (e.g. the rebound): reported, never better or worse
    case info
}

/// The unit a metric's value is in.
public enum KitMetricUnit: String, Codable {
    /// 0...1
    case share
    case degrees
    case millimetres
    case seconds
    case count
}

/// One number of the report. A value the scorer could not measure is nil, with the reason in `note`.
public struct KitMetric: Codable, Equatable {
    /// e.g. "lockRate" (see `KitMetric.catalogue`)
    public var id: String
    public var value: Double?
    public var unit: KitMetricUnit
    public var direction: KitMetricDirection
    /// why there is no value (n/a), or a detail
    public var note: String?
    /// how many frames, samples or shots it is over
    public var count: Int?

    public init(id: String, value: Double?, note: String? = nil, count: Int? = nil) {
        let k = KitMetric.kind(id)
        self.id = id; self.value = value.flatMap { $0.isFinite ? $0 : nil }; unit = k.unit; direction = k.direction
        self.note = note; self.count = count
        if value != nil && self.value == nil && note == nil { self.note = "not a finite number" }
    }

    /// n/a, with the reason
    public static func na(_ id: String, _ reason: String) -> KitMetric { KitMetric(id: id, value: nil, note: reason) }

    /// What a metric is: its title, unit, which way is better and the change that counts as one (in its unit).
    public struct Kind {
        public var title: String
        public var unit: KitMetricUnit
        public var direction: KitMetricDirection
        public var tolerance: Double
    }

    /// Every metric the scorer reports. Tolerances are the changes too small to call better or worse.
    public static let catalogue: [String: Kind] = [
        "lockRate": Kind(title: "Lock rate", unit: .share, direction: .higher, tolerance: 0.02),
        "timeToLock": Kind(title: "Time to first lock", unit: .seconds, direction: .lower, tolerance: 0.15),
        "neverLocked": Kind(title: "Slab shots never locked", unit: .count, direction: .lower, tolerance: 0),
        "tiltErrorMedian": Kind(title: "Tilt error, median", unit: .degrees, direction: .lower, tolerance: 0.05),
        "tiltErrorP90": Kind(title: "Tilt error, 90th percentile", unit: .degrees, direction: .lower, tolerance: 0.1),
        "tiltBias": Kind(title: "Tilt bias (tracker minus true)", unit: .degrees, direction: .towardZero, tolerance: 0.05),
        "normalErrorMedian": Kind(title: "Normal direction error, median", unit: .degrees, direction: .lower, tolerance: 0.1),
        "normalErrorP90": Kind(title: "Normal direction error, 90th percentile", unit: .degrees, direction: .lower, tolerance: 0.2),
        "cornerRms": Kind(title: "Corner stability (RMS)", unit: .millimetres, direction: .lower, tolerance: 0.5),
        "slabSizeError": Kind(title: "Slab size error", unit: .millimetres, direction: .towardZero, tolerance: 1),
        "slabFoundRate": Kind(title: "Slab found where there is none", unit: .share, direction: .lower, tolerance: 0.01),
        "slabLockedRate": Kind(title: "Slab locked where there is none", unit: .share, direction: .lower, tolerance: 0.01),
        "ballDetectionRate": Kind(title: "Ball detection rate", unit: .share, direction: .higher, tolerance: 0.03),
        "ballFalsePositiveRate": Kind(title: "Ball found where there is none", unit: .share, direction: .lower, tolerance: 0.01),
        "ballDistanceError": Kind(title: "Ball distance from its size minus from the slab", unit: .millimetres, direction: .towardZero, tolerance: 3),
        "dropHeightError": Kind(title: "Drop height error", unit: .millimetres, direction: .towardZero, tolerance: 3),
        "landingError": Kind(title: "Landing error", unit: .millimetres, direction: .lower, tolerance: 5),
        "landingDistanceError": Kind(title: "Landing distance error", unit: .millimetres, direction: .towardZero, tolerance: 5),
        "apexError": Kind(title: "Apex height error", unit: .millimetres, direction: .towardZero, tolerance: 5),
        "impactHeightError": Kind(title: "Launch height error (predicted minus measured impact)", unit: .millimetres, direction: .towardZero, tolerance: 3),
        "rebound": Kind(title: "Rebound measured", unit: .share, direction: .info, tolerance: 0.02),
    ]

    /// The catalogue's entry (an unknown id is an info metric without a unit).
    public static func kind(_ id: String) -> Kind {
        catalogue[id] ?? Kind(title: id, unit: .count, direction: .info, tolerance: 0)
    }

    public var title: String { KitMetric.kind(id).title }
    public var tolerance: Double { KitMetric.kind(id).tolerance }

    /// The value as the report shows it ("93.3%", "0.12°", "3.4 mm", "0.52 s", "2"), or "n/a".
    public var formatted: String { KitMetric.format(value, unit) }

    public static func format(_ v: Double?, _ unit: KitMetricUnit) -> String {
        guard let v = v else { return "n/a" }
        switch unit {
        case .share: return String(format: "%.1f%%", v * 100)
        case .degrees: return String(format: "%.2f°", v)
        case .millimetres: return String(format: "%.1f mm", v)
        case .seconds: return String(format: "%.2f s", v)
        case .count: return v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.2f", v)
        }
    }
}

/// One shot's scores.
public struct KitShotScore: Codable, Equatable {
    public var shotId: String
    public var step: Int
    /// the slab position (and generation) it was captured in, and that position's true tilt (degrees), if it has one
    public var positionId: String?
    public var trueTiltDegrees: Double?
    /// video frames scored, and the shot's length (s)
    public var frames: Int
    public var seconds: Double
    /// why the shot could not be scored at all (no video, frames that do not match, ...)
    public var error: String?
    public var metrics: [KitMetric]
    /// drops: the bounce in detail
    public var bounce: KitBounceAnalysis?

    public init(shotId: String, step: Int, positionId: String? = nil, trueTiltDegrees: Double? = nil, frames: Int = 0, seconds: Double = 0,
                error: String? = nil, metrics: [KitMetric] = [], bounce: KitBounceAnalysis? = nil) {
        self.shotId = shotId; self.step = step; self.positionId = positionId; self.trueTiltDegrees = trueTiltDegrees; self.frames = frames
        self.seconds = seconds; self.error = error; self.metrics = metrics; self.bounce = bounce
    }

    public func metric(_ id: String) -> KitMetric? { metrics.first { $0.id == id } }
}

/// One slab position's scores (frames of all its shots pooled).
public struct KitPositionScore: Codable, Equatable {
    /// "p2", or "p2#2" for a later generation
    public var positionId: String
    public var label: String
    /// the true tilt (degrees) and how it was read (`KitTrueTilt.Method`), if usable
    public var trueTiltDegrees: Double?
    public var method: String?
    public var uncertaintyDegrees: Double?
    /// the shots scored in it
    public var shots: [String]
    /// the CoreMotion-to-ARKit link used for the normal's direction, if one could be made
    public var link: KitMotionLink?
    public var metrics: [KitMetric]

    public init(positionId: String, label: String, trueTiltDegrees: Double? = nil, method: String? = nil, uncertaintyDegrees: Double? = nil,
                shots: [String] = [], link: KitMotionLink? = nil, metrics: [KitMetric] = []) {
        self.positionId = positionId; self.label = label; self.trueTiltDegrees = trueTiltDegrees; self.method = method
        self.uncertaintyDegrees = uncertaintyDegrees; self.shots = shots; self.link = link; self.metrics = metrics
    }

    public func metric(_ id: String) -> KitMetric? { metrics.first { $0.id == id } }
}

/// One kit's scores.
public struct KitScoreReport: Codable, Equatable {
    public static let formatName = "bouncekit-score"
    public var format = KitScoreReport.formatName
    public var version = 1
    public var kitId: String
    public var planId: String
    /// the build that captured the kit (kit.json), and the phone model and iOS version (no device name)
    public var build: String
    public var deviceModel: String
    public var systemVersion: String
    public var hasLiDAR: Bool
    /// "kit" for a captured kit, "synthetic" for the synthetic one
    public var source: String
    /// "app": the app's own settings (what the owner's phone runs); "measured": the kit's measured slab and ball
    public var settings: String
    /// the owner entered the measurements (step 1)
    public var measurementsEntered: Bool
    public var shots: [KitShotScore]
    public var positions: [KitPositionScore]
    public var aggregates: [KitMetric]
    public var notes: [String]

    public init(kitId: String, planId: String, build: String, deviceModel: String, systemVersion: String, hasLiDAR: Bool, source: String,
                settings: String, measurementsEntered: Bool, shots: [KitShotScore] = [], positions: [KitPositionScore] = [],
                aggregates: [KitMetric] = [], notes: [String] = []) {
        self.kitId = kitId; self.planId = planId; self.build = build; self.deviceModel = deviceModel; self.systemVersion = systemVersion
        self.hasLiDAR = hasLiDAR; self.source = source; self.settings = settings; self.measurementsEntered = measurementsEntered
        self.shots = shots; self.positions = positions; self.aggregates = aggregates; self.notes = notes
    }

    public func aggregate(_ id: String) -> KitMetric? { aggregates.first { $0.id == id } }
    public func shot(_ id: String) -> KitShotScore? { shots.first { $0.shotId == id } }
    public func position(_ id: String) -> KitPositionScore? { positions.first { $0.positionId == id } }

    /// Every metric with its key ("aggregate/<id>", "<shotId>/<id>", "position <posId>/<id>"), for comparisons.
    public var keyedMetrics: [(key: String, scope: String, metric: KitMetric)] {
        var out: [(key: String, scope: String, metric: KitMetric)] = aggregates.map { (key: "aggregate/" + $0.id, scope: "aggregate", metric: $0) }
        for p in positions {
            out += p.metrics.map { (key: "position \(p.positionId)/" + $0.id, scope: "position \(p.positionId)", metric: $0) }
        }
        for s in shots { out += s.metrics.map { (key: "\(s.shotId)/" + $0.id, scope: s.shotId, metric: $0) } }
        return out
    }
}

/// The scores of one run of the scorer: one report per kit (JSON top level).
public struct KitScoreSet: Codable, Equatable {
    public static let formatName = "bouncekit-scores"
    public var format = KitScoreSet.formatName
    public var version = 1
    /// when it was scored (ISO, UTC) and by which scorer (a build label or git hash, if given)
    public var scoredAt: String?
    public var scorer: String?
    public var reports: [KitScoreReport]

    public init(reports: [KitScoreReport], scoredAt: String? = nil, scorer: String? = nil) {
        self.reports = reports; self.scoredAt = scoredAt; self.scorer = scorer
    }

    public func report(_ kitId: String) -> KitScoreReport? { reports.first { $0.kitId == kitId } }
    /// The report of a kit scored with the given settings ("app" or "measured").
    public func report(_ kitId: String, settings: String) -> KitScoreReport? { reports.first { $0.kitId == kitId && $0.settings == settings } }

    public func json() throws -> Data { try KitJSON.encode(self) }
    public static func read(_ data: Data) throws -> KitScoreSet {
        // a single report reads as a set of one
        if let s = try? KitJSON.decode(KitScoreSet.self, from: data), s.format == formatName { return s }
        return KitScoreSet(reports: [try KitJSON.decode(KitScoreReport.self, from: data)])
    }
}

// MARK: comparison

/// How one metric changed from an earlier report.
public struct KitMetricChange: Codable, Equatable {
    public enum Status: String, Codable {
        /// better by more than the metric's tolerance
        case better
        /// worse by more than the tolerance, or a value that is now n/a
        case worse
        /// within the tolerance (or n/a both times)
        case same
        /// an info metric that changed by more than its tolerance
        case changed
        /// not in the earlier report
        case new
        /// in the earlier report only
        case gone
    }
    public var kitId: String
    /// "aggregate", a shot id, or "position p2"
    public var scope: String
    public var metric: String
    public var before: Double?
    public var after: Double?
    public var unit: KitMetricUnit
    public var status: Status
    /// after's n/a reason when it lost its value
    public var note: String?

    public var isRegression: Bool { status == .worse || (status == .gone && before != nil) }
}

/// A report compared with an earlier one.
public struct KitScoreComparison: Codable, Equatable {
    public var changes: [KitMetricChange]
    /// kits in only one of the two
    public var kitsAdded: [String]
    public var kitsRemoved: [String]
    /// kits scored with other settings than before ("app" against "measured"): not compared, since their scores
    /// would differ for that reason alone
    public var settingsChanged: [String] = []

    public var regressions: [KitMetricChange] { changes.filter { $0.isRegression } }
    public var improvements: [KitMetricChange] { changes.filter { $0.status == .better } }
    public var hasRegressions: Bool { !regressions.isEmpty }

    /// The status of a change from `before` to `after` for a metric kind.
    public static func status(_ k: KitMetric.Kind, before: Double?, after: Double?) -> KitMetricChange.Status {
        switch (before, after) {
        case (nil, nil): return .same
        case (.some, nil): return k.direction == .info ? .changed : .worse
        case (nil, .some): return k.direction == .info ? .changed : .better
        case let (.some(b), .some(a)):
            let tol = k.tolerance + 1e-9
            switch k.direction {
            case .lower: return a > b + tol ? .worse : a < b - tol ? .better : .same
            case .higher: return a < b - tol ? .worse : a > b + tol ? .better : .same
            case .towardZero: return abs(a) > abs(b) + tol ? .worse : abs(a) < abs(b) - tol ? .better : .same
            case .info: return abs(a - b) > tol ? .changed : .same
            }
        }
    }
}

extension KitScoreSet {
    /// Every metric compared with an earlier run's, kit by kit (matched by kit id and the settings it was scored with,
    /// `KitScoreReport.settings`), with direction-aware tolerances (`KitMetric.catalogue`): `regressions` are the
    /// metrics that got worse, or lost their value. A kit scored with other settings than before is not compared
    /// (`settingsChanged`): scoring with the measured slab and ball instead of the app's changes the scores by itself.
    public func compare(previous: KitScoreSet) -> KitScoreComparison {
        var changes: [KitMetricChange] = []
        var settingsChanged: [String] = []
        let beforeIds = Set(previous.reports.map { $0.kitId }), afterIds = Set(reports.map { $0.kitId })
        for r in reports {
            if let p = previous.report(r.kitId, settings: r.settings) { changes += r.compare(previous: p) }
            else if previous.report(r.kitId) != nil { settingsChanged.append(r.kitId) }
        }
        var c = KitScoreComparison(changes: changes, kitsAdded: reports.map { $0.kitId }.filter { !beforeIds.contains($0) },
                                   kitsRemoved: previous.reports.map { $0.kitId }.filter { !afterIds.contains($0) })
        c.settingsChanged = settingsChanged
        return c
    }
}

extension KitScoreReport {
    /// Every metric of this report against the same metric of `previous` (the same kit, scored earlier).
    public func compare(previous: KitScoreReport) -> [KitMetricChange] {
        var out: [KitMetricChange] = []
        let before = Dictionary(previous.keyedMetrics.map { ($0.key, $0.metric) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        for (key, scope, m) in keyedMetrics {
            seen.insert(key)
            let k = KitMetric.kind(m.id)
            guard let b = before[key] else {
                out.append(KitMetricChange(kitId: kitId, scope: scope, metric: m.id, before: nil, after: m.value, unit: m.unit, status: .new, note: m.note))
                continue
            }
            let st = KitScoreComparison.status(k, before: b.value, after: m.value)
            out.append(KitMetricChange(kitId: kitId, scope: scope, metric: m.id, before: b.value, after: m.value, unit: m.unit, status: st,
                                       note: m.value == nil ? m.note : nil))
        }
        for (key, scope, m) in previous.keyedMetrics where !seen.contains(key) {
            out.append(KitMetricChange(kitId: kitId, scope: scope, metric: m.id, before: m.value, after: nil, unit: m.unit, status: .gone, note: nil))
        }
        return out
    }
}

// MARK: Markdown

extension KitScoreReport {
    static func cell(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ") }

    /// The report as Markdown: the kit's headline numbers, its slab positions, its shots, and what could not be
    /// measured and why.
    public func markdown() -> String {
        var md: [String] = []
        let kind = source == "synthetic" ? "synthetic kit" : "kit"
        md.append("### \(kitId) (\(kind))")
        md.append("")
        let lidar = hasLiDAR ? ", LiDAR" : ""
        let set = settings == "measured" ? "the kit's measured slab and ball" : "the app's own settings"
        md.append("Plan \(planId), captured with build \(build) on \(deviceModel) (iOS \(systemVersion)\(lidar)). Scored with \(set).")
        let scored = shots.filter { $0.error == nil }.count
        let failed = shots.filter { $0.error != nil }
        md.append("\(scored) video shots scored" + (failed.isEmpty ? "." : ", \(failed.count) could not be: "
                                                     + failed.map { "\($0.shotId) (\($0.error ?? ""))" }.joined(separator: "; ") + "."))
        if !notes.isEmpty { md.append("") }
        for n in notes { md.append("- " + KitScoreReport.cell(n)) }
        md.append("")
        md.append("| Metric | Value | Over |")
        md.append("|---|---|---|")
        for m in aggregates {
            md.append("| \(m.title) | \(m.formatted) | \(m.value == nil ? KitScoreReport.cell(m.note ?? "") : (m.count.map { String($0) } ?? "")) |")
        }
        if !positions.isEmpty {
            md.append("")
            md.append("| Position | True tilt | Read | Shots | Tilt error (median / p90) | Bias | Normal error (median / p90) |")
            md.append("|---|---|---|---|---|---|---|")
            for p in positions {
                let truth = p.trueTiltDegrees.map { String(format: "%.2f°", $0) + (p.uncertaintyDegrees.map { String(format: " ± %.2f°", $0) } ?? "") } ?? "none"
                func v(_ id: String) -> String { p.metric(id)?.formatted ?? "n/a" }
                md.append("| \(p.positionId) \(p.label) | \(truth) | \(p.method ?? "-") | \(p.shots.count) | \(v("tiltErrorMedian")) / \(v("tiltErrorP90")) | "
                          + "\(v("tiltBias")) | \(v("normalErrorMedian")) / \(v("normalErrorP90")) |")
            }
        }
        let slabShots = shots.filter { s in ["lockRate", "tiltErrorMedian", "slabFoundRate"].contains { s.metric($0) != nil } }
        if !slabShots.isEmpty {
            md.append("")
            md.append("| Shot | Position | Frames | Lock rate | First lock | Tilt error (median / p90) | Normal error | Corners | Size | False slab |")
            md.append("|---|---|---|---|---|---|---|---|---|---|")
            for s in slabShots {
                func v(_ id: String) -> String { s.metric(id).map { $0.formatted } ?? "" }
                let tilt = s.metric("tiltErrorMedian") == nil ? "" : "\(v("tiltErrorMedian")) / \(v("tiltErrorP90"))"
                let falseSlab = s.metric("slabFoundRate") == nil ? "" : "\(v("slabFoundRate")) found, \(v("slabLockedRate")) locked"
                md.append("| \(s.shotId) | \(s.positionId ?? "-") | \(s.frames) | \(v("lockRate")) | \(v("timeToLock")) | \(tilt) | "
                          + "\(v("normalErrorMedian")) | \(v("cornerRms")) | \(v("slabSizeError")) | \(falseSlab) |")
            }
        }
        let ballIds = ["ballDetectionRate", "ballFalsePositiveRate", "ballDistanceError", "dropHeightError", "landingError", "apexError", "rebound"]
        let ballShots = shots.filter { s in ballIds.contains { s.metric($0) != nil } }
        if !ballShots.isEmpty {
            md.append("")
            md.append("| Shot | Ball found | False ball | Ball distance | Drop height | Landing (launch height) | Apex | Rebound |")
            md.append("|---|---|---|---|---|---|---|---|")
            for s in ballShots {
                func v(_ id: String) -> String { s.metric(id).map { $0.formatted } ?? "" }
                let landing = s.metric("landingError") == nil ? "" : "\(v("landingError")) (\(v("impactHeightError")))"
                md.append("| \(s.shotId) | \(v("ballDetectionRate")) | \(v("ballFalsePositiveRate")) | \(v("ballDistanceError")) | "
                          + "\(v("dropHeightError")) | \(landing) | \(v("apexError")) | \(v("rebound")) |")
            }
        }
        // what could not be measured, grouped by reason
        var reasons: [String: [String]] = [:], order: [String] = []
        func add(_ reason: String, _ what: String) {
            if reasons[reason] == nil { order.append(reason) }
            reasons[reason, default: []].append(what)
        }
        for m in aggregates where m.value == nil { add(m.note ?? "no value", "aggregate \(m.id)") }
        for p in positions { for m in p.metrics where m.value == nil { add(m.note ?? "no value", "\(p.positionId) \(m.id)") } }
        for s in shots { for m in s.metrics where m.value == nil { add(m.note ?? "no value", "\(s.shotId) \(m.id)") } }
        if !order.isEmpty {
            md.append("")
            md.append("Not measured (n/a):")
            md.append("")
            for r in order {
                let w = reasons[r]!
                let list = w.count > 6 ? w.prefix(6).joined(separator: ", ") + " and \(w.count - 6) more" : w.joined(separator: ", ")
                md.append("- \(KitScoreReport.cell(r)): \(list)")
            }
        }
        return md.joined(separator: "\n")
    }
}

extension KitScoreComparison {
    /// The comparison as Markdown: regressions first, then improvements, and a count of what stayed the same.
    public func markdown() -> String {
        var md: [String] = ["### Compared with the previous scores", ""]
        if !kitsAdded.isEmpty { md.append("New kits: " + kitsAdded.joined(separator: ", ") + ".") }
        if !kitsRemoved.isEmpty { md.append("Kits no longer scored: " + kitsRemoved.joined(separator: ", ") + ".") }
        if !settingsChanged.isEmpty {
            md.append("Not compared, scored with other settings than before (the app's against the measured slab and ball): "
                      + settingsChanged.joined(separator: ", ") + ".")
        }
        func table(_ title: String, _ rows: [KitMetricChange]) {
            guard !rows.isEmpty else { return }
            md.append("")
            md.append("\(title):")
            md.append("")
            md.append("| Kit | Where | Metric | Before | After | Change |")
            md.append("|---|---|---|---|---|---|")
            for c in rows {
                let delta: String
                if let a = c.after, let b = c.before { delta = KitMetric.format(a - b, c.unit) } else { delta = c.after == nil ? "lost" : "new" }
                let after = c.after == nil ? "n/a" + (c.note.map { " (" + KitScoreReport.cell($0) + ")" } ?? "") : KitMetric.format(c.after, c.unit)
                md.append("| \(c.kitId) | \(c.scope) | \(KitMetric.kind(c.metric).title) | \(KitMetric.format(c.before, c.unit)) | \(after) | \(delta) |")
            }
        }
        let reg = regressions, imp = improvements
        if reg.isEmpty { md.append(""); md.append("No regressions.") }
        table("Worse", reg)
        table("Better", imp)
        let same = changes.filter { $0.status == .same }.count, new = changes.filter { $0.status == .new }.count
        let changed = changes.filter { $0.status == .changed }.count
        md.append("")
        md.append("\(same) metrics the same" + (changed > 0 ? ", \(changed) scene measurements changed" : "") + (new > 0 ? ", \(new) new" : "") + ".")
        return md.joined(separator: "\n")
    }
}

extension KitScoreSet {
    /// Every kit's report as Markdown, and the comparison if given.
    public func markdown(comparison: KitScoreComparison? = nil) -> String {
        var parts = ["## Capture kit scores", ""]
        if let s = scorer { parts.append("Scorer: \(s)."); parts.append("") }
        parts += reports.map { $0.markdown() + "\n" }
        if let c = comparison { parts.append(c.markdown()) }
        return parts.joined(separator: "\n")
    }
}
