import Foundation

/// Whether a kit unzipped from its bundle parts holds everything its kit.json says was captured (CaptureKit.md, "When
/// the kit is uploaded"). The part names say how many parts there were; this checks the content itself, so a part
/// that went missing, a file cut short or a kit put together from two different builds of the bundle shows up even
/// when the names look right. It reads the kit without changing it, and its lines carry shot ids, file kinds and
/// numbers only, never paths or anything from the pictures.
public struct KitArrivalReport: Equatable {
    public var kitId: String
    public var planId: String
    public var finished: Bool
    public var captured: [String] = []
    public var skipped: [String] = []
    public var pending: [String] = []
    /// held shots captured without an entered height
    public var noHeight: [String] = []
    /// what is missing or does not match ("s04-level-arc: video.mp4 is missing"); empty when everything arrived
    public var problems: [String] = []
    /// video, depth and motion files and their bytes, as counted
    public var videoFiles = 0
    public var depthFiles = 0
    public var bytes: Int64 = 0

    /// every captured shot has all its files, as kit.json and its shot.json describe them
    public var complete: Bool { problems.isEmpty }

    /// A few plain lines for the report.
    public var lines: [String] {
        var l: [String] = []
        let total = captured.count + skipped.count + pending.count
        l.append("shots: \(captured.count) of \(total) captured, \(skipped.count) skipped" + (pending.isEmpty ? "" : ", \(pending.count) not taken")
                 + (finished ? "" : " (the kit was not finished)"))
        if !skipped.isEmpty { l.append("skipped: " + skipped.joined(separator: ", ")) }
        if !pending.isEmpty { l.append("not taken: " + pending.joined(separator: ", ")) }
        if !noHeight.isEmpty { l.append("no height entered: " + noHeight.joined(separator: ", ")) }
        l.append(String(format: "files: %d videos, %d depth frames, %.1f MB", videoFiles, depthFiles, Double(bytes) / 1e6))
        if problems.isEmpty {
            l.append("contents: every captured shot has all its files (sizes, frame and sample counts match kit.json and shot.json)")
        } else {
            l.append("contents: \(problems.count) problem\(problems.count == 1 ? "" : "s"):")
            l += problems.map { "  " + $0 }
        }
        return l
    }
}

public enum KitArrival {
    /// Checks a kit folder: kit.json reads and names a known plan; for every shot it marks captured, its folder and
    /// shot.json (same kit, shot and attempt), and for a video shot video.mp4 of the size shot.json gives, frames.jsonl
    /// with a line per video frame, the depth files its lines name (as many as shot.json counts), and motion.jsonl with
    /// the samples it counts; a flat-phone shot's motion.jsonl and result. Returns nil when the folder holds no readable
    /// kit.json.
    public static func check(kitFolder: URL) -> KitArrivalReport? {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: kitFolder.appendingPathComponent(KitStore.manifestFile)),
              let m = try? KitJSON.decode(KitManifest.self, from: data), m.format == KitManifest.formatName else { return nil }
        var r = KitArrivalReport(kitId: m.kitId, planId: m.planId, finished: m.isFinished)
        if kitFolder.lastPathComponent != m.kitId { r.problems.append("the kit's folder is not named after its id") }
        guard let plan = KitPlan.named(m.planId, timeScale: m.timeScale ?? 1) else {
            r.problems.append("kit.json names a plan this build does not know (\(m.planId))")
            return r
        }
        for spec in plan.shots {
            guard let rec = m.record(spec.id) else { r.problems.append("\(spec.id): no record in kit.json"); continue }
            switch rec.status {
            case .skipped: r.skipped.append(spec.id); continue
            case .pending: r.pending.append(spec.id); continue
            case .captured: r.captured.append(spec.id)
            }
            if spec.isForm { continue }
            if spec.asksHeight && rec.enteredHeightInches == nil { r.noHeight.append(spec.id) }
            let folder = kitFolder.appendingPathComponent(rec.folder ?? (KitStore.shotsFolder + "/" + spec.id))
            func problem(_ s: String) { r.problems.append("\(spec.id): \(s)") }
            guard let sd = try? Data(contentsOf: folder.appendingPathComponent(KitClipFiles.shotManifest)) else {
                problem("\(KitClipFiles.shotManifest) is missing (the part holding this shot did not arrive)")
                continue
            }
            guard let sm = try? KitJSON.decode(KitShotManifest.self, from: sd) else { problem("\(KitClipFiles.shotManifest) does not read"); continue }
            if sm.kitId != m.kitId || sm.shotId != spec.id { problem("\(KitClipFiles.shotManifest) belongs to another kit or shot") }
            if sm.attempt != rec.attempts {
                problem("\(KitClipFiles.shotManifest) is attempt \(sm.attempt) but kit.json says \(rec.attempts) (parts from two builds of the bundle?)")
            }
            r.bytes += Int64(sd.count)
            // motion.jsonl: every shot the phone records has one (the demo's video shots too, empty)
            let motionURL = folder.appendingPathComponent(KitClipFiles.motion)
            if fm.fileExists(atPath: motionURL.path) {
                r.bytes += KitFiles.fileSize(motionURL.path)
                if let want = sm.motionSamples {
                    do {
                        let got = try KitJSONL.read(KitMotionSample.self, from: motionURL).count
                        // the last line may have been cut when the app was killed: one short is still whole
                        if got != want && got != want - 1 { problem("\(KitClipFiles.motion) has \(got) samples, shot.json says \(want)") }
                    } catch { problem("\(KitClipFiles.motion) does not read") }
                }
            } else if (sm.motionSamples ?? 0) > 0 || spec.isFlat {
                problem("\(KitClipFiles.motion) is missing")
            }
            if spec.isFlat {
                if sm.flat == nil { problem("\(KitClipFiles.shotManifest) has no flat-phone result") }
                continue
            }
            guard spec.isVideo else { continue }
            guard let video = sm.video else { problem("\(KitClipFiles.shotManifest) describes no video"); continue }
            // a video written to disk (the synthetic kit's in-memory frames have none)
            if video.fileBytes > 0 || video.codec != "memory" {
                let vu = folder.appendingPathComponent(KitClipFiles.video)
                if !fm.fileExists(atPath: vu.path) {
                    problem("\(KitClipFiles.video) is missing")
                } else {
                    let size = KitFiles.fileSize(vu.path)
                    r.videoFiles += 1; r.bytes += size
                    if video.fileBytes > 0 && size != video.fileBytes { problem("\(KitClipFiles.video) has \(size) bytes, shot.json says \(video.fileBytes)") }
                }
            }
            let fu = folder.appendingPathComponent(KitClipFiles.frames)
            let frames: [KitFrame]
            do { frames = try KitJSONL.read(KitFrame.self, from: fu) } catch {
                problem(fm.fileExists(atPath: fu.path) ? "\(KitClipFiles.frames) does not read" : "\(KitClipFiles.frames) is missing")
                continue
            }
            r.bytes += KitFiles.fileSize(fu.path)
            if frames.count != video.frameCount { problem("\(KitClipFiles.frames) has \(frames.count) lines, the video \(video.frameCount) frames") }
            let named = frames.compactMap { $0.depthFile }
            var missingDepth = 0
            for name in named {
                let du = KitClipFiles.depthURL(shotFolder: folder, file: name)
                if fm.fileExists(atPath: du.path) { r.depthFiles += 1; r.bytes += KitFiles.fileSize(du.path) } else { missingDepth += 1 }
            }
            if missingDepth > 0 { problem("\(missingDepth) of its \(named.count) depth files are missing") }
            if let want = sm.depthFrames, want != named.count { problem("frames.jsonl names \(named.count) depth files, shot.json says \(want)") }
        }
        return r
    }
}
