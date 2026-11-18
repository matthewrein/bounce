import Foundation

/// The developer log behind Settings > Developer > Copy log: one line per event, "time level area message", appended to
/// a file the app chooses (Application Support), so one failed attempt on the phone still says what went wrong.
///
/// - Every `log` call writes its line to the file before it returns (no buffering in the app), so a crash or a kill
///   right after still leaves the line. (A power cut may lose the last lines: nothing is fsynced.)
/// - Thread-safe: one lock, lines never interleave.
/// - Size-capped: at most `maxBytes` in two files. When the current file (devlog.txt) would pass half of it, it becomes
///   devlog.1.txt (replacing the older one) and a new devlog.txt starts. `text()` reads both, oldest first.
/// - Words and numbers only: messages pass through `redact` (file paths and URLs are cut out) and errors should be
///   described with `describe` (domain, code and a short text, without paths). Never log names, photos or kit content.
/// - Never throws and never traps: a line that cannot be written is counted in `failedWrites` and dropped.
public final class DevLog: @unchecked Sendable {
    public enum Level: String, Codable, CaseIterable {
        case debug, info, warn, error
        /// as written in a line: "DEBUG", "INFO", "WARN", "ERROR"
        public var tag: String { rawValue.uppercased() }
    }

    public static let currentName = "devlog.txt"
    public static let previousName = "devlog.1.txt"
    /// messages longer than this are cut (with "...")
    public static let maxMessageCharacters = 2000

    public let folder: URL
    /// both files together stay under this (plus one line)
    public let maxBytes: Int
    public var currentURL: URL { folder.appendingPathComponent(DevLog.currentName) }
    public var previousURL: URL { folder.appendingPathComponent(DevLog.previousName) }

    private let lock = NSLock()
    private let clock: () -> Date
    private let formatter: ISO8601DateFormatter
    private var handle: FileHandle? = nil
    private var size = 0
    private var failures = 0

    /// `folder` is created on the first line. `clock` is for tests.
    public init(folder: URL, maxBytes: Int = 1_000_000, clock: @escaping () -> Date = Date.init) {
        self.folder = folder
        self.maxBytes = max(1024, maxBytes)
        self.clock = clock
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
    }

    deinit { try? handle?.close() }

    /// Lines that could not be written (the disk full, the folder gone).
    public var failedWrites: Int { lock.lock(); defer { lock.unlock() }; return failures }

    // MARK: writing

    /// Append one line: "2026-11-18T07:15:02.123Z ERROR kit could not save the shot: ...". `area` is one short word
    /// ("kit", "recorder", "preflight", "arkit"); the message is redacted and kept on one line.
    public func log(_ level: Level, _ area: String, _ message: String) {
        lock.lock(); defer { lock.unlock() }
        let line = DevLog.line(time: formatter.string(from: clock()), level: level, area: area, message: message)
        guard let data = line.data(using: .utf8) else { return }
        do {
            if handle != nil, size > 0, size + data.count > maxBytes / 2 { rotate() }
            let h = try openIfNeeded()
            // at the end of the file even if another instance (or a relaunch) wrote to it meanwhile
            size = Int(try h.seekToEnd())
            try h.write(contentsOf: data)
            size += data.count
        } catch {
            failures += 1
            try? handle?.close()
            handle = nil
        }
    }

    public func debug(_ area: String, _ message: String) { log(.debug, area, message) }
    public func info(_ area: String, _ message: String) { log(.info, area, message) }
    public func warn(_ area: String, _ message: String) { log(.warn, area, message) }
    public func error(_ area: String, _ message: String) { log(.error, area, message) }

    /// An error line: "<what>: <describe(error)>".
    public func error(_ area: String, _ what: String, _ error: Error) { log(.error, area, what + ": " + DevLog.describe(error)) }

    /// The line as written (with its newline). Public for tests and for the app's own previews.
    public static func line(time: String, level: Level, area: String, message: String) -> String {
        "\(time) \(level.tag) \(cleanArea(area)) \(cleanMessage(message))\n"
    }

    /// One short word: letters, digits, "-" and "_" (anything else becomes "-"), at most 24 characters; "app" if empty.
    static func cleanArea(_ area: String) -> String {
        let s = String(area.prefix(24).map { c -> Character in
            c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_") ? c : "-"
        })
        return s.isEmpty ? "app" : s
    }

    /// One line, paths redacted, cut to `maxMessageCharacters`.
    static func cleanMessage(_ message: String) -> String {
        var m = message.replacingOccurrences(of: "\r\n", with: " | ")
        m = m.replacingOccurrences(of: "\n", with: " | ").replacingOccurrences(of: "\r", with: " | ").replacingOccurrences(of: "\t", with: " ")
        m = redact(m)
        if m.count > maxMessageCharacters { m = String(m.prefix(maxMessageCharacters)) + "..." }
        return m
    }

    private func openIfNeeded() throws -> FileHandle {
        if let h = handle { return h }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: currentURL.path) {
            guard fm.createFile(atPath: currentURL.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        }
        let h = try FileHandle(forWritingTo: currentURL)
        size = Int(try h.seekToEnd())
        handle = h
        if size >= maxBytes / 2 { rotate(); return try openIfNeeded() }
        return h
    }

    /// devlog.txt becomes devlog.1.txt (the older one goes); the next line starts a new devlog.txt. (Lock held.)
    private func rotate() {
        try? handle?.close()
        handle = nil
        size = 0
        let fm = FileManager.default
        try? fm.removeItem(at: previousURL)
        try? fm.moveItem(at: currentURL, to: previousURL)
    }

    // MARK: reading

    /// Everything kept, oldest line first (for Copy log). Empty when nothing was logged.
    public func text() -> String {
        lock.lock(); defer { lock.unlock() }
        var out = ""
        for u in [previousURL, currentURL] {
            if let d = try? Data(contentsOf: u) { out += String(decoding: d, as: UTF8.self) }
        }
        return out
    }

    /// The lines kept, oldest first.
    public func lines() -> [String] { text().split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }

    /// Bytes kept in both files.
    public func bytes() -> Int {
        lock.lock(); defer { lock.unlock() }
        return [previousURL, currentURL].reduce(0) { $0 + Int(KitFiles.fileSize($1.path)) }
    }

    /// Remove both files (Clear log).
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        try? handle?.close()
        handle = nil
        size = 0
        try? FileManager.default.removeItem(at: currentURL)
        try? FileManager.default.removeItem(at: previousURL)
    }

    // MARK: words and numbers only

    /// An error in words and numbers, without paths: "NSCocoaErrorDomain 640 (from NSPOSIXErrorDomain 28) out of space:
    /// <short text>". Foundation errors give their domain, code, the underlying error's domain and code, and their
    /// localized text; the app's own errors (KitStoreError, ...) give their description. Paths and URLs are redacted
    /// and the text is cut to about 300 characters.
    public static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var head = "\(ns.domain) \(ns.code)"
        let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        if let u = underlying { head += " (from \(u.domain) \(u.code))" }
        if let name = knownName(domain: ns.domain, code: ns.code) ?? underlying.flatMap({ knownName(domain: $0.domain, code: $0.code) }) {
            head += " " + name
        }
        let text: String
        if isFoundationError(error) {
            text = ns.localizedDescription
        } else {
            text = String(describing: error)
        }
        var t = redact(text.replacingOccurrences(of: "\n", with: " "))
        if t.count > 300 { t = String(t.prefix(300)) + "..." }
        return redact(head) + ": " + t
    }

    /// The phone is out of space (Cocoa's or POSIX's way of saying so, or an error caused by it).
    public static func isOutOfSpace(_ error: Error) -> Bool {
        let ns = error as NSError
        func full(_ e: NSError) -> Bool {
            (e.domain == NSCocoaErrorDomain && e.code == CocoaError.fileWriteOutOfSpace.rawValue) || (e.domain == NSPOSIXErrorDomain && e.code == 28)
        }
        if full(ns) { return true }
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return full(u) }
        return false
    }

    static func isFoundationError(_ error: Error) -> Bool {
        if error is CocoaError || error is POSIXError || error is URLError { return true }
        return type(of: error) is NSError.Type
    }

    /// Plain words for the codes a phone run is likely to hit.
    static func knownName(domain: String, code: Int) -> String? {
        switch (domain, code) {
        case (NSCocoaErrorDomain, 640), (NSPOSIXErrorDomain, 28): return "out of space"
        case (NSCocoaErrorDomain, 4), (NSCocoaErrorDomain, 260), (NSPOSIXErrorDomain, 2): return "no such file"
        case (NSCocoaErrorDomain, 257), (NSCocoaErrorDomain, 513), (NSPOSIXErrorDomain, 1), (NSPOSIXErrorDomain, 13): return "no permission"
        case (NSCocoaErrorDomain, 516), (NSPOSIXErrorDomain, 17): return "already exists"
        case (NSPOSIXErrorDomain, 5): return "input/output error"
        default: return nil
        }
    }

    /// File types the app writes: a path ending in one of these keeps its file name ("<path>/kit.json"); any other
    /// path is cut out whole ("<path>"), since a folder or file name may be a person's.
    static let keptExtensions: Set<String> = ["json", "jsonl", "mp4", "mov", "zip", "bdp2", "txt", "deflate", "bin", "jpg", "png"]

    /// Cut file paths and URLs out of a text: "file:///var/mobile/.../kit.json" and "/var/mobile/.../kit.json" become
    /// "<path>/kit.json", "/Users/name/notes" becomes "<path>", "https://..." becomes "<url>". A path is taken to start
    /// at "/" or "~/" after a space, a quote, a bracket or the start, and to run to the next space, quote or closing
    /// bracket, or on over a space when the next word continues it ("Application Support/Kits"). Ratios like "3/4" and
    /// a lone " / " are left alone.
    public static func redact(_ text: String) -> String {
        let c = Array(text)
        var out = ""
        var i = 0
        while i < c.count {
            if let (end, isURL, isFile) = pathOrURL(c, at: i) {
                var e = end
                // trailing punctuation belongs to the sentence
                while e > i + 1, ".,:;!?".contains(c[e - 1]) { e -= 1 }
                var token = String(c[i..<e])
                if isURL && !isFile {
                    out += "<url>"
                } else {
                    if isFile, let r = token.range(of: "://") { token = String(token[r.upperBound...]) }
                    out += redactedPath(token)
                }
                i = e
            } else {
                out.append(c[i])
                i += 1
            }
        }
        return out
    }

    static let opening: Set<Character> = [" ", "\t", "\"", "'", "\u{201C}", "\u{2018}", "(", "[", "<", "=", ":", ","]
    static let closing: Set<Character> = [" ", "\t", "\n", "\"", "'", "\u{201D}", "\u{2019}", "\u{201C}", ")", "]", ">", ","]

    /// Where a path or URL starting at `i` ends (exclusive), and what it is; nil if none starts there.
    static func pathOrURL(_ c: [Character], at i: Int) -> (end: Int, isURL: Bool, isFile: Bool)? {
        let boundary = i == 0 || opening.contains(c[i - 1])
        guard boundary else { return nil }
        var isURL = false, isFile = false
        var j = i
        if c[i].isLetter {
            // scheme://
            var k = i
            while k < c.count, c[k].isLetter || c[k].isNumber || c[k] == "+" || c[k] == "." || c[k] == "-" { k += 1 }
            guard k + 2 < c.count, c[k] == ":", c[k + 1] == "/", c[k + 2] == "/" else { return nil }
            isURL = true
            isFile = String(c[i..<k]).lowercased() == "file"
            j = k + 3
        } else if c[i] == "/" {
            guard i + 1 < c.count, !closing.contains(c[i + 1]) else { return nil }
            j = i + 1
        } else if c[i] == "~" {
            guard i + 1 < c.count, c[i + 1] == "/" else { return nil }
            j = i + 2
        } else {
            return nil
        }
        while true {
            while j < c.count, !closing.contains(c[j]) { j += 1 }
            // a space inside a path: go on when the next word continues it ("Application Support/Kits/...")
            guard j < c.count, c[j] == " " else { break }
            var k = j + 1
            while k < c.count, !closing.contains(c[k]) { k += 1 }
            let word = c[(j + 1)..<k]
            guard !word.isEmpty, word.first != "/", word.contains("/") else { break }
            j = k
        }
        return (j, isURL, isFile)
    }

    static func redactedPath(_ path: String) -> String {
        let last = path.split(separator: "/").last.map(String.init) ?? ""
        let ext = (last as NSString).pathExtension.lowercased()
        let safe = !ext.isEmpty && keptExtensions.contains(ext) && last.count <= 64
            && last.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
        return safe ? "<path>/" + last : "<path>"
    }
}
