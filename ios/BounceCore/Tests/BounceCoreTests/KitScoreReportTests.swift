import XCTest
@testable import BounceCore

/// The score report: comparison with an earlier run, and formatting.
final class KitScoreReportTests: XCTestCase {
    func report(kit: String = "slab-kit-20261117-153000", tilt: Double? = 0.2, lock: Double? = 0.95, rebound: Double? = 0.7,
                ballNote: String? = nil, shots: [KitShotScore]? = nil) -> KitScoreReport {
        var r = KitScoreReport(kitId: kit, planId: "standard-v1", build: "0.1 (1)", deviceModel: "iPhone16,1", systemVersion: "18.1",
                               hasLiDAR: true, source: "kit", settings: "app", measurementsEntered: true)
        r.aggregates = [KitMetric(id: "lockRate", value: lock, count: 10), KitMetric(id: "tiltErrorMedian", value: tilt, count: 300),
                        KitMetric(id: "tiltBias", value: -0.1), KitMetric(id: "rebound", value: rebound),
                        ballNote.map { KitMetric.na("ballDetectionRate", $0) } ?? KitMetric(id: "ballDetectionRate", value: 0.8)]
        r.shots = shots ?? [KitShotScore(shotId: "s04-level-still", step: 4, positionId: "p1", trueTiltDegrees: 0.4, frames: 150, seconds: 5,
                                         metrics: [KitMetric(id: "lockRate", value: lock), KitMetric(id: "timeToLock", value: 0.6),
                                                   KitMetric(id: "tiltErrorMedian", value: tilt), KitMetric(id: "tiltErrorP90", value: tilt.map { $0 * 2 })])]
        r.positions = [KitPositionScore(positionId: "p1", label: "level", trueTiltDegrees: 0.4, method: "twoReading", uncertaintyDegrees: 0.05,
                                        shots: ["s04-level-still"], metrics: [KitMetric(id: "tiltErrorMedian", value: tilt)])]
        return r
    }

    func testStatusIsDirectionAware() {
        let lower = KitMetric.kind("tiltErrorMedian"), higher = KitMetric.kind("lockRate"), zero = KitMetric.kind("tiltBias"), info = KitMetric.kind("rebound")
        XCTAssertEqual(KitScoreComparison.status(lower, before: 0.2, after: 0.3), .worse)
        XCTAssertEqual(KitScoreComparison.status(lower, before: 0.3, after: 0.2), .better)
        XCTAssertEqual(KitScoreComparison.status(lower, before: 0.2, after: 0.25), .same, "within the tolerance (0.05) is the same")
        XCTAssertEqual(KitScoreComparison.status(higher, before: 0.9, after: 0.8), .worse)
        XCTAssertEqual(KitScoreComparison.status(higher, before: 0.8, after: 0.9), .better)
        XCTAssertEqual(KitScoreComparison.status(zero, before: -0.1, after: 0.3), .worse, "further from zero")
        XCTAssertEqual(KitScoreComparison.status(zero, before: 0.3, after: -0.1), .better)
        XCTAssertEqual(KitScoreComparison.status(zero, before: 0.2, after: -0.2), .same)
        XCTAssertEqual(KitScoreComparison.status(info, before: 0.7, after: 0.5), .changed)
        XCTAssertEqual(KitScoreComparison.status(info, before: 0.7, after: 0.71), .same)
        XCTAssertEqual(KitScoreComparison.status(lower, before: 0.2, after: nil), .worse, "a value lost is a regression")
        XCTAssertEqual(KitScoreComparison.status(lower, before: nil, after: 0.2), .better)
        XCTAssertEqual(KitScoreComparison.status(lower, before: nil, after: nil), .same)
    }

    func testComparisonListsRegressions() throws {
        let before = KitScoreSet(reports: [report(), report(kit: "slab-kit-20261118-090000")])
        var worse = report(tilt: 0.5, lock: 0.97, rebound: 0.5, ballNote: "the slab never locked")
        worse.shots.append(KitShotScore(shotId: "s06-dim", step: 6, metrics: [KitMetric(id: "lockRate", value: 0.5)]))
        let after = KitScoreSet(reports: [worse, report(kit: "slab-kit-20261119-090000")])
        let c = after.compare(previous: before)
        XCTAssertEqual(c.kitsAdded, ["slab-kit-20261119-090000"])
        XCTAssertEqual(c.kitsRemoved, ["slab-kit-20261118-090000"])
        let reg = Set(c.regressions.map { "\($0.scope)/\($0.metric)" })
        XCTAssertEqual(reg, ["aggregate/tiltErrorMedian", "aggregate/ballDetectionRate", "s04-level-still/tiltErrorMedian",
                             "s04-level-still/tiltErrorP90", "position p1/tiltErrorMedian"])
        XCTAssertTrue(c.hasRegressions)
        XCTAssertEqual(c.changes.first { $0.scope == "aggregate" && $0.metric == "rebound" }?.status, .changed)
        XCTAssertEqual(c.changes.first { $0.scope == "aggregate" && $0.metric == "lockRate" }?.status, .same)
        XCTAssertEqual(c.changes.first { $0.scope == "s06-dim" }?.status, .new)
        XCTAssertEqual(c.changes.first { $0.metric == "ballDetectionRate" }?.note, "the slab never locked")
        // the same scores again: nothing worse
        XCTAssertFalse(before.compare(previous: before).hasRegressions)
        // a shot no longer scored is a regression for each metric it had a value for
        var fewer = report()
        fewer.shots = []
        let g = KitScoreSet(reports: [fewer]).compare(previous: KitScoreSet(reports: [report()]))
        XCTAssertEqual(g.regressions.filter { $0.status == .gone }.count, 4)
        let md = c.markdown()
        XCTAssertTrue(md.contains("Worse:"), md)
        XCTAssertTrue(md.contains("| slab-kit-20261117-153000 | aggregate | Tilt error, median | 0.20° | 0.50° | 0.30° |"), md)
        XCTAssertTrue(md.contains("n/a (the slab never locked)"), md)
        XCTAssertTrue(md.contains("New kits: slab-kit-20261119-090000."))
    }

    /// A kit scored with the measured slab and ball is not compared with the same kit scored with the app's settings:
    /// the settings alone change the scores, and that is no regression.
    func testOnlyRunsWithTheSameSettingsAreCompared() {
        var measured = report(tilt: 0.9, lock: 0.5)
        measured.settings = "measured"
        let c = KitScoreSet(reports: [measured]).compare(previous: KitScoreSet(reports: [report()]))
        XCTAssertFalse(c.hasRegressions)
        XCTAssertTrue(c.changes.isEmpty)
        XCTAssertEqual(c.settingsChanged, ["slab-kit-20261117-153000"])
        XCTAssertTrue(c.kitsAdded.isEmpty && c.kitsRemoved.isEmpty)
        XCTAssertTrue(c.markdown().contains("Not compared, scored with other settings than before"), c.markdown())
        // a set holding both: each is compared with its own kind
        let before = KitScoreSet(reports: [report(), { var r = report(); r.settings = "measured"; return r }()])
        let after = KitScoreSet(reports: [report(), measured])
        let d = after.compare(previous: before)
        XCTAssertEqual(Set(d.regressions.map { $0.metric }), ["tiltErrorMedian", "lockRate", "tiltErrorP90"])
        XCTAssertTrue(d.settingsChanged.isEmpty)
    }

    func testFormattingAndMarkdown() throws {
        XCTAssertEqual(KitMetric(id: "lockRate", value: 0.9333).formatted, "93.3%")
        XCTAssertEqual(KitMetric(id: "tiltErrorMedian", value: 0.123).formatted, "0.12°")
        XCTAssertEqual(KitMetric(id: "cornerRms", value: 3.44).formatted, "3.4 mm")
        XCTAssertEqual(KitMetric(id: "timeToLock", value: 0.5).formatted, "0.50 s")
        XCTAssertEqual(KitMetric(id: "neverLocked", value: 2).formatted, "2")
        XCTAssertEqual(KitMetric.na("lockRate", "why").formatted, "n/a")
        XCTAssertEqual(KitMetric(id: "lockRate", value: .nan).note, "not a finite number")
        XCTAssertNil(KitMetric(id: "lockRate", value: .infinity).value)
        let md = report(ballNote: "no ball finder in this build").markdown()
        XCTAssertTrue(md.hasPrefix("### slab-kit-20261117-153000 (kit)"), md)
        XCTAssertTrue(md.contains("captured with build 0.1 (1) on iPhone16,1 (iOS 18.1, LiDAR). Scored with the app's own settings."), md)
        XCTAssertTrue(md.contains("| Lock rate | 95.0% | 10 |"), md)
        XCTAssertTrue(md.contains("| Ball detection rate | n/a | no ball finder in this build |"), md)
        XCTAssertTrue(md.contains("| p1 level | 0.40° ± 0.05° | twoReading | 1 | 0.20° / n/a |"), md)
        XCTAssertTrue(md.contains("| s04-level-still | p1 | 150 | 95.0% | 0.60 s | 0.20° / 0.40° |"), md)
        XCTAssertTrue(md.contains("- no ball finder in this build: aggregate ballDetectionRate"), md)
        // a pipe in a reason cannot break the table
        XCTAssertTrue(report(ballNote: "a|b").markdown().contains("| n/a | a/b |"))
        // a single report reads as a set of one
        let one = try KitJSON.encode(report())
        XCTAssertEqual(try KitScoreSet.read(one).reports, [report()])
    }
}
