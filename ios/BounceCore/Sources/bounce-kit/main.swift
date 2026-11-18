// bounce-kit: capture-kit tools for the hand-off (ios/CaptureKit.md, "When the kit is uploaded").
//
//   bounce-kit write-synthetic <folder> [--codec hevc|h264] [--time-scale S] [--date YYYYMMDD-HHMMSS] [--no-lidar]
//   bounce-kit bundle <kit folder> <outbox> [--limit BYTES] [--no-deflate]
//   bounce-kit check <kit folder>
//   bounce-kit expect <scores.json> --kit ID [--max-tilt-error DEG] [--min-lock-rate SHARE] [--min-scored N]
//   bounce-kit budget
//
// Kits are private: it prints kit ids, shot ids, part names and numbers, never paths or anything from the pictures.
import BounceCore
import Foundation

#if os(macOS) || os(Linux)

let usage = """
usage: bounce-kit write-synthetic <folder> [options]   a synthetic kit the size of a real one, as the phone writes it
       bounce-kit bundle <kit folder> <outbox> [options] the kit's bundle parts, as the app makes them (KitBundle)
       bounce-kit check <kit folder>                     does the kit hold every file kit.json says it captured?
       bounce-kit expect <scores.json> --kit ID [options] checks a kit's scores (for the dry run)
       bounce-kit budget                                 the largest single file a real kit can hold, against a part

write-synthetic options:
  --codec hevc|h264      the phone's codec (default hevc; h264 where HEVC is unavailable, at 1.5 times the bitrate)
  --time-scale S         run the plan S times as fast (default 1, a real kit; the UI tests use 0.25)
  --date YYYYMMDD-HHMMSS when the kit was started, UTC (its id; default 20261119-083000)
  --no-lidar             a phone without LiDAR (no depth files)
  --render-fps N         new pictures a second where nothing moves fast (default 5)
  --quiet                no progress lines
bundle options:
  --limit BYTES          the part limit (default 24000000, the app's)
  --no-deflate           store every file (default: JSON, JSONL and depth deflated, as the app does, with gzip here)
expect options:
  --max-tilt-error DEG   fail if the kit's median tilt error is over DEG or missing
  --min-lock-rate SHARE  fail if its lock rate is under SHARE (0-1) or missing
  --min-scored N         fail if fewer than N of its video shots could be scored (0 scored: ffmpeg could not decode them)

check: exit status 0 complete, 4 something missing (listed), 1 no kit.json this checkout can read (why, on the second line)
"""

func fail(_ s: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("bounce-kit: " + s + "\n").utf8))
    exit(code)
}
func note(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

/// GitHub's web upload takes files up to 25 MiB.
let githubUploadLimit: Int64 = 25 * 1024 * 1024

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("no command\n\n" + usage) }
args.removeFirst()
func value(_ name: String) -> String {
    guard !args.isEmpty else { fail("\(name) needs a value\n\n" + usage) }
    return args.removeFirst()
}
func positional(_ n: Int, _ what: String) -> [String] {
    let p = args.filter { !$0.hasPrefix("-") }
    guard p.count >= n else { fail("\(command) needs \(what)\n\n" + usage) }
    return p
}

/// Raw DEFLATE (RFC 1951) from gzip: its output less the 10-byte header and the 8-byte trailer (Linux has no Apple
/// Compression framework; zlib's DEFLATE is the same format the app's COMPRESSION_ZLIB writes).
func gzipDeflate(_ d: Data) -> Data? {
    let fm = FileManager.default
    guard let gzip = ["/usr/bin/gzip", "/bin/gzip", "/opt/homebrew/bin/gzip", "/usr/local/bin/gzip"].first(where: { fm.isExecutableFile(atPath: $0) }) else { return nil }
    let tmp = fm.temporaryDirectory.appendingPathComponent("bounce-kit-\(UUID().uuidString).raw")
    defer { try? fm.removeItem(at: tmp) }
    guard (try? d.write(to: tmp)) != nil, let input = FileHandle(forReadingAtPath: tmp.path) else { return nil }
    defer { try? input.close() }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: gzip)
    p.arguments = ["-c", "-n", "-6"]
    let out = Pipe()
    p.standardInput = input; p.standardOutput = out; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let gz = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let b = [UInt8](gz)
    // ID1 ID2, CM = 8 (deflate), FLG = 0 (no name, comment or extra field)
    guard p.terminationStatus == 0, b.count >= 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8, b[3] == 0 else { return nil }
    return Data(b[10..<(b.count - 8)])
}

switch command {
case "write-synthetic":
    var o = KitSyntheticPhoneKit.Options()
    var quiet = false
    var rest: [String] = []
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "--codec": let c = value(a); guard let k = KitVideoStreamWriter.Codec(rawValue: c) else { fail("--codec is hevc or h264") }; o.codec = k
        case "--time-scale": guard let s = Double(value(a)), s > 0, s <= 1 else { fail("--time-scale needs a number in (0, 1]") }; o.timeScale = s
        case "--date":
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd-HHmmss"
            guard let d = f.date(from: value(a)) else { fail("--date is YYYYMMDD-HHMMSS (UTC)") }
            o.date = d
        case "--no-lidar": o.lidar = false
        case "--render-fps": guard let r = Double(value(a)), r > 0, r <= 60 else { fail("--render-fps needs a number in (0, 60]") }; o.renderFps = r
        case "--quiet": quiet = true
        default: if a.hasPrefix("-") { fail("unknown option \(a)\n\n" + usage) }; rest.append(a)
        }
    }
    guard let root = rest.first else { fail("write-synthetic needs a folder\n\n" + usage) }
    if !quiet { o.log = note }
    let t0 = Date()
    do {
        let kit = try KitSyntheticPhoneKit.build(root: URL(fileURLWithPath: root), options: o)
        let video = kit.stats.reduce(Int64(0)) { $0 + $1.videoBytes }, frames = kit.stats.reduce(0) { $0 + $1.frames }
        let s = kit.store.summary()
        note(String(format: "%@: %d captured, %d skipped; %d video frames, %.1f MB of video, %.1f MB in all; %.0f s",
                    kit.kitId, s.captured, s.skipped, frames, Double(video) / 1e6, Double(kit.store.bytesOnDisk()) / 1e6,
                    Date().timeIntervalSince(t0)))
        print(kit.kitId)
    } catch {
        fail("could not write the synthetic kit: \(KitScorer.describe(error))")
    }

case "bundle":
    var limit = KitBundle.defaultLimit, deflate = true
    var rest: [String] = []
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "--limit": guard let l = Int64(value(a)), l > 0 else { fail("--limit needs bytes") }; limit = l
        case "--no-deflate": deflate = false
        default: if a.hasPrefix("-") { fail("unknown option \(a)\n\n" + usage) }; rest.append(a)
        }
    }
    guard rest.count == 2 else { fail("bundle needs a kit folder and an outbox\n\n" + usage) }
    if deflate && gzipDeflate(Data("{}".utf8)) == nil { fail("gzip is needed to deflate as the app does (or pass --no-deflate)") }
    do {
        let r = try KitBundle.build(kitFolder: URL(fileURLWithPath: rest[0]), outbox: URL(fileURLWithPath: rest[1]), limit: limit,
                                    deflate: deflate ? gzipDeflate : nil)
        var over = 0
        for p in r.parts {
            let flag = p.bytes > githubUploadLimit ? "  OVER GitHub's 25 MiB upload limit" : (p.bytes > limit ? "  over the part limit" : "")
            if p.bytes > limit || p.bytes > githubUploadLimit { over += 1 }
            print("\(p.name) \(p.bytes) bytes, \(p.entries.count) files\(flag)")
        }
        note(String(format: "%d part%@, %.1f MB in all, %d files deflated, the largest part %d bytes (limit %lld)", r.parts.count,
                    r.parts.count == 1 ? "" : "s", Double(r.totalBytes) / 1e6, r.deflated.count, r.parts.map { $0.bytes }.max() ?? 0, limit))
        if !r.oversized.isEmpty { note("\(r.oversized.count) file(s) larger than a part on their own: each has a part of its own") }
        if over > 0 { fail("\(over) part(s) over the limit", 3) }
    } catch {
        fail("could not build the bundle: \(error)")
    }

case "check":
    let p = positional(1, "a kit folder")
    let folder = URL(fileURLWithPath: p[0])
    guard let r = KitArrival.check(kitFolder: folder) else {
        print("\(folder.lastPathComponent)")
        print("  " + (KitArrival.readProblem(kitFolder: folder) ?? "kit.json does not read"))
        exit(1)
    }
    print("\(r.kitId) (\(r.planId))")
    for l in r.lines { print("  " + l) }
    exit(r.complete ? 0 : 4)

case "expect":
    var kit: String? = nil, maxTilt: Double? = nil, minLock: Double? = nil, minScored: Int? = nil
    var rest: [String] = []
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "--kit": kit = value(a)
        case "--max-tilt-error": guard let d = Double(value(a)), d > 0 else { fail("--max-tilt-error needs degrees") }; maxTilt = d
        case "--min-lock-rate": guard let d = Double(value(a)), d >= 0, d <= 1 else { fail("--min-lock-rate needs a share 0-1") }; minLock = d
        case "--min-scored": guard let n = Int(value(a)), n >= 0 else { fail("--min-scored needs a number of shots") }; minScored = n
        default: if a.hasPrefix("-") { fail("unknown option \(a)\n\n" + usage) }; rest.append(a)
        }
    }
    guard let file = rest.first, let id = kit else { fail("expect needs a scores file and --kit\n\n" + usage) }
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: file)), let set = try? KitScoreSet.read(d) else { fail("not a scores file") }
    guard let r = set.reports.first(where: { $0.kitId == id }) else { fail("\(id) was not scored", 5) }
    var bad: [String] = []
    let tilt = r.aggregate("tiltErrorMedian")?.value, lock = r.aggregate("lockRate")?.value
    let scored = r.shots.filter { $0.error == nil }.count
    print("\(id): tilt error median \(tilt.map { String(format: "%.2f°", $0) } ?? "n/a"), lock rate \(lock.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a"), "
          + "\(scored) of \(r.shots.count) video shots scored")
    if let m = maxTilt, (tilt ?? .infinity) > m { bad.append(String(format: "median tilt error over %.2f°", m)) }
    if let m = minLock, (lock ?? -1) < m { bad.append(String(format: "lock rate under %.0f%%", m * 100)) }
    if let n = minScored, scored < n {
        let why = Set(r.shots.compactMap { $0.error }).sorted().prefix(3).joined(separator: "; ")
        bad.append("\(scored) of its \(r.shots.count) video shots could be scored" + (why.isEmpty ? "" : " (\(why))"))
    }
    if !bad.isEmpty { fail("\(id): " + bad.joined(separator: ", "), 5) }

case "budget":
    let capacity = KitBundle.defaultLimit - 22 - 100_000   // less the end record and a generous kit.json
    for hevc in [true, false] {
        guard let w = KitPhoneVideo.largestVideoBytes(plan: .standard, hevc: hevc) else { continue }
        print(String(format: "%@: the largest video is %@ at %.1f MB; a part holds %.1f MB, so the encoder would have to overshoot its bitrate %.2f times "
                     + "(GitHub's 25 MiB limit: %.2f times)", hevc ? "HEVC" : "H.264", w.shotId, Double(w.bytes) / 1e6, Double(capacity) / 1e6,
                     Double(capacity) / Double(w.bytes), Double(githubUploadLimit) / Double(w.bytes)))
    }

case "-h", "--help", "help":
    print(usage)

default:
    fail("unknown command \(command)\n\n" + usage)
}

#else
print("bounce-kit runs on macOS and Linux")
#endif
