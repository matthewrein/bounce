import BounceCore
import Foundation

/// Records a session (frames, camera poses, lens, motion, depth) into Documents/Recordings/<name>.bouncerec, on its own
/// queue so the camera never waits for the disk; on finish, zips it to Documents/<name>.bouncerec.zip for sharing.
/// Recordings show the owner's surroundings: they stay on the phone unless the owner shares them.
final class SessionRecorder {
    let name: String
    let folder: URL
    private let writer: RecordingWriter
    private let io = DispatchQueue(label: "slabbounce.recorder", qos: .utility)
    private let lock = NSLock()
    private var written = 0
    private var pending = 0

    var frameCount: Int { lock.lock(); defer { lock.unlock() }; return written }

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

    /// Queue a frame for writing. Frames are dropped (not queued) if the disk falls more than 20 behind.
    func append(_ frame: RecordedFrame, image: YCCImage, depth: DepthMap?) {
        lock.lock()
        if pending > 20 { lock.unlock(); return }
        pending += 1
        lock.unlock()
        io.async {
            try? self.writer.append(frame, image: image, depth: depth)
            self.lock.lock(); self.pending -= 1; self.written += 1; self.lock.unlock()
        }
    }

    /// Finish writing, zip the folder, and report the zip's URL (nil if zipping failed).
    func finish(_ done: @escaping (URL?) -> Void) {
        io.async {
            self.writer.close()
            let zip = self.folder.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(self.name + ".bouncerec.zip")
            do {
                try ZipWriter.zip(folder: self.folder, to: zip)
                done(zip)
            } catch {
                done(nil)
            }
        }
    }
}
