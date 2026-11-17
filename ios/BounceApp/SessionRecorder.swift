import BounceCore
import Foundation

/// Records a session (frames, camera poses, lens, motion, depth) into Documents/Recordings/<name>.bouncerec, on its own
/// queue so the camera never waits for the disk; on finish, zips it to Documents/<name>.bouncerec.zip for sharing and
/// removes the folder. Recordings show the owner's surroundings: they stay on the phone unless the owner shares them.
/// Any write error (a full disk, say) stops the recording and is reported; it never crashes the app.
final class SessionRecorder {
    enum RecorderError: LocalizedError {
        case notRecording, noSpace(needed: Int64, available: Int64), writeFailed(String)
        var errorDescription: String? {
            switch self {
            case .notRecording: return "no recording was running"
            case .noSpace(let n, let a): return "not enough free space (needs \(n / 1_000_000) MB, \(a / 1_000_000) MB free)"
            case .writeFailed(let m): return m
            }
        }
    }

    let name: String
    let folder: URL
    private let writer: RecordingWriter
    private let io = DispatchQueue(label: "slabbounce.recorder", qos: .utility)
    private let lock = NSLock()
    private var written = 0
    private var pending = 0
    private var bytes: Int64 = 0
    private var firstError: String? = nil
    /// a recording stops by itself at this size (the zip format's limits are far above; this keeps the phone's disk safe)
    static let maxBytes: Int64 = 1_500_000_000

    var frameCount: Int { lock.lock(); defer { lock.unlock() }; return written }
    /// why the recording stopped writing, if it did
    var failure: String? { lock.lock(); defer { lock.unlock() }; return firstError }

    init(settings: RecordingSettings, frameWidth: Int, frameHeight: Int) throws {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        name = "slab-\(f.string(from: Date()))"
        let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        folder = docs.appendingPathComponent("Recordings", isDirectory: true).appendingPathComponent(name + ".bouncerec", isDirectory: true)
        let session = RecordingSession(build: appBuild, device: Device.model, frameWidth: frameWidth, frameHeight: frameHeight, settings: settings,
                                       notes: "Slab Bounce recording", createdAt: ISO8601DateFormatter().string(from: Date()))
        writer = try RecordingWriter(folder: folder, session: session)
    }

    /// Queue a frame for writing. Frames are dropped (not queued) if the disk falls more than 20 behind, and nothing more is
    /// written after an error or past the size limit.
    func append(_ frame: RecordedFrame, image: YCCImage, depth: DepthMap?) {
        lock.lock()
        if pending > 20 || firstError != nil { lock.unlock(); return }
        pending += 1
        lock.unlock()
        let size = Int64(image.y.count + image.cb.count + image.cr.count + (depth.map { $0.depth.count * 5 } ?? 0))
        io.async {
            var err: String? = nil
            do { try self.writer.append(frame, image: image, depth: depth) } catch { err = error.localizedDescription }
            self.lock.lock()
            self.pending -= 1
            if let e = err { if self.firstError == nil { self.firstError = e } } else { self.written += 1; self.bytes += size }
            if self.bytes > SessionRecorder.maxBytes, self.firstError == nil { self.firstError = "size limit reached" }
            self.lock.unlock()
        }
    }

    /// Finish writing, zip the folder (after checking there is room), delete the folder, and report the zip's URL or why
    /// it failed. A partial zip is removed.
    func finish(_ done: @escaping (Result<URL, Error>) -> Void) {
        io.async {
            self.writer.close()
            let zip = self.folder.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(self.name + ".bouncerec.zip")
            let fm = FileManager.default
            let needed = SessionRecorder.folderSize(self.folder) + 1_000_000
            if let free = try? fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
               free < needed {
                done(.failure(RecorderError.noSpace(needed: needed, available: free)))
                return
            }
            do {
                try ZipWriter.zip(folder: self.folder, to: zip)
                try? fm.removeItem(at: self.folder)
                done(.success(zip))
            } catch {
                try? fm.removeItem(at: zip)
                done(.failure(RecorderError.writeFailed(error.localizedDescription)))
            }
        }
    }

    static func folderSize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        if let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in en { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        return total
    }
}
