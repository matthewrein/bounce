import BounceCore
import Foundation

/// Records a session (Settings > Developer > Record session) into Documents/Recordings/<name>.bouncerec, on its own queue
/// so the camera never waits for the disk; on finish, zips it to Documents/<name>.bouncerec.zip for sharing and removes
/// the folder. Recordings show the owner's surroundings: they stay on the phone unless the owner shares them.
///
/// Version 2 of the format: every frame the tracker processed gets a line (`RecordingCadence` decides which pixels go
/// with it). Lines are never dropped: if the disk falls behind, a frame's image and ball picture are left out (a replay
/// then uses the phone's results for it), never its line or depth. Any write error (a full disk, say), the size limit or
/// the file limit stops the recording and is reported; nothing here crashes the app.
final class SessionRecorder {
    enum RecorderError: LocalizedError {
        case notRecording, writeFailed(String)
        var errorDescription: String? {
            switch self {
            case .notRecording: return "no recording was running"
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
    private var files = 0
    private var dropped = 0
    private var firstError: String? = nil

    /// a recording stops by itself at this size (the zip format's limits are far above; this keeps the phone's disk safe)
    static let maxBytes: Int64 = 1_500_000_000
    /// and at this many files (a zip holds at most 65,535)
    static let maxFiles = 60_000
    /// frames waiting for the disk before their pixels are left out
    static let behindFrames = 20
    /// frames waiting for the disk before the recording stops (about 20 s at 60 frames a second): keeps memory bounded
    static let maxPendingFrames = 1_200

    /// lines written so far
    var frameCount: Int { lock.lock(); defer { lock.unlock() }; return written }
    /// frames whose image or ball picture was left out because the disk was behind
    var droppedPixels: Int { lock.lock(); defer { lock.unlock() }; return dropped }
    /// why the recording stopped writing, if it did
    var failure: String? { lock.lock(); defer { lock.unlock() }; return firstError }

    init(session: RecordingSession) throws {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        name = "slab-\(f.string(from: Date()))"
        let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        folder = docs.appendingPathComponent("Recordings", isDirectory: true).appendingPathComponent(name + ".bouncerec", isDirectory: true)
        writer = try RecordingWriter(folder: folder, session: session, byteLimit: SessionRecorder.maxBytes)
    }

    /// Queue a frame's line and pixels for writing (call from one queue, in frame order).
    func append(_ frame: RecordedFrame, image: YCCImage?, depth: DepthMap?, ball: Plane?) {
        lock.lock()
        if firstError != nil { lock.unlock(); return }
        if pending >= SessionRecorder.maxPendingFrames {
            firstError = "the phone's storage fell too far behind"
            lock.unlock()
            return
        }
        let behind = pending > SessionRecorder.behindFrames
        if behind && (image != nil || ball != nil) { dropped += 1 }
        pending += 1
        lock.unlock()
        let img = behind ? nil : image, b = behind ? nil : ball
        let newFiles = (img != nil ? 1 : 0) + (depth != nil ? 1 : 0) + (b != nil ? 1 : 0)
        io.async {
            self.lock.lock()
            let stopped = self.firstError != nil, full = self.files + newFiles > SessionRecorder.maxFiles
            if full && !stopped { self.firstError = "file limit reached" }
            self.lock.unlock()
            var err: String? = nil
            if !stopped && !full {
                do { try self.writer.append(frame, image: img, depth: depth, ball: b) } catch { err = SessionRecorder.describe(error) }
            }
            self.lock.lock()
            self.pending -= 1
            if !stopped && !full {
                if let e = err { if self.firstError == nil { self.firstError = e } } else { self.written += 1; self.files += newFiles }
            }
            self.lock.unlock()
        }
    }

    /// Finish writing, zip the folder (refused before writing anything if the phone has no room for it), delete the folder,
    /// and report the zip's URL (and its size) or why it failed. A partial zip is removed; the folder is kept on failure.
    func finish(_ done: @escaping (Result<URL, Error>, Int64?) -> Void) {
        io.async {
            self.writer.close()
            let fm = FileManager.default
            let zip = self.folder.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(self.name + ".bouncerec.zip")
            let free = (try? zip.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
            let size = try? ZipWriter.archiveSize(folder: self.folder)
            do {
                try ZipWriter.zip(folder: self.folder, to: zip, availableBytes: free)
                try? fm.removeItem(at: self.folder)
                done(.success(zip), size)
            } catch {
                try? fm.removeItem(at: zip)
                done(.failure(RecorderError.writeFailed(SessionRecorder.describe(error))), nil)
            }
        }
    }

    /// A short reason for the owner, without file names or paths.
    static func describe(_ error: Error) -> String {
        if let e = error as? RecordingError, case .limitReached = e { return "size limit reached" }
        if let e = error as? ZipWriter.ZipError { return e.localizedDescription }
        if let e = error as? RecorderError { return e.errorDescription ?? "recording error" }
        let ns = error as NSError
        if (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError) || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC)) {
            return "the phone is out of space"
        }
        return "write error \(ns.code)"
    }
}
