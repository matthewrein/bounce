import AVFoundation
import BounceCore
import Compression
import Foundation
import QuartzCore
import UIKit

/// Raw DEFLATE (RFC 1951) from Apple's Compression framework, for the kit's bundle (`KitDeflater`): COMPRESSION_ZLIB is
/// raw DEFLATE without the zlib header, exactly what a zip entry with method 8 holds.
enum KitDeflate {
    static func raw(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        // only worth storing deflated when it is smaller: a buffer the size of the input is enough to tell
        let capacity = data.count
        var out = Data(count: capacity)
        let n = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress, let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(d, capacity, s, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0 else { return nil }   // 0: it did not fit (or failed): stored as is
        out.count = n
        return out
    }
}

/// The capture kit's beeps and haptics. The tones are made here (short sine beeps) and played through the playback
/// audio category, so they sound even with the ring switch on silent; they mix with other audio.
@MainActor
final class KitFeedback {
    private var players: [Tone: AVAudioPlayer] = [:]
    private let impact: UIImpactFeedbackGenerator
    private let light: UIImpactFeedbackGenerator
    private let notify: UINotificationFeedbackGenerator

    init() {
        impact = UIImpactFeedbackGenerator(style: .heavy)
        light = UIImpactFeedbackGenerator(style: .light)
        notify = UINotificationFeedbackGenerator()
    }

    enum Tone: CaseIterable {
        /// the countdown's seconds
        case tick
        /// a recording started (not in drop shots) or stopped
        case phase
        /// "drop now": the only beep in a drop shot after the countdown
        case drop
        /// flat-phone shot: "turn it around now" (reading A is done), the only beep while the phone lies on the slab
        case turn
        /// flat-phone shot: done (a lower tone)
        case done
        var frequency: Double {
            switch self {
            case .tick: return 880
            case .phase: return 1320
            case .drop: return 1760
            case .turn: return 1320
            case .done: return 660
            }
        }
        var seconds: Double {
            switch self {
            case .tick: return 0.08
            case .phase: return 0.18
            case .drop: return 0.35
            case .turn: return 0.5
            case .done: return 0.5
            }
        }
    }

    func prepare() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        for t in Tone.allCases where players[t] == nil {
            if let p = try? AVAudioPlayer(data: KitFeedback.wav(frequency: t.frequency, seconds: t.seconds)) {
                p.prepareToPlay()
                players[t] = p
            }
        }
        impact.prepare(); light.prepare(); notify.prepare()
    }

    func close() {
        players.values.forEach { $0.stop() }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Play a tone (with its haptic). Returns the uptime when it was started.
    @discardableResult
    func play(_ t: Tone) -> Double {
        let now = CACurrentMediaTime()
        if let p = players[t] {
            p.currentTime = 0
            p.play()
        }
        switch t {
        case .tick: light.impactOccurred()
        case .phase: notify.notificationOccurred(.success)
        case .drop: impact.impactOccurred()
        // the phone lies on the slab: sound only, so nothing shakes it
        case .turn, .done: break
        }
        return now
    }

    /// A mono 16-bit PCM WAV of a sine tone with soft ends.
    static func wav(frequency: Double, seconds: Double, rate: Int = 44_100) -> Data {
        let n = Int(Double(rate) * seconds)
        var pcm = Data(capacity: n * 2)
        let fade = Double(rate) * 0.01
        for i in 0..<n {
            let env = min(1, Double(i) / fade, Double(n - i) / fade)
            let v = Int16(max(-1, min(1, 0.6 * env * sin(2 * .pi * frequency * Double(i) / Double(rate)))) * 32_000)
            pcm.append(UInt8(truncatingIfNeeded: v)); pcm.append(UInt8(truncatingIfNeeded: v >> 8))
        }
        var d = Data()
        func u32(_ x: Int) { var v = UInt32(x).littleEndian; withUnsafeBytes(of: &v) { d.append(contentsOf: $0) } }
        func u16(_ x: Int) { var v = UInt16(x).littleEndian; withUnsafeBytes(of: &v) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + pcm.count); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(pcm.count)
        d.append(pcm)
        return d
    }
}

/// The flat-phone shot's state machine (`KitFlatSession`, not thread-safe) fed from the motion queue (or the demo's
/// feed) and read by the screen, behind a lock.
final class KitFlatRunner {
    struct Snapshot {
        var phase: KitFlatSession.Phase
        var prompt: String
        var progress: Double
        var secondsLeft: Double?
        var result: KitTrueTilt?
        /// phase changes so far
        var changes: Int
        var samples: Int
    }

    private let lock = NSLock()
    private let session: KitFlatSession
    private var changes = 0

    init(session: KitFlatSession) { self.session = session }

    func feed(_ s: KitMotionSample) {
        lock.lock(); defer { lock.unlock() }
        if session.feed(s) { changes += 1 }
    }

    /// Let time pass (for the timeouts when no samples come).
    func advance(to t: Double) {
        lock.lock(); defer { lock.unlock() }
        if session.advance(to: t) { changes += 1 }
    }

    /// Stop now: the result from what was read so far.
    @discardableResult
    func finish() -> KitTrueTilt {
        lock.lock(); defer { lock.unlock() }
        let wasDone = session.isDone
        let r = session.finish()
        if !wasDone { changes += 1 }
        return r
    }

    var phase: KitFlatSession.Phase { lock.lock(); defer { lock.unlock() }; return session.phase }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(phase: session.phase, prompt: session.prompt, progress: session.progress, secondsLeft: session.secondsLeft,
                        result: session.result, changes: changes, samples: session.sampleCount)
    }
}

/// The demo's motion for a flat-phone shot (no CoreMotion in the Simulator): a phone lying on the demo slab with a fake
/// 1.5° camera bump (`KitDemoFlatPhone`), turned around by itself about a second after the turn prompt; 100 samples a
/// second on its own queue, on the uptime clock.
final class KitDemoMotionFeed {
    private let queue = DispatchQueue(label: "slabbounce.kit.demomotion", qos: .userInitiated)
    private var timer: DispatchSourceTimer? = nil
    private var phone: KitDemoFlatPhone

    init(tiltDegrees: Double, downhillAzimuthDegrees: Double) {
        phone = KitDemoFlatPhone(tiltDegrees: tiltDegrees, downhillAzimuthDegrees: downhillAzimuthDegrees)
    }

    /// `phase` tells it when the turn is asked for; `sink` gets every sample.
    func start(phase: @escaping () -> KitFlatSession.Phase, sink: @escaping (KitMotionSample) -> Void) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            let s = self.phone.sample(at: CACurrentMediaTime(), phase: phase())
            sink(s)
        }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

/// The bundle parts to share (KitViews' share sheet offers them all at once).
struct KitShareItem: Identifiable {
    let urls: [URL]
    let id = UUID()
}
