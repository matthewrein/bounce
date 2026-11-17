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
public enum ZipWriter {
    public enum ZipError: Error { case tooLarge, notAFolder }

    /// Zip every regular file under `folder` (recursively) into `destination`, with paths starting at the folder's name.
    public static func zip(folder: URL, to destination: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { throw ZipError.notAFolder }
        let root = folder.lastPathComponent
        var entries: [(String, URL)] = []
        if let en = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in en {
                let v = try url.resourceValues(forKeys: [.isRegularFileKey])
                guard v.isRegularFile == true else { continue }
                let rel = url.standardizedFileURL.path.replacingOccurrences(of: folder.standardizedFileURL.path + "/", with: "")
                entries.append((root + "/" + rel, url))
            }
        }
        entries.sort { $0.0 < $1.0 }
        try write(entries: entries.map { e -> (String, () throws -> Data) in let u = e.1; return (e.0, { try Data(contentsOf: u) }) }, to: destination)
    }

    /// Write entries (name, data provider) as a stored zip.
    public static func write(entries: [(String, () throws -> Data)], to destination: URL) throws {
        _ = FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        var central = Data(), offset: UInt64 = 0
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 255), UInt8((v >> 8) & 255)] }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8(v >> 24)] }
        // a fixed timestamp (1 Jan 2020) keeps archives reproducible
        let dosTime = 0, dosDate = ((2020 - 1980) << 9) | (1 << 5) | 1
        for (name, provide) in entries {
            let data = try provide(), nameBytes = [UInt8](name.utf8)
            guard data.count < Int(UInt32.max), offset < UInt64(UInt32.max) else { throw ZipError.tooLarge }
            let crc = CRC32.checksum(data), size = UInt32(data.count)
            var local = Data()
            local.append(contentsOf: le32(0x0403_4B50)); local.append(contentsOf: le16(20)); local.append(contentsOf: le16(0x0800)) // UTF-8 names
            local.append(contentsOf: le16(0)); local.append(contentsOf: le16(dosTime)); local.append(contentsOf: le16(dosDate))
            local.append(contentsOf: le32(crc)); local.append(contentsOf: le32(size)); local.append(contentsOf: le32(size))
            local.append(contentsOf: le16(nameBytes.count)); local.append(contentsOf: le16(0)); local.append(contentsOf: nameBytes)
            out.write(local); out.write(data)
            central.append(contentsOf: le32(0x0201_4B50)); central.append(contentsOf: le16(20)); central.append(contentsOf: le16(20))
            central.append(contentsOf: le16(0x0800)); central.append(contentsOf: le16(0)); central.append(contentsOf: le16(dosTime)); central.append(contentsOf: le16(dosDate))
            central.append(contentsOf: le32(crc)); central.append(contentsOf: le32(size)); central.append(contentsOf: le32(size))
            central.append(contentsOf: le16(nameBytes.count)); central.append(contentsOf: le16(0)); central.append(contentsOf: le16(0))
            central.append(contentsOf: le16(0)); central.append(contentsOf: le16(0)); central.append(contentsOf: le32(0)); central.append(contentsOf: le32(UInt32(offset)))
            central.append(contentsOf: nameBytes)
            offset += UInt64(local.count + data.count)
        }
        guard entries.count < 65535, offset < UInt64(UInt32.max) else { throw ZipError.tooLarge }
        var end = Data()
        end.append(contentsOf: le32(0x0605_4B50)); end.append(contentsOf: le16(0)); end.append(contentsOf: le16(0))
        end.append(contentsOf: le16(entries.count)); end.append(contentsOf: le16(entries.count))
        end.append(contentsOf: le32(UInt32(central.count))); end.append(contentsOf: le32(UInt32(offset))); end.append(contentsOf: le16(0))
        out.write(central); out.write(end)
    }
}
