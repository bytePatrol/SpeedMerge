import AppKit
import SpeedMergeCore

@MainActor
final class MergeViewModel: ObservableObject {
    static let shared = MergeViewModel()

    @Published var source: URL?
    @Published var destination: URL?
    @Published var parallelCopies = 8 {
        didSet { engine?.setParallelCopies(parallelCopies) }
    }
    @Published private(set) var snapshot: MergeSnapshot?
    @Published private(set) var speed: Double = 0
    @Published private(set) var failures: [MergeFailure] = []
    @Published var errorMessage: String?
    @Published private(set) var resumableJob: SavedJob?

    private var engine: MergeEngine?
    private var logger: MergeLogger?
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var speedSamples: [(time: TimeInterval, bytes: Int64)] = []
    private var savedJob: SavedJob?

    init() {
        if let job = JobStore.load(), !job.finished || job.failedCount > 0 {
            resumableJob = job
        }
    }

    var state: MergeState? { snapshot?.state }

    var isBusy: Bool {
        guard let state else { return false }
        return state != .finished && state != .cancelled
    }

    var canStart: Bool { !isBusy && source != nil && destination != nil }

    var logURL: URL? { logger?.url ?? resumableJob?.logPath.map { URL(fileURLWithPath: $0) } }

    // MARK: actions

    func start() {
        guard let source, let destination, !isBusy else { return }
        if let problem = MergeEngine.validate(source: source, destination: destination) {
            errorMessage = problem
            return
        }
        errorMessage = nil
        failures = []
        speed = 0
        speedSamples = []

        var options = MergeOptions()
        options.parallelCopies = parallelCopies
        logger = MergeLogger.makeDefault()
        let engine = MergeEngine(source: source, destination: destination, options: options, logger: logger)
        engine.onFinish = { _ in
            Task { @MainActor in MergeViewModel.shared.refresh() }
        }
        self.engine = engine

        let job = SavedJob(source: source.path, destination: destination.path, parallelCopies: parallelCopies, logPath: logger?.url.path)
        savedJob = job
        JobStore.save(job)
        resumableJob = nil

        // Keep the Mac from going to sleep while copying (the display may still sleep).
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "Merging folders")
        engine.start()
        snapshot = engine.snapshot()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in MergeViewModel.shared.refresh() }
        }
    }

    func resumeSavedJob() {
        guard let job = resumableJob else { return }
        source = URL(fileURLWithPath: job.source, isDirectory: true)
        destination = URL(fileURLWithPath: job.destination, isDirectory: true)
        parallelCopies = job.parallelCopies
        start()
    }

    func dismissSavedJob() {
        if var job = resumableJob {
            job.finished = true
            job.failedCount = 0
            JobStore.save(job)
        }
        resumableJob = nil
    }

    func togglePause() {
        guard let engine else { return }
        if state == .paused { engine.resume() } else { engine.pause() }
        refresh()
    }

    func cancel() {
        engine?.cancel()
        refresh()
    }

    func revealLog() {
        guard let url = logURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: progress

    func refresh() {
        guard let engine else { return }
        let snap = engine.snapshot()
        snapshot = snap

        let now = ProcessInfo.processInfo.systemUptime
        speedSamples.append((now, snap.bytesTransferred))
        speedSamples.removeAll { now - $0.time > 10 }
        if let first = speedSamples.first, now - first.time > 0.9 {
            speed = Double(snap.bytesTransferred - first.bytes) / (now - first.time)
        }
        if snap.state == .paused || snap.state == .waitingForNetwork { speed = 0 }

        if snap.state == .finished || snap.state == .cancelled {
            finishRun(snap)
        }
    }

    private func finishRun(_ snap: MergeSnapshot) {
        timer?.invalidate()
        timer = nil
        speed = 0
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        failures = engine?.failureList() ?? []
        if var job = savedJob {
            job.finished = snap.state == .finished
            job.failedCount = snap.filesFailed + snap.foldersFailed
            JobStore.save(job)
            savedJob = nil
        }
    }

    /// Stops the merge before quitting. Partial files are kept, so it can be resumed later.
    func prepareToQuit() {
        engine?.cancel()
        _ = engine?.waitUntilDone(timeout: 5)
        if let snap = engine?.snapshot() { finishRun(snap) }
    }
}
