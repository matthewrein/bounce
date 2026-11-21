import Foundation

// TrackerSettings and ShapeCheck.Limits as JSON, so a recording (session.json, settings changes) and the diagnostics can
// hold exactly the settings the phone ran with. Every field is written; when reading, a field that is missing (a file
// from an older build) keeps its default, so adding a setting never breaks reading older files.

/// A JSON key for the hand-written Codable conformances below.
struct SettingsKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// One stored property of a settings struct: its JSON key and how to write and read it.
struct SettingsField<Root> {
    let key: String
    let encode: (Root, inout KeyedEncodingContainer<SettingsKey>) throws -> Void
    let decode: (inout Root, KeyedDecodingContainer<SettingsKey>) throws -> Void

    init<T: Codable>(_ key: String, _ path: WritableKeyPath<Root, T>) {
        self.key = key
        encode = { r, c in try c.encode(r[keyPath: path], forKey: SettingsKey(key)) }
        decode = { r, c in if let v = try c.decodeIfPresent(T.self, forKey: SettingsKey(key)) { r[keyPath: path] = v } }
    }

    /// An optional property: written as null when nil, and read back as nil from null (a missing key keeps the default).
    init<T: Codable>(optional key: String, _ path: WritableKeyPath<Root, T?>) {
        self.key = key
        encode = { r, c in
            if let v = r[keyPath: path] { try c.encode(v, forKey: SettingsKey(key)) } else { try c.encodeNil(forKey: SettingsKey(key)) }
        }
        decode = { r, c in
            let k = SettingsKey(key)
            guard c.contains(k) else { return }
            r[keyPath: path] = try c.decodeNil(forKey: k) ? nil : c.decode(T.self, forKey: k)
        }
    }

    static func encode(_ value: Root, _ fields: [SettingsField<Root>], to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: SettingsKey.self)
        for f in fields { try f.encode(value, &c) }
    }

    static func decode(into value: inout Root, _ fields: [SettingsField<Root>], from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: SettingsKey.self)
        for f in fields { try f.decode(&value, c) }
    }
}

extension ShapeCheck.Limits: Codable {
    /// Every stored property (a test checks this list against the struct's properties).
    static let codingFields: [SettingsField<ShapeCheck.Limits>] = [
        .init("maxMisfitFraction", \.maxMisfitFraction),
        .init("minDistance", \.minDistance),
        .init("maxDistance", \.maxDistance),
        .init("maxTiltDegrees", \.maxTiltDegrees),
        .init(optional: "maxNormalSigmaDegrees", \.maxNormalSigmaDegrees),
    ]

    public init(from decoder: Decoder) throws {
        self.init()
        try SettingsField.decode(into: &self, ShapeCheck.Limits.codingFields, from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try SettingsField.encode(self, ShapeCheck.Limits.codingFields, to: encoder)
    }
}

extension TrackerSettings: Codable {
    /// Every stored property (a test checks this list against the struct's properties).
    static let codingFields: [SettingsField<TrackerSettings>] = [
        .init("spec", \.spec),
        .init("ball", \.ball),
        .init("defaultDropHeight", \.defaultDropHeight),
        .init("launchRule", \.launchRule),
        .init("recheckInterval", \.recheckInterval),
        .init("searchInterval", \.searchInterval),
        .init("minDetectionGap", \.minDetectionGap),
        .init("confirmCount", \.confirmCount),
        .init("matchDistance", \.matchDistance),
        .init("matchAngleDegrees", \.matchAngleDegrees),
        .init("moveCount", \.moveCount),
        .init("lostAfter", \.lostAfter),
        .init("historySize", \.historySize),
        .init("depthNormalWeight", \.depthNormalWeight),
        .init("depthCentreWeight", \.depthCentreWeight),
        .init(optional: "maxSweepRegions", \.maxSweepRegions),
        .init("sweepSkipsFinds", \.sweepSkipsFinds),
        .init("sweepSameOutlinePixels", \.sweepSameOutlinePixels),
        .init("ballInterval", \.ballInterval),
        .init("shapeLimits", \.shapeLimits),
        .init("cornerNoisePixels", \.cornerNoisePixels),
        .init("matchSigmas", \.matchSigmas),
        .init("maxMatchDistance", \.maxMatchDistance),
        .init("maxMatchAngleDegrees", \.maxMatchAngleDegrees),
        .init("maxLockSigmaDegrees", \.maxLockSigmaDegrees),
        .init("slideWindow", \.slideWindow),
        .init("slideSigmas", \.slideSigmas),
        .init("moveRadius", \.moveRadius),
        .init(optional: "cradleRadius", \.cradleRadius),
        .init("cutFlipTolerancePixels", \.cutFlipTolerancePixels),
        .init("topRelockCount", \.topRelockCount),
        .init("topRelockSeconds", \.topRelockSeconds),
        .init("minMissesForLost", \.minMissesForLost),
        .init("findsMovedSlab", \.findsMovedSlab),
        .init("movedSlabFinds", \.movedSlabFinds),
        .init("movedSlabHeight", \.movedSlabHeight),
        .init("movedSlabRadius", \.movedSlabRadius),
        .init("unconfirmedTimeout", \.unconfirmedTimeout),
        .init("poseJumpDistance", \.poseJumpDistance),
        .init("limitedResumeSeconds", \.limitedResumeSeconds),
        .init("seedTimeout", \.seedTimeout),
        .init("tapHints", \.tapHints),
        .init("tapSlackFraction", \.tapSlackFraction),
        .init("tapBallSeconds", \.tapBallSeconds),
        .init("tapDismissSeconds", \.tapDismissSeconds),
        .init("tapDismissMax", \.tapDismissMax),
        .init("tapSlabFirstSeconds", \.tapSlabFirstSeconds),
        .init("tapSetsBall", \.tapSetsBall),
        .init("tapAcceptSeconds", \.tapAcceptSeconds),
        .init("tapSetMaxHeight", \.tapSetMaxHeight),
        .init("depthSmoothingSeconds", \.depthSmoothingSeconds),
        .init("depthHoldSeconds", \.depthHoldSeconds),
        .init("depthMinInlierFraction", \.depthMinInlierFraction),
        .init("depthMaxOffsetFraction", \.depthMaxOffsetFraction),
        .init("depthMaxAngleDegrees", \.depthMaxAngleDegrees),
        .init("sideEvidenceCap", \.sideEvidenceCap),
        .init("sideEvidenceDecay", \.sideEvidenceDecay),
        .init("sideFlipMargin", \.sideFlipMargin),
        .init("sideDecidedEvidence", \.sideDecidedEvidence),
        .init("idleSearchAfter", \.idleSearchAfter),
        .init("idleSearchInterval", \.idleSearchInterval),
        .init("idleSearchMoveDegrees", \.idleSearchMoveDegrees),
        .init("idleSearchMoveDistance", \.idleSearchMoveDistance),
        .init("idleBallAfter", \.idleBallAfter),
        .init("idleBallInterval", \.idleBallInterval),
        .init("settle", \.settle),
        .init("readoutsFromSettledNormal", \.readoutsFromSettledNormal),
        .init("lockKeepsNewestPerView", \.lockKeepsNewestPerView),
        .init("multiViewLock", \.multiViewLock),
        .init(optional: "ballGate", \.ballGate),
    ]

    public init(from decoder: Decoder) throws {
        self.init()
        try SettingsField.decode(into: &self, TrackerSettings.codingFields, from: decoder)
        // Settings from before n11 lack the centre's weight: then the normal's weight moved the centre too (and fusion ran
        // only while it was above 0), so it is read as that weight and the file replays as the phone ran it.
        let c = try decoder.container(keyedBy: SettingsKey.self)
        if !c.contains(SettingsKey("depthCentreWeight")) { depthCentreWeight = depthNormalWeight }
    }

    public func encode(to encoder: Encoder) throws {
        try SettingsField.encode(self, TrackerSettings.codingFields, to: encoder)
    }
}
