#if os(macOS) || os(Linux)
import Foundation

/// Errors decoding (or encoding) a kit's video with ffmpeg. Messages carry file names, never folders.
public enum KitVideoError: Error, Equatable, CustomStringConvertible {
    /// ffmpeg or ffprobe is not installed (not on PATH)
    case toolMissing(String)
    /// ffprobe could not read the file
    case probeFailed(String)
    /// the file has no video stream
    case noVideoStream
    /// the video holds another number of frames than frames.jsonl has lines
    case frameCountMismatch(video: Int, frames: Int)
    /// ffmpeg failed while decoding or encoding
    case ffmpegFailed(String)
    /// a frame of another size than the encoder was given first
    case badFrame(String)

    public var description: String {
        switch self {
        case let .toolMissing(t):
            return "\(t) is not installed: the scorer decodes the kit's video with it (macOS: brew install ffmpeg; Linux: apt install ffmpeg)"
        case let .probeFailed(why): return "could not read the video: \(why)"
        case .noVideoStream: return "the file has no video stream"
        case let .frameCountMismatch(v, f): return "the video has \(v) frames but frames.jsonl has \(f) lines"
        case let .ffmpegFailed(why): return "ffmpeg failed: \(why)"
        case let .badFrame(why): return "bad frame: \(why)"
        }
    }
}

/// Runs ffmpeg and ffprobe.
public enum KitFFmpeg {
    /// The tool's location: on PATH, else in the usual Homebrew and system folders.
    public static func find(_ name: String) -> URL? {
        let env = ProcessInfo.processInfo.environment
        var dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for d in dirs where !d.isEmpty {
            let u = URL(fileURLWithPath: d).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: u.path) { return u }
        }
        return nil
    }

    /// Both ffmpeg and ffprobe are installed.
    public static var isAvailable: Bool { find("ffmpeg") != nil && find("ffprobe") != nil }

    /// Runs a tool to the end and returns its standard output; throws with its last error line if it fails.
    static func run(_ name: String, _ args: [String], hide: [String] = []) throws -> Data {
        guard let exe = find(name) else { throw KitVideoError.toolMissing(name) }
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let errText = PipeDrain(err.fileHandleForReading)
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let e = errText.finish()
        guard p.terminationStatus == 0 else {
            throw KitVideoError.ffmpegFailed(lastLine(e, hide: hide) ?? "\(name) exited with status \(p.terminationStatus)")
        }
        return data
    }

    /// The last non-empty line of a tool's error output, with the given paths replaced by their last component.
    static func lastLine(_ d: Data, hide: [String]) -> String? {
        guard var s = String(data: d, encoding: .utf8) else { return nil }
        for h in hide.sorted(by: { $0.count > $1.count }) where !h.isEmpty {
            s = s.replacingOccurrences(of: h, with: URL(fileURLWithPath: h).lastPathComponent)
        }
        return s.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
    }

    /// ffmpeg's version as (major, minor), if it says (git builds say "N-..." and count as new).
    static func version() -> (Int, Int)? {
        guard let d = try? run("ffmpeg", ["-hide_banner", "-version"]), let s = String(data: d, encoding: .utf8) else { return nil }
        guard let r = s.range(of: "ffmpeg version ") else { return nil }
        let rest = s[r.upperBound...].prefix { !$0.isWhitespace }
        let parts = rest.split(whereSeparator: { !$0.isNumber }).prefix(2).compactMap { Int($0) }
        guard rest.first?.isNumber == true, let major = parts.first else { return nil }
        return (major, parts.count > 1 ? parts[1] : 0)
    }

    /// The option that keeps every decoded frame as it is (no frames dropped or repeated for a constant rate).
    static func passthroughOptions() -> [String] {
        if let v = version(), v.0 < 5 || (v.0 == 5 && v.1 < 1) { return ["-vsync", "passthrough"] }
        return ["-fps_mode", "passthrough"]
    }
}

/// Reads a pipe to its end on a background thread (so a tool never blocks writing to it).
final class PipeDrain {
    private let lock = NSLock()
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ h: FileHandle) {
        DispatchQueue.global(qos: .utility).async {
            let d = h.readDataToEndOfFile()
            self.lock.lock(); self.data = d; self.lock.unlock()
            self.done.signal()
        }
    }

    func finish() -> Data {
        done.wait()
        lock.lock(); defer { lock.unlock() }
        return data
    }
}

/// What ffprobe says about a video's first stream.
public struct KitVideoProbe: Equatable {
    public var codec: String
    public var width: Int
    public var height: Int
    public var pixelFormat: String
    /// ffprobe's colour range tag ("tv", "pc"), nil when the file does not say
    public var colorRange: String?
    /// the number of frames (packets counted), if ffprobe could count them
    public var frames: Int?

    /// Full range (0-255) when the stream says so ("pc", or a "yuvj" pixel format); otherwise limited (16-235 luma,
    /// 16-240 chroma). A stream without a tag reads as limited here; the scorer judges such a stream from its samples
    /// instead (`KitVideoDecoder.rangeCheck`).
    public var isFullRange: Bool {
        if let r = colorRange?.lowercased(), ["pc", "jpeg", "full"].contains(r) { return true }
        return pixelFormat.hasPrefix("yuvj")
    }
}

/// How a video's samples are to be read, full or limited range, judged from the samples themselves and the camera's own
/// mean luma (`KitVideoDecoder.rangeCheck`).
public struct KitRangeCheck: Equatable {
    /// the samples are full range (0-255)
    public var fullRange: Bool
    /// how it was decided, in plain English
    public var reason: String
    /// share of luma samples outside the limited range (below 10 or above 245; a limited-range stream has hardly any)
    public var outsideShare: Double
    /// mean |decoded mean luma - frames.jsonl luma| with the samples read as full range, and as limited range (nil: no
    /// frame had a luma to compare)
    public var fullLumaError: Double?
    public var limitedLumaError: Double?
}

/// Decodes a kit's video (video.mp4) frame by frame with ffmpeg, into full-range 8-bit YCbCr 4:2:0 `YCCImage`s at the
/// video's size, without holding the whole video in memory. Limited-range streams (the usual for H.264 and HEVC) are
/// expanded to full range (BT.601: luma (Y - 16) x 255/219, chroma (C - 128) x 255/224 + 128), matching the phone's
/// full-range camera buffer. A stream without a range tag is read the way its samples say (`rangeCheck`, given to the
/// decoder as `fullRange`). Every decoded frame is kept as it is
/// (no frames dropped or repeated to a constant rate), and the rotation tag, if any, is ignored: the frames stay in the
/// sensor's orientation, which frames.jsonl's intrinsics describe.
///
/// `expectedFrames`: frames.jsonl's line count. A different number of frames in the video throws
/// `KitVideoError.frameCountMismatch`: up front when ffprobe can count them, else when the decoding ends.
public final class KitVideoDecoder: KitFrameSource {
    public let probe: KitVideoProbe
    public var width: Int { probe.width }
    public var height: Int { probe.height }
    /// frames read so far
    public private(set) var framesRead = 0
    private let expected: Int?
    private var process: Process?
    private var output: FileHandle?
    private var errors: PipeDrain?
    private let name: String
    private let hide: [String]
    private var ended = false
    private let lut: (y: [UInt8], c: [UInt8])?

    /// The stream's description from ffprobe.
    public static func probe(_ url: URL) throws -> KitVideoProbe {
        let hide = [url.path, url.deletingLastPathComponent().path]
        let d: Data
        do {
            d = try KitFFmpeg.run("ffprobe", ["-v", "error", "-select_streams", "v:0", "-count_packets",
                                              "-show_entries", "stream=codec_name,width,height,pix_fmt,color_range,nb_frames,nb_read_packets",
                                              "-of", "json", url.path], hide: hide)
        } catch let KitVideoError.ffmpegFailed(why) {
            throw KitVideoError.probeFailed(why)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw KitVideoError.probeFailed("ffprobe said nothing readable") }
        guard let s = (obj["streams"] as? [[String: Any]])?.first else { throw KitVideoError.noVideoStream }
        func int(_ k: String) -> Int? {
            if let i = s[k] as? Int { return i }
            if let n = s[k] as? NSNumber { return n.intValue }
            if let t = s[k] as? String { return Int(t) }
            return nil
        }
        guard let w = int("width"), let h = int("height"), w > 0, h > 0 else { throw KitVideoError.noVideoStream }
        let range = (s["color_range"] as? String).flatMap { $0 == "unknown" ? nil : $0 }
        return KitVideoProbe(codec: s["codec_name"] as? String ?? "?", width: w, height: h, pixelFormat: s["pix_fmt"] as? String ?? "?",
                             colorRange: range, frames: int("nb_read_packets") ?? int("nb_frames"))
    }

    /// The range a kit's video is in, from its first frames (up to `maxFrames`, decoded as they are): samples outside
    /// 10-245 on more than 0.2% of the luma (every 8th pixel) mean full range (a limited-range stream keeps luma within
    /// 16-235, give or take the encoder's ringing). Otherwise the frames' mean luma (every 8th pixel), read either way,
    /// is compared with the camera's own mean luma on the same frames (frames.jsonl `luma`, full range, every 8th pixel
    /// of the camera image), and the closer reading wins when they differ by more than 1.5 levels. Near mid-grey the
    /// two readings hardly differ; then it is full range, as the app's recorder gives the encoder full-range samples.
    public static func rangeCheck(url: URL, luma: [Double?], maxFrames: Int = 8) throws -> KitRangeCheck {
        let raw = try KitVideoDecoder(url: url, fullRange: true)
        defer { raw.close() }
        let t = expansionTables()
        var outside = 0, samples = 0
        var errFull = 0.0, errLimited = 0.0, compared = 0
        var i = 0
        while i < maxFrames, let f = try raw.next() {
            var sum = 0, sumExpanded = 0, n = 0
            var y = 0
            while y < f.height {
                var x = 0
                let row = y * f.width
                while x < f.width {
                    let v = f.y[row + x]
                    if v < 10 || v > 245 { outside += 1 }
                    sum += Int(v); sumExpanded += Int(t.y[Int(v)]); n += 1
                    x += 8
                }
                y += 8
            }
            samples += n
            if i < luma.count, let l = luma[i], l.isFinite, n > 0 {
                errFull += abs(Double(sum) / Double(n) - l)
                errLimited += abs(Double(sumExpanded) / Double(n) - l)
                compared += 1
            }
            i += 1
        }
        let share = samples > 0 ? Double(outside) / Double(samples) : 0
        let eF = compared > 0 ? errFull / Double(compared) : nil, eL = compared > 0 ? errLimited / Double(compared) : nil
        if share > 0.002 {
            return KitRangeCheck(fullRange: true, reason: String(format: "%.1f%% of its luma is outside 16-235, so it is full range", share * 100),
                                 outsideShare: share, fullLumaError: eF, limitedLumaError: eL)
        }
        if let f = eF, let l = eL, abs(f - l) > 1.5 {
            let full = f < l
            return KitRangeCheck(fullRange: full, reason: String(format: "its mean luma matches the camera's when read as %@ range (%.1f against %.1f levels off)",
                                                               full ? "full" : "limited", min(f, l), max(f, l)),
                                 outsideShare: share, fullLumaError: eF, limitedLumaError: eL)
        }
        return KitRangeCheck(fullRange: true, reason: "its samples do not show which range they are in; read as full range, as the app records",
                             outsideShare: share, fullLumaError: eF, limitedLumaError: eL)
    }

    /// A word on the colour range for the report, if there is anything to say: how an untagged stream is read, or a
    /// tagged one whose samples look like the other range (nil: tagged, and the samples agree).
    public var rangeNote: String? = nil

    /// Starts decoding. `fullRange`: override the stream's range tag (nil: as the stream says).
    public init(url: URL, expectedFrames: Int? = nil, fullRange: Bool? = nil) throws {
        name = url.lastPathComponent
        hide = [url.path, url.deletingLastPathComponent().path]
        guard KitFFmpeg.find("ffmpeg") != nil else { throw KitVideoError.toolMissing("ffmpeg") }
        let p = try KitVideoDecoder.probe(url)
        probe = p
        expected = expectedFrames
        if let e = expectedFrames, let n = p.frames, n != e { throw KitVideoError.frameCountMismatch(video: n, frames: e) }
        let full = fullRange ?? p.isFullRange
        lut = full ? nil : KitVideoDecoder.expansionTables()
        // 8-bit 4:2:0 streams come out exactly as decoded; others are converted to 8-bit 4:2:0 keeping their range
        var args = ["-nostdin", "-v", "error", "-noautorotate", "-i", url.path, "-map", "0:v:0", "-an", "-sn", "-dn"]
        args += KitFFmpeg.passthroughOptions()
        if p.pixelFormat == "yuv420p" || p.pixelFormat == "yuvj420p" {
            args += ["-pix_fmt", p.pixelFormat]
        } else {
            let r = full ? "pc" : "tv"
            args += ["-vf", "scale=in_range=\(r):out_range=\(r)", "-pix_fmt", "yuv420p"]
        }
        args += ["-f", "rawvideo", "pipe:1"]
        let proc = Process()
        proc.executableURL = KitFFmpeg.find("ffmpeg")
        proc.arguments = args
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out; proc.standardError = err
        proc.standardInput = FileHandle.nullDevice
        errors = PipeDrain(err.fileHandleForReading)
        try proc.run()
        process = proc
        output = out.fileHandleForReading
    }

    deinit { close() }

    /// Luma and chroma tables from limited to full range.
    static func expansionTables() -> (y: [UInt8], c: [UInt8]) {
        let y = (0..<256).map { UInt8(clamp(((Double($0) - 16) * 255 / 219).rounded(), 0, 255)) }
        let c = (0..<256).map { UInt8(clamp(((Double($0) - 128) * 255 / 224 + 128).rounded(), 0, 255)) }
        return (y, c)
    }

    /// Reads exactly n bytes, or fewer at the end of the stream.
    private func read(_ n: Int) throws -> Data {
        guard let h = output else { return Data() }
        var d = Data()
        d.reserveCapacity(n)
        while d.count < n {
            guard let chunk = try h.read(upToCount: n - d.count), !chunk.isEmpty else { break }
            d.append(chunk)
        }
        return d
    }

    public func next() throws -> YCCImage? {
        guard !ended else { return nil }
        let w = width, h = height, cw = (w + 1) / 2, ch = (h + 1) / 2
        let size = w * h + 2 * cw * ch
        let d = try read(size)
        if d.count < size {
            try end(partial: !d.isEmpty)
            return nil
        }
        framesRead += 1
        var y = [UInt8](d[0..<(w * h)])
        var cb = [UInt8](d[(w * h)..<(w * h + cw * ch)])
        var cr = [UInt8](d[(w * h + cw * ch)..<size])
        if let t = lut {
            for i in 0..<y.count { y[i] = t.y[Int(y[i])] }
            for i in 0..<cb.count { cb[i] = t.c[Int(cb[i])]; cr[i] = t.c[Int(cr[i])] }
        }
        return YCCImage(width: w, height: h, y: y, cb: cb, cr: cr)
    }

    /// The end of the stream: check ffmpeg's exit and the frame count.
    private func end(partial: Bool) throws {
        ended = true
        output = nil
        guard let p = process else { return }
        p.waitUntilExit()
        process = nil
        let e = errors?.finish() ?? Data()
        errors = nil
        if p.terminationStatus != 0 {
            throw KitVideoError.ffmpegFailed(KitFFmpeg.lastLine(e, hide: hide) ?? "exit status \(p.terminationStatus) decoding \(name)")
        }
        if partial { throw KitVideoError.ffmpegFailed("\(name) ended in the middle of a frame") }
        if let x = expected, x != framesRead { throw KitVideoError.frameCountMismatch(video: framesRead, frames: x) }
    }

    /// Whether the video holds more frames than read so far (reads one more to find out); throws on a frame count that
    /// differs from `expectedFrames`.
    public func finish() throws {
        if ended { return }
        if try next() != nil {
            // more frames than frames.jsonl: count them all
            while try next() != nil {}
        }
    }

    /// Stops decoding: closes the pipe (so ffmpeg's next write fails), asks ffmpeg to stop and, if it does not within
    /// 2 s, kills it.
    public func close() {
        ended = true
        try? output?.close()
        output = nil
        if let p = process {
            if p.isRunning {
                p.terminate()
                let deadline = Date().addingTimeInterval(2)
                while p.isRunning && Date() < deadline { usleep(10_000) }
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
            p.waitUntilExit()
        }
        process = nil
        _ = errors?.finish()
        errors = nil
    }
}

/// Encodes frames into an MP4 with ffmpeg (for tests and synthetic kits): H.264 (libx264) or HEVC (libx265), full or
/// limited range (limited: the frames are converted to 16-235 / 16-240 and tagged "tv"; full: kept and tagged "pc";
/// `tagRange` false leaves the tag out, as an encoder may).
public enum KitVideoEncoder {
    public enum Codec: String { case h264 = "libx264", hevc = "libx265" }

    /// Writes `frames` (all the same size) at `fps`. `crf`: quality (lower is better; 18 is nearly lossless to the eye).
    public static func encode(_ frames: [YCCImage], fps: Double, codec: Codec, fullRange: Bool, tagRange: Bool = true, crf: Int = 18,
                              to url: URL) throws {
        guard let first = frames.first else { throw KitVideoError.badFrame("no frames") }
        guard let exe = KitFFmpeg.find("ffmpeg") else { throw KitVideoError.toolMissing("ffmpeg") }
        let w = first.width, h = first.height
        // a closed pipe must throw, not kill the process
        signal(SIGPIPE, SIG_IGN)
        let tag = tagRange ? ["-color_range", fullRange ? "pc" : "tv"] : []
        var args = ["-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "yuv420p", "-s", "\(w)x\(h)", "-r", String(format: "%.6g", fps)]
            + tag + ["-i", "pipe:0", "-c:v", codec.rawValue, "-pix_fmt", "yuv420p"] + tag + ["-crf", String(crf)]
        if codec == .hevc { args += ["-x265-params", "log-level=error", "-tag:v", "hvc1"] }
        args += [url.path]
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        let inPipe = Pipe(), err = Pipe()
        p.standardInput = inPipe; p.standardError = err; p.standardOutput = FileHandle.nullDevice
        let errText = PipeDrain(err.fileHandleForReading)
        try p.run()
        let inv = KitVideoEncoder.compressionTables()
        var failure: Error? = nil
        for f in frames {
            guard f.width == w, f.height == h else { failure = KitVideoError.badFrame("frames differ in size"); break }
            var d = Data(capacity: f.y.count + 2 * f.cb.count)
            if fullRange {
                d.append(contentsOf: f.y); d.append(contentsOf: f.cb); d.append(contentsOf: f.cr)
            } else {
                d.append(contentsOf: f.y.map { inv.y[Int($0)] }); d.append(contentsOf: f.cb.map { inv.c[Int($0)] })
                d.append(contentsOf: f.cr.map { inv.c[Int($0)] })
            }
            do { try inPipe.fileHandleForWriting.write(contentsOf: d) } catch { failure = error; break }
        }
        try? inPipe.fileHandleForWriting.close()
        p.waitUntilExit()
        let e = errText.finish()
        if p.terminationStatus != 0 {
            throw KitVideoError.ffmpegFailed(KitFFmpeg.lastLine(e, hide: [url.path, url.deletingLastPathComponent().path])
                                             ?? "exit status \(p.terminationStatus)")
        }
        if let f = failure { throw f }
    }

    /// Full-range to limited-range tables.
    static func compressionTables() -> (y: [UInt8], c: [UInt8]) {
        let y = (0..<256).map { UInt8(clamp((16 + Double($0) * 219 / 255).rounded(), 0, 255)) }
        let c = (0..<256).map { UInt8(clamp((128 + (Double($0) - 128) * 224 / 255).rounded(), 0, 255)) }
        return (y, c)
    }
}
#endif
