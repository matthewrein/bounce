import XCTest
@testable import BounceCore

/// Tiny raw-DEFLATE encoders (RFC 1951) for the tests: the app uses Apple's Compression framework, which Linux lacks.
enum KitTestDeflate {
    /// Stored blocks only (BTYPE=00): valid DEFLATE that never shrinks anything.
    static func stored(_ d: Data) -> Data {
        let b = [UInt8](d)
        var out: [UInt8] = []
        var i = 0
        repeat {
            let n = min(65535, b.count - i), final = i + n >= b.count
            let len = UInt16(n), nlen = ~len
            out.append(final ? 1 : 0)
            out += [UInt8(len & 255), UInt8(len >> 8), UInt8(nlen & 255), UInt8(nlen >> 8)]
            out += b[i..<(i + n)]
            i += n
        } while i < b.count
        return Data(out)
    }

    struct Bits {
        var out: [UInt8] = []
        var acc: UInt32 = 0
        var n = 0
        mutating func put(_ v: UInt32, _ bits: Int) {
            acc |= v << n; n += bits
            while n >= 8 { out.append(UInt8(acc & 255)); acc >>= 8; n -= 8 }
        }
        /// Huffman codes go most significant bit first
        mutating func code(_ c: UInt32, _ len: Int) {
            var r: UInt32 = 0
            for i in 0..<len { r |= ((c >> i) & 1) << (len - 1 - i) }
            put(r, len)
        }
        mutating func flush() { if n > 0 { out.append(UInt8(acc & 255)); acc = 0; n = 0 } }
    }

    static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097,
                           6145, 8193, 12289, 16385, 24577]
    static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    static func symbol(_ w: inout Bits, _ s: Int) {
        switch s {
        case 0...143: w.code(UInt32(0x30 + s), 8)
        case 144...255: w.code(UInt32(0x190 + s - 144), 9)
        case 256...279: w.code(UInt32(s - 256), 7)
        default: w.code(UInt32(0xC0 + s - 280), 8)
        }
    }

    /// One block with the fixed Huffman codes (BTYPE=01) and greedy LZ77 matches: shrinks JSON nicely.
    static func fixedHuffman(_ d: Data) -> Data {
        let b = [UInt8](d)
        var w = Bits()
        w.put(1, 1); w.put(1, 2) // BFINAL, BTYPE=01
        var head = [Int](repeating: -1, count: 1 << 15)
        var i = 0
        while i < b.count {
            var len = 0, dist = 0
            if i + 2 < b.count {
                let h = ((Int(b[i]) << 10) ^ (Int(b[i + 1]) << 5) ^ Int(b[i + 2])) & 0x7FFF
                let cand = head[h]
                head[h] = i
                if cand >= 0 && i - cand <= 32768 {
                    var l = 0
                    while l < 258 && i + l < b.count && b[cand + l] == b[i + l] { l += 1 }
                    if l >= 3 { len = l; dist = i - cand }
                }
            }
            if len >= 3 {
                var k = lengthBase.count - 1
                while lengthBase[k] > len { k -= 1 }
                symbol(&w, 257 + k)
                w.put(UInt32(len - lengthBase[k]), lengthExtra[k])
                var j = distBase.count - 1
                while distBase[j] > dist { j -= 1 }
                w.code(UInt32(j), 5)
                w.put(UInt32(dist - distBase[j]), distExtra[j])
                i += len
            } else {
                symbol(&w, Int(b[i]))
                i += 1
            }
        }
        symbol(&w, 256)
        w.flush()
        return Data(w.out)
    }
}

final class KitBundleTests: XCTestCase {
    var tmp: URL!
    let fm = FileManager.default
    override func setUp() {
        tmp = fm.temporaryDirectory.appendingPathComponent("kitbundle-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() { try? fm.removeItem(at: tmp) }

    static func tool(_ names: [String]) -> String? { names.first { FileManager.default.isExecutableFile(atPath: $0) } }
    /// python3, if one is installed and runs (a macOS stub without the command-line tools does not)
    static let python: String? = {
        #if os(Linux) || os(macOS)
        for path in ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"] where FileManager.default.isExecutableFile(atPath: path) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["-I", "-c", "import zipfile, zlib"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil { p.waitUntilExit(); if p.terminationStatus == 0 { return path } }
        }
        #endif
        return nil
    }()
    static let unzip = tool(["/usr/bin/unzip", "/opt/homebrew/bin/unzip"])

    /// Run a tool; (exit status, standard output). nil when processes cannot be run here.
    func run(_ exe: String, _ args: [String]) throws -> (Int32, String)? {
        #if os(Linux) || os(macOS)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
        #else
        return nil
        #endif
    }

    /// Python checks every part with zipfile (CRCs included), compares every entry with the kit's own file, and prints
    /// {name: [compress_type per part it is in]}.
    static let checkScript = """
    import sys, zipfile, os, json
    parent, parts = sys.argv[1], sys.argv[2:]
    seen = {}
    for p in parts:
        with zipfile.ZipFile(p) as z:
            bad = z.testzip()
            if bad is not None:
                print("bad entry", bad); sys.exit(2)
            for info in z.infolist():
                data = z.read(info)
                with open(os.path.join(parent, info.filename), "rb") as f:
                    if f.read() != data:
                        print("differs", info.filename); sys.exit(3)
                seen.setdefault(info.filename, []).append(info.compress_type)
    print(json.dumps(seen))
    """

    /// A kit with fake shots: videos of random bytes (do not compress), JSONL that does, depth files.
    func makeKit(videoSizes: [Int] = [90_000, 60_000, 120_000, 40_000, 75_000]) throws -> KitStore {
        let store = try KitStore.create(root: tmp.appendingPathComponent("work"), device: KitManifestTests.device,
                                        measurements: KitManifestTests.measurements, build: "test", date: Date(timeIntervalSince1970: 1_794_929_400))
        var rng = KitTestRandom(seed: 99)
        let ids = ["s02-scan", "s04-level-still", "s04-level-arc", "s05-tilt1-still", "s05-tilt1-arc"]
        for (n, id) in ids.enumerated() {
            let folder = try store.beginShot(id)
            try Data((0..<videoSizes[n % videoSizes.count]).map { _ in UInt8(truncatingIfNeeded: rng.next()) }).write(to: folder.appendingPathComponent("video.mp4"))
            let frames = try KitJSONLWriter(url: folder.appendingPathComponent("frames.jsonl"))
            for i in 0..<300 {
                try frames.append(KitFrame(index: i, time: 1000 + Double(i) / 30, pose: RigidTransform.identity.columnMajor4x4.map(Float.init),
                                           intrinsics: [900, 900, 640, 480], luma: 120, blur: 1.5, live: KitLiveResult(state: .searching)))
            }
            try frames.close()
            let motion = try KitJSONLWriter(url: folder.appendingPathComponent("motion.jsonl"))
            for i in 0..<500 { try motion.append(KitMotionSample(time: 1000 + Double(i) / 100, gravity: Vec3(0.01, -0.02, -0.9997))) }
            try motion.close()
            try fm.createDirectory(at: folder.appendingPathComponent("depth"), withIntermediateDirectories: true)
            for f in 0..<2 {
                let d = try KitDepth(width: 64, height: 48, millimetres: (0..<(64 * 48)).map { UInt16(800 + $0 % 50) }, confidence: [UInt8](repeating: 2, count: 64 * 48))
                try d.data.write(to: folder.appendingPathComponent("depth").appendingPathComponent(KitDepth.fileName(frame: f * 30)))
            }
            let m = try store.newShotManifest(id, startedAt: Date(timeIntervalSince1970: 1_794_929_400), duration: 10)
            try store.commitShot(id, manifest: m, date: Date(timeIntervalSince1970: 1_794_929_500))
        }
        // leftovers that must not go into the bundle
        try fm.createDirectory(at: store.attemptFolder("s06-dim"), withIntermediateDirectories: true)
        try Data("half".utf8).write(to: store.attemptFolder("s06-dim").appendingPathComponent("video.mp4"))
        try Data("x".utf8).write(to: store.folder.appendingPathComponent(".DS_Store"))
        return store
    }

    func testFixedHuffmanEncoderIsValidDeflate() throws {
        var rng = KitTestRandom(seed: 5)
        let inputs: [Data] = [Data(), Data("a".utf8), Data(String(repeating: "hello hello hello ", count: 500).utf8),
                              Data((0..<70_000).map { _ in UInt8(truncatingIfNeeded: rng.next()) }),
                              Data(repeating: 7, count: 100_000),
                              Data((0..<40_000).map { UInt8(($0 / 3) % 256) })]
        let fixed = inputs.map(KitTestDeflate.fixedHuffman)
        XCTAssertLessThan(fixed[2].count, inputs[2].count / 10, "repetitive text shrinks")
        let stored = inputs.map(KitTestDeflate.stored)
        XCTAssertEqual(stored[3].count, inputs[3].count + 10, "two stored blocks, 5 bytes of header each")
        guard let py = Self.python else { return }
        var args: [String] = []
        for (n, input) in inputs.enumerated() {
            let a = tmp.appendingPathComponent("in\(n)"), f = tmp.appendingPathComponent("fixed\(n)"), s = tmp.appendingPathComponent("stored\(n)")
            try input.write(to: a); try fixed[n].write(to: f); try stored[n].write(to: s)
            args += [a.path, f.path, s.path]
        }
        let script = """
        import sys, zlib
        a = sys.argv[1:]
        for i in range(0, len(a), 3):
            orig = open(a[i], "rb").read()
            for enc in a[i + 1:i + 3]:
                if zlib.decompress(open(enc, "rb").read(), -15) != orig:
                    print("mismatch", enc); sys.exit(1)
        print("ok")
        """
        let r = try run(py, ["-I", "-c", script] + args)
        XCTAssertEqual(r?.0, 0, r?.1 ?? "")
        XCTAssertEqual(r?.1.trimmingCharacters(in: .whitespacesAndNewlines), "ok")
    }

    func testPartsStayUnderTheLimitWithEveryFileOnce() throws {
        let store = try makeKit()
        let outbox = tmp.appendingPathComponent("outbox")
        let limit: Int64 = 200_000
        let r = try KitBundle.build(kitFolder: store.folder, outbox: outbox, limit: limit, deflate: KitTestDeflate.fixedHuffman, chunkSize: 4096)
        let kitId = store.kitId
        XCTAssertGreaterThan(r.parts.count, 1)
        XCTAssertEqual(r.oversized, [])
        let files = KitBundle.files(in: store.folder)
        XCTAssertFalse(files.contains { $0.contains(".attempt") || $0.contains(".DS_Store") })
        XCTAssertEqual(files.count, 1 + 5 * 6, "kit.json, and per shot: video, frames, motion, two depth files, shot.json")
        var seen: [String: Int] = [:]
        for (k, p) in r.parts.enumerated() {
            XCTAssertEqual(p.index, k + 1); XCTAssertEqual(p.count, r.parts.count)
            XCTAssertEqual(p.name, "\(kitId)-part\(k + 1)of\(r.parts.count).zip")
            XCTAssertEqual(p.url.lastPathComponent, p.name)
            XCTAssertEqual(KitFiles.fileSize(p.url.path), p.bytes)
            XCTAssertLessThanOrEqual(p.bytes, limit)
            XCTAssertFalse(p.oversized)
            XCTAssertEqual(p.entries.first, "\(kitId)/kit.json", "kit.json leads every part")
            for e in p.entries {
                XCTAssertTrue(e.hasPrefix(kitId + "/"))
                seen[e, default: 0] += 1
            }
            // the zip's end record says how many entries it holds
            let bytes = [UInt8](try Data(contentsOf: p.url))
            XCTAssertEqual(Array(bytes.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
            let eocd = bytes.count - 22
            XCTAssertEqual(Array(bytes[eocd..<(eocd + 4)]), [0x50, 0x4B, 0x05, 0x06])
            XCTAssertEqual(Int(bytes[eocd + 10]) | Int(bytes[eocd + 11]) << 8, p.entries.count)
        }
        XCTAssertEqual(Set(seen.keys), Set(files.map { kitId + "/" + $0 }))
        for (name, n) in seen { XCTAssertEqual(n, name.hasSuffix("/kit.json") ? r.parts.count : 1, name) }
        XCTAssertEqual(r.totalBytes, r.parts.reduce(0) { $0 + $1.bytes })
        XCTAssertEqual(r.urls, KitBundle.existingParts(kitId: kitId, in: outbox))
        // JSON, JSONL and depth are deflated; video is stored
        XCTAssertTrue(r.deflated.contains("\(kitId)/shots/s02-scan/frames.jsonl"))
        XCTAssertTrue(r.deflated.contains("\(kitId)/shots/s02-scan/depth/d000030.bdp2"))
        XCTAssertTrue(r.deflated.contains("\(kitId)/kit.json"))
        XCTAssertFalse(r.deflated.contains { $0.hasSuffix(".mp4") })
        // nothing else is left in the outbox
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: outbox.path).sorted(), r.parts.map { $0.name }.sorted())

        // every part is a valid zip, and unzipping all of them rebuilds the kit
        if let py = Self.python {
            let out = try XCTUnwrap(try run(py, ["-I", "-c", Self.checkScript, store.folder.deletingLastPathComponent().path] + r.parts.map { $0.url.path }))
            XCTAssertEqual(out.0, 0, out.1)
            let types = try JSONSerialization.jsonObject(with: Data(out.1.utf8)) as? [String: [Int]]
            XCTAssertEqual(types?["\(kitId)/shots/s04-level-arc/video.mp4"], [0])
            XCTAssertEqual(types?["\(kitId)/shots/s04-level-arc/motion.jsonl"], [8])
            XCTAssertEqual(types?["\(kitId)/kit.json"], [Int](repeating: 8, count: r.parts.count))
        }
        if let uz = Self.unzip {
            let dest = tmp.appendingPathComponent("unzipped")
            for p in r.parts {
                XCTAssertEqual(try run(uz, ["-t", "-q", p.url.path])?.0, 0)
                XCTAssertEqual(try run(uz, ["-o", "-q", p.url.path, "-d", dest.path])?.0, 0)
            }
            for f in files {
                XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent(kitId).appendingPathComponent(f)),
                               try Data(contentsOf: store.folder.appendingPathComponent(f)), f)
            }
        }
    }

    func testAFileLargerThanTheLimitGetsItsOwnPart() throws {
        let store = try makeKit(videoSizes: [30_000, 260_000, 30_000, 30_000, 30_000])
        let outbox = tmp.appendingPathComponent("outbox")
        let r = try KitBundle.build(kitFolder: store.folder, outbox: outbox, limit: 200_000, deflate: KitTestDeflate.fixedHuffman)
        let big = "\(store.kitId)/shots/s04-level-still/video.mp4"
        XCTAssertEqual(r.oversized, [big])
        let part = try XCTUnwrap(r.parts.first { $0.oversized })
        XCTAssertEqual(part.entries, ["\(store.kitId)/kit.json", big])
        XCTAssertGreaterThan(part.bytes, 200_000)
        for p in r.parts where !p.oversized { XCTAssertLessThanOrEqual(p.bytes, 200_000) }
        if let py = Self.python {
            XCTAssertEqual(try run(py, ["-I", "-c", Self.checkScript, store.folder.deletingLastPathComponent().path] + r.parts.map { $0.url.path })?.0, 0)
        }
    }

    func testStoredWhenTheCompressorDoesNotHelp() throws {
        let store = try makeKit()
        let outbox = tmp.appendingPathComponent("outbox")
        // stored-block DEFLATE never shrinks anything, and nil means the compressor failed: both fall back to stored
        for deflate in [KitTestDeflate.stored, { (_: Data) -> Data? in nil }, nil] as [KitDeflater?] {
            let r = try KitBundle.build(kitFolder: store.folder, outbox: outbox, limit: 24_000_000, deflate: deflate)
            XCTAssertEqual(r.parts.count, 1)
            XCTAssertEqual(r.deflated, [])
            XCTAssertEqual(r.parts[0].name, "\(store.kitId)-part1of1.zip")
            if let py = Self.python {
                let out = try XCTUnwrap(try run(py, ["-I", "-c", Self.checkScript, store.folder.deletingLastPathComponent().path, r.parts[0].url.path]))
                XCTAssertEqual(out.0, 0, out.1)
                XCTAssertFalse(out.1.contains("8"), "every entry stored: \(out.1)")
            }
        }
    }

    func testRebuildingReplacesEarlierParts() throws {
        let store = try makeKit()
        let outbox = tmp.appendingPathComponent("outbox")
        let many = try KitBundle.build(kitFolder: store.folder, outbox: outbox, limit: 150_000, deflate: KitTestDeflate.fixedHuffman)
        XCTAssertGreaterThan(many.parts.count, 2)
        try Data("keep".utf8).write(to: outbox.appendingPathComponent("other-file.txt"))
        let one = try KitBundle.build(kitFolder: store.folder, outbox: outbox, deflate: KitTestDeflate.fixedHuffman)
        XCTAssertEqual(one.parts.count, 1)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: outbox.path).sorted(), ["other-file.txt", "\(store.kitId)-part1of1.zip"].sorted())
    }

    func testFailureLeavesNothingBehind() throws {
        let store = try makeKit()
        let outbox = tmp.appendingPathComponent("outbox")
        // a video disappears while the bundle is being built (the compressor runs first, so it can pull the rug)
        let victim = store.shotFolder("s05-tilt1-arc").appendingPathComponent("video.mp4")
        let deflate: KitDeflater = { data in
            try? FileManager.default.removeItem(at: victim)
            return KitTestDeflate.fixedHuffman(data)
        }
        XCTAssertThrowsError(try KitBundle.build(kitFolder: store.folder, outbox: outbox, limit: 150_000, deflate: deflate))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: outbox.path), [], "no parts and no scratch files")
        // not a kit; a limit too small for kit.json
        XCTAssertThrowsError(try KitBundle.build(kitFolder: tmp, outbox: outbox)) { XCTAssertEqual($0 as? KitBundleError, .notAKit(tmp.lastPathComponent)) }
        XCTAssertThrowsError(try KitBundle.build(kitFolder: store.folder, outbox: outbox, limit: 1000)) {
            XCTAssertEqual($0 as? KitBundleError, .limitTooSmall(1000))
        }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: outbox.path), [])
    }

    func testZipWriterStreamsAndPatchesTheCRC() throws {
        let src = tmp.appendingPathComponent("big.bin")
        var rng = KitTestRandom(seed: 3)
        let payload = Data((0..<100_003).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
        try payload.write(to: src)
        let zipURL = tmp.appendingPathComponent("w.zip")
        let z = try KitZipWriter(url: zipURL)
        try z.addFile(name: "kit/big.bin", from: src, chunkSize: 7)
        XCTAssertEqual(try z.addData(name: "kit/a.json", data: Data(String(repeating: "{\"a\":1}\n", count: 100).utf8), deflate: KitTestDeflate.fixedHuffman), .deflated)
        XCTAssertEqual(try z.addData(name: "kit/b.json", data: Data("{}".utf8), deflate: KitTestDeflate.fixedHuffman), .stored, "too small to shrink")
        XCTAssertEqual(try z.addData(name: "kit/é.txt", data: Data("utf-8 name".utf8)), .stored)
        let size = try z.finish()
        XCTAssertEqual(size, KitFiles.fileSize(zipURL.path))
        XCTAssertEqual(z.names, ["kit/big.bin", "kit/a.json", "kit/b.json", "kit/é.txt"])
        XCTAssertThrowsError(try z.addData(name: "late", data: Data())) { XCTAssertEqual($0 as? KitBundleError, .closed) }
        XCTAssertThrowsError(try z.finish())
        // the predicted cost of a stored entry is exact
        XCTAssertEqual(KitZipWriter.entryCost(name: "kit/big.bin", payloadBytes: 100_003) + KitZipWriter.endRecordBytes,
                       {
                           let only = tmp.appendingPathComponent("only.zip")
                           let w = try? KitZipWriter(url: only)
                           try? w?.addFile(name: "kit/big.bin", from: src)
                           return (try? w?.finish()) ?? 0
                       }())
        if let py = Self.python {
            let script = """
            import sys, zipfile
            z = zipfile.ZipFile(sys.argv[1])
            assert z.testzip() is None
            assert z.read("kit/big.bin") == open(sys.argv[2], "rb").read()
            assert z.read("kit/a.json") == b'{"a":1}\\n' * 100
            assert z.getinfo("kit/a.json").compress_type == 8
            assert z.read("kit/é.txt") == b"utf-8 name"
            print("ok")
            """
            let r = try run(py, ["-I", "-c", script, zipURL.path, src.path])
            XCTAssertEqual(r?.0, 0, r?.1 ?? "")
        }
    }
}
