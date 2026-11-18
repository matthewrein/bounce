import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Monotonic clock (ns).
@inline(__always) func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

@inline(__always) func msSince(_ t0: UInt64) -> Double { Double(nowNs() &- t0) / 1e6 }

/// Keeps a result alive so the optimiser cannot drop the work that made it (a call it cannot see into).
@inline(never) @_optimize(none)
func blackHole<T>(_ x: T) { _ = x }

/// Summary of a set of timings (ms).
struct Stats: Codable, Equatable {
    var n: Int
    var min: Double
    var p50: Double
    var p95: Double
    var max: Double
    var mean: Double

    init(_ xs: [Double]) {
        let s = xs.sorted()
        n = s.count
        if s.isEmpty { min = .nan; p50 = .nan; p95 = .nan; max = .nan; mean = .nan; return }
        func rank(_ q: Double) -> Double { s[Swift.max(0, Swift.min(s.count - 1, Int((q * Double(s.count)).rounded(.up)) - 1))] }
        min = s.first!; max = s.last!
        p50 = s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        p95 = rank(0.95)
        mean = s.reduce(0, +) / Double(s.count)
    }

    /// the same timings scaled (another machine's estimate)
    func scaled(_ k: Double) -> Stats {
        var o = self
        o.min *= k; o.p50 *= k; o.p95 *= k; o.max *= k; o.mean *= k
        return o
    }
}

/// How long to time a stage: warm-up runs (not counted), then up to `iterations` timed runs, stopping early once
/// `maxSeconds` have gone by (but never before `minIterations`).
struct Budget {
    var warmup: Int
    var iterations: Int
    var minIterations: Int
    var maxSeconds: Double

    static let fast = Budget(warmup: 5, iterations: 60, minIterations: 15, maxSeconds: 2.5)
    static let slow = Budget(warmup: 2, iterations: 25, minIterations: 8, maxSeconds: 6)
    func quick() -> Budget { Budget(warmup: 1, iterations: max(3, iterations / 6), minIterations: 3, maxSeconds: maxSeconds / 4) }
    func with(iterations n: Int) -> Budget { var b = self; b.iterations = n; b.minIterations = min(minIterations, n); return b }
}

/// Times `body` per the budget; returns the timings (ms).
func timeRuns(_ b: Budget, _ body: () -> Void) -> [Double] {
    for _ in 0..<b.warmup { body() }
    var out: [Double] = []
    out.reserveCapacity(b.iterations)
    let start = nowNs()
    for i in 0..<b.iterations {
        let t0 = nowNs()
        body()
        out.append(msSince(t0))
        if i + 1 >= b.minIterations && Double(nowNs() &- start) / 1e9 > b.maxSeconds { break }
    }
    return out
}

// MARK: calibration

/// A fixed CPU workload (integer hashing, a dependent chain of double arithmetic, a branch the predictor cannot learn,
/// loads and stores in a 32 kB table): what the detectors' inner loops are made of, without depending on any of their
/// code, so its time compares machines and runs (the same binary, the same work, always).
@inline(never)
func calibrationKernel(iterations n: Int, seed: UInt64) -> UInt64 {
    var x = seed | 1
    var acc = 0.0
    var table = [Double](repeating: 0.25, count: 4096)
    table.withUnsafeMutableBufferPointer { t in
        for _ in 0..<n {
            x ^= x << 13; x ^= x >> 7; x ^= x << 17
            let j = Int(truncatingIfNeeded: x & 4095)
            let v = Double(x >> 11) * 0x1p-53
            t[j] = t[j] * 0.5 + v
            if v > 0.5 { acc += (v * t[j]).squareRoot() } else { acc -= v * 0.75 }
        }
    }
    return x ^ acc.bitPattern ^ table[17].bitPattern
}

/// Memory streaming: sums a 32 MB buffer of bytes (what the image conversions and crops lean on).
@inline(never)
func memoryKernel(_ buf: UnsafeBufferPointer<UInt8>) -> UInt64 {
    var s0: UInt64 = 0, s1: UInt64 = 0, s2: UInt64 = 0, s3: UInt64 = 0
    let n = buf.count / 32 * 32
    buf.baseAddress!.withMemoryRebound(to: UInt64.self, capacity: n / 8) { p in
        var i = 0
        while i < n / 8 {
            s0 &+= p[i] & 0x00FF00FF00FF00FF; s1 &+= (p[i + 1] >> 8) & 0x00FF00FF00FF00FF
            s2 &+= p[i + 2] & 0x00FF00FF00FF00FF; s3 &+= (p[i + 3] >> 8) & 0x00FF00FF00FF00FF
            i += 4
        }
    }
    return s0 &+ s1 &+ s2 &+ s3
}

struct Calibration: Codable {
    /// the CPU kernel's time (ms) for `iterations` iterations: min and median of the runs
    var cpuMs: Stats
    var iterations: Int
    var nsPerIteration: Double
    /// streaming 32 MB (GB/s, best run)
    var memoryGBps: Double

    static func run(quick: Bool, iterations n: Int = 10_000_000) -> Calibration {
        let runs = quick ? 5 : 15
        var ts: [Double] = []
        for r in 0..<(runs + 2) {
            let t0 = nowNs()
            blackHole(calibrationKernel(iterations: n, seed: 0x9E3779B97F4A7C15 &+ UInt64(r)))
            let ms = msSince(t0)
            if r >= 2 { ts.append(ms) }
        }
        let st = Stats(ts)
        let bytes = 32 << 20
        let buf = [UInt8](unsafeUninitializedCapacity: bytes) { b, c in
            for i in 0..<bytes { b[i] = UInt8(truncatingIfNeeded: i &* 2654435761 >> 13) }
            c = bytes
        }
        var best = Double.infinity
        buf.withUnsafeBufferPointer { b in
            for _ in 0..<(quick ? 4 : 10) {
                let t0 = nowNs()
                blackHole(memoryKernel(b))
                best = min(best, msSince(t0))
            }
        }
        return Calibration(cpuMs: st, iterations: n, nsPerIteration: st.min * 1e6 / Double(n), memoryGBps: Double(bytes) / 1e9 / (best / 1000))
    }
}

// MARK: the host

struct HostInfo: Codable {
    var os: String
    var arch: String
    var cpu: String
    var cores: Int
    var loadAverage: String?
    var swiftOptimised: Bool
    var date: String

    static func current() -> HostInfo {
        #if os(macOS)
        let os = "macOS " + ProcessInfo.processInfo.operatingSystemVersionString
        #elseif os(Linux)
        let os = "Linux " + ProcessInfo.processInfo.operatingSystemVersionString
        #else
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        #endif
        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "other"
        #endif
        var cpu = "unknown"
        #if os(macOS)
        var size = 0
        if sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 {
            var b = [CChar](repeating: 0, count: size)
            if sysctlbyname("machdep.cpu.brand_string", &b, &size, nil, 0) == 0 { cpu = b.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } }
        }
        #else
        if let s = try? String(contentsOfFile: "/proc/cpuinfo", encoding: .utf8),
           let line = s.split(separator: "\n").first(where: { $0.hasPrefix("model name") }),
           let v = line.split(separator: ":", maxSplits: 1).last {
            cpu = v.trimmingCharacters(in: .whitespaces)
        }
        #endif
        var load: String? = nil
        var la = [Double](repeating: 0, count: 3)
        if getloadavg(&la, 3) == 3 { load = String(format: "%.2f %.2f %.2f", la[0], la[1], la[2]) }
        #if DEBUG
        let opt = false
        #else
        let opt = true
        #endif
        let f = ISO8601DateFormatter()
        return HostInfo(os: os, arch: arch, cpu: cpu, cores: ProcessInfo.processInfo.activeProcessorCount, loadAverage: load,
                        swiftOptimised: opt, date: f.string(from: Date()))
    }

    var isAppleSiliconMac: Bool {
        #if os(macOS) && arch(arm64)
        return true
        #else
        return false
        #endif
    }
}

/// A short calibration probe between stage groups: the same kernel, 2M iterations, best of 3, scaled to the full
/// calibration's 10M. Its drift over the run shows how much the machine's load changed while it ran (the stages between
/// two probes are as much slower as the probes are).
struct Probe: Codable {
    var label: String
    var ms: Double

    static func take(_ label: String, quickRun: Bool = false) -> Probe {
        let n = quickRun ? 200_000 : 2_000_000
        var best = Double.infinity
        for r in 0..<3 {
            let t0 = nowNs()
            blackHole(calibrationKernel(iterations: n, seed: 0x51ED27 &+ UInt64(r)))
            best = min(best, msSince(t0))
        }
        return Probe(label: label, ms: best * 10_000_000 / Double(n))
    }
}
