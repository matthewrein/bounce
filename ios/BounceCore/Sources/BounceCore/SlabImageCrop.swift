import Foundation

/// Where the slab's full-resolution luma comes from: the full camera image's pixels from (x0, y0), `width` x `height` of
/// them, shrunk by averaging `factor` x `factor` blocks (the same rectangle-and-factor form as `BallImageCrop`, and cut
/// the same way: the app's `FrameConversion.lumaCrop`).
///
/// The slab finder finds the slab on the processing frame (the camera image shrunk by about 4, ~480 px wide: a 7 in slab
/// is ~55 px across at 4 ft), and refines its edges on this crop when it has one (`DetailImage`), so the corners the
/// pose is solved from are located on the camera's own pixels. The tracker asks for it (`TrackerFrame.slabDetail`) only
/// on frames where its detector runs: around the lock's outline on a re-check, or, on a search (searching, confirming),
/// around the outline the search found on the processing frame (a second, short pass following that outline alone).
public struct SlabImageCrop: Codable, Equatable {
    /// the crop's rectangle in the full camera image (pixels of ARKit's captured image, sensor orientation)
    public var x0: Int
    public var y0: Int
    public var width: Int
    public var height: Int
    /// the shrink factor: the crop's image is width / factor x height / factor pixels
    public var factor: Int

    public init(x0: Int, y0: Int, width: Int, height: Int, factor: Int) {
        self.x0 = x0; self.y0 = y0; self.width = width; self.height = height; self.factor = factor
    }

    /// size of the crop's image (pixels)
    public var imageWidth: Int { width / factor }
    public var imageHeight: Int { height / factor }

    /// The intrinsics of the crop's image, given the full camera image's.
    public func intrinsics(full: CameraIntrinsics) -> CameraIntrinsics {
        full.cropped(x0: Double(x0), y0: Double(y0), scale: 1 / Double(factor), width: imageWidth, height: imageHeight)
    }

    /// How far the crop reaches beyond the outline it is planned around, on every side: `margin` of the outline's
    /// longest side plus `marginPixels` (full image pixels). The edge steps look up to about 0.45 of the longest side
    /// beyond an outline (two bands of the cut face plus a margin: `FinderRun.detailReach`), and the outline found may
    /// lie some way off the one predicted (the camera's motion since the lock was projected, a coarse search hit): 0.6
    /// leaves 0.15 of a side, plus 16 px, for that.
    public static let margin = 0.6
    public static let marginPixels = 16.0
    /// The crop's image never has more pixels than this: a nearer slab gets a larger shrink factor (2 from about 2 ft
    /// in for a 7 in slab at 1920x1440), so cutting it costs at most about this many output pixels whatever the
    /// distance. (At 3-6 ft the whole crop is 200-650 px across at factor 1.)
    public static let maxPixels = 500_000
    /// A crop smaller than this either way is not worth cutting (the outline is mostly outside the image).
    public static let minSide = 32

    /// The crop around an outline. `outline`: four corners in pixels of the processing frame (`processing`: its
    /// intrinsics, the full image shrunk); `full`: the full camera image's intrinsics. The outline's bounding box in full
    /// image pixels, grown by `margin` of its longest side plus `marginPixels`, clamped to the image, with the smallest
    /// shrink factor that keeps its image within `maxPixels`. nil if the outline is not four finite corners or the
    /// clamped crop is under `minSide` pixels either way.
    public static func plan(outline: [Vec2], processing: CameraIntrinsics, full: CameraIntrinsics,
                            margin: Double = SlabImageCrop.margin, marginPixels: Double = SlabImageCrop.marginPixels,
                            maxPixels: Int = SlabImageCrop.maxPixels) -> SlabImageCrop? {
        guard outline.count == 4, outline.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), full.width > 0, full.height > 0 else { return nil }
        let map = ImageMap(from: processing, to: full)
        let q = outline.map(map.forward)
        let longest = (0..<4).map { q[$0].distance(to: q[($0 + 1) % 4]) }.max() ?? 0
        let g = margin * longest + marginPixels
        let xs = q.map { $0.x }, ys = q.map { $0.y }
        let bx0 = xs.min()! - g, bx1 = xs.max()! + g, by0 = ys.min()! - g, by1 = ys.max()! + g
        guard bx0.isFinite, bx1.isFinite, by0.isFinite, by1.isFinite else { return nil }
        let x0 = max(0, Int(floor(max(-1e9, bx0)))), y0 = max(0, Int(floor(max(-1e9, by0))))
        let x1 = min(full.width, Int(ceil(min(1e9, bx1)))), y1 = min(full.height, Int(ceil(min(1e9, by1))))
        let w = x1 - x0, h = y1 - y0
        guard w >= minSide, h >= minSide else { return nil }
        var k = 1
        while (w / k) * (h / k) > max(1, maxPixels) { k += 1 }
        guard w / k >= minSide / 2, h / k >= minSide / 2 else { return nil }
        // a whole number of blocks, so the crop's image covers exactly the rectangle
        return SlabImageCrop(x0: x0, y0: y0, width: (w / k) * k, height: (h / k) * k, factor: k)
    }

    /// The tracker's `TrackerFrame.slabDetail` for a frame: plans the crop for the outline the tracker asks about (`plan`)
    /// and cuts it with `cut`, which returns the crop's pixels (`imageWidth` x `imageHeight` block averages of the full
    /// camera image's luma; in the app `FrameConversion.lumaCrop(pixelBuffer, x0:y0:width:height:factor:)`) or nil when it
    /// cannot. A cut of another size is refused.
    public static func provider(processing: CameraIntrinsics, full: CameraIntrinsics,
                                cut: @escaping (SlabImageCrop) -> Plane?) -> ([Vec2]) -> SlabDetail? {
        { outline in
            guard let c = plan(outline: outline, processing: processing, full: full), let p = cut(c),
                  p.width == c.imageWidth, p.height == c.imageHeight else { return nil }
            return SlabDetail(crop: c, luma: p, intrinsics: c.intrinsics(full: full))
        }
    }
}

/// A full-resolution crop of the camera image's luma for the slab's edge steps: where it was cut, its pixels and their
/// intrinsics (the same camera as the processing frame's, `DetailImage`).
public struct SlabDetail: Equatable {
    public var crop: SlabImageCrop
    public var luma: Plane
    public var intrinsics: CameraIntrinsics
    public init(crop: SlabImageCrop, luma: Plane, intrinsics: CameraIntrinsics) {
        self.crop = crop; self.luma = luma; self.intrinsics = intrinsics
    }
    /// as the slab finder takes it
    public var image: DetailImage { DetailImage(luma: luma, intrinsics: intrinsics) }
}
