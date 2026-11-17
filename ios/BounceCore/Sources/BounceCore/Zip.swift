import Foundation

/// CRC-32 (IEEE 802.3), as zip files use.
public enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }
    public static func checksum<S: Sequence>(_ bytes: S, initial: UInt32 = 0) -> UInt32 where S.Element == UInt8 {
        var c = ~initial
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return ~c
    }
}

/// Writes a plain zip archive (files stored without compression, which every unzip tool reads). Used to share a
/// recording folder as one file. Stays within the classic zip limits (under 4 GB, under 65,535 files).
///
/// Every failure throws (a full disk or any other IO error included; nothing here traps), and a failed archive is
/// removed rather than left half-written.
public enum ZipWriter {
    /// Hashable, as it was before `notEnoughSpace` came (an associated value ends the implicit conformance).
    public enum ZipError: Error, Hashable, LocalizedError {
        case tooLarge, notAFolder
        /// the archive needs `needed` bytes and only `available` are free
        case notEnoughSpace(needed: Int64, available: Int64)

        public var errorDescription: String? {
            switch self {
            case .tooLarge: return "the recording is too large to zip (over 4 GB or 65,535 files)"
            case .notAFolder: return "the recording's folder is missing"
            case let .notEnoughSpace(n, a):
                return "not enough free space to zip the recording (needs \(n / 1_000_000) MB, \(a / 1_000_000) MB free)"
            }
        }
    }

    /// The regular files under `folder` (recursively) as zip entries named from the folder's own name, sorted.
    static func entries(of folder: URL) throws -> [(name: String, url: URL, size: Int)] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { throw ZipError.notAFolder }
        let root = folder.lastPathComponent
        var entries: [(name: String, url: URL, size: Int)] = []
        if let en = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            for case let url as URL in en {
                let v = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard v.isRegularFile == true else { continue }
                let rel = url.standardizedFileURL.path.replacingOccurrences(of: folder.standardizedFileURL.path + "/", with: "")
                entries.append((root + "/" + rel, url, v.fileSize ?? 0))
            }
        }
        entries.sort { $0.name < $1.name }
        return entries
    }

    /// The size (bytes) the zip of `folder` will have.
    public static func archiveSize(folder: URL) throws -> Int64 {
        archiveSize(try entries(of: folder).map { ($0.name, $0.size) })
    }

    static func archiveSize(_ entries: [(name: String, size: Int)]) -> Int64 {
        // local header 30 + name, data, central header 46 + name; end record 22
        entries.reduce(Int64(22)) { $0 + Int64(30 + 46 + 2 * $1.name.utf8.count + $1.size) }
    }

    /// Zip every regular file under `folder` (recursively) into `destination`, with paths starting at the folder's name.
    /// `availableBytes`: the free space where the zip goes, if known (on iOS: the volume's capacity for important
    /// usage); the zip is refused before anything is written if it would not fit.
    public static func zip(folder: URL, to destination: URL, availableBytes: Int64? = nil) throws {
        let entries = try entries(of: folder)
        let size = archiveSize(entries.map { ($0.name, $0.size) })
        if let a = availableBytes, size > a { throw ZipError.notEnoughSpace(needed: size, available: a) }
        try write(entries: entries.map { e -> (String, () throws -> Data) in let u = e.url; return (e.name, { try Data(contentsOf: u) }) }, to: destination)
    }

    /// Write entries (name, data provider) as a stored zip. On any failure the partial file is removed.
    public static func write(entries: [(String, () throws -> Data)], to destination: URL) throws {
        guard entries.count < 65535 else { throw ZipError.tooLarge }
        let fm = FileManager.default
        guard fm.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }
        do {
            let out = try FileHandle(forWritingTo: destination)
            defer { try? out.close() }
            try write(entries: entries, to: out)
            try out.synchronize()
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    /// The archive's bytes to an open handle (tests use one that fails).
    static func write(entries: [(String, () throws -> Data)], to out: FileHandle) throws {
        guard entries.count < 65535 else { throw ZipError.tooLarge }
        var central = Data(), offset: UInt64 = 0
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 255), UInt8((v >> 8) & 255)] }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8(v >> 24)] }
        // a fixed timestamp (1 Jan 2020) keeps archives reproducible
        let dosTime = 0, dosDate = ((2020 - 1980) << 9) | (1 << 5) | 1
        for (name, provide) in entries {
            let data = try provide(), nameBytes = [UInt8](name.utf8)
            guard data.count < Int(UInt32.max), offset + UInt64(30 + nameBytes.count + data.count) < UInt64(UInt32.max) else { throw ZipError.tooLarge }
            let crc = CRC32.checksum(data), size = UInt32(data.count)
            var local = Data()
            local.append(contentsOf: le32(0x0403_4B50)); local.append(contentsOf: le16(20)); local.append(contentsOf: le16(0x0800)) // UTF-8 names
            local.append(contentsOf: le16(0)); local.append(contentsOf: le16(dosTime)); local.append(contentsOf: le16(dosDate))
            local.append(contentsOf: le32(crc)); local.append(contentsOf: le32(size)); local.append(contentsOf: le32(size))
            local.append(contentsOf: le16(nameBytes.count)); local.append(contentsOf: le16(0)); local.append(contentsOf: nameBytes)
            // the throwing writes: the old write(_:) raised an Objective-C exception on a full disk, which crashed the app
            try out.write(contentsOf: local); try out.write(contentsOf: data)
            central.append(contentsOf: le32(0x0201_4B50)); central.append(contentsOf: le16(20)); central.append(contentsOf: le16(20))
            central.append(contentsOf: le16(0x0800)); central.append(contentsOf: le16(0)); central.append(contentsOf: le16(dosTime)); central.append(contentsOf: le16(dosDate))
            central.append(contentsOf: le32(crc)); central.append(contentsOf: le32(size)); central.append(contentsOf: le32(size))
            central.append(contentsOf: le16(nameBytes.count)); central.append(contentsOf: le16(0)); central.append(contentsOf: le16(0))
            central.append(contentsOf: le16(0)); central.append(contentsOf: le16(0)); central.append(contentsOf: le32(0)); central.append(contentsOf: le32(UInt32(offset)))
            central.append(contentsOf: nameBytes)
            offset += UInt64(local.count + data.count)
        }
        guard offset + UInt64(central.count) < UInt64(UInt32.max) else { throw ZipError.tooLarge }
        var end = Data()
        end.append(contentsOf: le32(0x0605_4B50)); end.append(contentsOf: le16(0)); end.append(contentsOf: le16(0))
        end.append(contentsOf: le16(entries.count)); end.append(contentsOf: le16(entries.count))
        end.append(contentsOf: le32(UInt32(central.count))); end.append(contentsOf: le32(UInt32(offset))); end.append(contentsOf: le16(0))
        try out.write(contentsOf: central); try out.write(contentsOf: end)
    }
}

/// Free space for recordings.
public enum RecordingStorage {
    /// Free bytes on the volume holding `url` (the file system's free size; on iOS prefer the volume's capacity for
    /// important usage, which counts space the system would free). nil if unknown.
    public static func freeBytes(at url: URL) -> Int64? {
        let a = try? FileManager.default.attributesOfFileSystem(forPath: url.path)
        return (a?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    /// The bytes under a folder (its regular files).
    public static func size(of folder: URL) throws -> Int64 {
        try ZipWriter.entries(of: folder).reduce(Int64(0)) { $0 + Int64($1.size) }
    }
}
