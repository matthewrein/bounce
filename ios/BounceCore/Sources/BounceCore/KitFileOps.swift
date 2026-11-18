import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The kit store's file operations. Every change `KitStore` makes on disk goes through one of these, so a test can make
/// any of them fail (a full disk) or copy the kit folder just before each one (the app killed at that point).
///
/// JSON files (kit.json, shot.json) are written with `writeAtomically`: the bytes go to a hidden temporary file in the
/// same folder (".kit.json.writing-<uuid>"), are flushed to storage, and the file is then renamed over the old one in one
/// step. A kill or a full disk part-way leaves the old file whole; `KitStore.load` removes the temporary file left behind.
public struct KitFileOps {
    /// Create (or truncate) a file with these bytes and flush it to storage. Not atomic on its own.
    public var writeFile: (Data, URL) throws -> Void
    /// Rename a file over another (replacing it in one step; POSIX rename).
    public var replace: (URL, URL) throws -> Void
    /// Move a file or folder to a free name (throws if the name is taken).
    public var move: (URL, URL) throws -> Void
    /// Remove a file or folder.
    public var remove: (URL) throws -> Void
    /// Create a folder and its parents (fine if it exists).
    public var makeFolder: (URL) throws -> Void

    public init(writeFile: @escaping (Data, URL) throws -> Void, replace: @escaping (URL, URL) throws -> Void,
                move: @escaping (URL, URL) throws -> Void, remove: @escaping (URL) throws -> Void, makeFolder: @escaping (URL) throws -> Void) {
        self.writeFile = writeFile; self.replace = replace; self.move = move; self.remove = remove; self.makeFolder = makeFolder
    }

    /// The real file system.
    public static let standard = KitFileOps(
        writeFile: { data, url in
            try data.write(to: url)
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            try h.synchronize()
        },
        replace: { from, to in
            guard rename(from.path, to.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        },
        move: { from, to in try FileManager.default.moveItem(at: from, to: to) },
        remove: { url in try FileManager.default.removeItem(at: url) },
        makeFolder: { url in try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) })

    /// The standard operations, each preceded by `before(op, url)` with op "write", "replace", "move", "remove" or
    /// "folder" (the url is the file written, or the source of a rename or move). `before` may throw to fail that one.
    public static func observed(_ before: @escaping (_ op: String, _ url: URL) throws -> Void) -> KitFileOps {
        let s = standard
        return KitFileOps(writeFile: { d, u in try before("write", u); try s.writeFile(d, u) },
                          replace: { a, b in try before("replace", a); try s.replace(a, b) },
                          move: { a, b in try before("move", a); try s.move(a, b) },
                          remove: { u in try before("remove", u); try s.remove(u) },
                          makeFolder: { u in try before("folder", u); try s.makeFolder(u) })
    }

    /// what marks a temporary file: ".<name>.writing-<uuid>"
    static let tempMarker = ".writing-"

    /// The temporary file `writeAtomically` uses for `url`.
    static func tempURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + tempMarker + UUID().uuidString)
    }

    /// A temporary file of `writeAtomically`, or of Foundation's own atomic writes (which earlier builds used for kit.json
    /// and shot.json): hidden, and named after one of the kit's JSON files.
    static func isLeftoverTemp(_ name: String) -> Bool {
        guard name.hasPrefix(".") else { return false }
        if name.contains(tempMarker) { return true }
        if name.hasPrefix(".dat.nosync") { return true }
        return [KitStore.manifestFile, KitStore.shotManifestFile].contains { name.hasPrefix("." + $0) }
    }

    /// Write `data` to `url` all or nothing: a hidden temporary file, flushed, then renamed over `url`. On failure the
    /// temporary file is removed (best effort) and `url` is as it was.
    public func writeAtomically(_ data: Data, to url: URL) throws {
        let tmp = KitFileOps.tempURL(for: url)
        do {
            try writeFile(data, tmp)
            try replace(tmp, url)
        } catch {
            if FileManager.default.fileExists(atPath: tmp.path) { try? remove(tmp) }
            throw error
        }
    }

    /// Remove the temporary files left in a folder (not recursive). Returns how many were removed.
    @discardableResult
    func removeLeftoverTemps(in folder: URL) -> Int {
        var n = 0
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where KitFileOps.isLeftoverTemp(name) {
            if (try? remove(folder.appendingPathComponent(name))) != nil { n += 1 }
        }
        return n
    }
}
