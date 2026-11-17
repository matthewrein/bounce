import Foundation

// The quick quality check after each shot (CaptureKit.md, "Quality check"). It only flags problems the owner can fix by
// retrying; a detector missing the slab on good footage is exactly what the kit is for, so detector-based checks say
// "if it was in view, Next is fine". Computed on the phone from per-frame statistics, unit-tested here.

/// One frame's numbers for the quality check (the app collects one per recorded video frame).
public struct KitFrameStat: Codable, Equatable {
    /// frame time (s)
    public var t: Double
    /// ARKit tracking was "normal"
    public var trackingNormal: Bool
    /// mean luma 0-255
    public var luma: Double
    /// estimated motion blur (video pixels)
    public var blurPixels: Double
    /// the slab was found (confirming or locked)
    public var slabFound: Bool
    /// the slab was locked
    public var slabLocked: Bool
    /// the ball was found
    public var ballFound: Bool
    /// ARKit's ambient light estimate (lumens), if any
    public var ambientLumens: Double?

    public init(t: Double, trackingNormal: Bool = true, luma: Double = 128, blurPixels: Double = 0, slabFound: Bool = false,
                slabLocked: Bool = false, ballFound: Bool = false, ambientLumens: Double? = nil) {
        self.t = t; self.trackingNormal = trackingNormal; self.luma = luma; self.blurPixels = blurPixels
        self.slabFound = slabFound || slabLocked; self.slabLocked = slabLocked; self.ballFound = ballFound; self.ambientLumens = ambientLumens
    }

    /// From a recorded frame (missing luma or blur count as mid-grey and sharp, so they never fail a check).
    public init(frame f: KitFrame) {
        self.init(t: f.time, trackingNormal: f.tracking.isNormal, luma: f.luma ?? 128, blurPixels: f.blur ?? 0,
                  slabFound: f.live?.slabFound ?? false, slabLocked: f.live?.state == .locked, ballFound: f.live?.ballCircle != nil,
                  ambientLumens: f.ambientLumens)
    }
}

/// The overall verdict on a shot.
public enum KitVerdict: String, Codable, Comparable {
    /// every check passed
    case good
    /// a soft check failed; Next stays the default
    case fair
    /// Retry is suggested
    case poor

    var rank: Int { switch self { case .good: return 0; case .fair: return 1; case .poor: return 2 } }
    public static func < (a: KitVerdict, b: KitVerdict) -> Bool { a.rank < b.rank }
}

/// What a failed check means.
public enum KitSeverity: String, Codable {
    /// reported only, never fails the shot
    case info
    /// failing makes the shot fair
    case fair
    /// failing makes the shot poor
    case poor
}

/// One check's outcome.
public struct KitQualityCheck: Codable, Equatable {
    /// "frames", "tracking", "light", "lightChange", "blur", "slab", "ball", "falsePositives", "reading", "still", "flat",
    /// "turn", "bump"
    public var id: String
    public var passed: Bool
    /// the effect of this check on the verdict (when it failed, or for info checks always)
    public var severity: KitSeverity
    public var value: Double?
    public var threshold: Double?
    /// plain English for the owner
    public var message: String

    public init(id: String, passed: Bool, severity: KitSeverity, value: Double? = nil, threshold: Double? = nil, message: String) {
        self.id = id; self.passed = passed; self.severity = severity; self.value = value; self.threshold = threshold; self.message = message
    }
}

/// The quality check's result for one shot.
public struct KitQualityReport: Codable, Equatable {
    public var verdict: KitVerdict
    public var checks: [KitQualityCheck]
    /// one line for the screen: the verdict and the first problem, if any
    public var summary: String
    /// frames recorded (video shots)
    public var frames: Int?
    /// median luma over the frames (video shots): the dim and bright shots compare against the level shot's
    public var medianLuma: Double?
    /// median motion blur (video shots, pixels)
    public var medianBlur: Double?

    public init(verdict: KitVerdict, checks: [KitQualityCheck], summary: String, frames: Int? = nil, medianLuma: Double? = nil, medianBlur: Double? = nil) {
        self.verdict = verdict; self.checks = checks; self.summary = summary; self.frames = frames; self.medianLuma = medianLuma; self.medianBlur = medianBlur
    }

    /// the check with this id, if it ran
    public func check(_ id: String) -> KitQualityCheck? { checks.first { $0.id == id } }
    /// failed checks that count (fair or poor)
    public var problems: [KitQualityCheck] { checks.filter { !$0.passed && $0.severity != .info } }

    /// Build a report from checks: poor if a poor check failed, fair if a fair one did, else good.
    public init(checks: [KitQualityCheck], frames: Int? = nil, medianLuma: Double? = nil, medianBlur: Double? = nil) {
        let failed = checks.filter { !$0.passed }
        let verdict: KitVerdict = failed.contains { $0.severity == .poor } ? .poor : (failed.contains { $0.severity == .fair } ? .fair : .good)
        let summary: String
        switch verdict {
        case .good: summary = "Good. Every check passed."
        case .fair: summary = "Fair. " + (failed.first { $0.severity == .fair }?.message ?? "") + " Next is fine."
        case .poor: summary = "Poor. " + (failed.first { $0.severity == .poor }?.message ?? "") + " Retry is suggested."
        }
        self.init(verdict: verdict, checks: checks, summary: summary, frames: frames, medianLuma: medianLuma, medianBlur: medianBlur)
    }
}

/// What the light checks compare against.
public struct KitQualityReference: Codable, Equatable {
    /// the median luma of the level hold-still shot (`KitPlan.lightReferenceShotId`), if it was captured
    public var levelStillMedianLuma: Double?
    public init(levelStillMedianLuma: Double? = nil) { self.levelStillMedianLuma = levelStillMedianLuma }
}

/// The quality rules.
public enum KitQuality {
    /// at least this share of the expected frames, otherwise poor
    public static let minFrameShare = 0.8
    /// median luma at least this, otherwise fair (dim shots: `minDimLuma`)
    public static let minLuma = 45.0
    public static let minDimLuma = 12.0
    /// dim shots: below this share of the reference; bright shots: above `brightRatio` of it
    public static let dimRatio = 0.7
    public static let brightRatio = 1.1
    /// median blur at most this (pixels) for still / moving shots, otherwise fair; above `poorBlurFactor` times it, poor
    public static let maxBlurStill = 3.0
    public static let maxBlurMoving = 6.0
    public static let poorBlurFactor = 2.0
    /// the slab found in at least this share of frames, otherwise fair
    public static let minSlabShare = 0.5
    /// the ball found in at least this share of frames, otherwise fair
    public static let minBallShare = 0.3
    /// flat-phone readings: spread at most this (degrees), otherwise poor
    public static let maxReadingSpread = 0.3
    /// flat-phone readings: the phone's own tilt at most this (degrees), otherwise poor
    public static let maxReadingTilt = 25.0
    /// flat-phone turn: this range is good; outside it (or no reading B), fair
    public static let goodTurn: ClosedRange<Double> = 120...240
    /// flat-phone bump at most this (degrees), otherwise fair
    public static let maxBump = 5.0

    static let eps = 1e-9

    /// Frames a video shot should have at a frame rate (the frame rate kept in the file).
    public static func expectedFrames(shot: KitShotSpec, fps: Double) -> Int {
        guard let s = shot.kind.videoSeconds, fps > 0, fps.isFinite else { return 0 }
        return Int((s * fps).rounded())
    }

    static func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }

    /// Check a video shot from its frames' statistics. `expectedFrames` is what the recording should have held;
    /// `reference` carries the level shot's brightness for the dim and bright shots. Form shots get an empty, good
    /// report; flat-phone shots are checked with `evaluate(shot:flat:)`.
    public static func evaluate(shot: KitShotSpec, stats: [KitFrameStat], expectedFrames: Int,
                                reference: KitQualityReference = KitQualityReference()) -> KitQualityReport {
        guard shot.isVideo else { return KitQualityReport(checks: []) }
        var checks: [KitQualityCheck] = []
        let n = stats.count, nd = Double(max(n, 1))

        // frames
        let frameShare = expectedFrames > 0 ? Double(n) / Double(expectedFrames) : (n > 0 ? 1 : 0)
        let framesOK = expectedFrames > 0 ? Double(n) >= minFrameShare * Double(expectedFrames) - eps : n > 0
        checks.append(KitQualityCheck(id: "frames", passed: framesOK, severity: .poor, value: frameShare, threshold: minFrameShare,
                                      message: framesOK ? "Recorded \(n) of \(expectedFrames) frames."
                                                        : "The phone dropped frames (only \(pct(frameShare)) recorded). Close other apps, then retry."))
        guard n > 0 else {
            return KitQualityReport(checks: checks, frames: 0)
        }

        // tracking
        let trackShare = Double(stats.filter { $0.trackingNormal }.count) / nd
        let minTrack = shot.expect.minTrackingShare
        let trackOK = trackShare >= minTrack - eps
        checks.append(KitQualityCheck(id: "tracking", passed: trackOK, severity: .fair, value: trackShare, threshold: minTrack,
                                      message: trackOK ? "Tracking was steady."
                                                       : "The phone lost track of the room in \(pct(1 - trackShare)) of frames. Move more slowly and keep more of the room in view."))

        // light
        let luma = KitStats.median(stats.map { $0.luma })
        let floor = shot.expect.light == .dim ? minDimLuma : minLuma
        let lightOK = luma >= floor - eps
        checks.append(KitQualityCheck(id: "light", passed: lightOK, severity: .fair, value: luma, threshold: floor,
                                      message: lightOK ? String(format: "Brightness %.0f of 255.", luma)
                                                       : shot.expect.light == .dim
                                                         ? String(format: "Too dark even for the dim shot (brightness %.0f of 255). Turn one lamp on.", luma)
                                                         : String(format: "Too dark (brightness %.0f of 255). Turn on more light, then retry.", luma)))
        if let ref = reference.levelStillMedianLuma, ref > 0, shot.expect.light != .normal {
            if shot.expect.light == .dim {
                let limit = dimRatio * ref, ok = luma < limit
                checks.append(KitQualityCheck(id: "lightChange", passed: ok, severity: .fair, value: luma / ref, threshold: dimRatio,
                                              message: ok ? String(format: "Dimmer than the level shot (%.0f vs %.0f).", luma, ref)
                                                          : String(format: "It doesn't look dimmer than the level shot (brightness %.0f vs %.0f). Dim the room more.", luma, ref)))
            } else {
                let limit = brightRatio * ref, ok = luma > limit
                checks.append(KitQualityCheck(id: "lightChange", passed: ok, severity: .fair, value: luma / ref, threshold: brightRatio,
                                              message: ok ? String(format: "Brighter than the level shot (%.0f vs %.0f).", luma, ref)
                                                          : String(format: "It doesn't look brighter than the level shot (brightness %.0f vs %.0f). Turn on more light.", luma, ref)))
            }
        }

        // blur
        let blur = KitStats.median(stats.map { $0.blurPixels })
        let moving = shot.expect.motion == .moving
        let maxBlur = moving ? maxBlurMoving : maxBlurStill
        let blurOK = blur <= maxBlur + eps
        let blurPoor = blur > poorBlurFactor * maxBlur + eps
        let steadier = moving ? "Walk more slowly and keep the phone steady." : "Hold the phone steadier (brace your elbows)."
        checks.append(KitQualityCheck(id: "blur", passed: blurOK, severity: blurPoor ? .poor : .fair, value: blur, threshold: maxBlur,
                                      message: blurOK ? String(format: "Sharp enough (blur about %.1f px).", blur)
                                                      : String(format: "The picture is blurred (about %.0f px). ", blur) + steadier))

        // slab and ball
        let slabShare = Double(stats.filter { $0.slabFound }.count) / nd
        let ballShare = Double(stats.filter { $0.ballFound }.count) / nd
        if shot.expect.slab == .required {
            let ok = slabShare >= minSlabShare - eps
            checks.append(KitQualityCheck(id: "slab", passed: ok, severity: .fair, value: slabShare, threshold: minSlabShare,
                                          message: ok ? "The app found the slab in \(pct(slabShare)) of frames."
                                                      : "The app found the slab in only \(pct(slabShare)) of frames. If the slab was in view, Next is fine."))
        }
        if shot.expect.ball == .required {
            let ok = ballShare >= minBallShare - eps
            checks.append(KitQualityCheck(id: "ball", passed: ok, severity: .fair, value: ballShare, threshold: minBallShare,
                                          message: ok ? "The app found the ball in \(pct(ballShare)) of frames."
                                                      : "The app found the ball in only \(pct(ballShare)) of frames. If the ball was in view, Next is fine."))
        }
        if shot.expect.slab == .forbidden || shot.expect.ball == .forbidden {
            var found = 0
            for s in stats where (shot.expect.slab == .forbidden && s.slabFound) || (shot.expect.ball == .forbidden && s.ballFound) { found += 1 }
            let share = Double(found) / nd
            var what: [String] = []
            if shot.expect.slab == .forbidden { what.append("slab") }
            if shot.expect.ball == .forbidden { what.append("ball") }
            checks.append(KitQualityCheck(id: "falsePositives", passed: true, severity: .info, value: share, threshold: nil,
                                          message: "For the record: the app saw a \(what.joined(separator: " or ")) that isn't there in \(pct(share)) of frames."))
        }
        return KitQualityReport(checks: checks, frames: n, medianLuma: luma, medianBlur: blur)
    }

    /// Check a flat-phone shot from its result.
    public static func evaluate(shot: KitShotSpec, flat r: KitTrueTilt) -> KitQualityReport {
        var checks: [KitQualityCheck] = []
        guard let a = r.readingA, r.method != .failed else {
            checks.append(KitQualityCheck(id: "reading", passed: false, severity: .poor,
                                          message: "No reading: the phone did not lie still. Lay it flat, let go and keep the slab still."))
            return KitQualityReport(checks: checks)
        }
        let readings = [("A", a)] + (r.readingB.map { [("B", $0)] } ?? [])
        for (name, x) in readings {
            let ok = x.spreadDegrees <= maxReadingSpread + eps
            checks.append(KitQualityCheck(id: "still", passed: ok, severity: .poor, value: x.spreadDegrees, threshold: maxReadingSpread,
                                          message: ok ? String(format: "Reading %@ was steady (%.2f°).", name, x.spreadDegrees)
                                                      : String(format: "The phone moved during reading %@ (%.2f°). Let go completely and don't touch the slab.", name, x.spreadDegrees)))
        }
        for (name, x) in readings {
            let ok = x.tiltDegrees <= maxReadingTilt + eps
            checks.append(KitQualityCheck(id: "flat", passed: ok, severity: .poor, value: x.tiltDegrees, threshold: maxReadingTilt,
                                          message: ok ? String(format: "Reading %@: the phone lay flat enough (%.1f°).", name, x.tiltDegrees)
                                                      : String(format: "In reading %@ the phone was not lying flat (%.0f°). Lay it flat in the middle of the slab.", name, x.tiltDegrees)))
        }
        if r.readingB == nil || r.turnDegrees == nil {
            checks.append(KitQualityCheck(id: "turn", passed: false, severity: .fair, value: nil, threshold: nil,
                                          message: "Only one reading: the phone was not turned around and laid down again."))
        } else if let turn = r.turnDegrees {
            let ok = goodTurn.contains(turn)
            let loose = turn >= KitFlatTilt.minTurnDegrees && turn <= 360 - KitFlatTilt.minTurnDegrees
            checks.append(KitQualityCheck(id: "turn", passed: ok, severity: .fair, value: turn, threshold: 180,
                                          message: ok ? String(format: "Turned %.0f°.", turn)
                                                      : loose ? String(format: "The phone was turned %.0f°, not about 180°; it still works, less precisely.", turn)
                                                              : String(format: "The phone was turned only %.0f°; turn it all the way around (top toward you).", min(turn, 360 - turn))))
        }
        if r.method == .twoReading, let b = r.bumpDegrees, b.count == 2 {
            let mag = Vec2(b[0], b[1]).length, ok = mag <= maxBump + eps
            checks.append(KitQualityCheck(id: "bump", passed: ok, severity: .fair, value: mag, threshold: maxBump,
                                          message: ok ? String(format: "Camera bump %.1f°.", mag)
                                                      : String(format: "The phone rocks %.0f° on its camera bump; a thick or uneven case?", mag)))
        }
        return KitQualityReport(checks: checks)
    }
}

/// Cheap image statistics the app computes per frame.
public enum KitImageStats {
    /// Mean of a luma plane over every `step`-th pixel in x and y.
    public static func meanLuma(_ p: Plane, step: Int = 4) -> Double {
        let k = max(1, step)
        var s = 0.0, n = 0
        var y = 0
        while y < p.height {
            var x = 0
            let row = y * p.width
            while x < p.width { s += Double(p.data[row + x]); n += 1; x += k }
            y += k
        }
        return n > 0 ? s / Double(n) : 0
    }

    /// A cheap sharpness measure: mean absolute central difference (horizontal plus vertical, grey levels per pixel)
    /// over every `step`-th interior pixel. Higher is sharper; a blurred copy of the same scene scores lower.
    public static func sharpness(_ p: Plane, step: Int = 2) -> Double {
        let k = max(1, step)
        guard p.width >= 3, p.height >= 3 else { return 0 }
        var s = 0.0, n = 0
        var y = 1
        while y < p.height - 1 {
            var x = 1
            while x < p.width - 1 {
                let gx = p.data[y * p.width + x + 1] - p.data[y * p.width + x - 1]
                let gy = p.data[(y + 1) * p.width + x] - p.data[(y - 1) * p.width + x]
                s += Double(abs(gx) + abs(gy)) / 2
                n += 1
                x += k
            }
            y += k
        }
        return n > 0 ? s / Double(n) : 0
    }
}

/// Motion blur from the camera's rotation between two frames.
public enum KitMotionBlur {
    /// Roll blurs the image in proportion to the distance from the centre; it is counted at half a focal length (about
    /// the middle of the image's half-height).
    public static let rollRadiusInFocals = 0.5

    /// Angular speeds (rad/s) of the optical axis (pan and tilt) and of the roll about it, between two world-from-camera
    /// poses. Either ARKit's or BounceCore's camera axes: both have the optical axis on z.
    public static func rates(previous: RigidTransform, current: RigidTransform, dt: Double) -> (axis: Double, roll: Double) {
        guard dt > 0, dt.isFinite else { return (0, 0) }
        let rel = previous.rotation.transposed * current.rotation // current camera axes in previous camera axes
        let swing = acos(clamp(rel[2, 2], -1, 1))
        let q = KitQuaternion(matrix: rel)
        // twist about z (swing-twist decomposition): the z part of the quaternion
        var twist = 2 * atan2(q.z, q.w)
        if twist > .pi { twist -= 2 * .pi } else if twist < -.pi { twist += 2 * .pi }
        return (swing / dt, abs(twist) / dt)
    }

    /// Blur in pixels: exposure x focal x the angular speed (the axis's swing plus the roll at `rollRadiusInFocals`).
    /// 0 for a missing exposure or frame interval.
    public static func pixels(previous: RigidTransform, current: RigidTransform, dt: Double, exposure: Double, focal: Double) -> Double {
        guard exposure > 0, exposure.isFinite, focal > 0, focal.isFinite else { return 0 }
        let r = rates(previous: previous, current: current, dt: dt)
        let w = (r.axis * r.axis + pow(r.roll * rollRadiusInFocals, 2)).squareRoot()
        return w * exposure * focal
    }
}
