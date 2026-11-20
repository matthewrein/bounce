import SwiftUI

/// Draws the locked slab, the drop line, the bounce path, its apex and landing spot over the camera feed.
struct OverlayView: View {
    let overlay: OverlayState

    var body: some View {
        Canvas { ctx, _ in
            let o = overlay
            // a detection that is not yet locked
            if o.measured.count == 4 {
                ctx.stroke(polygon(o.measured), with: .color(.white.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            // the slab's top (the plane through its four corners)
            if o.outline.count == 4 {
                ctx.stroke(polygon(o.outline), with: .color(.yellow), lineWidth: 2.5)
                for p in o.outline { ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.yellow)) }
            }
            // while the tilt settles the launch line and the path are faint and dashed, and there is no landing spot
            let faint: Double = o.settling ? 0.4 : 1.0
            let pathDash: [CGFloat] = o.settling ? [6, 5] : []
            // the launch direction (the way the bounce leaves the slab: the path's own direction)
            if let s = o.start, let t = o.normalTip {
                var p = Path(); p.move(to: s); p.addLine(to: t)
                ctx.stroke(p, with: .color(.white.opacity(faint)), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
            }
            // the ball and its drop line
            if let b = o.ball {
                let r = max(o.ballRadius, 6)
                ctx.stroke(Path(ellipseIn: CGRect(x: b.x - r, y: b.y - r, width: 2 * r, height: 2 * r)), with: .color(.orange), lineWidth: 2.5)
                if let s = o.start {
                    var p = Path(); p.move(to: b); p.addLine(to: s)
                    ctx.stroke(p, with: .color(.orange), style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
                }
            }
            // a ball the owner set by tapping it: its own mark, not the finder's ring (a dashed yellow ring with a dot in the
            // middle), and its drop line
            if let b = o.setBall {
                let r = max(o.setBallRadius, 6)
                ctx.stroke(Path(ellipseIn: CGRect(x: b.x - r, y: b.y - r, width: 2 * r, height: 2 * r)), with: .color(.yellow),
                           style: StrokeStyle(lineWidth: 2.5, dash: [5, 3]))
                ctx.fill(Path(ellipseIn: CGRect(x: b.x - 3, y: b.y - 3, width: 6, height: 6)), with: .color(.yellow))
                if let s = o.start {
                    var p = Path(); p.move(to: b); p.addLine(to: s)
                    ctx.stroke(p, with: .color(.yellow), style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
                }
            }
            // the bounce
            if o.path.count > 1 {
                var p = Path(); p.addLines(o.path)
                ctx.stroke(p, with: .color(.cyan.opacity(faint)),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, dash: pathDash))
            }
            if let a = o.apex {
                ctx.fill(Path(ellipseIn: CGRect(x: a.x - 5, y: a.y - 5, width: 10, height: 10)), with: .color(.cyan))
                ctx.draw(Text("apex").font(.caption.bold()).foregroundColor(.cyan), at: CGPoint(x: a.x, y: a.y - 14))
            }
            if let l = o.landing, !o.settling {
                ctx.stroke(Path(ellipseIn: CGRect(x: l.x - 9, y: l.y - 9, width: 18, height: 18)), with: .color(.green), lineWidth: 2.5)
                ctx.draw(Text("lands").font(.caption.bold()).foregroundColor(.green), at: CGPoint(x: l.x, y: l.y + 18))
            }
            // a tap's brief mark: a ring spreading from the finger (slab: white; ball: orange, dashed), or the dismissed
            // ball's ring crossed out in red (a cleared set ball's mark: in yellow), fading
            if let m = o.tapMark {
                let a = max(0, min(1, m.fade))
                let grow = CGFloat(1 - a) * 10
                let r = m.radius
                let rect = CGRect(x: m.center.x - r, y: m.center.y - r, width: 2 * r, height: 2 * r)
                switch m.kind {
                case .slab:
                    ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -grow, dy: -grow)), with: .color(.white.opacity(0.9 * a)), lineWidth: 2)
                case .ball:
                    ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -grow, dy: -grow)), with: .color(.orange.opacity(0.9 * a)),
                               style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                case .dismissed, .cleared:
                    let c: Color = m.kind == .cleared ? .yellow : .red
                    ctx.stroke(Path(ellipseIn: rect), with: .color(c.opacity(a)), lineWidth: 2.5)
                    let k = r * 0.7
                    var x = Path()
                    x.move(to: CGPoint(x: m.center.x - k, y: m.center.y - k)); x.addLine(to: CGPoint(x: m.center.x + k, y: m.center.y + k))
                    x.move(to: CGPoint(x: m.center.x + k, y: m.center.y - k)); x.addLine(to: CGPoint(x: m.center.x - k, y: m.center.y + k))
                    ctx.stroke(x, with: .color(c.opacity(a)), lineWidth: 2.5)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func polygon(_ pts: [CGPoint]) -> Path {
        var p = Path()
        p.addLines(pts)
        p.closeSubpath()
        return p
    }
}
