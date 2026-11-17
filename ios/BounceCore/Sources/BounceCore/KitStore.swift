import Foundation

// The kit on disk (CaptureKit.md, "Clip format"):
//
//   <root>/<kitId>/kit.json                 KitManifest, rewritten atomically after every change
//   <root>/<kitId>/shots/<shotId>/          a committed shot: shot.json plus its files
//   <root>/<kitId>/shots/<shotId>.attempt/  a shot being recorded (moved into place on commit)
//
// A shot is recorded into its attempt folder and only replaces the committed one when it is committed, so quitting or
// crashing half-way through a retry keeps the earlier capture. Attempt folders left behind (the app died mid-shot) are
// removed when the kit is loaded, and that shot stays as it was.

/// Errors from the kit store. IO errors from Foundation are passed through as they are.
public enum KitStoreError: Error, Equatable, CustomStringConvertible {
    /// the folder holds no readable kit.json
    case notAKit(String)
    /// a kit.json of another format, a newer version or an unknown plan
    case unsupported(String)
    case unknownShot(String)
    /// the call does not fit the shot (e.g. a recording for the measurements form)
    case wrongKind(String)
    /// commit without an attempt folder (beginShot was not called, or the attempt was discarded)
    case notStarted(String)
    /// the shot has not been captured
    case notCaptured(String)
    case invalidMeasurements([String])
    case invalidHeight(Double)

    public var description: String {
        switch self {
        case let .notAKit(p): return "not a kit: \(p)"
        case let .unsupported(why): return "unsupported kit: \(why)"
        case let .unknownShot(id): return "unknown shot \(id)"
        case let .wrongKind(why): return why
        case let .notStarted(id): return "shot \(id) was not started"
        case let .notCaptured(id): return "shot \(id) has not been captured"
        case let .invalidMeasurements(p): return p.joined(separator: " ")
        case let .invalidHeight(h): return "height \(h) in is out of range"
        }
    }
}

/// Where the kit stands: the next shot to take and how far along it is.
public struct KitProgress: Equatable {
    /// the first pending shot in plan order (optional shots included); nil when every shot is captured or skipped
    public var nextShotId: String?
    public var nextIndex: Int?
    /// the step of the next shot (the last step once complete)
    public var step: Int
    public var stepCount: Int
    /// "Step 4 of 12", or "All done"
    public var label: String
    /// captured + skipped
    public var done: Int
    public var total: Int
    public var captured: Int
    public var skipped: Int
    public var isComplete: Bool { nextShotId == nil }
    public var fraction: Double { total > 0 ? Double(done) / Double(total) : 1 }
}

/// A kit found under a root folder.
public struct KitListing: Equatable {
    public var folder: URL
    public var kitId: String
    public var createdAt: String
    public var updatedAt: String
    public var finished: Bool
    public var captured: Int
    public var skipped: Int
    public var total: Int
}

/// One step on the end screen.
public struct KitStepSummary: Equatable {
    public var number: Int
    public var title: String
    public var captured: [String]
    public var skipped: [String]
    public var pending: [String]
    public var fair: [String]
    public var poor: [String]
    /// "5 Slab only, tilts: 6 captured, 3 skipped (1 fair: Tilt 1: walk around)."
    public var line: String
}

/// The end screen: what was captured and what was skipped.
public struct KitSummary: Equatable {
    public var steps: [KitStepSummary]
    public var captured: Int
    public var skipped: Int
    public var pending: Int
    public var total: Int
    public var bytes: Int64
    /// "Captured 25 of 28 shots, skipped 3. 61.2 MB."
    public var headline: String
    /// one line per slab position: "Level: 0.42° (two readings)."
    public var positionLines: [String]
    /// headline, step lines, position lines
    public var lines: [String]
}

/// A kit folder: create, load (and resume), record shots, skip them, finish. Not thread-safe: use from one queue.
/// Every write throws on failure; nothing traps on bad files.
public final class KitStore {
    public static let manifestFile = "kit.json"
    public static let shotsFolder = "shots"
    public static let shotManifestFile = "shot.json"
    static let attemptSuffix = ".attempt"
    static let oldSuffix = ".old"

    public let folder: URL
    public let plan: KitPlan
    public private(set) var manifest: KitManifest
    /// shots whose unfinished attempt was thrown away when the kit was loaded
    public private(set) var discardedOnLoad: [String] = []

    public var kitId: String { manifest.kitId }
    public var isFinished: Bool { manifest.isFinished }

    init(folder: URL, plan: KitPlan, manifest: KitManifest) {
        self.folder = folder; self.plan = plan; self.manifest = manifest
    }

    // MARK: create, load, list

    /// Start a new kit in a new folder under `root` (created if needed), named after `date` ("slab-kit-...", with
    /// "-2", "-3" appended if that name is taken). Measurements are usually the app's settings until step 1 commits.
    public static func create(root: URL, plan: KitPlan = .standard, device: KitDevice, measurements: KitMeasurements,
                              build: String, date: Date) throws -> KitStore {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let base = KitTime.kitId(for: date)
        var id = base, n = 1
        while fm.fileExists(atPath: root.appendingPathComponent(id).path) { n += 1; id = "\(base)-\(n)" }
        let folder = root.appendingPathComponent(id)
        try fm.createDirectory(at: folder.appendingPathComponent(shotsFolder), withIntermediateDirectories: true)
        let records = plan.shots.map { KitShotRecord(id: $0.id, step: $0.step, optional: $0.optional) }
        let m = KitManifest(kitId: id, planId: plan.id, timeScale: plan.timeScale == 1 ? nil : plan.timeScale, build: build,
                            createdAt: KitTime.iso(date), device: device, measurements: measurements, shots: records)
        let store = KitStore(folder: folder, plan: plan, manifest: m)
        do { try store.save() } catch { try? fm.removeItem(at: folder); throw error }
        return store
    }

    static func readManifest(_ folder: URL) throws -> KitManifest {
        let url = folder.appendingPathComponent(manifestFile)
        guard let data = try? Data(contentsOf: url) else { throw KitStoreError.notAKit(folder.lastPathComponent) }
        let m: KitManifest
        do { m = try KitJSON.decode(KitManifest.self, from: data) } catch { throw KitStoreError.notAKit(folder.lastPathComponent) }
        guard m.format == KitManifest.formatName else { throw KitStoreError.unsupported("format \(m.format)") }
        guard m.version <= KitManifest.currentVersion else { throw KitStoreError.unsupported("version \(m.version)") }
        return m
    }

    /// Open a kit. Cleans up after a crash: unfinished attempt folders are removed (the shot stays as it was), a shot
    /// marked captured whose files are gone becomes pending again, and records missing for the plan's shots are added.
    public static func load(folder: URL) throws -> KitStore {
        var m = try readManifest(folder)
        guard let plan = KitPlan.named(m.planId, timeScale: m.timeScale ?? 1) else { throw KitStoreError.unsupported("plan \(m.planId)") }
        let fm = FileManager.default
        let shots = folder.appendingPathComponent(shotsFolder)
        try fm.createDirectory(at: shots, withIntermediateDirectories: true)
        var changed = false, discarded: [String] = []

        // records in plan order, one per plan shot (unknown ones kept at the end)
        let byId = Dictionary(m.shots.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var records = plan.shots.map { s -> KitShotRecord in
            if var r = byId[s.id] { r.step = s.step; r.optional = s.optional; return r }
            changed = true
            return KitShotRecord(id: s.id, step: s.step, optional: s.optional)
        }
        records += m.shots.filter { r in !plan.shots.contains { $0.id == r.id } }
        if records != m.shots { changed = true }

        // folders: finish an interrupted commit, drop unfinished attempts and folders without shot.json
        let names = (try? fm.contentsOfDirectory(atPath: shots.path)) ?? []
        for name in names where name.hasSuffix(oldSuffix) {
            let id = String(name.dropLast(oldSuffix.count)), old = shots.appendingPathComponent(name), final = shots.appendingPathComponent(id)
            if fm.fileExists(atPath: final.appendingPathComponent(shotManifestFile).path) {
                try fm.removeItem(at: old)
            } else {
                if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
                try fm.moveItem(at: old, to: final)
            }
        }
        for name in names where name.hasSuffix(attemptSuffix) {
            try fm.removeItem(at: shots.appendingPathComponent(name))
            discarded.append(String(name.dropLast(attemptSuffix.count)))
        }
        for name in (try? fm.contentsOfDirectory(atPath: shots.path)) ?? [] {
            let u = shots.appendingPathComponent(name)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue,
               !fm.fileExists(atPath: u.appendingPathComponent(shotManifestFile).path) {
                try fm.removeItem(at: u)
                discarded.append(name)
            }
        }
        for i in records.indices where records[i].status == .captured && records[i].folder != nil {
            if !fm.fileExists(atPath: folder.appendingPathComponent(records[i].folder ?? "").appendingPathComponent(shotManifestFile).path) {
                records[i] = KitShotRecord(id: records[i].id, step: records[i].step, attempts: records[i].attempts, optional: records[i].optional)
                changed = true
            }
        }
        m.shots = records
        let store = KitStore(folder: folder, plan: plan, manifest: m)
        store.discardedOnLoad = Array(Set(discarded)).sorted()
        if changed || !discarded.isEmpty {
            store.refreshPositionIds()
            try store.save()
        }
        return store
    }

    /// Kits under `root`, newest first. Folders without a readable kit.json are left out.
    public static func list(root: URL) -> [KitListing] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var out: [KitListing] = []
        for name in names {
            let f = root.appendingPathComponent(name)
            guard let m = try? readManifest(f) else { continue }
            out.append(KitListing(folder: f, kitId: m.kitId, createdAt: m.createdAt, updatedAt: m.updatedAt, finished: m.isFinished,
                                  captured: m.shots.filter { $0.status == .captured }.count,
                                  skipped: m.shots.filter { $0.status == .skipped }.count, total: m.shots.count))
        }
        return out.sorted { ($0.createdAt, $0.kitId) > ($1.createdAt, $1.kitId) }
    }

    /// The newest kit that is not finished (the app offers Resume for it).
    public static func resumable(root: URL) -> KitListing? { list(root: root).first { !$0.finished } }

    /// Delete a kit folder.
    public static func delete(folder: URL) throws { try FileManager.default.removeItem(at: folder) }

    /// Delete this kit.
    public func delete() throws { try KitStore.delete(folder: folder) }

    // MARK: paths

    public var manifestURL: URL { folder.appendingPathComponent(KitStore.manifestFile) }
    /// shots/<id>: the committed shot
    public func shotFolder(_ id: String) -> URL { folder.appendingPathComponent(KitStore.shotsFolder).appendingPathComponent(id) }
    /// shots/<id>.attempt: the shot being recorded
    public func attemptFolder(_ id: String) -> URL {
        folder.appendingPathComponent(KitStore.shotsFolder).appendingPathComponent(id + KitStore.attemptSuffix)
    }

    public func record(_ id: String) -> KitShotRecord? { manifest.record(id) }

    func spec(_ id: String) throws -> KitShotSpec {
        guard let s = plan.shot(id), manifest.record(id) != nil else { throw KitStoreError.unknownShot(id) }
        return s
    }

    func setRecord(_ r: KitShotRecord) {
        if let i = manifest.shots.firstIndex(where: { $0.id == r.id }) { manifest.shots[i] = r }
    }

    func save() throws {
        try KitJSON.encode(manifest).write(to: manifestURL, options: .atomic)
    }

    func touch(_ date: Date) { manifest.updatedAt = KitTime.iso(date) }

    // MARK: progress

    public var progress: KitProgress {
        let captured = manifest.shots.filter { $0.status == .captured }.count
        let skipped = manifest.shots.filter { $0.status == .skipped }.count
        let nextIndex = plan.shots.firstIndex { manifest.record($0.id)?.status == .pending }
        let step = nextIndex.map { plan.shots[$0].step } ?? plan.stepCount
        return KitProgress(nextShotId: nextIndex.map { plan.shots[$0].id }, nextIndex: nextIndex, step: step, stepCount: plan.stepCount,
                           label: nextIndex == nil ? "All done" : plan.progressLabel(step: step),
                           done: captured + skipped, total: manifest.shots.count, captured: captured, skipped: skipped)
    }

    // MARK: slab positions

    /// The slab position a shot belongs to: that of the latest flat-phone shot at or before it in plan order whose
    /// position has started (captured, or skipped when not optional).
    public func positionId(forShot id: String) -> String? {
        guard let idx = plan.index(of: id) else { return nil }
        var current: String?
        for s in plan.shots[0...idx] {
            if let p = s.startsPosition, manifest.position(p.id) != nil { current = p.id }
        }
        return current
    }

    public func position(forShot id: String) -> KitSlabPosition? { positionId(forShot: id).flatMap { manifest.position($0) } }

    /// The camera bump from the latest two-reading true tilt in this kit (to correct a single reading).
    public var knownBump: KitBump? {
        manifest.positions.reversed().compactMap { $0.groundTruth?.solvedBump }.first { $0.magnitude <= KitQuality.maxBump }
    }

    /// The reference for the dim and bright shots' light checks.
    public var qualityReference: KitQualityReference { KitQualityReference(levelStillMedianLuma: manifest.lightReferenceLuma) }

    func upsertPosition(_ p: KitPositionSpec, shotId: String, groundTruth: KitTrueTilt?, date: Date) {
        let pos = KitSlabPosition(id: p.id, label: p.label, shotId: shotId, groundTruth: groundTruth, startedAt: KitTime.iso(date))
        if let i = manifest.positions.firstIndex(where: { $0.id == p.id }) {
            manifest.positions[i] = pos
        } else {
            manifest.positions.append(pos)
            let order = plan.shots.compactMap { $0.startsPosition?.id }
            manifest.positions.sort { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
        }
    }

    func refreshPositionIds() {
        for i in manifest.shots.indices where manifest.shots[i].status == .captured {
            manifest.shots[i].positionId = positionId(forShot: manifest.shots[i].id)
        }
    }

    // MARK: shots

    /// Commit step 1: the measurements (validated against the Settings ranges). Marks the plan's form shot captured.
    public func commitMeasurements(_ m: KitMeasurements, date: Date) throws {
        guard m.isValid else { throw KitStoreError.invalidMeasurements(m.problems) }
        manifest.measurements = m
        if let form = plan.shots.first(where: { $0.isForm }), var r = manifest.record(form.id) {
            r.status = .captured; r.attempts += 1; r.capturedAt = KitTime.iso(date)
            setRecord(r)
        }
        touch(date)
        try save()
    }

    /// A shot manifest filled in with what the store knows (ids, attempt, device, measurements, position and its true
    /// tilt, release cue). The app adds the video, quality and so on, then commits it.
    public func newShotManifest(_ id: String, startedAt: Date, duration: Double) throws -> KitShotManifest {
        let s = try spec(id)
        let pos = position(forShot: id)
        return KitShotManifest(kitId: kitId, shotId: id, step: s.step, attempt: (record(id)?.attempts ?? 0) + 1,
                               startedAt: KitTime.iso(startedAt), duration: duration, build: manifest.build, device: manifest.device,
                               measurements: manifest.measurements, positionId: pos?.id, trueTilt: pos?.groundTruth,
                               releaseCue: s.kind.releaseCue)
    }

    /// Start recording a shot: returns an empty attempt folder for its files (a previous unfinished attempt's files
    /// are removed; a committed capture stays until this attempt is committed).
    public func beginShot(_ id: String) throws -> URL {
        let s = try spec(id)
        guard !s.isForm else { throw KitStoreError.wrongKind("\(id) is a form: use commitMeasurements") }
        let fm = FileManager.default
        let a = attemptFolder(id)
        if fm.fileExists(atPath: a.path) { try fm.removeItem(at: a) }
        try fm.createDirectory(at: a, withIntermediateDirectories: true)
        return a
    }

    /// Throw away the attempt being recorded (the shot stays as it was).
    public func discardAttempt(_ id: String) throws {
        let a = attemptFolder(id)
        if FileManager.default.fileExists(atPath: a.path) { try FileManager.default.removeItem(at: a) }
    }

    /// Commit the attempt: writes shot.json (with the store's ids, attempt number, position and true tilt filled in),
    /// moves the attempt into place (replacing an earlier capture) and updates kit.json. A flat-phone shot starts (or
    /// restarts) its slab position with `manifest.flat` as the true tilt. Returns the manifest as written.
    @discardableResult
    public func commitShot(_ id: String, manifest input: KitShotManifest, date: Date) throws -> KitShotManifest {
        let s = try spec(id)
        let fm = FileManager.default
        let attempt = attemptFolder(id), final = shotFolder(id)
        guard fm.fileExists(atPath: attempt.path) else { throw KitStoreError.notStarted(id) }
        guard var r = record(id) else { throw KitStoreError.unknownShot(id) }
        let savedManifest = manifest

        var m = input
        m.kitId = kitId; m.shotId = id; m.step = s.step; m.attempt = r.attempts + 1
        if let p = s.startsPosition {
            upsertPosition(p, shotId: id, groundTruth: (m.flat?.isUsable ?? false) ? m.flat : nil, date: date)
        }
        let pos = position(forShot: id)
        m.positionId = pos?.id; m.trueTilt = pos?.groundTruth
        do {
            try KitJSON.encode(m).write(to: attempt.appendingPathComponent(KitStore.shotManifestFile), options: .atomic)
            // swap in: keep the old capture aside until the new one is in place
            let old = final.deletingLastPathComponent().appendingPathComponent(id + KitStore.oldSuffix)
            if fm.fileExists(atPath: old.path) { try fm.removeItem(at: old) }
            let hadOld = fm.fileExists(atPath: final.path)
            if hadOld { try fm.moveItem(at: final, to: old) }
            do { try fm.moveItem(at: attempt, to: final) } catch {
                if hadOld { try? fm.moveItem(at: old, to: final) }
                throw error
            }
            if hadOld { try? fm.removeItem(at: old) }
        } catch {
            manifest = savedManifest
            throw error
        }

        r.status = .captured; r.attempts += 1; r.folder = KitStore.shotsFolder + "/" + id; r.positionId = pos?.id
        r.verdict = m.quality?.verdict; r.enteredHeightInches = m.enteredHeightInches; r.duration = m.duration
        r.frames = m.video?.frameCount ?? m.motionSamples; r.bytes = KitFiles.size(of: final); r.capturedAt = KitTime.iso(date)
        setRecord(r)
        if id == plan.lightReferenceShotId { manifest.lightReferenceLuma = m.quality?.medianLuma }
        refreshPositionIds()
        touch(date)
        try save()
        return m
    }

    /// Skip a shot (removing a capture it had). Skipping a flat-phone shot still starts its slab position, without a true
    /// tilt, since the slab was moved. Skipping an optional flat-phone shot skips its whole optional group (the third
    /// tilt) and starts no position: the slab stays where it was.
    public func skipShot(_ id: String, date: Date) throws {
        let s = try spec(id)
        var ids = [id]
        if s.optional, s.startsPosition != nil, let i = plan.index(of: id) {
            for t in plan.shots[(i + 1)...] {
                guard t.optional, t.startsPosition == nil else { break }
                ids.append(t.id)
            }
        }
        let fm = FileManager.default
        for x in ids {
            try discardAttempt(x)
            if fm.fileExists(atPath: shotFolder(x).path) { try fm.removeItem(at: shotFolder(x)) }
            guard let r = record(x) else { continue }
            setRecord(KitShotRecord(id: r.id, step: r.step, status: .skipped, attempts: r.attempts, optional: r.optional))
            if x == plan.lightReferenceShotId { manifest.lightReferenceLuma = nil }
        }
        if let p = s.startsPosition {
            if s.optional { manifest.positions.removeAll { $0.id == p.id } }
            else { upsertPosition(p, shotId: id, groundTruth: nil, date: date) }
        }
        refreshPositionIds()
        touch(date)
        try save()
    }

    /// Record (or clear, with nil) the measured height of the ball above the slab for a captured shot that asks for it
    /// (0-120 in). Updates kit.json and the shot's shot.json.
    public func setHeight(_ id: String, inches: Double?, date: Date) throws {
        let s = try spec(id)
        guard s.asksHeight else { throw KitStoreError.wrongKind("\(id) does not ask for a height") }
        guard var r = record(id), r.status == .captured else { throw KitStoreError.notCaptured(id) }
        if let h = inches { guard h.isFinite, h > 0, h <= 120 else { throw KitStoreError.invalidHeight(h) } }
        let url = shotFolder(id).appendingPathComponent(KitStore.shotManifestFile)
        var m = try KitJSON.decode(KitShotManifest.self, from: Data(contentsOf: url))
        m.enteredHeightInches = inches
        try KitJSON.encode(m).write(to: url, options: .atomic)
        r.enteredHeightInches = inches
        setRecord(r)
        touch(date)
        try save()
    }

    /// The committed shot.json of a shot, if it was captured with files.
    public func shotManifest(_ id: String) throws -> KitShotManifest? {
        let url = shotFolder(id).appendingPathComponent(KitStore.shotManifestFile)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try KitJSON.decode(KitShotManifest.self, from: Data(contentsOf: url))
    }

    /// Mark the kit finished (it is no longer offered for Resume).
    public func finish(date: Date) throws {
        manifest.finishedAt = KitTime.iso(date)
        touch(date)
        try save()
    }

    /// Bytes the kit takes on disk.
    public func bytesOnDisk() -> Int64 { KitFiles.size(of: folder) }

    // MARK: summary

    /// What was captured and skipped, per step, for the end screen.
    public func summary() -> KitSummary {
        var steps: [KitStepSummary] = []
        for st in plan.steps {
            let shots = plan.shots(inStep: st.number)
            func titles(_ f: (KitShotRecord) -> Bool) -> [String] { shots.filter { record($0.id).map(f) ?? false }.map { $0.title } }
            let captured = titles { $0.status == .captured }, skipped = titles { $0.status == .skipped }
            let pending = titles { $0.status == .pending }
            let fair = titles { $0.status == .captured && $0.verdict == .fair }, poor = titles { $0.status == .captured && $0.verdict == .poor }
            var parts: [String] = []
            if shots.count == 1 && captured.count == 1 { parts.append("done") }
            else if !captured.isEmpty { parts.append(captured.count == shots.count ? "all \(captured.count) captured" : "\(captured.count) captured") }
            if !skipped.isEmpty { parts.append("\(skipped.count) skipped") }
            if !pending.isEmpty { parts.append("\(pending.count) not done") }
            var line = "\(st.number) \(st.title): " + parts.joined(separator: ", ")
            var notes: [String] = []
            if !fair.isEmpty { notes.append("\(fair.count) fair: " + fair.joined(separator: ", ")) }
            if !poor.isEmpty { notes.append("\(poor.count) poor: " + poor.joined(separator: ", ")) }
            if !notes.isEmpty { line += " (" + notes.joined(separator: "; ") + ")" }
            steps.append(KitStepSummary(number: st.number, title: st.title, captured: captured, skipped: skipped, pending: pending,
                                        fair: fair, poor: poor, line: line + "."))
        }
        let captured = manifest.shots.filter { $0.status == .captured }.count
        let skipped = manifest.shots.filter { $0.status == .skipped }.count
        let pending = manifest.shots.filter { $0.status == .pending }.count
        let bytes = bytesOnDisk()
        var headline = "Captured \(captured) of \(manifest.shots.count) shots"
        if skipped > 0 { headline += ", skipped \(skipped)" }
        if pending > 0 { headline += ", \(pending) not done" }
        headline += String(format: ". %.1f MB.", Double(bytes) / 1_000_000)
        let positionLines = manifest.positions.map { p -> String in
            let label = p.label.prefix(1).uppercased() + p.label.dropFirst()
            guard let g = p.groundTruth, let t = g.tiltDegrees else { return "\(label): no true tilt (skipped)." }
            let how: String
            switch g.method {
            case .twoReading: how = "two readings"
            case .bumpCorrected: how = "one reading, bump-corrected"
            case .uncorrected: how = "one reading, uncorrected"
            case .failed: how = "failed"
            }
            return String(format: "%@: %.2f° (%@).", label, t, how)
        }
        return KitSummary(steps: steps, captured: captured, skipped: skipped, pending: pending, total: manifest.shots.count, bytes: bytes,
                          headline: headline, positionLines: positionLines, lines: [headline] + steps.map { $0.line } + positionLines)
    }
}

/// File helpers for the kit.
public enum KitFiles {
    /// Size of a file, or the total of the regular files under a folder (bytes).
    public static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return fileSize(url.path) }
        var total: Int64 = 0
        for rel in regularFiles(in: url) { total += fileSize(url.appendingPathComponent(rel).path) }
        return total
    }

    static func fileSize(_ path: String) -> Int64 {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return 0 }
        if let n = a[.size] as? NSNumber { return n.int64Value }
        if let n = a[.size] as? Int64 { return n }
        if let n = a[.size] as? UInt64 { return Int64(n) }
        if let n = a[.size] as? Int { return Int64(n) }
        return 0
    }

    /// Relative paths of the regular files under a folder, sorted.
    public static func regularFiles(in folder: URL) -> [String] {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: folder.path) else { return [] }
        var out: [String] = []
        while let rel = en.nextObject() as? String {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: folder.appendingPathComponent(rel).path, isDirectory: &isDir), !isDir.boolValue { out.append(rel) }
        }
        return out.sorted()
    }
}
