import BounceCore
import Foundation
import QuartzCore
import SwiftUI
import UIKit

/// Where the kit's motion samples go (motion queue, or the demo's feed): the recording's motion.jsonl and the flat-phone
/// session. Thread-safe.
final class KitMotionRoute {
    private let lock = NSLock()
    private var recorder: KitRecorder? = nil
    private var runner: KitFlatRunner? = nil

    func set(recorder r: KitRecorder?, runner f: KitFlatRunner?) {
        lock.lock(); recorder = r; runner = f; lock.unlock()
    }

    func clear() { set(recorder: nil, runner: nil) }

    func deliver(_ s: KitMotionSample) {
        lock.lock(); let r = recorder, f = runner; lock.unlock()
        r?.appendMotion(s)
        f?.feed(s)
    }
}

/// The capture kit (Settings > Developer > Capture kit), a developer tool: the guided shots of CaptureKit.md over the
/// live camera, recorded into a kit folder (Application Support/Kits, not shown in Files) through BounceCore's
/// `KitStore`, then zipped into bundle parts (Documents/Kits/<kitId>, shown in Files) to send privately.
///
/// It never opens by itself. While it is open: ARKit runs its 4:3 format with the highest frame rate (one ARSession,
/// never reset by the kit), CoreMotion runs at 100 Hz (one run), and the screen stays awake. Progress is saved after
/// every shot; a shot cut short (the app leaving the foreground, the camera interrupted, Quit) is thrown away and stays
/// pending, and every shot before it stays as it was. A retake that fails or is cut short leaves the earlier take in
/// place ("Keep earlier").
///
/// Every error and every milestone (kit opened, shot started, committed, skipped, cancelled, bundle made) goes to the
/// developer log (`AppLog`, area "kit"), so one failed attempt on the phone still says what happened.
@MainActor
final class KitSession: ObservableObject {
    enum Screen: Equatable { case start, measurements, shot, finish }
    enum Phase: Equatable { case ready, countdown, recording, flat, saving, review, failed }

    @Published private(set) var screen: Screen = .start
    @Published private(set) var phase: Phase = .ready

    // the start screen
    /// "Resume: Step 4 of 12, 5 of 28 shots done", when there is a kit to resume
    @Published private(set) var resumeText: String? = nil
    /// "Last kit: slab-kit-..., finished", when the newest kit on the phone is finished (its end screen can share it
    /// again or delete it)
    @Published private(set) var lastKitText: String? = nil
    /// New kit was tapped while an unfinished kit exists: asking before deleting it
    @Published private(set) var confirmingNew = false
    /// On Resume in the middle of a slab position: its label, while asking whether the slab has moved
    @Published private(set) var slabMovedLabel: String? = nil

    // the shot
    @Published private(set) var shot: KitShotSpec? = nil
    /// "Step 4 of 12" (the shown shot's step)
    @Published private(set) var progressLabel = ""
    /// e.g. "Shot 2 of 3 in this step"
    @Published private(set) var shotInStep = ""
    @Published private(set) var countdownLeft = 0
    @Published private(set) var secondsLeft = 0.0
    @Published private(set) var dropNow = false
    @Published private(set) var flat: KitFlatRunner.Snapshot? = nil
    @Published private(set) var report: KitQualityReport? = nil
    @Published private(set) var trueTilt: KitTrueTilt? = nil
    @Published private(set) var heightAsked = false
    /// empty until the owner types a height: the shot's nominal height is only the placeholder, never a value
    @Published var heightText = ""
    @Published private(set) var heightPlaceholder = "inches"
    @Published private(set) var heightNote: String? = nil
    /// a passing note (e.g. a shot thrown away when the app went to the background)
    @Published private(set) var notice: String? = nil
    @Published private(set) var error: String? = nil
    /// the shown shot already has a take on the phone (a retake failed or was cut short): offer to keep it, not Skip
    @Published private(set) var hasEarlierCapture = false

    // the measurements form (step 1)
    @Published var widthText = ""
    @Published var depthText = ""
    @Published var thicknessText = ""
    @Published var dishText = ""
    @Published var ballText = ""
    @Published private(set) var formProblems: [String] = []

    // the finish screen
    @Published private(set) var summary: KitSummary? = nil
    @Published private(set) var finished = false
    @Published private(set) var bundling = false
    @Published private(set) var bundleText: String? = nil
    @Published private(set) var bundleURLs: [URL] = []
    @Published var share: KitShareItem? = nil
    @Published private(set) var confirmingDelete = false

    private weak var model: AppModel?
    private let controller: ARController
    private let feedback = KitFeedback()
    private let route = KitMotionRoute()
    private var store: KitStore? = nil
    /// the kit offered for Resume (loaded, so its progress is known)
    private var resumable: KitStore? = nil
    /// the newest kit, when it is finished
    private var lastFinished: KitListing? = nil
    private var recorder: KitRecorder? = nil
    private var runner: KitFlatRunner? = nil
    private var demoFeed: KitDemoMotionFeed? = nil
    private var task: Task<Void, Never>? = nil
    /// bumped whenever a shot starts or is thrown away, so late callbacks of an older one are ignored
    private var token = 0
    private var shotStartedAt = Date()
    /// uptime of the recording's first frame, of the drop beep, of the flat-phone shot's start
    private var startUptime: Double? = nil
    private var releaseTime: Double? = nil
    private var flatStart = 0.0
    private var flatResult: KitTrueTilt? = nil
    private var runIds: (ar: String, motion: String) = ("", "")

    init(model: AppModel, controller: ARController) {
        self.model = model
        self.controller = controller
    }

    // MARK: places and settings

    /// Application Support/Kits: the working kits (not shown in the Files app)
    nonisolated static var kitsRoot: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Kits", isDirectory: true)
    }

    /// Documents/Kits: the bundle parts, one folder per kit (shown in Files under On My iPhone > Slab Bounce > Kits)
    nonisolated static var outboxRoot: URL? {
        try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Kits", isDirectory: true)
    }

    /// The plan: the standard one, or at a quarter of its timings for the UI tests (launch argument -kitFast YES).
    static var plan: KitPlan {
        UserDefaults.standard.bool(forKey: "kitFast") ? KitPlan.standard.scaled(by: 0.25) : KitPlan.standard
    }

    private var isDemo: Bool { model?.demoRunning ?? false }

    /// the camera's frame rate (the kit's ARKit format; the demo's frames)
    private var sourceFps: Double {
        isDemo ? 1 / ARController.demoFrameInterval : (controller.kitCameraFormat?.fps ?? 60)
    }

    // MARK: open and close

    /// Settings > Developer > Capture kit.
    func open() {
        resetAll()
        screen = .start
        AppLog.info("kit", "opened (\(isDemo ? "demo scene" : "camera"), plan at \(KitSession.plan.timeScale == 1 ? "full" : "test") speed)")
        feedback.prepare()
        UIApplication.shared.isIdleTimerDisabled = true
        controller.setKitMode(true, motion: KitSession.motionHandler(route))
        if let root = KitSession.kitsRoot, let out = KitSession.outboxRoot {
            for k in KitStore.list(root: root) {
                KitBundle.removeLeftovers(kitId: k.kitId, in: out.appendingPathComponent(k.kitId, isDirectory: true))
            }
        }
        refreshStart()
    }

    /// Quit: progress is saved after every shot; a shot in progress is thrown away.
    func quit() {
        AppLog.info("kit", "quit" + (store.map { " (\($0.kitId): \(KitSession.progressWords($0.progress)))" } ?? ""))
        cancelShot(notice: nil, reason: "Quit")
        close()
    }

    private func close() {
        AppLog.info("kit", "closed")
        token += 1
        task?.cancel(); task = nil
        demoFeed?.stop(); demoFeed = nil
        route.clear()
        controller.detachKitRecorder()
        controller.setKitMode(false, motion: nil)
        feedback.close()
        store = nil
        resumable = nil
        model?.kitClosed()
    }

    private func resetAll() {
        token += 1
        task?.cancel(); task = nil
        store = nil; resumable = nil; lastFinished = nil; recorder = nil; runner = nil
        resumeText = nil; lastKitText = nil; confirmingNew = false; slabMovedLabel = nil
        shot = nil; phase = .ready; progressLabel = ""; shotInStep = ""; hasEarlierCapture = false
        resetShotDisplay()
        notice = nil; error = nil; formProblems = []
        summary = nil; finished = false; bundling = false; bundleText = nil; bundleURLs = []; share = nil; confirmingDelete = false
    }

    private func resetShotDisplay() {
        countdownLeft = 0; secondsLeft = 0; dropNow = false; flat = nil; report = nil; trueTilt = nil
        heightAsked = false; heightText = ""; heightNote = nil
    }

    /// The app is leaving the foreground: a shot in progress is thrown away, and the kit stays where it was.
    func appBackgrounded() {
        AppLog.info("kit", "the app went to the background")
        cancelShot(notice: "The app went to the background, so that shot was not saved. Start it again when you are ready.",
                   reason: "the app went to the background")
    }

    /// ARKit's session was interrupted: a video shot in progress is thrown away (a flat-phone shot needs no camera).
    func cameraInterrupted() {
        guard shot?.isFlat != true else {
            AppLog.info("kit", "camera interrupted during a flat-phone shot (it carries on)")
            return
        }
        cancelShot(notice: "The camera was interrupted, so that shot was not saved. Start it again.", reason: "the camera was interrupted")
    }

    // MARK: the start screen

    private func refreshStart() {
        resumable = nil
        resumeText = nil
        lastFinished = nil
        lastKitText = nil
        guard let root = KitSession.kitsRoot else { return }
        if let newest = KitStore.list(root: root).first, newest.finished, newest.loadable {
            lastFinished = newest
            lastKitText = "Last kit: \(newest.kitId), finished. Share or delete it"
        }
        guard let listing = KitStore.resumable(root: root) else { return }
        do {
            let s = try KitStore.load(folder: listing.folder)
            KitSession.logLoad(s)
            let p = s.progress
            resumable = s
            resumeText = "Resume: \(p.label), \(p.done) of \(p.total) shots done"
        } catch {
            showError("The unfinished kit could not be opened: \(KitSession.describe(error))", error)
        }
    }

    func resume() {
        guard let s = resumable else { return }
        AppLog.info("kit", "resumed \(s.kitId): \(KitSession.progressWords(s.progress))")
        store = s
        error = nil
        if let p = s.positionInProgress { slabMovedLabel = p.label } else { goToNext() }
    }

    /// The answer to "Has the slab moved since you stopped?". Yes: the slab position starts again from its flat-phone shot.
    func answerSlabMoved(_ moved: Bool) {
        guard let s = store else { return }
        slabMovedLabel = nil
        AppLog.info("kit", "slab moved since the last shot: \(moved ? "yes" : "no")")
        if moved, let next = s.progress.nextShotId {
            do { try s.restartPosition(forShot: next, date: Date()) } catch {
                showError("Could not set the slab up again: \(KitSession.describe(error))", error)
            }
        }
        goToNext()
    }

    /// The newest kit's end screen (it is finished): share its bundle again, make it again, or delete the kit.
    func openLastKit() {
        guard let l = lastFinished else { return }
        do {
            let s = try KitStore.load(folder: l.folder)
            KitSession.logLoad(s)
            AppLog.info("kit", "opened the last kit \(s.kitId)")
            store = s
            showFinish()
            if let out = KitSession.outboxRoot?.appendingPathComponent(s.kitId, isDirectory: true) {
                let parts = KitBundle.existingParts(kitId: s.kitId, in: out)
                if !parts.isEmpty {
                    bundleURLs = parts
                    let bytes = parts.reduce(Int64(0)) { $0 + KitFiles.size(of: $1) }
                    bundleText = "\(parts.count) part\(parts.count == 1 ? "" : "s"), " + String(format: "%.1f MB", Double(bytes) / 1_000_000)
                        + " (\(bytes) bytes), in Files: On My iPhone > Slab Bounce > Kits > \(s.kitId)."
                }
            }
        } catch {
            showError("The last kit could not be opened: \(KitSession.describe(error))", error)
        }
    }

    func newKit() {
        if resumable != nil && !confirmingNew { confirmingNew = true; return }
        createKit()
    }

    func cancelNew() { confirmingNew = false }

    /// A new kit (after confirming, the unfinished one and its bundle are deleted first).
    func createKit() {
        confirmingNew = false
        error = nil
        if let old = resumable {
            AppLog.info("kit", "deleting the unfinished kit \(old.kitId) for a new one (\(KitSession.progressWords(old.progress)))")
            do { try old.delete() } catch { AppLog.error("kit", "could not delete the unfinished kit \(old.kitId)", error) }
            KitSession.removeOutbox(kitId: old.kitId)
            resumable = nil; resumeText = nil
        }
        guard let root = KitSession.kitsRoot else { showError("No place to keep the kit on this phone.", nil); return }
        let format = controller.kitCameraFormat
        let device = KitDevice(modelIdentifier: Device.model, systemVersion: UIDevice.current.systemVersion,
                               hasLiDAR: ARController.depthSupported, cameraFormat: format, highFrameRateFormat: format)
        do {
            let s = try KitStore.create(root: root, plan: KitSession.plan, device: device,
                                        measurements: KitMeasurements(settings: AppSettings().recording), build: appBuild, date: Date())
            store = s
            let formatWords = format.map { f in String(format: "%dx%d at %.0f fps", f.width, f.height, f.fps) } ?? "no camera format (demo)"
            AppLog.info("kit", "created \(s.kitId): \(device.modelIdentifier), LiDAR \(device.hasLiDAR ? "yes" : "no"), \(formatWords)")
            KitSession.excludeFromBackup(root)
            goToNext()
        } catch {
            showError("Could not create the kit: \(KitSession.describe(error))", error)
        }
    }

    // MARK: moving through the shots

    /// The next pending shot, or the finish screen.
    private func goToNext() {
        guard let s = store else { return }
        token += 1
        task?.cancel(); task = nil
        resetShotDisplay()
        notice = nil; error = nil; formProblems = []
        guard let id = s.progress.nextShotId, let spec = s.plan.shot(id) else { showFinish(); return }
        show(spec)
    }

    private func show(_ spec: KitShotSpec) {
        guard let s = store else { return }
        shot = spec
        hasEarlierCapture = s.record(spec.id)?.status == .captured
        progressLabel = s.plan.progressLabel(step: spec.step)
        let inStep = s.plan.shots(inStep: spec.step)
        if inStep.count > 1, let i = inStep.firstIndex(where: { $0.id == spec.id }) {
            shotInStep = "Shot \(i + 1) of \(inStep.count) in this step"
        } else {
            shotInStep = ""
        }
        phase = .ready
        if spec.isForm {
            fillForm(s.manifest.measurements, entered: s.manifest.measurementsEntered)
            screen = .measurements
        } else {
            screen = .shot
        }
    }

    func next() { goToNext() }

    /// Skip the shown shot (a capture it had is removed; skipping the optional third tilt's flat-phone shot skips the tilt).
    func skip() {
        guard let s = store, let spec = shot else { return }
        cancelShot(notice: nil, reason: "Skip")
        let had = s.record(spec.id)?.status == .captured
        do {
            try s.skipShot(spec.id, date: Date())
            AppLog.info("kit", "shot \(spec.id) skipped" + (had ? " (its take was deleted)" : ""))
            goToNext()
        } catch {
            showError("Could not skip: \(KitSession.describe(error))", error)
        }
    }

    /// Keep earlier: a retake failed or was cut short, and the take already on the phone is kept (it is never lost).
    func keepEarlier() {
        guard let spec = shot else { return }
        cancelShot(notice: nil, reason: "Keep earlier")
        AppLog.info("kit", "shot \(spec.id): the earlier take is kept")
        goToNext()
    }

    /// Take the shot again (the earlier capture stays until the new one is saved).
    func retry() {
        phase = .ready
        start()
    }

    /// Finish now: the end screen with what is done (the kit can still be resumed until the bundle is made).
    func finishNow() {
        AppLog.info("kit", "Finish now")
        cancelShot(notice: nil, reason: "Finish now")
        showFinish()
    }

    func backToShots() { goToNext() }

    // MARK: step 1, the measurements

    /// The form shows what the owner entered before (a retake of step 1), else nothing: the app's built-in slab and ball
    /// are only the placeholders, so Start never records them as if they had been measured.
    private func fillForm(_ m: KitMeasurements, entered: Bool) {
        guard entered else {
            widthText = ""; depthText = ""; thicknessText = ""; dishText = ""; ballText = ""
            return
        }
        widthText = KitSession.fmt(m.slabWidthInches)
        depthText = KitSession.fmt(m.slabDepthInches)
        thicknessText = KitSession.fmt(m.slabThicknessInches)
        dishText = m.dishInches.map(KitSession.fmt) ?? ""
        ballText = KitSession.fmt(m.ballDiameterMm)
    }

    /// Start (step 1): the values are checked and stored in the kit's kit.json only (never in the app's settings).
    func commitMeasurements() {
        guard let s = store else { return }
        let required = [widthText, depthText, thicknessText, ballText].map { $0.trimmingCharacters(in: .whitespaces) }
        guard !required.contains(where: { $0.isEmpty }) else {
            formProblems = ["Enter the slab's width, depth and thickness and the ball's diameter as you measured them, or tap Skip (the kit then keeps the app's built-in slab and ball)."]
            return
        }
        let dish = dishText.trimmingCharacters(in: .whitespaces)
        let m = KitMeasurements(slabWidthInches: KitSession.number(widthText) ?? .nan, slabDepthInches: KitSession.number(depthText) ?? .nan,
                                slabThicknessInches: KitSession.number(thicknessText) ?? .nan,
                                dishInches: dish.isEmpty ? nil : (KitSession.number(dish) ?? .nan),
                                ballDiameterMm: KitSession.number(ballText) ?? .nan)
        guard m.isValid else {
            formProblems = m.problems
            AppLog.info("kit", "measurements not accepted: \(m.problems.count) problem(s)")
            return
        }
        do {
            try s.commitMeasurements(m, date: Date())
            AppLog.info("kit", "measurements saved")
            formProblems = []
            goToNext()
        } catch {
            AppLog.error("kit", "could not save the measurements", error)
            formProblems = [KitSession.describe(error)]
        }
    }

    // MARK: a shot

    /// Start: the countdown, then the recording (or the flat-phone readings).
    func start() {
        guard let s = store, let spec = shot, !spec.isForm, phase == .ready || phase == .review || phase == .failed else { return }
        token += 1
        let tk = token
        task?.cancel()
        resetShotDisplay()
        notice = nil; error = nil
        let folder: URL
        do { folder = try s.beginShot(spec.id) } catch {
            fail("Could not start the shot: \(KitSession.describe(error))", error)
            return
        }
        AppLog.info("kit", "shot \(spec.id) started (\(s.plan.progressLabel(step: spec.step))" + (hasEarlierCapture ? ", a retake" : "") + ")")
        phase = .countdown
        task = Task { [weak self] in
            await self?.run(spec, folder: folder, token: tk)
        }
    }

    private func run(_ spec: KitShotSpec, folder: URL, token tk: Int) async {
        let end = CACurrentMediaTime() + spec.countdown
        var shown = -1
        while tk == token {
            let left = end - CACurrentMediaTime()
            if left <= 0 { break }
            let n = Int(left.rounded(.up))
            if n != shown { shown = n; countdownLeft = n; feedback.play(.tick) }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard tk == token else { return }
        if spec.isFlat { await runFlat(spec, folder: folder, token: tk) } else { await runVideo(spec, folder: folder, token: tk) }
    }

    // MARK: video shots

    private func runVideo(_ spec: KitShotSpec, folder: URL, token tk: Int) async {
        guard let seconds = spec.kind.videoSeconds else { return }
        let cb = KitSession.recorderCallbacks(self, token: tk)
        let rec: KitRecorder
        do {
            rec = try KitRecorder(folder: folder, video: true, duration: seconds, highFrameRate: spec.kind.highFrameRate, sourceFps: sourceFps,
                                  wantsDepth: ARController.depthSupported && !isDemo, label: "shot \(spec.id)",
                                  onStart: cb.started, completion: cb.done)
        } catch {
            discardAttempt()
            fail("Could not start the recording: \(KitSession.describe(error))", error)
            return
        }
        recorder = rec
        runIds = controller.runIds
        shotStartedAt = Date()
        startUptime = nil
        releaseTime = nil
        route.set(recorder: rec, runner: nil)
        controller.attachKitRecorder(rec)
        phase = .recording
        secondsLeft = seconds
        // a drop shot's only beep after the countdown is the one to let go at (`recordingStarted` plays it)
        if spec.kind.releaseCue == nil { feedback.play(.phase) }
        let t0 = CACurrentMediaTime()
        var stopped = false
        while tk == token && phase == .recording {
            let since = startUptime.map { CACurrentMediaTime() - $0 } ?? 0
            secondsLeft = max(0, seconds - since)
            // no frames coming (the camera stopped): stop with what there is
            if !stopped && CACurrentMediaTime() - t0 > seconds + 8 {
                stopped = true
                AppLog.warn("kit", "shot \(spec.id): no frames for \(Int(seconds + 8)) s, stopping with what there is")
                rec.finish()
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// The recording's first frame (its uptime is the origin of the video and of the release cue).
    fileprivate func recordingStarted(at t: Double, token tk: Int) {
        guard tk == token, phase == .recording else { return }
        startUptime = t
        guard let cue = shot?.kind.releaseCue else { return }
        Task { [weak self] in
            let delay = t + cue - CACurrentMediaTime()
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard let self = self, tk == self.token, self.phase == .recording else { return }
            self.releaseTime = self.feedback.play(.drop)
            self.dropNow = true
        }
    }

    /// The recording is complete: check it and commit it (or say why it failed).
    fileprivate func recordingDone(_ r: KitRecorder.Result, token tk: Int) {
        guard tk == token, let s = store, let spec = shot else { return }
        recorder = nil
        route.clear()
        controller.detachKitRecorder()
        if let e = r.error {
            discardAttempt()
            fail("The recording failed: \(e). " + retryHint)
            return
        }
        phase = .saving
        feedback.play(.phase)
        let fps = r.keptFps
        let duration = (r.endTime ?? 0) - (r.startTime ?? 0) + (fps > 0 ? 1 / fps : 0)
        do {
            var m = try s.newShotManifest(spec.id, startedAt: shotStartedAt, duration: duration)
            m.startTime = r.startTime
            m.releaseTime = releaseTime
            m.motionSessionId = runIds.motion
            m.arSessionId = runIds.ar
            m.video = r.video
            m.cameraFormat = isDemo ? nil : controller.kitCameraFormat
            m.hasDepth = r.depthFrames > 0
            m.depthFrames = r.depthFrames > 0 ? r.depthFrames : nil
            m.motionSamples = r.motionSamples
            let q = KitQuality.evaluate(shot: spec, stats: r.stats, expectedFrames: KitQuality.expectedFrames(shot: spec, fps: fps),
                                        reference: s.qualityReference)
            m.quality = q
            if isDemo { m.notes = "demo scene: synthetic frames, no motion samples" }
            try s.commitShot(spec.id, manifest: m, date: Date())
            let seconds = String(format: "%.1f s", duration)
            let video = r.video.map { "\($0.codec) \($0.fileBytes) bytes" } ?? "no video"
            AppLog.info("kit", "shot \(spec.id) committed: \(r.frames) frames, \(seconds), \(video), depth \(r.depthFrames), "
                        + "motion \(r.motionSamples), check \(q.verdict.rawValue)")
            self.report = q
            hasEarlierCapture = true
            heightAsked = spec.asksHeight
            heightText = ""
            heightPlaceholder = spec.nominalHeightInches.map { "about " + KitSession.fmt($0) } ?? "inches"
            phase = .review
        } catch {
            discardAttempt()
            fail("Could not save the shot: \(KitSession.describe(error)). " + retryHint, error)
        }
    }

    // MARK: flat-phone shots

    private func runFlat(_ spec: KitShotSpec, folder: URL, token tk: Int) async {
        guard let s = store else { return }
        let start = CACurrentMediaTime()
        let session = KitFlatSession(settings: s.plan.flatSettings, knownBump: s.knownBump, startTime: start)
        let fr = KitFlatRunner(session: session)
        let cb = KitSession.recorderCallbacks(self, token: tk)
        let rec: KitRecorder
        do {
            rec = try KitRecorder(folder: folder, video: false, duration: 0, highFrameRate: false, sourceFps: 100, wantsDepth: false,
                                  label: "shot \(spec.id)", onStart: cb.started, completion: cb.flatDone)
        } catch {
            discardAttempt()
            fail("Could not start the reading: \(KitSession.describe(error))", error)
            return
        }
        recorder = rec
        runner = fr
        runIds = controller.runIds
        shotStartedAt = Date()
        flatStart = start
        flatResult = nil
        route.set(recorder: rec, runner: fr)
        if isDemo {
            // no CoreMotion in the Simulator: a phone lying on the demo slab, turned by itself after the prompt
            let script = AppModel.demoScript() ?? DemoScript()
            let feed = KitDemoMotionFeed(tiltDegrees: script.tilt, downhillAzimuthDegrees: script.heading + 90)
            feed.start(phase: KitSession.phaseReader(fr), sink: KitSession.motionHandler(route))
            demoFeed = feed
        }
        phase = .flat
        // Two cues only, as the instructions say: the turn beep when reading A is done (the phone may be picked up),
        // and a lower tone when it is all done. None when a reading starts or starts over, and no haptics while the
        // phone lies on the slab.
        var lastPhase = fr.snapshot().phase
        while tk == token {
            fr.advance(to: CACurrentMediaTime())
            let snap = fr.snapshot()
            flat = snap
            if snap.phase != lastPhase {
                if snap.phase == .waitingForLift { feedback.play(.turn) }
                if snap.phase == .done { feedback.play(.done) }
                let after = String(format: "%.1f s", CACurrentMediaTime() - start)
                AppLog.info("kit", "shot \(spec.id): \(lastPhase.rawValue) -> \(snap.phase.rawValue) after \(after), \(snap.samples) samples")
                lastPhase = snap.phase
            }
            if snap.phase == .done { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard tk == token else { return }
        demoFeed?.stop(); demoFeed = nil
        route.clear()
        let result = fr.snapshot().result ?? fr.finish()
        flatResult = result
        if !result.isUsable {
            AppLog.warn("kit", "shot \(spec.id): no usable true tilt (\(result.method.rawValue)): " + (result.reasons.first ?? "no reason given"))
        }
        phase = .saving
        rec.finish()
    }

    /// Stop the flat-phone readings now (the result from what was read so far).
    func stopFlat() {
        AppLog.info("kit", "flat-phone readings stopped by hand")
        runner?.finish()
    }

    /// motion.jsonl is closed: commit the flat-phone shot with its result and check.
    fileprivate func flatRecordingDone(_ r: KitRecorder.Result, token tk: Int) {
        guard tk == token, let s = store, let spec = shot, let result = flatResult else { return }
        recorder = nil
        runner = nil
        if let e = r.error {
            discardAttempt()
            fail("The reading failed: \(e). " + retryHint)
            return
        }
        let end = flat?.result?.readingB?.end ?? flat?.result?.readingA?.end ?? CACurrentMediaTime()
        do {
            var m = try s.newShotManifest(spec.id, startedAt: shotStartedAt, duration: max(0, end - flatStart))
            m.startTime = flatStart
            m.motionSessionId = runIds.motion
            m.arSessionId = runIds.ar
            m.motionSamples = r.motionSamples
            m.flat = result
            let q = KitQuality.evaluate(shot: spec, flat: result)
            m.quality = q
            if isDemo { m.notes = "demo scene: synthetic motion with a 1.5 degree camera bump" }
            try s.commitShot(spec.id, manifest: m, date: Date())
            let tilt = result.tiltDegrees.map { String(format: "%.2f deg", $0) } ?? "none"
            AppLog.info("kit", "shot \(spec.id) committed: true tilt \(tilt) (\(result.method.rawValue)), \(r.motionSamples) motion samples, "
                        + "check \(q.verdict.rawValue)")
            trueTilt = result
            self.report = q
            hasEarlierCapture = true
            phase = .review
        } catch {
            discardAttempt()
            fail("Could not save the shot: \(KitSession.describe(error)). " + retryHint, error)
        }
    }

    // MARK: heights (step 9)

    func saveHeight() {
        guard let s = store, let spec = shot else { return }
        guard let h = KitSession.number(heightText), h > 0, h <= 120 else {
            heightNote = "Enter the height in inches (more than 0, at most 120)."
            return
        }
        do {
            try s.setHeight(spec.id, inches: h, date: Date())
            AppLog.info("kit", "shot \(spec.id): height saved")
            heightAsked = false
            heightNote = "Height saved: \(KitSession.fmt(h)) in."
        } catch {
            AppLog.error("kit", "shot \(spec.id): could not save the height", error)
            heightNote = "Could not save the height: \(KitSession.describe(error))"
        }
    }

    func skipHeight() {
        heightAsked = false
        heightNote = "No height entered."
    }

    // MARK: cancelling

    /// Throw away a shot in progress (it stays pending; an earlier capture of it stays, and so does every other shot).
    private func cancelShot(notice text: String?, reason: String) {
        guard phase == .countdown || phase == .recording || phase == .flat || phase == .saving else { return }
        AppLog.info("kit", "shot \(shot?.id ?? "?") cancelled during \(phase) (\(reason)): this attempt is thrown away"
                    + (hasEarlierCapture ? ", the earlier take stays" : ", the shot stays pending"))
        token += 1
        task?.cancel(); task = nil
        controller.detachKitRecorder()
        recorder?.cancel()
        recorder = nil
        runner = nil
        demoFeed?.stop(); demoFeed = nil
        route.clear()
        discardAttempt()
        resetShotDisplay()
        phase = .ready
        notice = text
    }

    private func discardAttempt() {
        guard let s = store, let spec = shot, !spec.isForm else { return }
        do { try s.discardAttempt(spec.id) } catch {
            // the next Start (or the next load) removes it; nothing committed is touched
            AppLog.warn("kit", "shot \(spec.id): could not remove the unfinished attempt", error)
        }
    }

    /// A shot failed: its attempt is already thrown away (an earlier take of it stays).
    private func fail(_ message: String, _ cause: Error? = nil) {
        error = message
        phase = .failed
        if let s = store, let spec = shot { hasEarlierCapture = s.record(spec.id)?.status == .captured }
        AppLog.error("kit", "shot \(shot?.id ?? "?"): " + message + (cause.map { " [" + DevLog.describe($0) + "]" } ?? ""))
    }

    /// What a failed shot's message suggests: with an earlier take on the phone, keeping it.
    private var retryHint: String {
        guard let s = store, let spec = shot, s.record(spec.id)?.status == .captured else { return "Retry or Skip." }
        return "Retry, or Keep earlier to keep the take you have."
    }

    /// An error on the start or finish screen (shown, and logged with its cause).
    private func showError(_ message: String, _ cause: Error?) {
        error = message
        AppLog.error("kit", message + (cause.map { " [" + DevLog.describe($0) + "]" } ?? ""))
    }

    // MARK: finish

    private func showFinish() {
        guard let s = store else { return }
        screen = .finish
        summary = s.summary()
        AppLog.info("kit", "end screen for \(s.kitId): " + (summary?.headline ?? ""))
        finished = s.isFinished
        confirmingDelete = false
    }

    var hasPendingShots: Bool { (summary?.pending ?? 0) > 0 }

    /// Make bundle: the kit is marked finished and zipped into parts (each at most 24,000,000 bytes) in
    /// Documents/Kits/<kitId>/, JSON, JSONL and depth deflated with Apple's Compression framework.
    func makeBundle() {
        guard let s = store, !bundling, let outRoot = KitSession.outboxRoot else { return }
        error = nil
        if !s.isFinished {
            do { try s.finish(date: Date()) } catch {
                showError("Could not finish the kit: \(KitSession.describe(error))", error)
                return
            }
        }
        AppLog.info("kit", "making the bundle for \(s.kitId) (" + String(format: "%.1f MB", Double(s.bytesOnDisk()) / 1e6) + ")")
        finished = true
        summary = s.summary()
        bundling = true
        bundleText = nil
        bundleURLs = []
        let kitFolder = s.folder, outbox = outRoot.appendingPathComponent(s.kitId, isDirectory: true)
        let done = KitSession.bundleCallback(self, kitId: s.kitId)
        DispatchQueue.global(qos: .userInitiated).async {
            done(Result<KitBundleResult, Error>(catching: { try KitBundle.build(kitFolder: kitFolder, outbox: outbox, deflate: KitDeflate.raw) }))
        }
    }

    fileprivate func bundleDone(_ r: Result<KitBundleResult, Error>, kitId: String) {
        bundling = false
        guard store?.kitId == kitId else { return }
        switch r {
        case .success(let b):
            bundleURLs = b.urls
            let n = b.parts.count
            let partSizes: [String] = b.parts.map { p in "part \(p.index): \(p.bytes)" + (p.oversized ? " oversized" : "") }
            AppLog.info("kit", "bundle made for \(kitId): \(n) part(s), \(b.totalBytes) bytes (\(partSizes.joined(separator: ", "))), "
                        + "\(b.deflated.count) files deflated")
            var text = "\(n) part\(n == 1 ? "" : "s"), " + String(format: "%.1f MB", Double(b.totalBytes) / 1_000_000)
                + " (\(b.totalBytes) bytes), in Files: On My iPhone > Slab Bounce > Kits > \(kitId)."
            if !b.oversized.isEmpty { text += " \(b.oversized.count) file(s) were larger than a part on their own." }
            bundleText = text
        case .failure(let e):
            showError("Could not make the bundle: \(KitSession.describe(e)). Tap Make bundle to try again.", e)
        }
    }

    /// Share kit: every part at once (AirDrop, Save to Files, ...).
    func shareKit() {
        guard !bundleURLs.isEmpty else { return }
        AppLog.info("kit", "share sheet opened with \(bundleURLs.count) part(s)")
        share = KitShareItem(urls: bundleURLs)
    }

    func askDelete() { confirmingDelete = true }
    func cancelDelete() { confirmingDelete = false }

    /// Delete kit from phone: the working kit and its bundle parts.
    func confirmDelete() {
        confirmingDelete = false
        guard let s = store else { return }
        do {
            try s.delete()
            AppLog.info("kit", "deleted \(s.kitId)")
            KitSession.removeOutbox(kitId: s.kitId)
            close()
        } catch {
            showError("Could not delete the kit: \(KitSession.describe(error))", error)
        }
    }

    // MARK: helpers (no isolation: the closures they make run on other queues)

    nonisolated static func motionHandler(_ route: KitMotionRoute) -> (KitMotionSample) -> Void {
        { s in route.deliver(s) }
    }

    nonisolated static func phaseReader(_ runner: KitFlatRunner) -> () -> KitFlatSession.Phase {
        { runner.phase }
    }

    /// The recorder's callbacks (its queue) hop to the main actor. They hold the session until the recorder is let go.
    nonisolated static func recorderCallbacks(_ session: KitSession, token: Int)
        -> (started: (Double) -> Void, done: (KitRecorder.Result) -> Void, flatDone: (KitRecorder.Result) -> Void) {
        ({ t in Task { @MainActor in session.recordingStarted(at: t, token: token) } },
         { r in Task { @MainActor in session.recordingDone(r, token: token) } },
         { r in Task { @MainActor in session.flatRecordingDone(r, token: token) } })
    }

    nonisolated static func bundleCallback(_ session: KitSession, kitId: String) -> (Result<KitBundleResult, Error>) -> Void {
        { r in Task { @MainActor in session.bundleDone(r, kitId: kitId) } }
    }

    nonisolated static func removeOutbox(kitId: String) {
        guard let out = outboxRoot?.appendingPathComponent(kitId, isDirectory: true),
              FileManager.default.fileExists(atPath: out.path) else { return }
        do { try FileManager.default.removeItem(at: out) } catch {
            AppLog.error("kit", "could not delete the bundle parts of \(kitId)", error)
        }
    }

    nonisolated static func excludeFromBackup(_ folder: URL) {
        var url = folder
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        do { try url.setResourceValues(v) } catch { AppLog.warn("kit", "could not exclude the kits from backup", error) }
    }

    /// What `KitStore.load` repaired after an earlier run stopped mid-step (logged; nothing is shown).
    nonisolated static func logLoad(_ s: KitStore) {
        AppLog.info("kit", "loaded \(s.kitId): \(progressWords(s.progress))")
        if !s.discardedOnLoad.isEmpty {
            AppLog.warn("kit", "unfinished attempts thrown away on load (the app stopped mid-shot): " + s.discardedOnLoad.joined(separator: ", "))
        }
        if !s.repairedOnLoad.isEmpty {
            AppLog.warn("kit", "records rebuilt from shot.json on load (the app stopped mid-commit): " + s.repairedOnLoad.joined(separator: ", "))
        }
        if s.unsavedRepairOnLoad { AppLog.warn("kit", "the repaired kit.json could not be saved yet (out of space?); the next step saves it") }
    }

    /// "Step 4 of 12, 4 of 28 done (4 captured, 0 skipped), next p1-arc"
    nonisolated static func progressWords(_ p: KitProgress) -> String {
        "\(p.label), \(p.done) of \(p.total) done (\(p.captured) captured, \(p.skipped) skipped)" + (p.nextShotId.map { ", next \($0)" } ?? "")
    }

    /// A number typed by the owner ("7", "7.25", "7,25").
    nonisolated static func number(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let v = Double(t), v.isFinite else { return nil }
        return v
    }

    /// "7", "0.125", "35"
    nonisolated static func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.0f", v) : String(format: "%g", v)
    }

    /// A short reason without paths: the kit's own messages, else an error code.
    nonisolated static func describe(_ e: Error) -> String {
        if let k = e as? KitStoreError { return k.description }
        if let b = e as? KitBundleError { return b.description }
        if let f = e as? KitFormatError { return f.description }
        let ns = e as NSError
        if (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError) || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC)) {
            return "the phone is out of space"
        }
        return "error \(ns.code)"
    }
}
