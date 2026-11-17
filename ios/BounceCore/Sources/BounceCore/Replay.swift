import Foundation

/// Plays a recording through the tracker (the same code the app runs), frame by frame.
public struct ReplayRunner {
    public let reader: RecordingReader
    public init(reader: RecordingReader) { self.reader = reader }

    public struct Step {
        public var frame: RecordedFrame
        public var output: TrackerOutput
    }

    /// Run every frame. `detector` and `ballLocator` default to what the caller supplies (SlabFinder / BallLocator in the
    /// app). Settings come from the recording unless given.
    public func run(detector: SlabDetecting, ballLocator: BallLocating? = nil, settings: TrackerSettings? = nil,
                    floorY: Double? = nil) throws -> (steps: [Step], tracker: SlabTracker) {
        var ts = settings ?? TrackerSettings()
        if settings == nil {
            ts.spec = reader.session.settings.slab
            ts.ball = reader.session.settings.ball
            ts.defaultDropHeight = reader.session.settings.dropHeight
        }
        let tracker = SlabTracker(settings: ts, detector: detector, ballLocator: ballLocator)
        var steps: [Step] = []
        for f in reader.frames {
            let img = try reader.image(for: f)
            let depth = try reader.depth(for: f)
            let tf = TrackerFrame(timestamp: f.timestamp, view: f.view, frame: img.colorFrame, depth: depth, depthIntrinsics: f.depthIntrinsics,
                                  ballImage: ballLocator != nil ? img.luma : nil, ballIntrinsics: ballLocator != nil ? f.intrinsics : nil,
                                  floorY: floorY, trackingNormal: f.trackingNormal)
            steps.append(Step(frame: f, output: tracker.process(tf)))
        }
        return (steps, tracker)
    }
}
