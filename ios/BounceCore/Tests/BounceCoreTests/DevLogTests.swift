import XCTest
@testable import BounceCore

final class DevLogTests: XCTestCase {
    var tmp: URL!
    let fm = FileManager.default

    override func setUp() { tmp = fm.temporaryDirectory.appendingPathComponent("devlog-\(UUID().uuidString)") }
    override func tearDown() { try? fm.removeItem(at: tmp) }

    var folder: URL { tmp.appendingPathComponent("Logs") }

    func testLinesAreTimeLevelAreaMessage() {
        let t = Date(timeIntervalSince1970: 1_794_985_502.25) // 2026-11-18 07:05:02.250 UTC (exact in binary)
        let log = DevLog(folder: folder, clock: { t })
        XCTAssertEqual(log.text(), "", "nothing logged yet")
        log.info("kit", "shot s02-scan saved, 150 frames")
        log.log(.error, "recorder", "the video encoder stopped (error -11800)")
        log.warn("pre flight!", "two\nlines\r\nhere")
        log.debug("", "x")
        XCTAssertEqual(log.lines(), [
            "2026-11-18T07:05:02.250Z INFO kit shot s02-scan saved, 150 frames",
            "2026-11-18T07:05:02.250Z ERROR recorder the video encoder stopped (error -11800)",
            "2026-11-18T07:05:02.250Z WARN pre-flight- two | lines | here",
            "2026-11-18T07:05:02.250Z DEBUG app x",
        ])
        XCTAssertTrue(log.text().hasSuffix("\n"))
        XCTAssertEqual(log.failedWrites, 0)
        // long messages are cut
        log.info("kit", String(repeating: "a", count: 5000))
        XCTAssertEqual(log.lines().last?.count, "2026-11-18T07:05:02.250Z INFO kit ".count + DevLog.maxMessageCharacters + 3)
    }

    func testEveryLineIsOnDiskWhenLogReturns() throws {
        let log = DevLog(folder: folder)
        log.error("kit", "could not save the shot")
        // read the file directly (as after a crash): the line is there, with no close or flush
        let onDisk = String(decoding: try Data(contentsOf: log.currentURL), as: UTF8.self)
        XCTAssertTrue(onDisk.hasSuffix("ERROR kit could not save the shot\n"))
        // a second log on the same folder (the app launched again) appends
        let again = DevLog(folder: folder)
        again.info("app", "launched")
        XCTAssertEqual(again.lines().count, 2)
        XCTAssertTrue(again.lines()[0].hasSuffix("could not save the shot"))
        // the first one writing again does not overwrite the second's line
        log.info("app", "still here")
        XCTAssertEqual(log.lines().map { $0.split(separator: " ").dropFirst(3).joined(separator: " ") },
                       ["could not save the shot", "launched", "still here"])
    }

    func testConcurrentWritersNeverInterleave() {
        let log = DevLog(folder: folder, maxBytes: 50_000_000)
        let writers = 8, each = 250
        DispatchQueue.concurrentPerform(iterations: writers) { w in
            for i in 0..<each { log.info("w\(w)", "line \(i) " + String(repeating: "x", count: (i * 7) % 91)) }
        }
        let lines = log.lines()
        XCTAssertEqual(lines.count, writers * each)
        var next = [Int](repeating: 0, count: writers)
        for l in lines {
            let parts = l.split(separator: " ").map(String.init)
            guard parts.count >= 5, parts[1] == "INFO", let w = Int(parts[2].dropFirst()), let i = Int(parts[4]) else { XCTFail("bad line \(l)"); continue }
            XCTAssertEqual(parts.count, i % 13 == 0 ? 5 : 6, l)
            XCTAssertEqual(i, next[w], "each writer's lines in its order, none lost or torn")
            next[w] = i + 1
            XCTAssertEqual(parts[3], "line")
        }
        XCTAssertEqual(next, [Int](repeating: each, count: writers))
        XCTAssertEqual(log.failedWrites, 0)
    }

    func testRotationKeepsTheNewestLinesUnderTheCap() throws {
        let cap = 4000
        let log = DevLog(folder: folder, maxBytes: cap)
        for i in 0..<400 { log.info("kit", "line \(i) padding padding padding") }
        let lines = log.lines()
        XCTAssertEqual(lines.last.map { $0.hasSuffix("line 399 padding padding padding") }, true)
        XCTAssertLessThan(lines.count, 400, "old lines go")
        XCTAssertGreaterThan(lines.count, 20, "about the cap's worth is kept")
        let numbers = lines.compactMap { l in l.split(separator: " ").dropFirst(4).first.flatMap { Int($0) } }
        XCTAssertEqual(numbers, Array((400 - numbers.count)..<400), "the newest lines, in order, none missing")
        XCTAssertLessThanOrEqual(log.bytes(), cap + 100)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: folder.path).sorted(), [DevLog.previousName, DevLog.currentName].sorted())
        // read back after rotation by another instance (a relaunch): same text, still capped as it goes on
        let again = DevLog(folder: folder, maxBytes: cap)
        XCTAssertEqual(again.text(), log.text())
        for i in 400..<800 { again.info("kit", "line \(i) padding padding padding") }
        XCTAssertLessThanOrEqual(again.bytes(), cap + 100)
        XCTAssertTrue(again.lines().last?.hasSuffix("line 799 padding padding padding") ?? false)
        // clear
        again.clear()
        XCTAssertEqual(again.text(), "")
        XCTAssertEqual(again.bytes(), 0)
        again.info("app", "after clear")
        XCTAssertEqual(again.lines().count, 1)
    }

    func testAnUnwritableFolderDropsLinesWithoutTrapping() throws {
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data("not a folder".utf8).write(to: folder) // a file where the folder should be
        let log = DevLog(folder: folder)
        log.error("kit", "nowhere to go")
        log.error("kit", "still nowhere")
        XCTAssertEqual(log.failedWrites, 2)
        XCTAssertEqual(log.text(), "")
    }

    // MARK: words and numbers only

    func testPathsAndURLsAreRedacted() {
        let cases: [(String, String)] = [
            ("could not write /var/mobile/Containers/Data/Application/0A1B-2C3D/Library/Application Support/Kits/slab-kit-20261117-153000/kit.json",
             "could not write <path>/kit.json"),
            ("at file:///var/mobile/Containers/Data/Application/0A1B/Documents/Kits/x/slab-kit-1-part1of2.zip.",
             "at <path>/slab-kit-1-part1of2.zip."),
            ("The file “video.mp4” couldn’t be saved in the folder “/private/var/mobile/Containers/Data/Application/ABC/tmp”.",
             "The file “video.mp4” couldn’t be saved in the folder “<path>”."),
            ("no such file: /Users/matthew/Desktop/notes", "no such file: <path>"),
            ("(/Users/Jane Doe/My Kits/kit.json)", "(<path>/kit.json)"),
            ("path=~/Library/Caches/thing", "path=<path>"),
            ("see https://example.com/a?b=c for more", "see <url> for more"),
            ("tilt 3/4 of a degree, 5 / 7 shots, 1/30 s", "tilt 3/4 of a degree, 5 / 7 shots, 1/30 s"),
            ("kit slab-kit-1/shots/s02-scan/video.mp4 too large", "kit slab-kit-1/shots/s02-scan/video.mp4 too large"),
            ("error 640", "error 640"),
            ("/", "/"),
            ("", ""),
        ]
        for (input, expected) in cases { XCTAssertEqual(DevLog.redact(input), expected, input) }
        // a log line never carries a path
        let log = DevLog(folder: folder)
        log.error("kit", "failed at /var/mobile/Containers/Data/Application/X/Library/kit.json")
        XCTAssertFalse(log.text().contains("/var/mobile"))
        XCTAssertTrue(log.text().contains("<path>/kit.json"))
    }

    func testErrorsAreDescribedWithoutPaths() {
        let path = "/var/mobile/Containers/Data/Application/0A1B/Library/Application Support/Kits/slab-kit-1/kit.json"
        let full = CocoaError(.fileWriteOutOfSpace, userInfo: [NSFilePathErrorKey: path,
                                                               NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 28)])
        let d = DevLog.describe(full)
        XCTAssertTrue(d.hasPrefix("NSCocoaErrorDomain 640 (from NSPOSIXErrorDomain 28) out of space: "), d)
        XCTAssertFalse(d.contains("/var/"), d)
        XCTAssertFalse(d.contains("Application Support"), d)
        XCTAssertTrue(DevLog.isOutOfSpace(full))
        XCTAssertTrue(DevLog.isOutOfSpace(POSIXError(.ENOSPC)))
        XCTAssertFalse(DevLog.isOutOfSpace(POSIXError(.EIO)))

        let posix = DevLog.describe(POSIXError(.ENOSPC))
        XCTAssertTrue(posix.hasPrefix("NSPOSIXErrorDomain 28 out of space: "), posix)

        let ns = NSError(domain: "AVFoundationErrorDomain", code: -11800,
                         userInfo: [NSLocalizedDescriptionKey: "The operation could not be completed: file:///private/var/mobile/x/video.mp4"])
        XCTAssertEqual(DevLog.describe(ns), "AVFoundationErrorDomain -11800: The operation could not be completed: <path>/video.mp4")

        // the app's own errors say what they are
        let k = DevLog.describe(KitStoreError.notStarted("s02-scan"))
        XCTAssertTrue(k.hasSuffix(": shot s02-scan was not started"), k)
        XCTAssertTrue(k.contains("KitStoreError"), k)
        XCTAssertTrue(DevLog.describe(KitBundleError.limitTooSmall(1000)).hasSuffix("part limit 1000 bytes is too small"))

        let log = DevLog(folder: folder)
        log.error("kit", "could not save the shot", full)
        XCTAssertTrue(log.lines().last?.contains("ERROR kit could not save the shot: NSCocoaErrorDomain 640") ?? false)
        XCTAssertFalse(log.text().contains("/var/"))
    }
}
