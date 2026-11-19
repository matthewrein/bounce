import XCTest
@testable import BounceCore

/// Profiles the refiner's tests run on: the old box (vertical 1 in cut faces, the original rules) and the owner's slab
/// with its sloped sides (`SlabSpec.ownerSlab`'s face drop and side run), sharp-edged and rounded.
enum TestProfiles {
    static let vertical = SlabSpec.standard
    /// the owner's measured side profile, with a sharp edge
    static let sloped = SlabSpec(sideU: Units.inches(7), sideV: Units.inches(7), thickness: Units.inches(1), dishDepth: Units.inches(0.125),
                                 faceDrop: 0.0215, sideRun: 0.0075)
    /// the same with a rounded edge of radius r and the near departure at psi_n
    static func rounded(_ r: Double, psiN: Double = 0) -> SlabSpec {
        var s = sloped; s.edgeRadius = r; s.nearFeatureAngle = psiN; return s
    }
    /// the vertical 1 in box as a profile prior (the face drops by the thickness, no run): what learning starts from when
    /// nothing better is known
    static var verticalPrior: SlabSpec { var s = vertical; s.faceDrop = s.thickness; return s }
}

/// The edge refiner with the slab's side profile (`SlabSpec.hasProfile`, `EdgeRefiner.refineWithProfile`) on rendered
/// slabs with sloped sides (`BoxScene`): the owner's slab (face drop 21.5 mm, run 7.5 mm out; slab-kit-20261118), lit,
/// shadowed and about as light as the top, from near, edge-on, grazing and nearly face-on views, with sharp and rounded
/// edges; and the profile learned from a wrong (vertical) prior.
final class EdgeRefinerProfileTests: XCTestCase {
    static let views = EdgeRefinerTests.views

    func scene(_ v: (K: CameraIntrinsics, distance: Double, label: String), band: Float, spec: SlabSpec = TestProfiles.sloped,
               pitch: Double = 50, tilt: Double = 6, heading: Double = 30, yaw: Double = 15) -> BoxScene {
        BoxScene(view: SyntheticView.make(pitch: pitch, distance: v.distance, tilt: tilt, heading: heading, yaw: yaw, spec: spec, intrinsics: v.K), bandLuma: band)
    }

    /// corner errors against the true top corners (same order), and the normal's error (degrees)
    func errors(_ r: EdgeRefiner.Result, _ s: BoxScene) -> (corners: [Double], normal: Double) {
        ((0..<4).map { r.outline[$0].distance(to: s.view.corners[$0]) }, angleDeg(r.fit.pose.normal, s.view.pose.normal))
    }

    /// Per side of the output, how far the true top edge lies outward of the side's line at its two ends (pixels of `q`).
    func sideOffsets(_ q: [Vec2], _ truth: [Vec2]) -> [(Double, Double)] {
        let c = Geometry.centroid(q)
        return (0..<4).map { i in
            let a = q[i], b = q[(i + 1) % 4]
            var n = (b - a).normalized.perpendicular
            if n.dot((a + b) / 2 - c) < 0 { n = -n }
            return ((truth[i] - a).dot(n), (truth[(i + 1) % 4] - a).dot(n))
        }
    }

    func describe(_ r: EdgeRefiner.Result) -> String {
        r.sides.map {
            String(format: "%@/%@ band %.1f (seen %@) sigma %.2f%@", $0.used.rawValue, $0.feature?.rawValue ?? "-", $0.bandPixels,
                   $0.measuredBandPixels.map { String(format: "%.1f", $0) } ?? "-", $0.topSigmaPixels, $0.modelPlaced ? " model-placed" : "")
        }.joined(separator: "; ")
    }

    /// The near side's band on the owner's slab is wider than the vertical 1 in model predicts: 1.3x seen 50 deg down,
    /// about 2x seen 76 deg down (the kit's steep views measured 1.83-1.86x). With the profile a lit band lands on the
    /// top edge from the outer outline and from the top one; the vertical model on the same renders leaves sides off.
    func testAWideLitBandLandsOnTheTopEdge() {
        for v in Self.views {
          for (pitch, least) in [(50.0, 1.2), (76, 1.8)] {
            let s = scene(v, band: 150, pitch: pitch), frame = s.render()
            let wide = Geometry.predictBands(pose: s.view.pose, outline: s.view.corners, intrinsics: v.K, spec: TestProfiles.sloped)
            let narrow = Geometry.predictBands(pose: s.view.pose, outline: s.view.corners, intrinsics: v.K, spec: .standard)
            let near = (0..<4).max { wide[$0].start + wide[$0].end < wide[$1].start + wide[$1].end }!
            let ratio = (wide[near].start + wide[near].end) / (narrow[near].start + narrow[near].end)
            print(String(format: "  %@: near band %.1f px, the vertical model's %.1f px (%.2fx)", v.label, (wide[near].start + wide[near].end) / 2,
                         (narrow[near].start + narrow[near].end) / 2, ratio))
            XCTAssertGreaterThan(ratio, least, v.label); XCTAssertLessThan(ratio, 3.6, v.label)
            for (start, q) in [("outer", s.outerOutline()), ("top", s.view.corners)] {
                guard let r = EdgeRefiner().refine(outline: q, frame: frame, intrinsics: v.K, spec: s.view.spec, down: s.view.down) else {
                    XCTFail("\(v.label) from \(start): no result"); continue
                }
                let e = errors(r, s)
                print(String(format: "  %@ from the %@ outline: worst corner %.2f px, normal %.2f deg; %@", v.label, start, e.corners.max()!, e.normal, describe(r)))
                XCTAssertLessThan(e.corners.max()!, 0.6, "\(v.label) from \(start)")
                XCTAssertLessThan(e.normal, 1.0)
                XCTAssertTrue(r.sides[near].twoEdges, "\(v.label): both edges of the near band seen")
                XCTAssertEqual(r.sides[near].measuredBandPixels ?? 0, (wide[near].start + wide[near].end) / 2, accuracy: 0.5)
            }
            if let r = EdgeRefiner().refine(outline: s.outerOutline(), frame: frame, intrinsics: v.K, spec: .standard, down: s.view.down) {
                let e = errors(r, s)
                print(String(format: "  %@ pitch %.0f, the vertical model: worst corner %.2f px, normal %.2f deg", v.label, pitch, e.corners.max()!, e.normal))
            }
          }
        }
    }

    /// A side seen edge-on (the camera straight above its top edge): the vertical model sees no band there, the sloped
    /// face shows one of R f / d. The refiner sees both its edges, measures that band, and its line is on the top edge.
    /// (Edge-on from 0.6-0.8 m is 6-9 deg from face-on, where every face shows: the other sides are held to their sigmas.)
    func testAnEdgeOnSideShowsItsRunAndItsLineIsOnTheTop() {
        for v in Self.views {
            // a level slab, unturned: the near side's middle is straight below the camera when d cos(pitch) = half the side
            let pitch = Units.degrees(acos(TestProfiles.sloped.halfU / v.distance))
            for band: Float in [150, 60] {
                let s = scene(v, band: band, pitch: pitch, tilt: 0, heading: 0, yaw: 0), frame = s.render()
                guard let fit = PoseSolver.solve(corners: s.view.corners, intrinsics: v.K, spec: s.view.spec, down: s.view.down),
                      let r = EdgeRefiner().refine(outline: s.outerOutline(), frame: frame, intrinsics: v.K, spec: s.view.spec, down: s.view.down) else {
                    XCTFail("\(v.label): no result"); continue
                }
                let box = SlabBoxView(fit: fit, spec: s.view.spec, intrinsics: v.K)
                let near = (0..<4).min { abs(Units.degrees(box.sideProfile(outlineSide: $0)!.viewAngle) - 90) < abs(Units.degrees(box.sideProfile(outlineSide: $1)!.viewAngle) - 90) }!
                let p = box.sideProfile(outlineSide: near)!
                XCTAssertEqual(Units.degrees(p.viewAngle), 90, accuracy: 0.5)
                let depth = ((box.topCorners[0] + box.topCorners[1] + box.topCorners[2] + box.topCorners[3]) / 4).z
                print(String(format: "  %@ band %.0f: edge-on side %d, predicted band %.2f px (R f / d about %.2f), seen %@; worst corner %.2f px; %@", v.label, band, near,
                             p.bandMiddle, 0.0075 * v.K.fx / depth, r.sides[near].measuredBandPixels.map { String(format: "%.2f", $0) } ?? "-",
                             errors(r, s).corners.max()!, describe(r)))
                XCTAssertTrue(p.faceVisible)
                XCTAssertEqual(r.sides[near].feature, .departure)
                XCTAssertTrue(r.sides[near].twoEdges, "\(v.label) band \(band)")
                XCTAssertEqual(r.sides[near].measuredBandPixels ?? 0, p.bandMiddle, accuracy: 0.4, "\(v.label) band \(band)")
                let off = sideOffsets(r.outline, s.view.corners)
                XCTAssertLessThan(max(abs(off[near].0), abs(off[near].1)), 0.3, "\(v.label) band \(band): the edge-on side's line")
                for i in 0..<4 {
                    XCTAssertLessThanOrEqual(max(abs(off[i].0), abs(off[i].1)), 2 * r.sides[i].topSigmaPixels, "\(v.label) band \(band) side \(i)")
                }
            }
        }
    }

    /// A band about as light as the top (105, top 105) on the black base shows one step per side: the band's bottom (the
    /// top edge a band in) or, were the band dark, the top edge itself. The refiner flags those sides (model-placed, an
    /// ambiguity of half the band either way), and the truth lies inside each side's sigma.
    func testAnAsLightBandIsFlaggedWithTheTruthInsideItsSigma() {
        for v in Self.views {
            for (pitch, yaw) in [(50.0, 15.0), (35, -25), (65, 40)] {
                let s = scene(v, band: 105, pitch: pitch, yaw: yaw), frame = s.render()
                guard let r = EdgeRefiner().refine(outline: s.outerOutline(), frame: frame, intrinsics: v.K, spec: s.view.spec, down: s.view.down) else {
                    XCTFail("\(v.label) pitch \(pitch): no result"); continue
                }
                let off = sideOffsets(r.outline, s.view.corners)
                print(String(format: "  %@ pitch %.0f: offsets %@; %@", v.label, pitch,
                             off.map { String(format: "%+.2f/%+.2f", $0.0, $0.1) }.joined(separator: " "), describe(r)))
                var flagged = 0
                for i in 0..<4 {
                    let e = r.sides[i]
                    XCTAssertLessThanOrEqual(max(abs(off[i].0), abs(off[i].1)), 2 * e.topSigmaPixels + 0.1, "\(v.label) pitch \(pitch) side \(i)")
                    if e.feature == .departure {
                        XCTAssertFalse(e.twoEdges)
                        XCTAssertTrue(e.modelPlaced, "\(v.label) pitch \(pitch) side \(i)")
                        XCTAssertEqual(e.ambiguityShiftPixels, e.bandPixels / 2, accuracy: 1e-9)
                        XCTAssertGreaterThanOrEqual(e.topSigmaPixels, e.bandPixels / 2)
                        flagged += 1
                    }
                }
                XCTAssertGreaterThan(flagged, 0)
            }
        }
    }

    /// Learning the profile from a wrong prior, the vertical 1 in box (face drop 25.4 mm, no run): over views from
    /// several sides and distances, with lit and shadowed bands, the face drop and run come within 1.5 mm of the
    /// render's (21.5 / 7.5 mm), and stay there; early detections do not hold it.
    func testTheProfileIsLearnedFromTheVerticalPrior() {
        let v = Self.views[0]
        let prior = TestProfiles.verticalPrior
        var choice: EdgeChoice? = nil
        var trace: [(Double, Double)] = []
        for k in 0..<14 {
            let pitch = 38 + Double(k % 5) * 6, yaw = -30 + Double(k * 23 % 60), d = 0.6 + 0.05 * Double(k % 4)
            let s = BoxScene(view: SyntheticView.make(pitch: pitch, distance: d, tilt: 5, heading: 30 + Double(k) * 25, yaw: yaw, spec: TestProfiles.sloped,
                                                      intrinsics: v.K), bandLuma: k % 2 == 0 ? 150 : 60)
            let frame = s.render()
            guard let r = EdgeRefiner().refine(outline: s.outerOutline(), frame: frame, intrinsics: v.K, spec: prior, down: s.view.down, choice: choice),
                  let p = r.choice.profile else {
                XCTFail("view \(k): no result"); continue
            }
            choice = r.choice
            trace.append((p.faceDrop * 1000, p.sideRun * 1000))
            print(String(format: "  view %d (pitch %.0f, %.2f m): learned H %.2f mm, R %.2f mm from %d bands; worst corner %.2f px; %@", k, pitch, d,
                         p.faceDrop * 1000, p.sideRun * 1000, p.resolved, errors(r, s).corners.max()!, describe(r)))
        }
        guard let last = trace.last, let p = choice?.profile else { return XCTFail("nothing learned") }
        XCTAssertGreaterThanOrEqual(p.resolved, EdgeRefiner.Options().learnAfter)
        XCTAssertEqual(last.0, 21.5, accuracy: 1.5)
        XCTAssertEqual(last.1, 7.5, accuracy: 1.5)
        // it got there and stayed: the last five within 1.5 mm
        for t in trace.suffix(5) { XCTAssertEqual(t.0, 21.5, accuracy: 1.5); XCTAssertEqual(t.1, 7.5, accuracy: 1.5) }
        // the learned sigmas replace the prior's, with their floors
        let sg = p.sigmas(EdgeRefiner.Options())
        XCTAssertLessThan(sg[0], EdgeRefiner.Options().faceDropPriorSigma); XCTAssertGreaterThanOrEqual(sg[0], EdgeRefiner.Options().learnedFaceDropFloor)
        XCTAssertGreaterThanOrEqual(sg[1], EdgeRefiner.Options().learnedSideRunFloor)
    }

    /// Nearly face-on (the camera 10 and 15 deg from the slab's normal): every sloped face shows (from across the slab
    /// too, below 19.2 deg). Lit and shadowed bands put every line on the top edge; with bands about as light as the top
    /// each side's truth lies inside its sigma. (On the kit neither checker's finder handled this view: renders only.)
    func testNearlyFaceOnEveryFaceShows() {
        for v in Self.views {
            for theta in [10.0, 15.0] {
                for band: Float in [150, 60, 105] {
                    let s = scene(v, band: band, pitch: 90 - theta, tilt: 3, heading: 30, yaw: 15), frame = s.render()
                    guard let r = EdgeRefiner().refine(outline: s.outerOutline(), frame: frame, intrinsics: v.K, spec: s.view.spec, down: s.view.down) else {
                        XCTFail("\(v.label) theta \(theta) band \(band): no result"); continue
                    }
                    let e = errors(r, s), off = sideOffsets(r.outline, s.view.corners)
                    let shown = (0..<4).filter { s.box.cutFaceVisible(side: $0) }.count
                    print(String(format: "  %@ theta %.0f band %.0f: %d faces show; worst corner %.2f px, normal %.2f deg; %@", v.label, theta, band, shown,
                                 e.corners.max()!, e.normal, describe(r)))
                    if theta <= 10 { XCTAssertEqual(shown, 4, "\(v.label) theta \(theta)") }
                    if band == 105 {
                        for i in 0..<4 {
                            XCTAssertLessThanOrEqual(max(abs(off[i].0), abs(off[i].1)), 2 * r.sides[i].topSigmaPixels + 0.1, "\(v.label) theta \(theta) side \(i)")
                        }
                    } else {
                        XCTAssertLessThan(e.corners.max()!, 0.6, "\(v.label) theta \(theta) band \(band)")
                    }
                }
            }
        }
    }

    /// A rounded edge, at the image size the phone refines on (ARKit's 1920x1440; the processing frame a quarter of it):
    /// seen from 20-40 deg off the normal, the near sides' departure (at the rounding's psi_n) and the far sides' outline
    /// (the rounding's tangent point) refer to the same flat top: corners within 0.3 processing pixels and the normal
    /// within 0.5 deg. The render lights the rounding like the top before psi_n and like the face after it (the spec's
    /// convention); the cradle is drawn 20% wider than the faces reach, so the far side's outline lies on black.
    func testARoundedEdgeGivesOneFlatTop() {
        let KF = CameraIntrinsics(fx: 1450, fy: 1450, cx: 960, cy: 720, width: 1920, height: 1440), K4 = KF.scaled(by: 0.25)
        for spec in [TestProfiles.rounded(0.002, psiN: Units.radians(45)), TestProfiles.rounded(0.004, psiN: Units.radians(45))] {
            for (pitch, d) in [(50.0, 0.8), (60, 1.0), (68, 1.2)] {
                for band: Float in [150, 60] {
                    var s = BoxScene(view: SyntheticView.make(pitch: pitch, distance: d, tilt: 6, heading: 30, yaw: 15, spec: spec, intrinsics: KF), bandLuma: band)
                    s.baseScale = 1.2
                    let frame = s.render()
                    let q4 = s.outerOutline().map { $0 * 0.25 }
                    guard let r = EdgeRefiner().refine(outline: q4, intrinsics: K4, luma: frame.y, lumaIntrinsics: KF, spec: spec, down: s.view.down) else {
                        XCTFail("r \(spec.edgeRadius) pitch \(pitch): no result"); continue
                    }
                    let truth4 = s.view.corners.map { $0 * 0.25 }
                    let e = (0..<4).map { r.outline[$0].distance(to: truth4[$0]) }, ne = angleDeg(r.fit.pose.normal, s.view.pose.normal)
                    print(String(format: "  r %.0f mm psi_n 45, pitch %.0f, %.1f m, band %.0f: worst corner %.3f px (processing), normal %.2f deg; %@",
                                 spec.edgeRadius * 1000, pitch, d, band, e.max()!, ne, describe(r)))
                    XCTAssertLessThan(e.max()!, 0.3, "r \(spec.edgeRadius) pitch \(pitch) band \(band)")
                    XCTAssertLessThan(ne, 0.5, "r \(spec.edgeRadius) pitch \(pitch) band \(band)")
                }
            }
        }
    }

    /// The app's effective convention for the owner's slab (r 2 mm with the near departure at the rounding's start,
    /// `SlabSpec.ownerSlab`), on renders that light the whole rounding like the face: where the rounding is dark or as
    /// light as the floor beyond, a far side's step is its departure, not its outline, up to r (1 - cos beta) off. That
    /// is what the rounding's sigma (`Options.edgeRadiusSigma`, 1.5 mm) is for: every side's truth stays inside two of its
    /// sigmas.
    func testTheEffectiveRoundingStaysInsideItsSigma() {
        let KF = CameraIntrinsics(fx: 1450, fy: 1450, cx: 960, cy: 720, width: 1920, height: 1440), K4 = KF.scaled(by: 0.25)
        let spec = TestProfiles.rounded(0.002)
        for (pitch, d) in [(50.0, 0.8), (65, 1.2), (35, 1.0)] {
            for band: Float in [40, 150] {
                let s = BoxScene(view: SyntheticView.make(pitch: pitch, distance: d, tilt: 6, heading: 30, yaw: 15, spec: spec, intrinsics: KF), bandLuma: band)
                let frame = s.render()
                guard let r = EdgeRefiner().refine(outline: s.outerOutline().map { $0 * 0.25 }, intrinsics: K4, luma: frame.y, lumaIntrinsics: KF,
                                                   spec: spec, down: s.view.down) else { XCTFail("pitch \(pitch): no result"); continue }
                let off = sideOffsets(r.outline, s.view.corners.map { $0 * 0.25 })
                print(String(format: "  pitch %.0f band %.0f: offsets %@ (processing px); %@", pitch, band,
                             off.map { String(format: "%+.2f/%+.2f", $0.0, $0.1) }.joined(separator: " "), describe(r)))
                for i in 0..<4 {
                    XCTAssertLessThanOrEqual(max(abs(off[i].0), abs(off[i].1)), 2 * r.sides[i].topSigmaPixels, "pitch \(pitch) band \(band) side \(i)")
                }
            }
        }
    }

    /// The owner's slab as the app's demo and the synthetic kits draw it (`SyntheticScene`, r 2 mm, the near departure at
    /// the rounding's start), read the way the app reads it: the outline in a 480x360 frame, the edges in the full
    /// 1920x1440 image (here a crop round the slab, as `SlabImageCrop` cuts it). Near sides (read at their departure) and
    /// far sides (at their outline) land on the true flat-top edge: both kinds' mean signed offsets under 0.1 processing
    /// pixel (measured 0.02). (Read in the 480x360 frame itself, as the synthetic kits' 480x360 videos are, the near
    /// sides' departure lands 0.24 px inside: the lit rounding and the face meet within one pixel there, and the image's own
    /// halfway point between the top's level and the band's lies 0.27-0.41 px inside the edge. That moves those kits'
    /// lock plane by a few millimetres; KitScorerTests allow for it.)
    func testTheOwnersSlabReadAtTheAppsResolutionHasNoEdgeBias() throws {
        let spec = SlabSpec.ownerSlab
        let full = CameraIntrinsics(fx: 0.78 * 1920, fy: 0.78 * 1920, cx: 960, cy: 720, width: 1920, height: 1440), proc = full.scaled(by: 0.25)
        var near: [Double] = [], far: [Double] = []
        for (el, dist, hd) in [(45.0, 0.9, 30.0), (55, 1.0, 210), (40, 1.3, 300), (60, 0.7, 120), (50, 0.6, 30), (45, 1.1, 210)] {
            let pose = SyntheticScene.slabPose(tilt: 6, heading: hd, yaw: 20, spec: spec)
            let scene = SyntheticScene(spec: spec, slab: pose)
            let e = Units.radians(el)
            let view = SyntheticScene.camera(at: pose.center + Vec3(cos(e), sin(e), 0.3).normalized * dist, lookingAt: pose.center, intrinsics: full)
            let truth = try XCTUnwrap(scene.corners(in: view))
            // the crop round the slab, rendered at full resolution
            let m = 80.0
            let x0 = max(0, (truth.map { $0.x }.min()! - m).rounded(.down)), y0 = max(0, (truth.map { $0.y }.min()! - m).rounded(.down))
            let x1 = min(1920, (truth.map { $0.x }.max()! + m).rounded(.up)), y1 = min(1440, (truth.map { $0.y }.max()! + m).rounded(.up))
            let Kc = full.cropped(x0: x0, y0: y0, scale: 1, width: Int(x1 - x0), height: Int(y1 - y0))
            let crop = SyntheticScene.ycc(rgb: scene.renderRGB(view: CameraView(worldFromCamera: view.worldFromCamera, intrinsics: Kc)),
                                          width: Kc.width, height: Kc.height).luma
            let tp = truth.map { $0 * 0.25 }, c = Geometry.centroid(tp)
            let down = view.directionToCamera(ARKitConvention.worldDown)
            guard let r = EdgeRefiner().refine(outline: tp.map { c + ($0 - c) * 1.05 }, intrinsics: proc, luma: crop, lumaIntrinsics: Kc, spec: spec, down: down) else {
                XCTFail("el \(el) d \(dist): no result"); continue
            }
            let off = sideOffsets(r.outline, tp)
            print(String(format: "  el %.0f, %.1f m: offsets %@ (processing px); %@", el, dist,
                         off.map { String(format: "%+.2f/%+.2f", $0.0, $0.1) }.joined(separator: " "), describe(r)))
            for i in 0..<4 {
                let mid = (off[i].0 + off[i].1) / 2
                if r.sides[i].feature == .departure { near.append(mid) } else { far.append(mid) }
            }
        }
        let mn = near.reduce(0, +) / Double(max(1, near.count)), mf = far.reduce(0, +) / Double(max(1, far.count))
        print(String(format: "OWNER SLAB at the app's resolution: near sides %+.3f px (n %d), far sides %+.3f px (n %d)", mn, near.count, mf, far.count))
        XCTAssertGreaterThan(near.count, 3); XCTAssertGreaterThan(far.count, 3)
        XCTAssertLessThan(abs(mn), 0.1)
        XCTAssertLessThan(abs(mf), 0.1)
    }

    /// Every side's sigma is built from measured terms: at least the still-frame jitter floor and the edge's definition
    /// on the slab (0.5 mm at the side's distance), in quadrature with the rest; a turn sigma at least its floor.
    func testSideSigmasHaveTheirMeasuredFloors() {
        let v = Self.views[0], o = EdgeRefiner.Options()
        let s = scene(v, band: 150), frame = s.render()
        guard let r = EdgeRefiner().refine(outline: s.outerOutline(), frame: frame, intrinsics: v.K, spec: s.view.spec, down: s.view.down) else {
            return XCTFail("no result")
        }
        let j0 = o.edgeJitterRadians * v.K.fx, t0 = o.turnFloorRadians * v.K.fx
        for e in r.sides {
            let def = o.edgeDefinitionSigma * v.K.fx / 0.85   // the sides lie 0.7-0.9 m away
            XCTAssertGreaterThanOrEqual(e.topSigmaPixels, (j0 * j0 + def * def).squareRoot() * 0.9)
            XCTAssertGreaterThanOrEqual(e.turnSigmaPixels, t0 - 1e-12)
            XCTAssertNotNil(e.feature)
        }
    }
}
