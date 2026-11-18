import Foundation

// The capture kit's plan as data: which shots the owner takes, in which order, what each one shows and expects.
// The app draws its guided screens from this, the quality check reads its expectations, and the scorer reads which
// ground truth each clip carries. See ios/CaptureKit.md.

/// One of the kit's 12 steps (a group of shots under one heading: "Step 4 of 12").
public struct KitStepSpec: Codable, Equatable {
    /// 1...12
    public var number: Int
    public var title: String

    public init(number: Int, title: String) { self.number = number; self.title = title }
}

/// The small pictures the app draws beside a shot's instruction. One case per picture.
public enum KitDiagram: String, Codable, CaseIterable {
    /// a ruler across the slab's top and edge, calipers on the ball
    case measure
    /// the phone circling the slab 3-5 ft away
    case roomScan
    /// the phone lying flat in the middle of a level slab, with a "turn around" arrow
    case flatPhone
    /// the same on a slab propped up at one edge
    case flatPhoneTilted
    /// the phone held still 3-4 ft from the slab, slab in the middle of the screen
    case holdStill
    /// a half circle walked around the slab
    case walkArc
    /// a lamp switched off
    case dimLight
    /// lamps switched on
    case brightLight
    /// the ball on the floor, phone about 3 ft away
    case ballFloorNear
    /// the ball on the floor, phone about 5 ft away
    case ballFloorFar
    /// the ball resting in the middle of the dish
    case ballOnSlab
    /// a hand holding the ball about 4 in above the slab
    case ballHeldLow
    /// about 1 ft above
    case ballHeldMid
    /// about 2 ft above
    case ballHeldHigh
    /// the ball dropped onto the middle of the slab, with its bounce
    case dropCentre
    /// the ball dropped near one edge
    case dropEdge
    /// the room with no slab in view
    case noSlab
    /// the slab with no ball in view
    case noBall
}

/// What kind of screen a shot is.
public enum KitShotKind: Codable, Equatable {
    /// a form (the measurements); nothing is recorded
    case form
    /// a video clip of `seconds` that stops by itself. `highFrameRate`: record at the highest frame rate ARKit offers
    /// and keep every frame. `releaseCue`: seconds after the recording starts when the app beeps to let the ball go.
    case video(seconds: Double, highFrameRate: Bool, releaseCue: Double?)
    /// the phone lying flat on the slab (two gravity readings, no video); see `KitFlatSession`
    case flat

    public var isVideo: Bool { if case .video = self { return true } else { return false } }
    public var isFlat: Bool { self == .flat }
    /// the recording's length for video shots, else nil
    public var videoSeconds: Double? { if case let .video(s, _, _) = self { return s } else { return nil } }
    public var highFrameRate: Bool { if case let .video(_, h, _) = self { return h } else { return false } }
    public var releaseCue: Double? { if case let .video(_, _, c) = self { return c } else { return nil } }
}

/// Whether a shot should show something.
public enum KitPresence: String, Codable {
    /// it should be in view (the quality check looks for it)
    case required
    /// it must not be in view (anything found is a false positive)
    case forbidden
    /// either
    case any
}

/// The light a shot asks for.
public enum KitLight: String, Codable { case normal, dim, bright }

/// Whether the phone is held still or moved during a shot.
public enum KitMotion: String, Codable { case still, moving }

/// What a shot expects to see, for the quality check and the scorer.
public struct KitExpectations: Codable, Equatable {
    public var slab: KitPresence
    public var ball: KitPresence
    public var light: KitLight
    public var motion: KitMotion
    /// share of frames that must have ARKit tracking "normal" (0.7; the room scan, where tracking settles, 0.6)
    public var minTrackingShare: Double

    public init(slab: KitPresence = .any, ball: KitPresence = .any, light: KitLight = .normal, motion: KitMotion = .still,
                minTrackingShare: Double = 0.7) {
        self.slab = slab; self.ball = ball; self.light = light; self.motion = motion; self.minTrackingShare = minTrackingShare
    }
}

/// A slab position that a flat-phone shot starts ("p1", "level").
public struct KitPositionSpec: Codable, Equatable {
    public var id: String
    public var label: String
    public init(id: String, label: String) { self.id = id; self.label = label }
}

/// One shot: one screen of the guided flow.
public struct KitShotSpec: Codable, Equatable {
    /// e.g. "s04-level-still": step number, then what it is
    public var id: String
    /// the step it belongs to (1...12)
    public var step: Int
    /// short title for the screen ("Hold still")
    public var title: String
    /// the one-line instruction the screen shows
    public var instruction: String
    /// an optional second line (smaller print)
    public var detail: String?
    public var diagram: KitDiagram
    public var kind: KitShotKind
    /// seconds of countdown after Start before the recording begins (3; 5 for flat-phone shots; 0 for the form)
    public var countdown: Double
    public var expect: KitExpectations
    /// flat-phone shots start a new slab position
    public var startsPosition: KitPositionSpec?
    /// optional shots (the third tilt) can be skipped as a group
    public var optional: Bool
    /// after the shot, ask the owner for the measured height of the ball's bottom above the slab's surface right under it
    /// (a ruler stood on the slab under the ball, so in the dish): the app's drop height (`Bounce.drop`)
    public var asksHeight: Bool
    /// the height the instruction asks for (inches), as a hint for the height entry and the scorer
    public var nominalHeightInches: Double?

    public init(id: String, step: Int, title: String, instruction: String, detail: String? = nil, diagram: KitDiagram,
                kind: KitShotKind, countdown: Double, expect: KitExpectations = KitExpectations(), startsPosition: KitPositionSpec? = nil,
                optional: Bool = false, asksHeight: Bool = false, nominalHeightInches: Double? = nil) {
        self.id = id; self.step = step; self.title = title; self.instruction = instruction; self.detail = detail
        self.diagram = diagram; self.kind = kind; self.countdown = countdown; self.expect = expect
        self.startsPosition = startsPosition; self.optional = optional; self.asksHeight = asksHeight
        self.nominalHeightInches = nominalHeightInches
    }

    public var isVideo: Bool { kind.isVideo }
    public var isFlat: Bool { kind.isFlat }
    public var isForm: Bool { kind == .form }
}

/// The whole kit: 12 steps and their shots, in order.
public struct KitPlan: Codable, Equatable {
    /// "standard-v1"; kit.json records it so a kit is read against the plan it was taken with
    public var id: String
    /// 1 for real kits. UI tests run the plan faster (e.g. 0.25): recordings, countdowns, release cues and the
    /// flat-phone timings all shrink by this factor. Recorded in kit.json.
    public var timeScale: Double
    public var steps: [KitStepSpec]
    public var shots: [KitShotSpec]
    /// the shot whose median brightness is the reference for the dim and bright shots
    public var lightReferenceShotId: String

    public init(id: String, timeScale: Double = 1, steps: [KitStepSpec], shots: [KitShotSpec], lightReferenceShotId: String) {
        self.id = id; self.timeScale = timeScale; self.steps = steps; self.shots = shots; self.lightReferenceShotId = lightReferenceShotId
    }

    public var stepCount: Int { steps.count }
    public var shotCount: Int { shots.count }
    public var requiredShots: [KitShotSpec] { shots.filter { !$0.optional } }
    public var optionalShots: [KitShotSpec] { shots.filter { $0.optional } }

    public func step(_ number: Int) -> KitStepSpec? { steps.first { $0.number == number } }
    public func shots(inStep number: Int) -> [KitShotSpec] { shots.filter { $0.step == number } }
    /// position of a shot in plan order
    public func index(of shotId: String) -> Int? { shots.firstIndex { $0.id == shotId } }
    public func shot(_ id: String) -> KitShotSpec? { shots.first { $0.id == id } }
    /// "Step 4 of 12"
    public func progressLabel(step number: Int) -> String { "Step \(number) of \(stepCount)" }

    /// The flat-phone timings for this plan (scaled with the plan).
    public var flatSettings: KitFlatSettings { KitFlatSettings.standard.scaled(by: timeScale) }

    /// Recording time (seconds), counting each flat-phone shot at about 12 s; optional shots included if asked.
    public func recordingSeconds(includingOptional: Bool = false) -> Double {
        shots.filter { includingOptional || !$0.optional }.reduce(0) { sum, s in
            switch s.kind {
            case .form: return sum
            case let .video(seconds, _, _): return sum + seconds
            case .flat: return sum + 12 * timeScale
            }
        }
    }

    /// The same plan with every duration multiplied by `s` (recordings, countdowns, release cues; the flat-phone
    /// timings follow `timeScale`). Scaling a scaled plan multiplies the factors.
    public func scaled(by s: Double) -> KitPlan {
        precondition(s > 0 && s.isFinite, "time scale must be positive")
        var p = self
        p.timeScale = timeScale * s
        p.shots = shots.map { shot in
            var x = shot
            x.countdown = shot.countdown * s
            if case let .video(sec, hfr, cue) = shot.kind { x.kind = .video(seconds: sec * s, highFrameRate: hfr, releaseCue: cue.map { $0 * s }) }
            return x
        }
        return p
    }

    /// A plan by id (as kit.json records it), at a time scale.
    public static func named(_ id: String, timeScale: Double = 1) -> KitPlan? {
        guard id == standard.id, timeScale > 0, timeScale.isFinite else { return nil }
        return timeScale == 1 ? standard : standard.scaled(by: timeScale)
    }

    /// The standard kit (CaptureKit.md): 25 shots, plus 3 optional ones for a third tilt.
    public static let standard: KitPlan = {
        let slabOnly = KitExpectations(slab: .required, ball: .forbidden, motion: .still)
        let slabArc = KitExpectations(slab: .required, ball: .forbidden, motion: .moving)
        let ballAndSlab = KitExpectations(slab: .required, ball: .required, motion: .still)
        let steps = [
            KitStepSpec(number: 1, title: "Measurements"),
            KitStepSpec(number: 2, title: "Room scan"),
            KitStepSpec(number: 3, title: "True tilt (level)"),
            KitStepSpec(number: 4, title: "Slab only, level"),
            KitStepSpec(number: 5, title: "Slab only, tilts"),
            KitStepSpec(number: 6, title: "Light"),
            KitStepSpec(number: 7, title: "Ball only"),
            KitStepSpec(number: 8, title: "Ball on the slab"),
            KitStepSpec(number: 9, title: "Ball held above"),
            KitStepSpec(number: 10, title: "Bounces"),
            KitStepSpec(number: 11, title: "Off-centre bounce"),
            KitStepSpec(number: 12, title: "Negatives"),
        ]
        let flatDetail = "At the long beep (the screen says to turn it), pick it up, turn it around (top toward you), lay it down in the middle again and let go. A low tone means it is done."
        var shots: [KitShotSpec] = [
            KitShotSpec(id: "s01-measure", step: 1, title: "Measure",
                        instruction: "Measure the slab and the ball, and enter the numbers.",
                        detail: "Width and depth of the top, thickness at an edge, the dish depth if you can (a straightedge across the top), and the ball's diameter.",
                        diagram: .measure, kind: .form, countdown: 0),
            KitShotSpec(id: "s02-scan", step: 2, title: "Room scan",
                        instruction: "Walk slowly around the slab, 3 to 5 ft away, keeping it on the screen.",
                        detail: "This lets the phone settle its sense of the room.",
                        diagram: .roomScan, kind: .video(seconds: 20, highFrameRate: false, releaseCue: nil), countdown: 3,
                        expect: KitExpectations(slab: .any, ball: .any, motion: .moving, minTrackingShare: 0.6)),
            KitShotSpec(id: "s03-flat-level", step: 3, title: "True tilt",
                        instruction: "Set the slab down level. Lay the phone flat in its middle, screen up, top pointing away. Let go.",
                        detail: flatDetail, diagram: .flatPhone, kind: .flat, countdown: 5,
                        startsPosition: KitPositionSpec(id: "p1", label: "level")),
            KitShotSpec(id: "s04-level-still", step: 4, title: "Hold still",
                        instruction: "Hold the phone still, 3 to 4 ft from the slab, with the slab in the middle of the screen.",
                        detail: "No ball in view.", diagram: .holdStill,
                        kind: .video(seconds: 5, highFrameRate: false, releaseCue: nil), countdown: 3, expect: slabOnly),
            KitShotSpec(id: "s04-level-arc", step: 4, title: "Walk around",
                        instruction: "Walk a slow half circle around the slab, keeping it in the middle of the screen.",
                        detail: "Stay 3 to 4 ft away.", diagram: .walkArc,
                        kind: .video(seconds: 20, highFrameRate: false, releaseCue: nil), countdown: 3, expect: slabArc),
        ]
        let tilts: [(n: Int, deg: Int, pos: String, optional: Bool)] = [(1, 5, "p2", false), (2, 10, "p3", false), (3, 15, "p4", true)]
        for t in tilts {
            let opt = t.optional ? " Optional: tap Skip to leave the slab at tilt \(t.n - 1)." : ""
            shots.append(KitShotSpec(id: "s05-tilt\(t.n)-flat", step: 5, title: "Tilt \(t.n): true tilt",
                                     instruction: "Slide the slab in its cradle to tilt it about \(t.deg)°. Lay the phone flat in its middle, top pointing away. Let go.",
                                     detail: flatDetail + opt, diagram: .flatPhoneTilted, kind: .flat, countdown: 5,
                                     startsPosition: KitPositionSpec(id: t.pos, label: "tilt \(t.n)"), optional: t.optional))
            shots.append(KitShotSpec(id: "s05-tilt\(t.n)-still", step: 5, title: "Tilt \(t.n): hold still",
                                     instruction: "Hold the phone still, 3 to 4 ft from the slab, with the slab in the middle of the screen.",
                                     detail: "Leave the slab as it is.", diagram: .holdStill,
                                     kind: .video(seconds: 5, highFrameRate: false, releaseCue: nil), countdown: 3, expect: slabOnly,
                                     optional: t.optional))
            shots.append(KitShotSpec(id: "s05-tilt\(t.n)-arc", step: 5, title: "Tilt \(t.n): walk around",
                                     instruction: "Walk a slow half circle around the slab, keeping it in the middle of the screen.",
                                     detail: "Stay 3 to 4 ft away.", diagram: .walkArc,
                                     kind: .video(seconds: 15, highFrameRate: false, releaseCue: nil), countdown: 3, expect: slabArc,
                                     optional: t.optional))
        }
        shots += [
            KitShotSpec(id: "s06-dim", step: 6, title: "Dim light",
                        instruction: "Dim the room (lamps off, curtains drawn), then hold still with the slab in the middle of the screen.",
                        detail: "Leave the slab where it is.", diagram: .dimLight,
                        kind: .video(seconds: 6, highFrameRate: false, releaseCue: nil), countdown: 3,
                        expect: KitExpectations(slab: .required, ball: .forbidden, light: .dim, motion: .still)),
            KitShotSpec(id: "s06-bright", step: 6, title: "Bright light",
                        instruction: "Make the room bright (every light on), then hold still with the slab in the middle of the screen.",
                        detail: "Leave the slab where it is.", diagram: .brightLight,
                        kind: .video(seconds: 6, highFrameRate: false, releaseCue: nil), countdown: 3,
                        expect: KitExpectations(slab: .required, ball: .forbidden, light: .bright, motion: .still)),
            KitShotSpec(id: "s07-ball-3ft", step: 7, title: "Ball on the floor, near",
                        instruction: "Put the ball on the floor away from the slab. Hold the phone about 3 ft from it, ball in the middle.",
                        detail: "Keep the slab out of view.", diagram: .ballFloorNear,
                        kind: .video(seconds: 5, highFrameRate: false, releaseCue: nil), countdown: 3,
                        expect: KitExpectations(slab: .forbidden, ball: .required, motion: .still)),
            KitShotSpec(id: "s07-ball-5ft", step: 7, title: "Ball on the floor, far",
                        instruction: "Step back to about 5 ft from the ball, ball in the middle of the screen.",
                        detail: "Keep the slab out of view.", diagram: .ballFloorFar,
                        kind: .video(seconds: 5, highFrameRate: false, releaseCue: nil), countdown: 3,
                        expect: KitExpectations(slab: .forbidden, ball: .required, motion: .still)),
            KitShotSpec(id: "s08-ball-centre", step: 8, title: "Ball on the slab",
                        instruction: "Rest the ball in the slab's dish, as near the middle as it will stay. Hold still, slab in the middle of the screen.",
                        detail: "This ties the ball's size to the slab's distance.", diagram: .ballOnSlab,
                        kind: .video(seconds: 6, highFrameRate: false, releaseCue: nil), countdown: 3, expect: ballAndSlab),
        ]
        let held: [(String, String, KitDiagram, Double)] = [("low", "4 in", .ballHeldLow, 4), ("mid", "1 ft", .ballHeldMid, 12), ("high", "2 ft", .ballHeldHigh, 24)]
        for (name, text, diagram, inches) in held {
            shots.append(KitShotSpec(id: "s09-held-\(name)", step: 9, title: "Ball held \(name == "mid" ? "middle" : name)",
                                     instruction: "Hold the ball about \(text) above the middle of the slab. Keep both in view and hold still.",
                                     detail: "Afterwards you can enter the measured height of the ball's bottom above the slab right under it (a ruler stood on the slab under the ball), or skip that.",
                                     diagram: diagram, kind: .video(seconds: 5, highFrameRate: false, releaseCue: nil), countdown: 3,
                                     expect: ballAndSlab, asksHeight: true, nominalHeightInches: inches))
        }
        for n in 1...3 {
            shots.append(KitShotSpec(id: "s10-drop\(n)", step: 10, title: "Drop \(n) of 3",
                                     instruction: "Hold the ball about 1 ft over the middle of the slab and let go at the high beep (Drop now).",
                                     detail: "Keep the slab and the floor around it in view until the recording stops.",
                                     diagram: .dropCentre, kind: .video(seconds: 6, highFrameRate: true, releaseCue: 2), countdown: 3,
                                     expect: ballAndSlab, nominalHeightInches: 12))
        }
        shots += [
            KitShotSpec(id: "s11-drop-edge", step: 11, title: "Drop near an edge",
                        instruction: "Hold the ball about 1 ft over the slab, just inside one edge, and let go at the high beep (Drop now).",
                        detail: "Keep the slab and the floor around it in view until the recording stops.",
                        diagram: .dropEdge, kind: .video(seconds: 6, highFrameRate: true, releaseCue: 2), countdown: 3,
                        expect: ballAndSlab, nominalHeightInches: 12),
            KitShotSpec(id: "s12-no-slab", step: 12, title: "No slab",
                        instruction: "Point the phone around the room, moving slowly, with the slab and the ball out of view.",
                        diagram: .noSlab, kind: .video(seconds: 6, highFrameRate: false, releaseCue: nil), countdown: 3,
                        expect: KitExpectations(slab: .forbidden, ball: .forbidden, motion: .moving)),
            KitShotSpec(id: "s12-no-ball", step: 12, title: "No ball",
                        instruction: "Point the phone at the slab, moving slowly, with no ball anywhere in view.",
                        diagram: .noBall, kind: .video(seconds: 6, highFrameRate: false, releaseCue: nil), countdown: 3,
                        expect: KitExpectations(slab: .required, ball: .forbidden, motion: .moving)),
        ]
        return KitPlan(id: "standard-v1", steps: steps, shots: shots, lightReferenceShotId: "s04-level-still")
    }()
}
