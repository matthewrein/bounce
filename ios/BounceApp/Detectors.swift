import BounceCore

/// The detectors the tracker uses: the same ones the replay tests use (BounceCore.AppDetectors).
enum Detectors {
    static func slab() -> SlabDetecting { AppDetectors.slab() }
    static func ball() -> BallLocating? { AppDetectors.ball() }
}
