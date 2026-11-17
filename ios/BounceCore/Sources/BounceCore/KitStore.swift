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
//
// Every change that moves or removes a shot's files saves kit.json before anything is deleted: a commit moves the new
// files into place, saves kit.json, then deletes the old copy (shots/<id>.old); a skip (or a slab restart) renames the
// files to shots/<id>.trash, saves kit.json, then deletes them. A failed save puts the files back. If the app dies in
// between, `load` finishes the job. A commit whose files are in place counts: a shot folder whose shot.json disagrees
// with kit.json (another attempt, or a record not marked captured) is the newer truth, and its record is rebuilt from
// it. A skip that kit.json does not know of did not happen: its trash goes back into place.

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
    /// this build can open it (`KitStore.load`): its plan is known. A kit from a retired plan is listed but not resumed.
    public var loadable: Bool
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
    /// one line per slab position (and generation): "Level: 0.42° (two readings)."
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
    static let trashSuffix = ".trash"

    public let folder: URL
    public let plan: KitPlan
    public private(set) var manifest: KitManifest
    /// shots whose unfinished attempt was thrown away when the kit was loaded
    public private(set) var discardedOnLoad: [String] = []
    /// shots whose kit.json record was rebuilt from their shot.json when the kit was loaded (the app died after moving
    /// a capture into place, or after writing an entered height, but before kit.json was saved)
    public private(set) var repairedOnLoad: [String] = []

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

    /// Open a kit. Cleans up after a crash: unfinished attempt folders are removed (the shot stays as it was), an
    /// interrupted commit or skip is finished, a shot folder whose shot.json disagrees with kit.json has its record
    /// rebuilt from that shot.json (`repairedOnLoad`), a shot marked captured whose files are gone becomes pending again,
    /// and records missing for the plan's shots are added.
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

        // folders: finish an interrupted commit or skip, drop unfinished attempts and folders without shot.json
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
        for name in names where name.hasSuffix(trashSuffix) {
            let id = String(name.dropLast(trashSuffix.count)), trash = shots.appendingPathComponent(name), final = shots.appendingPathComponent(id)
            if byId[id]?.status == .captured, !fm.fileExists(atPath: final.path),
               fm.fileExists(atPath: trash.appendingPathComponent(shotManifestFile).path) {
                try fm.moveItem(at: trash, to: final) // the skip (or restart) was never saved: it did not happen
            } else {
                try fm.removeItem(at: trash)
            }
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
        m.shots = records
        let store = KitStore(folder: folder, plan: plan, manifest: m)

        // a shot folder that disagrees with its record is the newer truth
        var repaired: [String] = []
        for s in plan.shots where !s.isForm {
            let url = store.shotFolder(s.id).appendingPathComponent(shotManifestFile)
            guard let r = store.record(s.id), let data = try? Data(contentsOf: url),
                  let sm = try? KitJSON.decode(KitShotManifest.self, from: data), sm.shotId == s.id else { continue }
            if r.status != .captured || r.attempts != sm.attempt || r.enteredHeightInches != sm.enteredHeightInches || r.folder == nil {
                store.recordCommit(s, sm, capturedAt: sm.startedAt)
                repaired.append(s.id)
            }
        }
        // a shot marked captured whose files are gone is pending again
        for r in store.manifest.shots where r.status == .captured && r.folder != nil {
            if !fm.fileExists(atPath: folder.appendingPathComponent(r.folder ?? "").appendingPathComponent(shotManifestFile).path) {
                store.setRecord(KitShotRecord(id: r.id, step: r.step, attempts: r.attempts, optional: r.optional))
                if r.id == plan.lightReferenceShotId { store.manifest.lightReferenceLuma = nil; store.manifest.lightReferenceAmbient = nil }
                changed = true
            }
        }
        store.discardedOnLoad = Array(Set(discarded)).sorted()
        store.repairedOnLoad = repaired
        if changed || !discarded.isEmpty || !repaired.isEmpty {
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
                                  skipped: m.shots.filter { $0.status == .skipped }.count, total: m.shots.count,
                                  loadable: KitPlan.named(m.planId, timeScale: m.timeScale ?? 1) != nil))
        }
        return out.sorted { ($0.createdAt, $0.kitId) > ($1.createdAt, $1.kitId) }
    }

    /// The newest kit that is not finished and that this build can open (the app offers Resume for it).
    public static func resumable(root: URL) -> KitListing? { list(root: root).first { !$0.finished && $0.loadable } }

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
    func oldFolder(_ id: String) -> URL { folder.appendingPathComponent(KitStore.shotsFolder).appendingPathComponent(id + KitStore.oldSuffix) }
    func trashFolder(_ id: String) -> URL { folder.appendingPathComponent(KitStore.shotsFolder).appendingPathComponent(id + KitStore.trashSuffix) }

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

    /// The plan position ("p2") a shot belongs to: that of the latest flat-phone shot at or before it in plan order whose
    /// position has started (captured, or skipped when not optional).
    func planPositionId(forShot id: String) -> String? {
        guard let idx = plan.index(of: id) else { return nil }
        var current: String?
        for s in plan.shots[0...idx] {
            if let p = s.startsPosition, manifest.currentPosition(plan: p.id) != nil { current = p.id }
        }
        return current
    }

    /// The slab position (with its generation) a shot taken now belongs to.
    func currentPositionId(forShot id: String) -> String? {
        planPositionId(forShot: id).flatMap { manifest.currentPosition(plan: $0)?.id }
    }

    /// The slab position a shot belongs to: for a captured shot, the one (and the generation) it was captured in; for
    /// any other, the one it would be taken in now.
    public func positionId(forShot id: String) -> String? {
        if let r = record(id), r.status == .captured { return r.positionId }
        return currentPositionId(forShot: id)
    }

    public func position(forShot id: String) -> KitSlabPosition? { positionId(forShot: id).flatMap { manifest.position($0) } }

    /// The slab position the next shot continues: one already started, whose flat-phone shot is behind. nil when the
    /// next shot starts a position itself, belongs to none, or the kit is complete. On Resume, if this is set, the app
    /// asks "Has the slab moved since <label>?" and on Yes calls `restartPosition`.
    public var positionInProgress: KitSlabPosition? {
        guard let next = progress.nextShotId, let s = plan.shot(next), s.startsPosition == nil else { return nil }
        return currentPositionId(forShot: next).flatMap { manifest.position($0) }
    }

    /// The slab has moved (the owner said so on Resume): start a new generation of the slab position shot `id` belongs to,
    /// without a true tilt, and set that position's flat-phone shot back to pending (its earlier capture is removed; its
    /// result stays in the earlier generation's entry), so it is taken next. Shots already captured there keep the
    /// earlier generation and its true tilt. A generation with nothing in it yet (no true tilt, no shot captured) is
    /// reused rather than followed by another. Returns the position the next shots will belong to; nil when the shot
    /// belongs to no position yet (nothing to restart).
    @discardableResult
    public func restartPosition(forShot id: String, date: Date) throws -> KitSlabPosition? {
        _ = try spec(id)
        guard let planId = planPositionId(forShot: id),
              let flat = plan.shots.first(where: { $0.startsPosition?.id == planId }), let ps = flat.startsPosition,
              let cur = manifest.currentPosition(plan: planId) else { return nil }
        let saved = manifest
        let used = cur.groundTruth != nil || manifest.shots.contains { $0.status == .captured && $0.positionId == cur.id && $0.id != flat.id }
        let next: KitSlabPosition
        if used {
            let g = cur.generationNumber + 1
            next = KitSlabPosition(id: KitSlabPosition.id(plan: planId, generation: g), label: ps.label, shotId: flat.id,
                                   startedAt: KitTime.iso(date), generation: g)
            manifest.positions.append(next)
            sortPositions()
        } else {
            var x = cur
            x.groundTruth = nil; x.startedAt = KitTime.iso(date)
            if let i = manifest.positions.firstIndex(where: { $0.id == cur.id }) { manifest.positions[i] = x }
            next = x
        }
        // the flat-phone shot is taken again
        let fm = FileManager.default
        var trash: [(trash: URL, back: URL)] = []
        do {
            try discardAttempt(flat.id)
            if fm.fileExists(atPath: shotFolder(flat.id).path) {
                try moveToTrash(flat.id)
                trash.append((trash: trashFolder(flat.id), back: shotFolder(flat.id)))
            }
        } catch {
            manifest = saved
            throw error
        }
        if let r = record(flat.id) { setRecord(KitShotRecord(id: r.id, step: r.step, attempts: r.attempts, optional: r.optional)) }
        refreshPositionIds()
        touch(date)
        try saveOrRestore(saved, trash: trash)
        return manifest.position(next.id)
    }

    /// The camera bump from the latest two-reading true tilt in this kit (to correct a single reading). Only a result
    /// whose readings were steady and flat counts, and only a bump of at most `KitQuality.maxBump`.
    public var knownBump: KitBump? {
        manifest.positions.reversed().compactMap { p -> KitBump? in
            guard let g = p.groundTruth, [g.readingA, g.readingB].allSatisfy({ $0.map { $0.isSteady && $0.isFlat } ?? true }) else { return nil }
            return g.solvedBump
        }.first { $0.magnitude <= KitQuality.maxBump }
    }

    /// The reference for the dim and bright shots' light checks.
    public var qualityReference: KitQualityReference {
        KitQualityReference(levelStillMedianLuma: manifest.lightReferenceLuma, levelStillMedianAmbient: manifest.lightReferenceAmbient)
    }

    /// Set the true tilt of a plan position's current generation (starting the position if it has not started).
    func upsertPosition(_ p: KitPositionSpec, shotId: String, groundTruth: KitTrueTilt?, date: Date) {
        if let i = manifest.positions.lastIndex(where: { $0.planPositionId == p.id }) {
            var x = manifest.positions[i]
            x.label = p.label; x.shotId = shotId; x.groundTruth = groundTruth; x.startedAt = KitTime.iso(date)
            manifest.positions[i] = x
        } else {
            manifest.positions.append(KitSlabPosition(id: p.id, label: p.label, shotId: shotId, groundTruth: groundTruth, startedAt: KitTime.iso(date)))
            sortPositions()
        }
    }

    /// plan order, then generation
    func sortPositions() {
        let order = plan.shots.compactMap { $0.startsPosition?.id }
        manifest.positions.sort {
            let a = order.firstIndex(of: $0.planPositionId) ?? .max, b = order.firstIndex(of: $1.planPositionId) ?? .max
            return a != b ? a < b : $0.generationNumber < $1.generationNumber
        }
    }

    /// Captured shots keep the generation they were captured in, as long as it is still a generation of the plan
    /// position they belong to; otherwise (their position started later, or was dropped) they get its current one.
    func refreshPositionIds() {
        for i in manifest.shots.indices {
            guard manifest.shots[i].status == .captured else { manifest.shots[i].positionId = nil; continue }
            let planId = planPositionId(forShot: manifest.shots[i].id)
            if let have = manifest.shots[i].positionId, let p = manifest.position(have), p.planPositionId == planId { continue }
            manifest.shots[i].positionId = planId.flatMap { manifest.currentPosition(plan: $0)?.id }
        }
    }

    // MARK: shots

    /// Commit step 1: the measurements (validated against the Settings ranges). Marks the plan's form shot captured.
    public func commitMeasurements(_ m: KitMeasurements, date: Date) throws {
        guard m.isValid else { throw KitStoreError.invalidMeasurements(m.problems) }
        let saved = manifest
        manifest.measurements = m
        manifest.measurementsEnteredAt = KitTime.iso(date)
        if let form = plan.shots.first(where: { $0.isForm }), var r = manifest.record(form.id) {
            r.status = .captured; r.attempts += 1; r.capturedAt = KitTime.iso(date)
            setRecord(r)
        }
        touch(date)
        try saveOrRestore(saved)
    }

    /// A shot manifest filled in with what the store knows (ids, attempt, device, measurements and whether they were
    /// entered, position and its true tilt, release cue). The app adds `startTime`, `releaseTime`, `motionSessionId`,
    /// `arSessionId`, the video, quality and so on, then commits it.
    public func newShotManifest(_ id: String, startedAt: Date, duration: Double) throws -> KitShotManifest {
        let s = try spec(id)
        let pos = currentPositionId(forShot: id).flatMap { manifest.position($0) }
        return KitShotManifest(kitId: kitId, shotId: id, step: s.step, attempt: (record(id)?.attempts ?? 0) + 1,
                               startedAt: KitTime.iso(startedAt), duration: duration, build: manifest.build, device: manifest.device,
                               measurements: manifest.measurements, measurementsEntered: manifest.measurementsEntered,
                               positionId: pos?.id, trueTilt: pos?.groundTruth, releaseCue: s.kind.releaseCue)
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
    /// moves the attempt into place (replacing an earlier capture), saves kit.json and only then deletes the earlier
    /// capture. If kit.json cannot be saved, everything is put back as it was and the error is thrown. A flat-phone shot
    /// sets its slab position's true tilt (of the current generation; starting the position if needed) to
    /// `manifest.flat` when that is usable. Returns the manifest as written.
    @discardableResult
    public func commitShot(_ id: String, manifest input: KitShotManifest, date: Date) throws -> KitShotManifest {
        let s = try spec(id)
        let fm = FileManager.default
        let attempt = attemptFolder(id), final = shotFolder(id), old = oldFolder(id)
        guard fm.fileExists(atPath: attempt.path) else { throw KitStoreError.notStarted(id) }
        guard let r = record(id) else { throw KitStoreError.unknownShot(id) }
        let saved = manifest

        var m = input
        m.kitId = kitId; m.shotId = id; m.step = s.step; m.attempt = r.attempts + 1
        if let p = s.startsPosition {
            upsertPosition(p, shotId: id, groundTruth: (m.flat?.isUsable ?? false) ? m.flat : nil, date: date)
        }
        let pos = currentPositionId(forShot: id).flatMap { manifest.position($0) }
        m.positionId = pos?.id; m.trueTilt = pos?.groundTruth
        var hadOld = false
        do {
            try KitJSON.encode(m).write(to: attempt.appendingPathComponent(KitStore.shotManifestFile), options: .atomic)
            // swap in: keep the old capture aside until kit.json says the new one is in
            if fm.fileExists(atPath: old.path) { try fm.removeItem(at: old) }
            hadOld = fm.fileExists(atPath: final.path)
            if hadOld { try fm.moveItem(at: final, to: old) }
            do { try fm.moveItem(at: attempt, to: final) } catch {
                if hadOld { try? fm.moveItem(at: old, to: final) }
                throw error
            }
        } catch {
            manifest = saved
            throw error
        }

        recordCommit(s, m, capturedAt: KitTime.iso(date))
        touch(date)
        do { try save() } catch {
            manifest = saved
            try? fm.moveItem(at: final, to: attempt)
            if hadOld { try? fm.moveItem(at: old, to: final) }
            throw error
        }
        if hadOld { try? fm.removeItem(at: old) }
        return m
    }

    /// Update kit.json (in memory) for a capture now in shots/<id>/ with manifest `m`: the shot's record, its slab
    /// position (a flat-phone shot sets the true tilt) and the light reference. Used by commits and by `load` to repair.
    func recordCommit(_ s: KitShotSpec, _ m: KitShotManifest, capturedAt: String) {
        guard var r = record(s.id) else { return }
        if let p = s.startsPosition {
            upsertPosition(p, shotId: s.id, groundTruth: (m.flat?.isUsable ?? false) ? m.flat : nil, date: KitTime.date(capturedAt) ?? Date())
        }
        r.status = .captured; r.attempts = max(r.attempts, m.attempt); r.folder = KitStore.shotsFolder + "/" + s.id
        r.positionId = m.positionId
        r.verdict = m.quality?.verdict; r.enteredHeightInches = m.enteredHeightInches; r.duration = m.duration
        r.frames = m.video?.frameCount ?? m.motionSamples; r.bytes = KitFiles.size(of: shotFolder(s.id)); r.capturedAt = capturedAt
        setRecord(r)
        if s.id == plan.lightReferenceShotId {
            manifest.lightReferenceLuma = m.quality?.medianLuma
            manifest.lightReferenceAmbient = m.quality?.medianAmbient
        }
        refreshPositionIds()
    }

    /// Rename a shot's files to shots/<id>.trash (deleted once kit.json is saved; `load` deletes any left behind).
    func moveToTrash(_ id: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: trashFolder(id).path) { try fm.removeItem(at: trashFolder(id)) }
        try fm.moveItem(at: shotFolder(id), to: trashFolder(id))
    }

    /// Save kit.json; then delete the trash. If the save fails, restore `saved` in memory and the trashed folders.
    func saveOrRestore(_ saved: KitManifest, trash: [(trash: URL, back: URL)] = []) throws {
        let fm = FileManager.default
        do { try save() } catch {
            manifest = saved
            for t in trash { try? fm.moveItem(at: t.trash, to: t.back) }
            throw error
        }
        for t in trash { try? fm.removeItem(at: t.trash) }
    }

    /// Skip a shot (removing a capture it had). Skipping a flat-phone shot still starts its slab position, without a true
    /// tilt, since the slab was moved. Skipping an optional flat-phone shot skips its whole optional group (the third
    /// tilt) and starts no position: the slab stays where it was. Skipping the measurements form marks the measurements
    /// as not entered.
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
        let saved = manifest
        var trash: [(trash: URL, back: URL)] = []
        do {
            for x in ids {
                try discardAttempt(x)
                if fm.fileExists(atPath: shotFolder(x).path) {
                    try moveToTrash(x)
                    trash.append((trash: trashFolder(x), back: shotFolder(x)))
                }
            }
        } catch {
            for t in trash { try? fm.moveItem(at: t.trash, to: t.back) }
            throw error
        }
        for x in ids {
            guard let r = record(x) else { continue }
            setRecord(KitShotRecord(id: r.id, step: r.step, status: .skipped, attempts: r.attempts, optional: r.optional))
            if x == plan.lightReferenceShotId { manifest.lightReferenceLuma = nil; manifest.lightReferenceAmbient = nil }
            if plan.shot(x)?.isForm == true { manifest.measurementsEnteredAt = nil }
        }
        if let p = s.startsPosition {
            if s.optional { manifest.positions.removeAll { $0.planPositionId == p.id } }
            else { upsertPosition(p, shotId: id, groundTruth: nil, date: date) }
        }
        refreshPositionIds()
        touch(date)
        try saveOrRestore(saved, trash: trash)
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
        let saved = manifest
        try KitJSON.encode(m).write(to: url, options: .atomic)
        r.enteredHeightInches = inches
        setRecord(r)
        touch(date)
        try saveOrRestore(saved) // if this fails, shot.json holds the height and `load` copies it into kit.json
    }

    /// The committed shot.json of a shot, if it was captured with files.
    public func shotManifest(_ id: String) throws -> KitShotManifest? {
        let url = shotFolder(id).appendingPathComponent(KitStore.shotManifestFile)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try KitJSON.decode(KitShotManifest.self, from: Data(contentsOf: url))
    }

    /// Mark the kit finished (it is no longer offered for Resume).
    public func finish(date: Date) throws {
        let saved = manifest
        manifest.finishedAt = KitTime.iso(date)
        touch(date)
        try saveOrRestore(saved)
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
            var label = p.label.prefix(1).uppercased() + p.label.dropFirst()
            let g = p.generationNumber
            if g == 2 { label += " (set up again)" } else if g > 2 { label += " (set up again, \(g - 1) times)" }
            guard let gt = p.groundTruth, let t = gt.tiltDegrees else {
                // the flat-phone shot's record speaks for the current generation only
                guard manifest.currentPosition(plan: p.planPositionId)?.id == p.id, let r = record(p.shotId) else { return "\(label): no true tilt." }
                switch r.status {
                case .captured: return "\(label): no true tilt (the reading failed)."
                case .skipped: return "\(label): no true tilt (skipped)."
                case .pending: return "\(label): no true tilt (not taken yet)."
                }
            }
            let how: String
            switch gt.method {
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
