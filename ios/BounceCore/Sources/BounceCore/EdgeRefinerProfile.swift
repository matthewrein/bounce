import Foundation

/// Which feature of a side the edge refiner's line rests on, with a side profile (`SlabSpec.hasProfile`).
public enum SideFeature: String, Codable, Equatable {
    /// the side's face shows with a band wide enough to resolve (`EdgeRefiner.Options.bandSwitchPixels`): the top face's
    /// luma departure, at the profile's near feature angle (`SlabSpec.nearFeatureAngle`)
    case departure
    /// the face is hidden, or shows too thin a band to resolve: the side's outline against what lies beyond it (the
    /// rounded edge's tangent point, or the bottom of a face seen at a grazing angle)
    case outline
}

/// What the edge refiner learns of the slab's side profile while it follows one slab (`EdgeChoice.profile`): the face's
/// drop H and side run R, by least squares from the bands whose two edges were both seen (band = the profile's predicted
/// band, linear in H and R to first order), with the spec's values as a Gaussian prior.
///
/// Robust and bounded, so it cannot latch onto early misreads: each update refits all kept observations (the newest
/// `Options.profileMemory`) from the prior, with Cauchy weights whose scale is the observations' own spread (plain least
/// squares while there are fewer than 4), and the result is kept within 3 prior sigmas of the prior. Its sigmas are the
/// prior's until `Options.learnAfter` bands were seen, then the fit's, floored (`learnedFaceDropFloor`,
/// `learnedSideRunFloor`: views of one slab share systematic errors the fit's sigma does not know about).
public struct ProfileLearning: Equatable, Codable {
    public struct Observation: Equatable, Codable {
        /// the band seen and the band predicted (pixels of the image searched), the profile it was predicted with (metres)
        public var measured: Double
        public var predicted: Double
        public var faceDrop: Double
        public var sideRun: Double
        /// d(band)/d(faceDrop), d(band)/d(sideRun) (pixels per metre)
        public var dFaceDrop: Double
        public var dSideRun: Double
        /// the measured band's standard deviation (pixels)
        public var sigma: Double
    }
    public var priorFaceDrop: Double
    public var priorSideRun: Double
    public var priorSigmaFaceDrop: Double
    public var priorSigmaSideRun: Double
    /// the current estimate and the fit's sigmas (before floors)
    public var faceDrop: Double
    public var sideRun: Double
    public var fitSigmaFaceDrop: Double
    public var fitSigmaSideRun: Double
    /// the kept observations (newest last) and how many bands were seen in all
    public var observations: [Observation]
    public var resolved: Int

    public init(spec: SlabSpec, options: EdgeRefiner.Options) {
        priorFaceDrop = spec.drop; priorSideRun = spec.sideRun
        priorSigmaFaceDrop = options.faceDropPriorSigma; priorSigmaSideRun = options.sideRunPriorSigma
        faceDrop = priorFaceDrop; sideRun = priorSideRun
        fitSigmaFaceDrop = priorSigmaFaceDrop; fitSigmaSideRun = priorSigmaSideRun
        observations = []; resolved = 0
    }

    /// whether enough bands were seen for the learned values and sigmas to stand
    public func learned(_ options: EdgeRefiner.Options) -> Bool { resolved >= options.learnAfter }

    /// the spec with the learned face drop and side run
    public func spec(_ base: SlabSpec) -> SlabSpec { base.withProfile(faceDrop: faceDrop, sideRun: sideRun) }

    /// The profile's sigmas (faceDrop, sideRun, edgeRadius; metres): the prior's until learned, then the fit's with floors.
    public func sigmas(_ options: EdgeRefiner.Options) -> [Double] {
        guard learned(options) else { return [priorSigmaFaceDrop, priorSigmaSideRun, options.edgeRadiusSigma] }
        return [max(fitSigmaFaceDrop, options.learnedFaceDropFloor), max(fitSigmaSideRun, options.learnedSideRunFloor), options.edgeRadiusSigma]
    }

    /// Add this call's observations and refit.
    public mutating func add(_ obs: [Observation], options: EdgeRefiner.Options) {
        guard !obs.isEmpty else { return }
        observations += obs
        if observations.count > options.profileMemory { observations.removeFirst(observations.count - options.profileMemory) }
        resolved += obs.count
        refit()
    }

    mutating func refit() {
        let p0 = [priorFaceDrop, priorSideRun]
        let w0 = [1 / (priorSigmaFaceDrop * priorSigmaFaceDrop), 1 / (priorSigmaSideRun * priorSigmaSideRun)]
        let lo = [max(1e-4, p0[0] - 3 * priorSigmaFaceDrop), max(0, p0[1] - 3 * priorSigmaSideRun)]
        let hi = [p0[0] + 3 * priorSigmaFaceDrop, p0[1] + 3 * priorSigmaSideRun]
        var th = p0
        var cov = [[1 / w0[0], 0], [0, 1 / w0[1]]]
        func residual(_ o: Observation, _ t: [Double]) -> Double {
            o.measured - (o.predicted + o.dFaceDrop * (t[0] - o.faceDrop) + o.dSideRun * (t[1] - o.sideRun))
        }
        for _ in 0..<10 {
            // robust scale: the observations' own spread in their sigmas (none while there are too few to judge)
            var w = [Double](repeating: 1, count: observations.count)
            if observations.count >= 4 {
                let z = observations.map { abs(residual($0, th)) / max($0.sigma, 1e-9) }.sorted()
                let s = max(1, 1.4826 * z[z.count / 2])
                for (k, o) in observations.enumerated() {
                    let u = residual(o, th) / (2.385 * s * max(o.sigma, 1e-9))
                    w[k] = 1 / (1 + u * u)
                }
            }
            var A = [[w0[0], 0.0], [0.0, w0[1]]], b = [w0[0] * p0[0], w0[1] * p0[1]]
            for (k, o) in observations.enumerated() {
                let J = [o.dFaceDrop, o.dSideRun], iv = w[k] / max(o.sigma * o.sigma, 1e-12)
                let y = o.measured - o.predicted + o.dFaceDrop * o.faceDrop + o.dSideRun * o.sideRun
                for a in 0..<2 {
                    b[a] += iv * J[a] * y
                    for c in 0..<2 { A[a][c] += iv * J[a] * J[c] }
                }
            }
            let det = A[0][0] * A[1][1] - A[0][1] * A[1][0]
            guard abs(det) > 1e-30 else { break }
            cov = [[A[1][1] / det, -A[0][1] / det], [-A[1][0] / det, A[0][0] / det]]
            let next = [clamp(cov[0][0] * b[0] + cov[0][1] * b[1], lo[0], hi[0]), clamp(cov[1][0] * b[0] + cov[1][1] * b[1], lo[1], hi[1])]
            let moved = abs(next[0] - th[0]) + abs(next[1] - th[1])
            th = next
            if moved < 1e-7 { break }
        }
        faceDrop = th[0]; sideRun = th[1]
        fitSigmaFaceDrop = max(0, cov[0][0]).squareRoot(); fitSigmaSideRun = max(0, cov[1][1]).squareRoot()
    }
}

/// One step found in a luma profile: where it crosses halfway between the levels either side of it (an offset), where
/// its gradient peaks (sub-sample), and those levels. The two agree on a clean step; next to a narrow lobe or dip (a
/// sliver of the black base between the slab and a light floor, a thin highlight) the half crossing moves with the
/// lobe's depth, which blur reduces, while the gradient's peak stays on the step itself.
struct LumaStep: Equatable {
    var at: Double
    var before: Double
    var after: Double
    var peak: Double
    var size: Double { after - before }
}

/// One run along a side, read by the profile refiner: where it lies along the side, the top's level and the step
/// threshold just inside it, and the steps in its median luma profile.
struct ProfileSegment {
    var x: Double
    var top: Double
    var threshold: Double
    var steps: [LumaStep]
}

/// One side read by the profile refiner.
struct ProfileSideReading {
    /// the side's top line (the flat top's edge), as offsets from the given line at the side's two ends
    var top0: Double
    var top1: Double
    var edge: SideEdge
    var state: EdgeChoice.Side
    var observation: ProfileLearning.Observation?
}

extension EdgeRefiner {
    /// The refiner with the slab's side profile (`SlabSpec.hasProfile`; see `EdgeRefiner`'s notes): every side's line on
    /// its own feature (the departure on sides whose face shows a resolvable band, the outline on the others), moved to
    /// the flat top's edge by the profile's predicted offset of that feature, and the flat top's square fitted to those
    /// lines; pose -> offsets -> lines is iterated.
    func refineWithProfile(outline: [Vec2], intrinsics K: CameraIntrinsics, luma: Plane, lumaIntrinsics KD: CameraIntrinsics,
                           spec: SlabSpec, down: Vec3?, choice: EdgeChoice?) -> Result? {
        let map = ImageMap(from: K, to: KD)
        let ds = map.scale, unit = EdgeRefiner.unit(scale: ds)
        let prevSides = choice?.sides(matching: outline)
        let expected = choice?.expectedLines(matching: outline).map { $0.map { (map.forward($0.0), map.forward($0.1)) } }
        var learning = choice?.profile ?? ProfileLearning(spec: spec, options: options)
        let specL = learning.spec(spec)
        let sigmas = learning.sigmas(options)
        var cur = outline.map(map.forward)
        var readings: [ProfileSideReading] = []
        var round = 0
        while true {
            round += 1
            let fit = PoseSolver.solve(corners: cur, intrinsics: KD, spec: specL, down: down, previousNormal: choice?.normal, options: options.pose)
            let box = fit.map { SlabBoxView(fit: $0, spec: specL, intrinsics: KD) }
            let c = Geometry.centroid(cur)
            var lines: [Line2] = []
            var maxBand = 0.0
            readings = []
            for i in 0..<4 {
                let A = cur[i], B = cur[(i + 1) % 4], len = A.distance(to: B)
                guard len > 4 * unit else { return nil }
                let dir = (B - A) / len
                var nrm = dir.perpendicular
                if nrm.dot((A + B) / 2 - c) < 0 { nrm = -nrm }
                let prof = box?.sideProfile(outlineSide: i)
                // pixels per metre at the side (for the edge's definition on the slab)
                var pxPerMetre = KD.focal
                if let bx = box {
                    let (s, _) = bx.poseSide(forOutlineSide: i), tc = bx.topCorners
                    pxPerMetre = KD.focal / max(0.05, ((tc[s] + tc[(s + 1) % 4]) / 2).z)
                }
                let r = readProfileSide(luma: luma, a: A, b: B, normal: nrm, len: len, profile: prof, sigmas: sigmas, pxPerMetre: pxPerMetre,
                                        focal: KD.focal, ds: ds, unit: unit, prev: prevSides?[i], expected: expected?[i], learning: learning,
                                        neighbours: (cur[(i + 3) % 4], cur[(i + 2) % 4]))
                maxBand = max(maxBand, r.edge.bandPixels * ds)
                let p0 = A + nrm * r.top0, p1 = B + nrm * r.top1
                lines.append(Line2(p: p0, d: (p1 - p0).normalized))
                readings.append(r)
            }
            // corners where the new lines cross (a corner that would jump implausibly far keeps its place)
            var next = cur
            for i in 0..<4 {
                let a = lines[(i + 3) % 4], b = lines[i]
                guard let p = a.intersection(b) else { continue }
                let side = min(cur[i].distance(to: cur[(i + 3) % 4]), cur[i].distance(to: cur[(i + 1) % 4]))
                if p.distance(to: cur[i]) < 0.2 * side + 2 * maxBand + 2 * ds { next[i] = p }
            }
            guard ShapeCheck.isConvex(next) else { return nil }
            let moved = zip(next, cur).map { $0.distance(to: $1) }.max() ?? 0
            cur = next
            if round >= max(1, options.iterations) && (moved <= options.settlePixels * ds || round >= max(options.iterations, options.maxIterations)) { break }
        }
        let out = cur.map(map.inverse)
        guard let fit = PoseSolver.solve(corners: out, intrinsics: K, spec: specL, down: down, previousNormal: choice?.normal, options: options.pose) else { return nil }
        learning.add(readings.compactMap { $0.observation }, options: options)
        let newChoice = EdgeChoice(sides: readings.map { $0.state }, outline: out, normal: fit.pose.normal, profile: learning)
        return Result(outline: out, fit: fit, sides: readings.map { $0.edge }, choice: newChoice)
    }

    /// Read one side with the profile: its top line (offsets from the given line A-B at its two ends, outward positive) and
    /// what was seen. `profile`: the side's predicted features (pixels of the image searched; nil without a pose).
    func readProfileSide(luma: Plane, a A: Vec2, b B: Vec2, normal nrm: Vec2, len: Double, profile prof: SideProfile?, sigmas: [Double],
                         pxPerMetre: Double, focal: Double, ds: Double, unit: Double, prev: EdgeChoice.Side?, expected: (Vec2, Vec2)?,
                         learning: ProfileLearning, neighbours: (Vec2, Vec2)? = nil) -> ProfileSideReading {
        let o = options
        func quad(_ d: [Double]) -> Double { zip(d, sigmas).reduce(0) { $0 + pow($1.0 * $1.1, 2) }.squareRoot() }
        let dep0 = prof?.departureStart ?? 0, dep1 = prof?.departureEnd ?? 0
        let out0 = prof?.outerStart ?? 0, out1 = prof?.outerEnd ?? 0
        let band0 = max(0, out0 - dep0), band1 = max(0, out1 - dep1), bandMid = max(0, prof?.bandMiddle ?? 0)
        let sigDep = prof.map { quad($0.departureDerivatives) } ?? 0
        let sigOut = prof.map { quad($0.outerDerivatives) } ?? 0
        let sigBandProfile = prof.map { quad($0.bandDerivatives) } ?? 0
        let j0 = o.edgeJitterRadians * focal, t0 = o.turnFloorRadians * focal
        let defPx = o.edgeDefinitionSigma * pxPerMetre
        // the band's width as predicted, with the profile's uncertainty and the two edges' jitter and the reading's half-step
        let sigBand = (sigBandProfile * sigBandProfile + 2 * j0 * j0 + pow(0.5 * unit, 2)).squareRoot()
        let departureSide = (prof?.faceVisible ?? false) && bandMid >= o.bandSwitchPixels
        let margin = max(3 * ds, 0.06 * len)
        // how far the runs' edge points may stray from one straight side and still be the same edge
        let lineTol = max(1, 2 * unit)
        func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

        // The side's luma read across it: per run along it (`Options.segments`), the median of its readings' profiles,
        // the top's level and ripple read just inside where an edge is looked for, and the steps in it (`lumaSteps`).
        let tWin = 6 * unit
        let nSeg = max(3, o.segments)
        // How deep each reading may look inward and still be on the top: near a corner that looks acute in the image the
        // inward reading leaves the top through the neighbouring side (`neighbours`: the corners before A and after B)
        // and would read that side's band as the top's level.
        func insideDepth(_ sp: SpokeProfiles) -> [Double] {
            guard let (P, N) = neighbours else { return [Double](repeating: .infinity, count: sp.n) }
            func depth(_ p: Vec2, _ q0: Vec2, _ q1: Vec2) -> Double {
                let m = -nrm, e = q1 - q0, den = m.cross(e)
                guard abs(den) > 1e-9 else { return .infinity }
                let s = (q0 - p).cross(e) / den
                return s > 0 ? s : .infinity
            }
            return sp.base.map { min(depth($0, A, P), depth($0, B, N)) }
        }
        func segments(_ sp: SpokeProfiles, inner: Double, outer: Double) -> [ProfileSegment] {
            var out: [ProfileSegment] = []
            func idx(_ off: Double) -> Int { clamp(Int(((off - sp.l0) / sp.step).rounded()), 0, sp.mL - 1) }
            let deep = insideDepth(sp), need = -inner + tWin
            // the step measure spans about one pixel of the image searched (its edges' own blur): a band two pixels wide
            // still shows its two edges apart
            let h = max(1, Int((0.5 / sp.step).rounded()))
            for s in 0..<nSeg {
                // the run's readings that stay on the top as deep as the top's level is read (at least two)
                let js = (0..<sp.n).filter { $0 * nSeg / sp.n == s && deep[$0] >= need }
                guard js.count >= 2 else { continue }
                var L = [Double](repeating: 0, count: sp.mL)
                var col = [Double](repeating: 0, count: js.count)
                for k in 0..<sp.mL {
                    for (q, j) in js.enumerated() { col[q] = Double(sp.lum[j * sp.mL + k]) }
                    col.sort()
                    L[k] = col.count % 2 == 1 ? col[col.count / 2] : (col[col.count / 2 - 1] + col[col.count / 2]) / 2
                }
                let kT0 = idx(inner - tWin), kT1 = idx(inner)
                let tv = Array(L[kT0...max(kT0, kT1)]).sorted()
                let T = tv[tv.count / 2]
                let mad = tv.map { abs($0 - T) }.sorted()[tv.count / 2] * 1.4826
                let thr = max(o.minPartnerContrast, 5 * 2.0.squareRoot() * mad)
                let steps = EdgeRefiner.lumaSteps(L, o0: sp.l0, step: sp.step, k0: kT1, k1: idx(outer), h: h, threshold: thr, levelBefore: T)
                out.append(ProfileSegment(x: js.map { sp.t[$0] }.reduce(0, +) / Double(js.count) * len, top: T, threshold: thr, steps: steps))
            }
            return out
        }
        // the outline in each run: the strongest step to darker (to the black base, or a lit face's bottom), or over a
        // background lighter than the top, the first step
        func outlineSteps(_ segs: [ProfileSegment]) -> [LumaStep?] {
            segs.map { g in g.steps.filter { $0.size < 0 }.min(by: { $0.size < $1.size }) ?? g.steps.first }
        }

        if !departureSide {
            // an outline side: its line is the outline, at the profile's outer offset from the flat top's edge
            let reach = margin + 3 * sigOut, inner = reach + max(out0, out1)
            let sp = SpokeProfiles(luma: luma, a: A, b: B, normal: nrm, inward: inner + tWin, outward: reach, unit: unit, count: o.spokes)
            let segs = segments(sp, inner: -inner, outer: reach)
            let picks = outlineSteps(segs)
            guard let fitL = EdgeRefiner.segmentLine(positions: segs.map { $0.x }, offsets: picks.map { $0?.peak }, segments: nil, tolerance: lineTol) else {
                return unfittedReading(prev: prev, band: bandMid / ds)
            }
            // A hidden face's outline is the rounding's tangent point. A face seen at a grazing angle shows its two edges too
            // close together to tell apart: a lit face (the step comes down from above the top's level) puts the step at its
            // bottom; otherwise the step may be either edge, so the line goes halfway and its sigma covers both.
            var in0 = out0, in1 = out1, amb = 0.0, profTerm = sigOut
            if prof?.faceVisible == true && bandMid > 0 {
                let lit = zip(segs, picks).filter { g, p in p.map { $0.before > g.top + g.threshold } ?? false }.count
                if lit * 2 <= picks.compactMap({ $0 }).count {
                    in0 = (out0 + dep0) / 2; in1 = (out1 + dep1) / 2; amb = bandMid / 2
                    profTerm = prof.map { quad(zip($0.outerDerivatives, $0.departureDerivatives).map { ($0 + $1) / 2 }) } ?? sigOut
                }
            }
            let fitSig = fitL.sigma, turn = max(fitL.slopeSigma * len / 2, t0)
            let par = (pow(max(fitSig, j0), 2) + defPx * defPx + profTerm * profTerm + amb * amb).squareRoot()
            let sizes = picks.compactMap { $0?.size }.sorted()
            let mu = sizes.isEmpty ? 0 : sizes[sizes.count / 2]
            var e = SideEdge(mode: .silhouette, bandPixels: bandMid / ds, contrast: abs(mu), outerContrast: mu, innerContrast: 0, shift: 0,
                             points: fitL.count, outsideRatio: 0, observed: .silhouette, used: .silhouette)
            e.feature = .outline; e.topSigmaPixels = par / ds; e.turnSigmaPixels = turn / ds; e.fitSigmaPixels = fitSig / ds
            e.frameSigmaPixels = max(fitSig, j0) / ds
            e.segments = fitL.count; e.twoEdges = false
            return ProfileSideReading(top0: fitL.offset(0) - in0, top1: fitL.offset(len) - in1, edge: e,
                                      state: EdgeChoice.Side(mode: .silhouette, sightings: prev?.sightings ?? 0), observation: nil)
        }

        // a departure side: the top face's luma departure, and the band's bottom one predicted band further out
        let reachIn = margin + max(band0, band1) + 3 * sigBand + 3 * sigDep
        let reachOut = margin + max(out0, out1) + 3 * sigBand + 3 * sigOut
        let sp = SpokeProfiles(luma: luma, a: A, b: B, normal: nrm, inward: reachIn + tWin, outward: reachOut, unit: unit, count: o.spokes)
        let segs = segments(sp, inner: -reachIn, outer: reachOut)
        // Per run: either the top's departure (onto a band of its own level, or onto a band in deep shadow whose bottom onto
        // the base shows) with the band's bottom where the profile puts it, or the one step to the background (onto the
        // black base, or onto a floor the band meets directly), whose gradient peak is the side's outline. A run whose
        // departure is too faint to see (a band a few grey from the top) reads as the second kind even where its
        // neighbours see the first: the two are never mixed in one line.
        var depOff: [Double?] = [], bgPeak: [Double?] = [], bottomOK: [Bool] = []
        var measured: [(band: Double, predicted: Double)] = []
        var stepSizes: [Double] = [], firstSteps: [Double] = []
        var levels: (top: Double, far: Double) = (0, 0)
        for g in segs {
            let T = g.top, steps = g.steps
            guard let first = steps.first else { depOff.append(nil); bgPeak.append(nil); bottomOK.append(false); continue }
            firstSteps.append(first.size)
            stepSizes.append(steps.map { abs($0.size) }.max() ?? 0)
            let bandHere = lerp(band0, band1, g.x / len)
            let far = steps.last!.after
            levels.top += T / Double(segs.count); levels.far += far / Double(segs.count)
            // the band's bottom: a later step about one predicted band out, before the luma reaches the black base (the
            // slab sits on it: a step out of black is the base's own edge). A first step that lands on black is the step to
            // the base or onto a band in deep shadow: only a further darkening onto the base can be the band's bottom, and
            // only one that leaves the band clearly lighter than the black beyond it (`Options.darkBandContrast`): the
            // band is the slab's own light material in shadow, while the cradle's black top and its shaded side, a few
            // millimetres beyond the face's bottom, differ by far less and would otherwise pass for a dark band's edges.
            let dark = o.darkRatio * T
            var cands: [LumaStep] = []
            if first.after >= dark {
                for st in steps.dropFirst() { cands.append(st); if st.after < dark { break } }
            } else if steps.count > 1, steps[1].size < 0, first.after - steps[1].after >= max(g.threshold, o.darkBandContrast * first.after) {
                cands = [steps[1]]
            }
            cands = cands.filter { abs(($0.at - first.at) - bandHere) <= 3 * sigBand }
            if let e = cands.min(by: { abs(($0.at - first.at) - bandHere) < abs(($1.at - first.at) - bandHere) }) {
                depOff.append(first.at); bgPeak.append(nil); bottomOK.append(true)
                measured.append((e.at - first.at, bandHere))
            } else if first.after < dark || abs(first.after - far) <= max(g.threshold, 0.25 * abs(T - far)) {
                // the one step seen goes to the background: onto the black base, or onto the level that lies beyond
                depOff.append(nil); bgPeak.append(first.peak); bottomOK.append(false)
            } else {
                // the top's departure into a band of its own level, whose bottom is not where the profile puts it
                depOff.append(first.at); bgPeak.append(nil); bottomOK.append(false)
            }
        }
        let nDep = depOff.compactMap { $0 }.count, nBg = bgPeak.compactMap { $0 }.count
        var line: SegmentLine? = nil
        var twoEdges = false, stepToBackground = false
        if nDep >= 3 && nDep >= nBg, let l = EdgeRefiner.segmentLine(positions: segs.map { $0.x }, offsets: depOff, segments: nil, tolerance: lineTol) {
            line = l
            twoEdges = bottomOK.filter { $0 }.count >= 3
        } else if nBg >= 3, let l = EdgeRefiner.segmentLine(positions: segs.map { $0.x }, offsets: bgPeak, segments: nil, tolerance: lineTol) {
            line = l; stepToBackground = true
        } else if let l = EdgeRefiner.segmentLine(positions: segs.map { $0.x }, offsets: outlineSteps(segs).map { $0?.peak }, segments: nil, tolerance: lineTol) {
            // neither along the side: its outline, a single step (where it lies is ambiguous by a band)
            line = l; stepToBackground = true
        }
        guard line != nil else { return unfittedReading(prev: prev, band: bandMid / ds) }
        let L = line!
        // where the top line goes
        var used: EdgeMode, top0 = L.offset(0) - dep0, top1 = L.offset(len) - dep1
        var modelPlaced = false, shift = 0.0, profTerm = sigDep
        if twoEdges {
            used = .innerEdge
        } else if stepToBackground {
            // one step from the top's level to the background's: either the band is about as light as the top (the step is
            // its bottom: the top edge one band in) or it is about as dark as what lies beyond (the step is the top edge).
            // Remembered evidence decides (the last output, moved by the camera); else the band as light as the top, the
            // commoner case (a cut face lit like the top, on the black base). Either way the side's sigma covers both.
            var light = true
            if let ex = expected {
                let po = sp.offsets(of: Line2(p: ex.0, d: (ex.1 - ex.0).normalized))
                // the remembered top line's offset from the step: about -departure if the step is the top edge, about
                // -outer if it is the band's bottom
                let pe = zip(po, sp.t).map { $0.0 - L.offset($0.1 * len) }.reduce(0, +) / Double(po.count)
                let dTop = abs(pe + (dep0 + dep1) / 2), dIn = abs(pe + (out0 + out1) / 2)
                if abs(dTop - dIn) >= o.predictionMargin * bandMid && min(dTop, dIn) <= o.predictionReach * bandMid + ds { light = dIn < dTop }
            }
            if light {
                used = .shiftedOuter; modelPlaced = true; shift = bandMid / 2
                top0 = L.offset(0) - out0; top1 = L.offset(len) - out1
                profTerm = sigOut
            } else {
                used = .outerIsTop; shift = -bandMid / 2
            }
        } else {
            // the top's departure into a band of its own level, whose bottom was not found where the profile puts it
            used = .outerIsTop
        }
        let fitSig = L.sigma, turn = max(L.slopeSigma * len / 2, t0)
        let amb = twoEdges ? 0.0 : bandMid / 2
        let par = (pow(max(fitSig, j0), 2) + defPx * defPx + profTerm * profTerm + amb * amb).squareRoot()
        var obs: ProfileLearning.Observation? = nil
        if twoEdges, let p = prof {
            let mb = measured.map { $0.band }.reduce(0, +) / Double(measured.count)
            let pb = measured.map { $0.predicted }.reduce(0, +) / Double(measured.count)
            let dd = p.bandDerivatives
            let sm = (2 * pow(max(fitSig, j0), 2) + pow(dd[2] * sigmas[2], 2)).squareRoot()
            obs = ProfileLearning.Observation(measured: mb, predicted: pb, faceDrop: learning.faceDrop, sideRun: learning.sideRun,
                                              dFaceDrop: dd[0], dSideRun: dd[1], sigma: max(sm, 1e-3))
        }
        let firstStep = firstSteps.isEmpty ? 0 : firstSteps.sorted()[firstSteps.count / 2]
        let strongest = stepSizes.isEmpty ? 0 : stepSizes.sorted()[stepSizes.count / 2]
        var e = SideEdge(mode: used, bandPixels: bandMid / ds, contrast: abs(firstStep), outerContrast: -strongest, innerContrast: firstStep,
                         shift: modelPlaced || twoEdges ? 1 : 0, points: L.count, outsideRatio: levels.top > 0 ? levels.far / levels.top : 0,
                         observed: used, used: used)
        e.feature = .departure; e.topSigmaPixels = par / ds; e.turnSigmaPixels = turn / ds; e.fitSigmaPixels = fitSig / ds
        e.frameSigmaPixels = max(fitSig, j0) / ds
        e.segments = L.count; e.twoEdges = twoEdges; e.modelPlaced = modelPlaced; e.ambiguityShiftPixels = shift / ds
        if !measured.isEmpty { e.measuredBandPixels = measured.map { $0.band }.reduce(0, +) / Double(measured.count) / ds }
        let st = EdgeChoice.Side(mode: used, sightings: (prev?.sightings ?? 0) + (twoEdges ? 1 : 0))
        return ProfileSideReading(top0: top0, top1: top1, edge: e, state: st, observation: obs)
    }

    func unfittedReading(prev: EdgeChoice.Side?, band: Double) -> ProfileSideReading {
        var e = SideEdge(mode: .unfitted, bandPixels: band, contrast: 0, outerContrast: 0, innerContrast: 0, shift: 0, points: 0,
                         outsideRatio: 0, observed: .unfitted, used: .unfitted)
        // the line stays where the outline given put it, which may be either edge or neither: its noise is at least a band
        // (and a pixel), not known better; none of it is this frame's own (the line came from the outline given, which
        // follows earlier frames), so it is carried as the same error in every view (`frameSigmaPixels` 0)
        e.topSigmaPixels = max(1, band); e.turnSigmaPixels = max(1, band)
        return ProfileSideReading(top0: 0, top1: 0, edge: e, state: prev ?? EdgeChoice.Side(mode: .unfitted), observation: nil)
    }

    /// A straight line through edge offsets along a side (offset = a + b (x - mean x)): through each of `segments` runs'
    /// median offsets (or through the points themselves when `segments` is nil), through the most points that agree to
    /// within `tolerance` (pixels). Its offset sigma at the middle and its slope sigma come from those points' scatter.
    static func segmentLine(positions: [Double], offsets: [Double?], segments: Int?, tolerance: Double = 1) -> SegmentLine? {
        var px: [Double] = [], py: [Double] = []
        if let ns = segments {
            let n = positions.count
            for s in 0..<ns {
                let js = (0..<n).filter { $0 * ns / n == s && offsets[$0] != nil }
                guard js.count >= 2 else { continue }
                let v = js.map { offsets[$0]! }.sorted()
                py.append(v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2)
                px.append(js.map { positions[$0] }.reduce(0, +) / Double(js.count))
            }
        } else {
            for (x, y) in zip(positions, offsets) { if let y = y { px.append(x); py.append(y) } }
        }
        guard px.count >= 3 else { return nil }
        guard px.count >= 4 else { return SegmentLine(px, py) }
        // consensus: the line through two of the points that most of the others lie on (within `tolerance`), refitted
        // through those; a run that read another step (texture on the top, the base beyond) does not tilt it. No line when
        // fewer than three points agree.
        var best: (inliers: [Int], cost: Double)? = nil
        for i in 0..<px.count {
            for j in (i + 1)..<px.count where abs(px[j] - px[i]) > 1e-9 {
                let b = (py[j] - py[i]) / (px[j] - px[i])
                let res = (0..<px.count).map { abs(py[$0] - (py[i] + b * (px[$0] - px[i]))) }
                let inl = res.indices.filter { res[$0] <= tolerance }
                let cost = inl.reduce(0) { $0 + res[$1] }
                if best == nil || inl.count > best!.inliers.count || (inl.count == best!.inliers.count && cost < best!.cost) { best = (inl, cost) }
            }
        }
        guard let b = best, b.inliers.count >= 3 else { return nil }
        return SegmentLine(b.inliers.map { px[$0] }, b.inliers.map { py[$0] })
    }

    /// The steps in luma profile `L` (sample k at offset o0 + k step) between samples k0 and k1: each run where the luma
    /// changes by `threshold` or more across 2h samples (split where its change dips well between two peaks), the levels
    /// between steps (medians), and where each step crosses halfway between its two levels. `levelBefore`: the level
    /// before the first step (the top's). Steps that change the level by less than the threshold are dropped.
    static func lumaSteps(_ L: [Double], o0: Double, step: Double, k0: Int, k1: Int, h: Int, threshold thr: Double, levelBefore: Double) -> [LumaStep] {
        let n = L.count
        let a = max(h, k0), b = min(n - 1 - h, k1)
        guard b - a > 2 * h + 1 else { return [] }
        var D = [Double](repeating: 0, count: n)
        for k in a...b { D[k] = L[k + h] - L[k - h] }
        var peaks: [Int] = []
        var k = a
        while k <= b {
            guard abs(D[k]) >= thr else { k += 1; continue }
            let pos = D[k] > 0
            var j = k
            while j + 1 <= b && abs(D[j + 1]) >= thr && (D[j + 1] > 0) == pos { j += 1 }
            // the run's peaks, split where |D| dips below 60% of the smaller of two neighbouring peaks
            var local: [Int] = []
            for q in k...j where (q == k || abs(D[q]) >= abs(D[q - 1])) && (q == j || abs(D[q]) > abs(D[q + 1])) { local.append(q) }
            var kept: [Int] = []
            for q in local {
                if let last = kept.last {
                    let dip = (last...q).map { abs(D[$0]) }.min() ?? 0
                    if dip < 0.6 * min(abs(D[last]), abs(D[q])) && q - last > h { kept.append(q) }
                    else if abs(D[q]) > abs(D[last]) { kept[kept.count - 1] = q }
                } else { kept.append(q) }
            }
            peaks += kept
            k = j + 1
        }
        guard !peaks.isEmpty else { return [] }
        // the level after each step: the extreme its lobe reaches (the step's way) between it and the next step, clear of
        // both steps' own slopes (a plateau's level; a narrow lobe's peak; the base's black before a floor beyond it), the
        // mean of three samples about it
        func extreme(_ lo: Int, _ hi: Int, up: Bool) -> Double {
            let l = max(0, lo), r = min(n - 1, hi)
            guard r >= l else { return L[clamp((lo + hi) / 2, 0, n - 1)] }
            var best = l
            for k in l...r where up ? L[k] > L[best] : L[k] < L[best] { best = k }
            let a = max(l, best - 1), b = min(r, best + 1)
            return L[a...b].reduce(0, +) / Double(b - a + 1)
        }
        var lev: [Double] = [levelBefore]
        for (q, p) in peaks.enumerated() {
            let up = D[p] > 0
            if q + 1 < peaks.count {
                let nx = peaks[q + 1]
                lev.append(nx - p > 2 * h ? extreme(p + h, nx - h, up: up) : L[(p + nx) / 2])
            } else {
                lev.append(extreme(p + h, p + 5 * h, up: up))
            }
        }
        var out: [LumaStep] = []
        for (q, p) in peaks.enumerated() {
            let before = lev[q], after = lev[q + 1]
            guard abs(after - before) >= thr else { continue }
            let mid = (before + after) / 2
            // the halfway crossing nearest the peak
            var best: Double? = nil
            for kk in max(0, p - 2 * h)..<min(n - 1, p + 2 * h) {
                let u = L[kk] - mid, v = L[kk + 1] - mid
                guard (u <= 0 && v > 0) || (u >= 0 && v < 0) else { continue }
                let x = Double(kk) + u / (u - v)
                if best == nil || abs(x - Double(p)) < abs(best! - Double(p)) { best = x }
            }
            // the gradient's peak: a parabola through |D| about the peak sample
            var off = 0.0
            if p - 1 >= a && p + 1 <= b {
                let l = abs(D[p - 1]), c = abs(D[p]), r = abs(D[p + 1]), den = l - 2 * c + r
                if den < 0 { off = clamp(0.5 * (l - r) / den, -0.5, 0.5) }
            }
            out.append(LumaStep(at: o0 + step * (best ?? Double(p)), before: before, after: after, peak: o0 + step * (Double(p) + off)))
        }
        return out
    }
}

/// A straight line through points (x along a side, y an offset across it): y = a + b (x - mx), with its sigmas from the
/// points' scatter (at least 3 points).
struct SegmentLine {
    var a: Double
    var b: Double
    var mx: Double
    var count: Int
    /// rms of the points about the line
    var rms: Double
    /// the offset's sigma at the middle (rms / sqrt(n - 2)) and the slope's (per unit x)
    var sigma: Double
    var slopeSigma: Double

    init?(_ x: [Double], _ y: [Double]) {
        let n = x.count
        guard n >= 3 else { return nil }
        let mxv = x.reduce(0, +) / Double(n), my = y.reduce(0, +) / Double(n)
        var sxx = 0.0, sxy = 0.0
        for (p, q) in zip(x, y) { sxx += (p - mxv) * (p - mxv); sxy += (p - mxv) * (q - my) }
        guard sxx > 1e-12 else { return nil }
        b = sxy / sxx; a = my; mx = mxv; count = n
        var ss = 0.0
        for (p, q) in zip(x, y) { let r = q - (my + sxy / sxx * (p - mxv)); ss += r * r }
        rms = (ss / Double(n)).squareRoot()
        sigma = rms / Double(max(1, n - 2)).squareRoot()
        // the slope's sigma from the unbiased point scatter
        slopeSigma = (ss / Double(max(1, n - 2))).squareRoot() / sxx.squareRoot()
    }

    func offset(_ x: Double) -> Double { a + b * (x - mx) }
}
