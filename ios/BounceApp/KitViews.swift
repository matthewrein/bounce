import BounceCore
import SwiftUI
import UIKit

/// The capture kit's screens (a developer tool: Settings > Developer > Capture kit). The shot screen lies over the live
/// camera feed in ContentView; the start, measurements and finish screens cover it.
struct KitScreen: View {
    @ObservedObject var kit: KitSession

    var body: some View {
        switch kit.screen {
        case .start: KitStartView(kit: kit)
        case .measurements: KitMeasurementsView(kit: kit)
        case .shot: KitShotView(kit: kit)
        case .finish: KitFinishView(kit: kit)
        }
    }
}

/// Quit, at the top right of every kit screen: progress is saved after every shot.
private struct KitQuitButton: View {
    let kit: KitSession
    var body: some View {
        Button("Quit") { kit.quit() }
            .font(.body.weight(.semibold))
            .accessibilityIdentifier("kitQuit")
    }
}

// MARK: start

struct KitStartView: View {
    @ObservedObject var kit: KitSession

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Capture kit").font(.title2.bold())
                        Spacer()
                        KitQuitButton(kit: kit)
                    }
                    Text("A developer tool. It records the slab, the ball and a few bounces with the truth about them (your measurements and the slab's exact tilt), so the app can be tested against your room. About 10 minutes; every step can be skipped, and you can quit and resume.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    if let label = kit.slabMovedLabel {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Has the slab moved since you stopped?").font(.headline).accessibilityIdentifier("slabMovedQuestion")
                            Text("It was set up for \(label). If it moved, the kit takes its tilt again first.")
                                .font(.callout).foregroundColor(.secondary)
                            HStack(spacing: 12) {
                                Button("Yes, it moved") { kit.answerSlabMoved(true) }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("slabMovedYes")
                                Button("No") { kit.answerSlabMoved(false) }
                                    .buttonStyle(.borderedProminent)
                                    .accessibilityIdentifier("slabMovedNo")
                            }
                        }
                    } else if kit.confirmingNew {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Start a new kit? The unfinished kit and anything captured in it will be deleted from the phone.")
                                .font(.callout)
                            HStack(spacing: 12) {
                                Button("Delete it and start a new kit", role: .destructive) { kit.createKit() }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("kitNewConfirm")
                                Button("Cancel") { kit.cancelNew() }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("kitNewCancel")
                            }
                        }
                    } else {
                        if let r = kit.resumeText {
                            Button(action: { kit.resume() }) {
                                Text(r).frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("kitResume")
                        }
                        Button(action: { kit.newKit() }) {
                            Text("New kit").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("kitNew")
                        if let last = kit.lastKitText {
                            Button(last) { kit.openLastKit() }
                                .font(.footnote)
                                .accessibilityIdentifier("kitLast")
                        }
                    }
                    if let e = kit.error {
                        Text(e).font(.footnote).foregroundColor(.red).accessibilityIdentifier("kitError")
                    }
                }
                .padding()
            }
        }
    }
}

// MARK: step 1, measurements

struct KitMeasurementsView: View {
    @ObservedObject var kit: KitSession

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(kit.progressLabel).font(.headline).accessibilityIdentifier("kitProgress")
                Spacer()
                KitQuitButton(kit: kit)
            }
            .padding()
            Form {
                Section(header: Text(kit.shot?.title ?? "Measure"), footer: Text(kit.shot?.detail ?? "")) {
                    HStack(alignment: .top, spacing: 12) {
                        KitDiagramView(diagram: .measure)
                        Text(kit.shot?.instruction ?? "").accessibilityIdentifier("kitInstruction")
                    }
                }
                Section(header: Text("Slab, inches")) {
                    field("Width", text: $kit.widthText, placeholder: "7", id: "kitWidth")
                    field("Depth", text: $kit.depthText, placeholder: "7", id: "kitDepth")
                    field("Thickness", text: $kit.thicknessText, placeholder: "1", id: "kitThickness")
                    field("Dish depth", text: $kit.dishText, placeholder: "0.125 if not measured", id: "kitDish")
                }
                Section(header: Text("Ball, mm")) {
                    field("Diameter", text: $kit.ballText, placeholder: "35", id: "kitBall")
                }
                Section(header: Text("Phone (read by itself)"),
                        footer: Text("Kept with the kit only: the app itself keeps its built-in slab and ball.")) {
                    row("Model", Device.model)
                    row("LiDAR", ARController.depthSupported ? "yes" : "no")
                }
            }
            if !kit.formProblems.isEmpty {
                Text(kit.formProblems.joined(separator: "\n"))
                    .font(.footnote)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .accessibilityIdentifier("kitFormProblems")
            }
            // always in view (also above the keyboard)
            HStack(spacing: 12) {
                Button(action: { kit.commitMeasurements() }) { Text("Start").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("kitStart")
                Button("Skip") { kit.skip() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("shotSkip")
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String, id: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(placeholder, text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 170)
                .accessibilityIdentifier(id)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundColor(.secondary)
        }
    }
}

// MARK: the shot (over the camera)

struct KitShotView: View {
    @ObservedObject var kit: KitSession

    var body: some View {
        VStack(spacing: 10) {
            topBar
            Spacer(minLength: 0)
            centre
            Spacer(minLength: 0)
            card
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(kit.progressLabel).font(.headline).accessibilityIdentifier("kitProgress")
                if !kit.shotInStep.isEmpty { Text(kit.shotInStep).font(.caption) }
            }
            Spacer()
            Button("Finish now") { kit.finishNow() }
                .font(.subheadline)
                .accessibilityIdentifier("kitFinishNow")
            KitQuitButton(kit: kit)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.6)))
    }

    /// The big things: the countdown, the recording, "Drop now", the flat-phone prompts.
    @ViewBuilder private var centre: some View {
        switch kit.phase {
        case .countdown:
            Text("\(kit.countdownLeft)")
                .font(.system(size: 96, weight: .bold).monospacedDigit())
                .foregroundColor(.white)
                .shadow(radius: 6)
                .accessibilityIdentifier("kitCountdown")
        case .recording:
            VStack(spacing: 12) {
                if kit.dropNow {
                    Text("Drop now")
                        .font(.system(size: 48, weight: .heavy))
                        .foregroundColor(.yellow)
                        .shadow(radius: 6)
                        .accessibilityIdentifier("kitDropNow")
                }
                HStack(spacing: 8) {
                    Circle().fill(Color.red).frame(width: 12, height: 12)
                    Text(kit.secondsLeft > 0 ? String(format: "Recording, %.0f s left", kit.secondsLeft.rounded(.up)) : "Recording, finishing")
                        .font(.headline.monospacedDigit())
                        .accessibilityIdentifier("kitRecording")
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(Color.black.opacity(0.6)))
            }
        case .flat:
            flatPanel
        case .saving:
            HStack(spacing: 8) {
                ProgressView().tint(.white)
                Text("Checking").font(.headline)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(Color.black.opacity(0.6)))
        case .ready, .review, .failed:
            EmptyView()
        }
    }

    /// Read from a phone lying on the slab: large, high-contrast words.
    private var flatPanel: some View {
        VStack(spacing: 16) {
            Text(kit.flat?.prompt ?? "Lay the phone flat in the middle of the slab, screen up, top pointing away. Let go.")
                .font(.system(size: 34, weight: .bold))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.5)
                .accessibilityIdentifier("flatPrompt")
            ProgressView(value: kit.flat?.progress ?? 0)
                .tint(.green)
            if let left = kit.flat?.secondsLeft {
                Text(String(format: "%.0f s", left.rounded(.up))).font(.title3.monospacedDigit())
            }
            Button("Stop") { kit.stopFlat() }
                .font(.headline)
                .accessibilityIdentifier("flatStop")
        }
        .foregroundColor(.white)
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.85)))
    }

    /// The step, the instruction and the diagram, then what can be done now.
    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let s = kit.shot {
                HStack(alignment: .top, spacing: 12) {
                    KitDiagramView(diagram: s.diagram)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(s.title).font(.headline)
                        Text(s.instruction).font(.subheadline).accessibilityIdentifier("kitInstruction")
                        if let d = s.detail, kit.phase == .ready {
                            Text(d).font(.caption).foregroundColor(.white.opacity(0.75))
                        }
                    }
                }
            }
            if let n = kit.notice {
                Text(n).font(.caption).foregroundColor(.yellow).accessibilityIdentifier("kitNotice")
            }
            if let e = kit.error {
                Text(e).font(.caption).foregroundColor(.orange).accessibilityIdentifier("kitError")
            }
            if kit.phase == .review { review }
            controls
        }
        .foregroundColor(.white)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.7)))
    }

    /// The flat-phone result, the quality check and, for the held-ball shots, the height.
    private var review: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let t = kit.trueTilt {
                Text(KitShotView.trueTiltText(t))
                    .font(.title3.bold())
                    .accessibilityIdentifier("trueTilt")
            }
            if let r = kit.report {
                Text(r.summary)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(KitShotView.colour(r.verdict))
                    .accessibilityIdentifier("qualityVerdict")
                let notes = r.problems.map { $0.message }.filter { !r.summary.contains($0) }
                if !notes.isEmpty {
                    Text(notes.joined(separator: "\n")).font(.caption).accessibilityIdentifier("qualityMessages")
                }
            }
            if kit.heightAsked {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Height of the ball's bottom above the slab's top (inches), if you measured it:").font(.caption)
                    HStack(spacing: 8) {
                        TextField("inches", text: $kit.heightText)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                            .foregroundColor(.primary)
                            .frame(maxWidth: 110)
                            .accessibilityIdentifier("heightField")
                        Button("Save") { kit.saveHeight() }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("heightSave")
                        Button("Skip height") { kit.skipHeight() }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("heightSkip")
                    }
                }
            }
            if let h = kit.heightNote {
                Text(h).font(.caption).accessibilityIdentifier("heightNote")
            }
        }
    }

    @ViewBuilder private var controls: some View {
        switch kit.phase {
        case .ready:
            HStack(spacing: 12) {
                Button(action: { kit.start() }) { Text("Start").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("shotStart")
                Button("Skip") { kit.skip() }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .accessibilityIdentifier("shotSkip")
            }
        case .review, .failed:
            HStack(spacing: 12) {
                Button("Retry") { kit.retry() }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .accessibilityIdentifier("shotRetry")
                if kit.phase == .review {
                    Button(action: { kit.next() }) { Text("Next").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("shotNext")
                }
                Button("Skip") { kit.skip() }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .accessibilityIdentifier("shotSkip")
            }
        case .countdown, .recording, .flat, .saving:
            EmptyView()
        }
    }

    /// "True tilt 8.03° (two readings, ±0.02°)"
    static func trueTiltText(_ t: KitTrueTilt) -> String {
        guard t.isUsable, let deg = t.tiltDegrees else { return "True tilt: no result. " + (t.reasons.first ?? "") }
        let how: String
        switch t.method {
        case .twoReading: how = "two readings"
        case .bumpCorrected: how = "one reading, bump-corrected"
        case .uncorrected: how = "one reading, uncorrected"
        case .failed: how = "failed"
        }
        let pm = t.uncertaintyDegrees.map { String(format: ", ±%.2f°", $0) } ?? ""
        return String(format: "True tilt %.2f°", deg) + " (" + how + pm + ")"
    }

    static func colour(_ v: KitVerdict) -> Color {
        switch v {
        case .good: return .green
        case .fair: return .yellow
        case .poor: return .red
        }
    }
}

// MARK: finish

struct KitFinishView: View {
    @ObservedObject var kit: KitSession

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Capture kit: the end").font(.title2.bold())
                        Spacer()
                        KitQuitButton(kit: kit)
                    }
                    if let s = kit.summary {
                        Text(s.lines.joined(separator: "\n"))
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("kitSummary")
                    }
                    if kit.hasPendingShots && !kit.finished {
                        Button("Back to the shots") { kit.backToShots() }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("kitBackToShots")
                    }
                    Button(action: { kit.makeBundle() }) {
                        Text(kit.bundling ? "Making the bundle" : "Make bundle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(kit.bundling)
                    .accessibilityIdentifier("kitBundle")
                    if kit.bundling { ProgressView() }
                    if let b = kit.bundleText {
                        Text(b).font(.footnote).accessibilityIdentifier("kitBundleResult")
                        Button(action: { kit.shareKit() }) {
                            Text("Share kit").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("kitShare")
                    }
                    Text("Send it privately: upload the parts to your private bounce-captures repository, as \"Capture kit (developer tool)\" in ios/README.md shows, or AirDrop them to your Mac.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .accessibilityIdentifier("kitSendHelp")
                    Text("The kit shows your room: never attach it to an issue or anything public.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    if kit.confirmingDelete {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Delete this kit and its bundle from the phone? This cannot be undone.").font(.callout)
                            HStack(spacing: 12) {
                                Button("Delete", role: .destructive) { kit.confirmDelete() }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("kitDeleteConfirm")
                                Button("Cancel") { kit.cancelDelete() }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("kitDeleteCancel")
                            }
                        }
                    } else {
                        Button("Delete kit from phone", role: .destructive) { kit.askDelete() }
                            .accessibilityIdentifier("kitDelete")
                    }
                    if let e = kit.error {
                        Text(e).font(.footnote).foregroundColor(.red).accessibilityIdentifier("kitError")
                    }
                }
                .padding()
            }
        }
        .sheet(item: $kit.share) { item in
            KitShareSheet(urls: item.urls)
        }
    }
}

// MARK: diagrams

/// A small picture beside a shot's instruction: one simple drawing per `KitDiagram` (the slab, the phone, the ball,
/// arrows).
struct KitDiagramView: View {
    let diagram: KitDiagram

    var body: some View {
        let d = diagram
        return Canvas { ctx, size in
            KitDiagramPainter.draw(d, in: &ctx, size: size)
        }
        .frame(width: 96, height: 72)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.12)))
        .accessibilityHidden(true)
    }
}

/// The diagrams' drawing (plain functions on a GraphicsContext, outside any view).
enum KitDiagramPainter {
    static let slabColour = Color(white: 0.75)
    static let lineColour = Color.white
    static let ballColour = Color(red: 0.75, green: 0.78, blue: 0.85)
    static let accent = Color.yellow

    // a slab seen from the side and a little above: top face, front face, black cradle under it
    static func slab(_ ctx: inout GraphicsContext, centre c: CGPoint, width w: CGFloat, tilt: CGFloat = 0) {
        var g = ctx
        g.translateBy(x: c.x, y: c.y)
        g.rotate(by: .degrees(Double(-tilt)))
        let top = Path { p in
            p.move(to: CGPoint(x: -w / 2, y: 0)); p.addLine(to: CGPoint(x: -w / 2 + w * 0.18, y: -w * 0.16))
            p.addLine(to: CGPoint(x: w / 2 + w * 0.18, y: -w * 0.16)); p.addLine(to: CGPoint(x: w / 2, y: 0)); p.closeSubpath()
        }
        g.fill(top, with: .color(slabColour))
        g.fill(Path(CGRect(x: -w / 2, y: 0, width: w, height: w * 0.14)), with: .color(slabColour.opacity(0.7)))
        g.fill(Path(CGRect(x: -w / 2 - 3, y: w * 0.14, width: w + 6, height: 4)), with: .color(.black))
    }

    static func phone(_ ctx: inout GraphicsContext, centre c: CGPoint, size s: CGSize, angle: Double = 0) {
        var g = ctx
        g.translateBy(x: c.x, y: c.y)
        g.rotate(by: .degrees(angle))
        let r = CGRect(x: -s.width / 2, y: -s.height / 2, width: s.width, height: s.height)
        g.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(.black))
        g.stroke(Path(roundedRect: r, cornerRadius: 3), with: .color(lineColour), lineWidth: 1.2)
    }

    static func ball(_ ctx: inout GraphicsContext, centre c: CGPoint, radius r: CGFloat) {
        let e = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.fill(e, with: .color(ballColour))
        ctx.stroke(e, with: .color(lineColour), lineWidth: 0.8)
    }

    static func arrow(_ ctx: inout GraphicsContext, from a: CGPoint, to b: CGPoint, colour: Color = .yellow, dashed: Bool = false) {
        var p = Path(); p.move(to: a); p.addLine(to: b)
        ctx.stroke(p, with: .color(colour), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: dashed ? [3, 3] : []))
        let ang = atan2(b.y - a.y, b.x - a.x), l: CGFloat = 6
        var h = Path()
        h.move(to: b)
        h.addLine(to: CGPoint(x: b.x - l * cos(ang - 0.5), y: b.y - l * sin(ang - 0.5)))
        h.move(to: b)
        h.addLine(to: CGPoint(x: b.x - l * cos(ang + 0.5), y: b.y - l * sin(ang + 0.5)))
        ctx.stroke(h, with: .color(colour), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
    }

    /// an arc with an arrow head at its end (angles in degrees, y down)
    static func arcArrow(_ ctx: inout GraphicsContext, centre c: CGPoint, radius r: CGFloat, from a0: Double, to a1: Double,
                         colour: Color = .yellow, dashed: Bool = false) {
        var p = Path()
        p.addArc(center: c, radius: r, startAngle: .degrees(a0), endAngle: .degrees(a1), clockwise: a1 < a0)
        ctx.stroke(p, with: .color(colour), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: dashed ? [3, 3] : []))
        let e = CGPoint(x: c.x + r * CGFloat(cos(a1 * .pi / 180)), y: c.y + r * CGFloat(sin(a1 * .pi / 180)))
        let step = a1 > a0 ? -12.0 : 12.0
        let b = CGPoint(x: c.x + r * CGFloat(cos((a1 + step) * .pi / 180)), y: c.y + r * CGFloat(sin((a1 + step) * .pi / 180)))
        arrow(&ctx, from: b, to: e, colour: colour)
    }

    static func cross(_ ctx: inout GraphicsContext, centre c: CGPoint, size s: CGFloat) {
        var p = Path()
        p.move(to: CGPoint(x: c.x - s, y: c.y - s)); p.addLine(to: CGPoint(x: c.x + s, y: c.y + s))
        p.move(to: CGPoint(x: c.x + s, y: c.y - s)); p.addLine(to: CGPoint(x: c.x - s, y: c.y + s))
        ctx.stroke(p, with: .color(.red), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
    }

    static func label(_ ctx: inout GraphicsContext, _ text: String, at p: CGPoint) {
        ctx.draw(Text(text).font(.system(size: 9, weight: .bold)).foregroundColor(lineColour), at: p)
    }

    static func lamp(_ ctx: inout GraphicsContext, centre c: CGPoint, on: Bool) {
        let bulb = Path(ellipseIn: CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16))
        ctx.fill(bulb, with: .color(on ? .yellow : Color(white: 0.3)))
        ctx.stroke(bulb, with: .color(lineColour), lineWidth: 1)
        ctx.fill(Path(CGRect(x: c.x - 3, y: c.y + 8, width: 6, height: 5)), with: .color(Color(white: 0.6)))
        if on {
            var rays = Path()
            for k in 0..<8 {
                let a = Double(k) * .pi / 4
                rays.move(to: CGPoint(x: c.x + 11 * CGFloat(cos(a)), y: c.y + 11 * CGFloat(sin(a))))
                rays.addLine(to: CGPoint(x: c.x + 16 * CGFloat(cos(a)), y: c.y + 16 * CGFloat(sin(a))))
            }
            ctx.stroke(rays, with: .color(.yellow), lineWidth: 1.4)
        }
    }

    /// the phone held to the side, looking at a point, with its view drawn as two dashed lines
    static func phoneLooking(_ ctx: inout GraphicsContext, from p: CGPoint, at q: CGPoint) {
        var v = Path()
        v.move(to: p); v.addLine(to: CGPoint(x: q.x, y: q.y - 8))
        v.move(to: p); v.addLine(to: CGPoint(x: q.x, y: q.y + 8))
        ctx.stroke(v, with: .color(lineColour.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        phone(&ctx, centre: p, size: CGSize(width: 8, height: 15), angle: Double(atan2(q.y - p.y, q.x - p.x) * 180 / .pi) - 90)
    }

    static func draw(_ d: KitDiagram, in ctx: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        let mid = CGPoint(x: w * 0.5, y: h * 0.62)
        switch d {
        case .measure:
            slab(&ctx, centre: CGPoint(x: w * 0.38, y: h * 0.62), width: w * 0.48)
            var ruler = Path()
            ruler.move(to: CGPoint(x: w * 0.12, y: h * 0.38)); ruler.addLine(to: CGPoint(x: w * 0.66, y: h * 0.38))
            for k in 0...6 {
                let x = w * 0.12 + CGFloat(k) * w * 0.09
                ruler.move(to: CGPoint(x: x, y: h * 0.38)); ruler.addLine(to: CGPoint(x: x, y: h * 0.38 - (k % 2 == 0 ? 6 : 3)))
            }
            ctx.stroke(ruler, with: .color(accent), lineWidth: 1.4)
            ball(&ctx, centre: CGPoint(x: w * 0.84, y: h * 0.66), radius: 8)
            arrow(&ctx, from: CGPoint(x: w * 0.72, y: h * 0.42), to: CGPoint(x: w * 0.96, y: h * 0.42))
            arrow(&ctx, from: CGPoint(x: w * 0.96, y: h * 0.42), to: CGPoint(x: w * 0.72, y: h * 0.42))
        case .roomScan:
            slab(&ctx, centre: CGPoint(x: w * 0.5, y: h * 0.55), width: w * 0.3)
            arcArrow(&ctx, centre: CGPoint(x: w * 0.5, y: h * 0.5), radius: h * 0.4, from: 200, to: 470, dashed: true)
            phone(&ctx, centre: CGPoint(x: w * 0.5 + h * 0.4, y: h * 0.5), size: CGSize(width: 8, height: 15))
        case .flatPhone, .flatPhoneTilted:
            let tilt: CGFloat = d == .flatPhoneTilted ? 12 : 0
            slab(&ctx, centre: mid, width: w * 0.62, tilt: tilt)
            if tilt > 0 {
                ctx.fill(Path(CGRect(x: w * 0.8, y: mid.y - 2, width: 7, height: 12)), with: .color(.brown))
            }
            var g = ctx
            g.translateBy(x: mid.x, y: mid.y - w * 0.08)
            g.rotate(by: .degrees(Double(-tilt)))
            let r = CGRect(x: -w * 0.13, y: -4, width: w * 0.26, height: 5)
            g.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(.black))
            g.stroke(Path(roundedRect: r, cornerRadius: 2), with: .color(lineColour), lineWidth: 1)
            arcArrow(&ctx, centre: CGPoint(x: w * 0.5, y: h * 0.3), radius: 11, from: 160, to: 380)
        case .holdStill:
            slab(&ctx, centre: CGPoint(x: w * 0.32, y: h * 0.62), width: w * 0.36)
            phoneLooking(&ctx, from: CGPoint(x: w * 0.85, y: h * 0.3), at: CGPoint(x: w * 0.34, y: h * 0.55))
        case .walkArc:
            slab(&ctx, centre: CGPoint(x: w * 0.5, y: h * 0.62), width: w * 0.3)
            arcArrow(&ctx, centre: CGPoint(x: w * 0.5, y: h * 0.58), radius: w * 0.36, from: 180, to: 360, dashed: true)
            phone(&ctx, centre: CGPoint(x: w * 0.14, y: h * 0.58), size: CGSize(width: 8, height: 15))
        case .dimLight:
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.45)))
            lamp(&ctx, centre: CGPoint(x: w * 0.2, y: h * 0.3), on: false)
            slab(&ctx, centre: CGPoint(x: w * 0.6, y: h * 0.65), width: w * 0.4)
        case .brightLight:
            lamp(&ctx, centre: CGPoint(x: w * 0.2, y: h * 0.3), on: true)
            lamp(&ctx, centre: CGPoint(x: w * 0.8, y: h * 0.25), on: true)
            slab(&ctx, centre: CGPoint(x: w * 0.55, y: h * 0.7), width: w * 0.4)
        case .ballFloorNear, .ballFloorFar:
            let far = d == .ballFloorFar
            var floor = Path(); floor.move(to: CGPoint(x: 4, y: h * 0.8)); floor.addLine(to: CGPoint(x: w - 4, y: h * 0.8))
            ctx.stroke(floor, with: .color(lineColour.opacity(0.5)), lineWidth: 1)
            ball(&ctx, centre: CGPoint(x: w * 0.18, y: h * 0.8 - 7), radius: 7)
            let px = far ? w * 0.88 : w * 0.6
            phoneLooking(&ctx, from: CGPoint(x: px, y: h * 0.35), at: CGPoint(x: w * 0.18, y: h * 0.72))
            label(&ctx, far ? "5 ft" : "3 ft", at: CGPoint(x: (w * 0.18 + px) / 2, y: h * 0.92))
        case .ballOnSlab:
            slab(&ctx, centre: mid, width: w * 0.6)
            ball(&ctx, centre: CGPoint(x: mid.x + w * 0.05, y: mid.y - w * 0.08 - 6), radius: 7)
        case .ballHeldLow, .ballHeldMid, .ballHeldHigh:
            let (lift, text): (CGFloat, String) = d == .ballHeldLow ? (0.12, "4 in") : (d == .ballHeldMid ? (0.3, "1 ft") : (0.48, "2 ft"))
            let base = CGPoint(x: w * 0.42, y: h * 0.82)
            slab(&ctx, centre: base, width: w * 0.5)
            let bc = CGPoint(x: base.x + w * 0.05, y: base.y - w * 0.08 - h * lift - 7)
            ball(&ctx, centre: bc, radius: 6)
            var hand = Path()
            hand.addArc(center: CGPoint(x: bc.x, y: bc.y - 3), radius: 9, startAngle: .degrees(200), endAngle: .degrees(340), clockwise: false)
            ctx.stroke(hand, with: .color(Color(red: 0.95, green: 0.8, blue: 0.65)), lineWidth: 3)
            arrow(&ctx, from: CGPoint(x: w * 0.86, y: base.y - w * 0.08), to: CGPoint(x: w * 0.86, y: bc.y + 6))
            arrow(&ctx, from: CGPoint(x: w * 0.86, y: bc.y + 6), to: CGPoint(x: w * 0.86, y: base.y - w * 0.08))
            label(&ctx, text, at: CGPoint(x: w * 0.86, y: max(8, bc.y - 4)))
        case .dropCentre, .dropEdge:
            let edge = d == .dropEdge
            slab(&ctx, centre: mid, width: w * 0.6)
            let x = edge ? mid.x + w * 0.24 : mid.x + w * 0.04
            ball(&ctx, centre: CGPoint(x: x, y: h * 0.14), radius: 6)
            arrow(&ctx, from: CGPoint(x: x, y: h * 0.24), to: CGPoint(x: x, y: mid.y - w * 0.12))
            var bounce = Path()
            bounce.move(to: CGPoint(x: x, y: mid.y - w * 0.1))
            bounce.addQuadCurve(to: CGPoint(x: min(w - 3, x + w * 0.3), y: h * 0.86), control: CGPoint(x: x + w * 0.16, y: h * 0.12))
            ctx.stroke(bounce, with: .color(.cyan), style: StrokeStyle(lineWidth: 1.6, dash: [3, 3]))
        case .noSlab:
            slab(&ctx, centre: CGPoint(x: w * 0.3, y: h * 0.62), width: w * 0.32)
            cross(&ctx, centre: CGPoint(x: w * 0.3, y: h * 0.55), size: 11)
            ball(&ctx, centre: CGPoint(x: w * 0.7, y: h * 0.62), radius: 6)
            cross(&ctx, centre: CGPoint(x: w * 0.7, y: h * 0.62), size: 8)
        case .noBall:
            slab(&ctx, centre: CGPoint(x: w * 0.36, y: h * 0.66), width: w * 0.46)
            ball(&ctx, centre: CGPoint(x: w * 0.8, y: h * 0.32), radius: 7)
            cross(&ctx, centre: CGPoint(x: w * 0.8, y: h * 0.32), size: 9)
        }
    }
}

/// The system share sheet for the kit's bundle parts (all of them at once: AirDrop, Save to Files, ...).
struct KitShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
