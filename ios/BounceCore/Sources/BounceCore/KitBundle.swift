import Foundation

// The bundle the owner shares (CaptureKit.md, "Bundle"): the kit folder as one or more zip parts
// "<kitId>-partNofM.zip", each at most 24,000,000 bytes (GitHub's web upload takes files up to 25 MiB), each a valid zip
// of whole files with paths starting "<kitId>/", every part carrying kit.json. Unzipping all parts into one folder
// rebuilds the kit. Video is stored as is; JSON, JSONL and depth are deflated by a compressor the caller passes in
// (the app: Apple's Compression framework, raw DEFLATE).

/// Compresses bytes to raw DEFLATE (RFC 1951, no zlib header); nil if it cannot.
public typealias KitDeflater = (Data) -> Data?

public enum KitBundleError: Error, Equatable, CustomStringConvertible {
    /// the folder has no kit.json
    case notAKit(String)
    /// a file too large for a classic zip (4 GB), or too many files in one part
    case tooLarge(String)
    /// a file changed size while it was being zipped
    case changed(String)
    /// the part limit is too small to hold even kit.json
    case limitTooSmall(Int64)
    case closed

    public var description: String {
        switch self {
        case let .notAKit(p): return "not a kit: \(p)"
        case let .tooLarge(n): return "too large for a zip: \(n)"
        case let .changed(n): return "file changed while zipping: \(n)"
        case let .limitTooSmall(l): return "part limit \(l) bytes is too small"
        case .closed: return "the zip is closed"
        }
    }
}

/// A zip file written entry by entry without holding whole files in memory: stored entries are streamed from disk in
/// chunks (the CRC is computed on the way and patched into the header), deflated entries come from a compressor.
/// Classic zip only (under 4 GB, under 65,535 entries), UTF-8 names, a fixed timestamp so archives are reproducible.
public final class KitZipWriter {
    public enum Method: UInt16 { case stored = 0, deflated = 8 }

    struct Entry { var name: [UInt8]; var method: Method; var crc: UInt32; var compressed: UInt32; var size: UInt32; var offset: UInt32 }

    public let url: URL
    public private(set) var bytesWritten: Int64 = 0
    public private(set) var names: [String] = []
    private var handle: FileHandle?
    private var entries: [Entry] = []

    /// local header (30) + central directory entry (46), plus the name twice
    public static func entryCost(name: String, payloadBytes: Int64) -> Int64 { 76 + 2 * Int64(name.utf8.count) + payloadBytes }
    public static let endRecordBytes: Int64 = 22
    // 1 Jan 2020, 00:00 (as ZipWriter)
    static let dosTime: UInt16 = 0, dosDate: UInt16 = UInt16(((2020 - 1980) << 9) | (1 << 5) | 1)

    /// Creates (or truncates) the file.
    public init(url: URL) throws {
        self.url = url
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
    }

    deinit { try? handle?.close() }

    static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 255), UInt8(v >> 8)] }
    static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8(v >> 24)] }

    private func write(_ d: Data) throws {
        guard let h = handle else { throw KitBundleError.closed }
        try h.write(contentsOf: d)
        bytesWritten += Int64(d.count)
    }

    private func localHeader(_ e: Entry) -> Data {
        var d = Data()
        d.append(contentsOf: Self.le32(0x0403_4B50)); d.append(contentsOf: Self.le16(20)); d.append(contentsOf: Self.le16(0x0800))
        d.append(contentsOf: Self.le16(e.method.rawValue)); d.append(contentsOf: Self.le16(Self.dosTime)); d.append(contentsOf: Self.le16(Self.dosDate))
        d.append(contentsOf: Self.le32(e.crc)); d.append(contentsOf: Self.le32(e.compressed)); d.append(contentsOf: Self.le32(e.size))
        d.append(contentsOf: Self.le16(UInt16(e.name.count))); d.append(contentsOf: Self.le16(0)); d.append(contentsOf: e.name)
        return d
    }

    private func begin(name: String, method: Method, crc: UInt32, compressed: Int64, size: Int64) throws -> Entry {
        guard handle != nil else { throw KitBundleError.closed }
        let nameBytes = [UInt8](name.utf8)
        guard nameBytes.count < 65535, compressed < Int64(UInt32.max), size < Int64(UInt32.max), bytesWritten < Int64(UInt32.max),
              entries.count < 65534 else { throw KitBundleError.tooLarge(name) }
        let e = Entry(name: nameBytes, method: method, crc: crc, compressed: UInt32(compressed), size: UInt32(size), offset: UInt32(bytesWritten))
        try write(localHeader(e))
        return e
    }

    /// Stream a file's bytes into the zip (`payloadBytes` of them), returning their CRC.
    private func stream(_ source: URL, payloadBytes: Int64, chunkSize: Int, name: String) throws -> UInt32 {
        let src = try FileHandle(forReadingFrom: source)
        defer { try? src.close() }
        var crc: UInt32 = 0, total: Int64 = 0
        while true {
            guard let chunk = try src.read(upToCount: max(1, chunkSize)), !chunk.isEmpty else { break }
            crc = CRC32.checksum(chunk, initial: crc)
            total += Int64(chunk.count)
            guard total <= payloadBytes else { throw KitBundleError.changed(name) }
            try write(chunk)
        }
        guard total == payloadBytes else { throw KitBundleError.changed(name) }
        return crc
    }

    /// Add a file stored as is, read in chunks of `chunkSize` bytes.
    public func addFile(name: String, from source: URL, chunkSize: Int = 1 << 20) throws {
        let size = KitFiles.fileSize(source.path)
        var e = try begin(name: name, method: .stored, crc: 0, compressed: size, size: size)
        e.crc = try stream(source, payloadBytes: size, chunkSize: chunkSize, name: name)
        // patch the CRC into the local header (offset 14)
        guard let h = handle else { throw KitBundleError.closed }
        try h.seek(toOffset: UInt64(e.offset) + 14)
        try h.write(contentsOf: Data(Self.le32(e.crc)))
        _ = try h.seekToEnd()
        entries.append(e); names.append(name)
    }

    /// Add an entry whose payload, already compressed with `method`, is in a file; `crc` and `uncompressedSize` describe
    /// the original bytes.
    public func addPayload(name: String, method: Method, crc: UInt32, uncompressedSize: Int64, payload: URL, chunkSize: Int = 1 << 20) throws {
        let p = KitFiles.fileSize(payload.path)
        let e = try begin(name: name, method: method, crc: crc, compressed: p, size: uncompressedSize)
        _ = try stream(payload, payloadBytes: p, chunkSize: chunkSize, name: name)
        entries.append(e); names.append(name)
    }

    /// Add bytes from memory: deflated when `deflate` is given and makes them smaller, else stored. Returns the method.
    @discardableResult
    public func addData(name: String, data: Data, deflate: KitDeflater? = nil) throws -> Method {
        let crc = CRC32.checksum(data)
        if let f = deflate, let c = f(data), c.count < data.count {
            let e = try begin(name: name, method: .deflated, crc: crc, compressed: Int64(c.count), size: Int64(data.count))
            try write(c)
            entries.append(e); names.append(name)
            return .deflated
        }
        let e = try begin(name: name, method: .stored, crc: crc, compressed: Int64(data.count), size: Int64(data.count))
        try write(data)
        entries.append(e); names.append(name)
        return .stored
    }

    /// Write the central directory and close. Returns the zip's size in bytes.
    @discardableResult
    public func finish() throws -> Int64 {
        guard handle != nil else { throw KitBundleError.closed }
        let cdOffset = bytesWritten
        var cd = Data()
        for e in entries {
            cd.append(contentsOf: Self.le32(0x0201_4B50)); cd.append(contentsOf: Self.le16(20)); cd.append(contentsOf: Self.le16(20))
            cd.append(contentsOf: Self.le16(0x0800)); cd.append(contentsOf: Self.le16(e.method.rawValue))
            cd.append(contentsOf: Self.le16(Self.dosTime)); cd.append(contentsOf: Self.le16(Self.dosDate))
            cd.append(contentsOf: Self.le32(e.crc)); cd.append(contentsOf: Self.le32(e.compressed)); cd.append(contentsOf: Self.le32(e.size))
            cd.append(contentsOf: Self.le16(UInt16(e.name.count))); cd.append(contentsOf: Self.le16(0)); cd.append(contentsOf: Self.le16(0))
            cd.append(contentsOf: Self.le16(0)); cd.append(contentsOf: Self.le16(0)); cd.append(contentsOf: Self.le32(0))
            cd.append(contentsOf: Self.le32(e.offset)); cd.append(contentsOf: e.name)
        }
        guard cdOffset + Int64(cd.count) < Int64(UInt32.max) else { throw KitBundleError.tooLarge(url.lastPathComponent) }
        try write(cd)
        var end = Data()
        end.append(contentsOf: Self.le32(0x0605_4B50)); end.append(contentsOf: Self.le16(0)); end.append(contentsOf: Self.le16(0))
        end.append(contentsOf: Self.le16(UInt16(entries.count))); end.append(contentsOf: Self.le16(UInt16(entries.count)))
        end.append(contentsOf: Self.le32(UInt32(cd.count))); end.append(contentsOf: Self.le32(UInt32(cdOffset))); end.append(contentsOf: Self.le16(0))
        try write(end)
        try handle?.close()
        handle = nil
        return bytesWritten
    }
}

/// One zip part of a bundle.
public struct KitBundlePart: Equatable {
    /// 1-based
    public var index: Int
    public var count: Int
    /// "<kitId>-part2of3.zip"
    public var name: String
    public var url: URL
    public var bytes: Int64
    /// entry names in the order written (kit.json first)
    public var entries: [String]
    /// holds a single file larger than the limit (so the part is larger too)
    public var oversized: Bool
}

/// What `KitBundle.build` made.
public struct KitBundleResult: Equatable {
    public var parts: [KitBundlePart]
    /// entry names of files larger than the limit (each in a part of its own)
    public var oversized: [String]
    /// entry names stored deflated (the rest are stored as is)
    public var deflated: [String]
    public var totalBytes: Int64
    public var urls: [URL] { parts.map { $0.url } }
}

/// Builds a kit's bundle parts.
public enum KitBundle {
    public static let defaultLimit: Int64 = 24_000_000
    /// files with these extensions are deflated (when a compressor is given and it helps); everything else is stored
    public static let deflatedExtensions: Set<String> = ["json", "jsonl", "bdp2"]

    public static func shouldDeflate(_ name: String) -> Bool {
        deflatedExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// "<kitId>-part1of3.zip"
    public static func partName(kitId: String, index: Int, count: Int) -> String { "\(kitId)-part\(index)of\(count).zip" }

    /// Parts of this kit already in a folder (from an earlier build).
    public static func existingParts(kitId: String, in outbox: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: outbox.path)) ?? []
        return names.filter { $0.hasPrefix(kitId + "-part") && $0.hasSuffix(".zip") }.sorted().map { outbox.appendingPathComponent($0) }
    }

    /// Files of a kit folder that go into the bundle (relative paths, sorted): everything except unfinished attempts,
    /// interrupted commits and skips, and hidden files.
    public static func files(in kitFolder: URL) -> [String] {
        KitFiles.regularFiles(in: kitFolder).filter { rel in
            !rel.split(separator: "/").contains {
                $0.hasPrefix(".") || $0.hasSuffix(KitStore.attemptSuffix) || $0.hasSuffix(KitStore.oldSuffix) || $0.hasSuffix(KitStore.trashSuffix)
            }
        }
    }

    /// The hidden working folder of a build: ".<kitId>-bundle-<uuid>" in the outbox.
    static func scratchPrefix(kitId: String) -> String { ".\(kitId)-bundle-" }

    /// Remove what a build killed part-way left in the outbox (its hidden working folder, with the deflated copies and
    /// any parts written so far). `build` does this first; the app can also call it at launch.
    public static func removeLeftovers(kitId: String, in outbox: URL) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: outbox.path)) ?? [] where name.hasPrefix(scratchPrefix(kitId: kitId)) {
            try? fm.removeItem(at: outbox.appendingPathComponent(name))
        }
    }

    struct Prepared {
        var name: String
        var source: URL
        var method: KitZipWriter.Method
        var crc: UInt32
        var size: Int64
        var payload: URL
        var payloadBytes: Int64
        var cost: Int64
    }

    /// Zip the kit folder into parts in `outbox` (created if needed; earlier parts of the same kit there are replaced).
    /// Files are packed whole, first fit in path order, each part at most `limit` bytes; kit.json goes into every part.
    /// A file that cannot fit even alone gets a part of its own (larger than the limit) and is reported. Files are read
    /// in chunks of `chunkSize`; only files to be deflated are read whole (they are small). The parts are written in a
    /// hidden working folder and get their names in the outbox only once all of them are complete, so a half-written
    /// part never carries a part name; a working folder left by a build that was killed is removed first. On failure
    /// nothing is left behind in the outbox.
    public static func build(kitFolder: URL, outbox: URL, limit: Int64 = defaultLimit, deflate: KitDeflater? = nil,
                             chunkSize: Int = 1 << 20) throws -> KitBundleResult {
        let fm = FileManager.default
        let kitId = kitFolder.lastPathComponent
        guard fm.fileExists(atPath: kitFolder.appendingPathComponent(KitStore.manifestFile).path) else { throw KitBundleError.notAKit(kitId) }
        try fm.createDirectory(at: outbox, withIntermediateDirectories: true)
        removeLeftovers(kitId: kitId, in: outbox)
        for old in existingParts(kitId: kitId, in: outbox) { try fm.removeItem(at: old) }
        let scratch = outbox.appendingPathComponent(scratchPrefix(kitId: kitId) + UUID().uuidString)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        // prepare: deflate what should be (into scratch files), measure the rest
        var prepared: [Prepared] = []
        for (n, rel) in files(in: kitFolder).enumerated() {
            let src = kitFolder.appendingPathComponent(rel), name = kitId + "/" + rel
            let size = KitFiles.fileSize(src.path)
            guard size < Int64(UInt32.max) else { throw KitBundleError.tooLarge(name) }
            var p = Prepared(name: name, source: src, method: .stored, crc: 0, size: size, payload: src, payloadBytes: size, cost: 0)
            if let f = deflate, shouldDeflate(rel) {
                let data = try Data(contentsOf: src)
                if let c = f(data), c.count < data.count {
                    let out = scratch.appendingPathComponent(String(format: "%06d.deflate", n))
                    try c.write(to: out)
                    p.method = .deflated; p.crc = CRC32.checksum(data); p.size = Int64(data.count)
                    p.payload = out; p.payloadBytes = Int64(c.count)
                }
            }
            p.cost = KitZipWriter.entryCost(name: name, payloadBytes: p.payloadBytes)
            prepared.append(p)
        }
        let manifestName = kitId + "/" + KitStore.manifestFile
        guard let kitEntry = prepared.first(where: { $0.name == manifestName }) else { throw KitBundleError.notAKit(kitId) }
        let others = prepared.filter { $0.name != manifestName }

        // plan: first fit in path order
        let capacity = limit - KitZipWriter.endRecordBytes - kitEntry.cost
        guard capacity > 0 else { throw KitBundleError.limitTooSmall(limit) }
        var parts: [[Int]] = [], room: [Int64] = [], oversizedPart: [Bool] = []
        for (i, p) in others.enumerated() {
            if p.cost > capacity {
                parts.append([i]); room.append(0); oversizedPart.append(true)
                continue
            }
            if let j = room.indices.first(where: { !oversizedPart[$0] && room[$0] >= p.cost && parts[$0].count < 65000 }) {
                parts[j].append(i); room[j] -= p.cost
            } else {
                parts.append([i]); room.append(capacity - p.cost); oversizedPart.append(false)
            }
        }
        if parts.isEmpty { parts = [[]]; oversizedPart = [false] }

        // write, in the working folder
        var result: [KitBundlePart] = []
        let partsFolder = scratch.appendingPathComponent("parts")
        try fm.createDirectory(at: partsFolder, withIntermediateDirectories: true)
        for (k, members) in parts.enumerated() {
            let name = partName(kitId: kitId, index: k + 1, count: parts.count)
            let z = try KitZipWriter(url: partsFolder.appendingPathComponent(name))
            for p in [kitEntry] + members.map({ others[$0] }) {
                if p.method == .deflated {
                    try z.addPayload(name: p.name, method: .deflated, crc: p.crc, uncompressedSize: p.size, payload: p.payload, chunkSize: chunkSize)
                } else {
                    try z.addFile(name: p.name, from: p.source, chunkSize: chunkSize)
                }
            }
            let bytes = try z.finish()
            result.append(KitBundlePart(index: k + 1, count: parts.count, name: name, url: outbox.appendingPathComponent(name), bytes: bytes,
                                        entries: z.names, oversized: oversizedPart[k]))
        }
        // all complete: give them their names in the outbox
        var moved: [URL] = []
        do {
            for p in result {
                try fm.moveItem(at: partsFolder.appendingPathComponent(p.name), to: p.url)
                moved.append(p.url)
            }
        } catch {
            for u in moved { try? fm.removeItem(at: u) }
            throw error
        }
        return KitBundleResult(parts: result, oversized: zip(parts, oversizedPart).filter { $0.1 }.flatMap { $0.0.map { others[$0].name } },
                               deflated: prepared.filter { $0.method == .deflated }.map { $0.name },
                               totalBytes: result.reduce(0) { $0 + $1.bytes })
    }
}
