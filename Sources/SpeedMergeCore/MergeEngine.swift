import Foundation
import Darwin

public struct MergeOptions: @unchecked Sendable {
    /// Number of files copied at the same time.
    public var parallelCopies = 8
    /// Number of threads walking the source folder tree.
    public var scannerThreads = 4
    /// A copy that makes no progress for this long is abandoned and retried.
    public var stallTimeout: TimeInterval = 60
    /// Attempts per file before it is reported as failed.
    public var maxAttempts = 3
    /// Base delay before a retry; multiplied by the attempt number.
    public var retryDelay: TimeInterval = 5
    public var chunkSize = 8 * 1024 * 1024
    /// When resuming a partial file, this much of its tail is copied again in case it was not fully written.
    public var resumeOverlap: Int64 = 64 * 1024 * 1024
    /// How often both shares are checked to still be mounted and reachable.
    public var networkCheckInterval: TimeInterval = 3
    /// If no reachability check has succeeded for this long, the shares are treated as unreachable.
    public var networkUnhealthyAfter: TimeInterval = 20
    /// Files and folders that are never copied (macOS and NAS housekeeping).
    public var excludedNames: Set<String> = MergeOptions.defaultExcludedNames
    /// Test hook, called before each chunk of a file is read.
    public var chunkHook: ((_ relativePath: String, _ attempt: Int) -> Void)?

    public static let defaultExcludedNames: Set<String> = [
        ".DS_Store", ".Trashes", ".Spotlight-V100", ".fseventsd", ".TemporaryItems",
        "@eaDir", "#recycle", "#snapshot", "@Recycle", "@Recently-Snapshot", ".@__thumb",
    ]

    public init() {}
}

public enum MergeState: String, Sendable {
    case running, paused, waitingForNetwork, stopping, cancelled, finished
}

public struct ActiveFileInfo: Identifiable, Sendable {
    public let id: Int
    public let path: String
    public let size: Int64
    public let done: Int64
    public let attempt: Int
}

public struct MergeFailure: Identifiable, Sendable {
    public let id = UUID()
    public let path: String
    public let message: String
}

public struct MergeSnapshot: Sendable {
    public var state: MergeState = .running
    public var scanComplete = false
    public var foldersScanned = 0
    public var filesFound = 0
    public var bytesFound: Int64 = 0
    public var filesSkipped = 0
    public var bytesSkipped: Int64 = 0
    public var filesCopied = 0
    /// Bytes of files that needed copying that are now in the destination (including progress on in-flight files).
    public var bytesDone: Int64 = 0
    /// Bytes actually sent over the network this session (used for speed).
    public var bytesTransferred: Int64 = 0
    public var filesFailed = 0
    public var foldersFailed = 0
    public var retries = 0
    public var stalls = 0
    public var active: [ActiveFileInfo] = []
    public var elapsed: TimeInterval = 0

    /// Fraction of all data found so far that is now in the destination.
    public var fraction: Double {
        bytesFound > 0 ? min(1, Double(bytesSkipped + bytesDone) / Double(bytesFound)) : 0
    }
    public var bytesRemaining: Int64 { max(0, bytesFound - bytesSkipped - bytesDone) }
}

/// Copies everything in a source folder into a destination folder, keeping the folder structure.
/// The source is only read. Destination files are replaced unless they already match by size and
/// modification date, which also makes an interrupted merge resumable by simply running it again.
public final class MergeEngine: @unchecked Sendable {
    public let sourceRoot: String
    public let destinationRoot: String
    public let options: MergeOptions
    public let logger: MergeLogger?
    /// Called once on a background queue when every file has been processed.
    public var onFinish: ((MergeSnapshot) -> Void)?

    static let partialSuffix = ".smpartial"
    static let maxQueuedFiles = 20_000
    static let maxNetworkRetries = 30
    static let maxStuckThreads = 64
    static let networkErrnos: Set<Int32> = [
        ENOTCONN, ETIMEDOUT, ENETDOWN, ENETUNREACH, ENETRESET, ECONNRESET, ECONNABORTED,
        EHOSTDOWN, EHOSTUNREACH, ENXIO, ESTALE, ENODEV, EPIPE,
    ]
    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
    ]
    private static let resourceKeySet = Set(resourceKeys)

    private struct FileJob {
        let rel: String
        let size: Int64
        let mtime: Double
        let isSymlink: Bool
        var attempt = 0
        var networkRetries = 0
    }

    private struct DirJob {
        let rel: String
        var attempt = 0
        var networkRetries = 0
    }

    private struct RootInfo {
        let path: String
        /// Where the volume holding this folder is mounted, e.g. /Volumes/Media.
        let mountPoint: String
        let device: dev_t
    }

    private final class ActiveCopy {
        let id: Int
        let job: FileJob
        /// `networkOutages` when the copy started; if it changes, errors are blamed on the outage.
        let outagesAtStart: Int
        var counted: Int64 = 0
        var lastProgress: TimeInterval
        var abandoned = false

        init(id: Int, job: FileJob, outagesAtStart: Int) {
            self.id = id
            self.job = job
            self.outagesAtStart = outagesAtStart
            lastProgress = monotonicNow()
        }
    }

    private enum CopyResult {
        case copied
        case stopped
        case failed(Int32, String)
    }

    // Everything below is guarded by `cond`.
    private let cond = NSCondition()
    private var started = false
    private var paused = false
    private var cancelled = false
    private var finished = false
    private var networkDown = false
    private var networkOutages = 0
    private var lastHealthyCheck: TimeInterval = 0
    private var roots: [RootInfo] = []
    /// Device of the destination volume; refreshed when a share comes back, since a remount gets a new device.
    private var destinationDevice: dev_t?
    private var dirStack: [DirJob] = []
    private var scannersBusy = 0
    private var scannersAlive = 0
    private var scannersWaitingForRoom = 0
    private var scanDone = false
    private var queue = JobQueue<FileJob>()
    private var retryQueue: [FileJob] = []
    private var pendingRetries = 0
    private var activeCopies: [Int: ActiveCopy] = [:]
    private var nextCopyID = 0
    private var targetWorkers: Int
    private var workerCount = 0
    private var stuckWorkers = 0
    private var stats = MergeSnapshot()
    private var failures: [MergeFailure] = []
    private var startTime: TimeInterval = 0
    private var endTime: TimeInterval?

    public init(source: URL, destination: URL, options: MergeOptions = MergeOptions(), logger: MergeLogger? = nil) {
        sourceRoot = MergeEngine.normalize(source)
        destinationRoot = MergeEngine.normalize(destination)
        self.options = options
        self.logger = logger
        targetWorkers = max(1, options.parallelCopies)
    }

    static func normalize(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Returns a message explaining why these folders can't be merged, or nil if they can.
    public static func validate(source: URL, destination: URL) -> String? {
        let src = normalize(source)
        let dst = normalize(destination)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: src, isDirectory: &isDir), isDir.boolValue else {
            return "The source folder can't be found. Is the share still connected?"
        }
        guard FileManager.default.fileExists(atPath: dst, isDirectory: &isDir), isDir.boolValue else {
            return "The destination folder can't be found. Is the share still connected?"
        }
        if src == dst { return "The source and destination are the same folder." }
        if dst.hasPrefix(src + "/") { return "The destination is inside the source folder, so the merge would copy into itself." }
        if src.hasPrefix(dst + "/") { return "The source is inside the destination folder." }
        if access(dst, W_OK) != 0 { return "You don't have permission to write to the destination folder." }
        return nil
    }

    /// Name of the hidden temporary file a copy is written to before being renamed into place.
    /// It encodes the source's size and date, so a leftover partial is only resumed for the same version of the file.
    static func partialName(for name: String, size: Int64, mtime: Double) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(name)|\(size)|\(Int64(mtime.rounded(.down)))".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        var base = name
        while base.utf8.count > 150 { base.removeLast() }
        return "." + base + "." + String(format: "%016llx", hash) + partialSuffix
    }

    // MARK: - Control

    public func start() {
        cond.lock()
        guard !started else { cond.unlock(); return }
        started = true
        startTime = monotonicNow()
        lastHealthyCheck = startTime
        roots = [sourceRoot, destinationRoot].compactMap(Self.rootInfo)
        destinationDevice = Self.rootInfo(destinationRoot)?.device
        dirStack.append(DirJob(rel: ""))
        log("Merge started: \"\(sourceRoot)\" -> \"\(destinationRoot)\" with \(targetWorkers) parallel copies")
        for _ in 0..<max(1, options.scannerThreads) {
            scannersAlive += 1
            spawn("scanner") { self.scannerLoop() }
        }
        for _ in 0..<targetWorkers { spawnWorkerLocked() }
        spawn("watchdog") { self.watchdogLoop() }
        spawn("monitor") { self.monitorLoop() }
        cond.unlock()
    }

    public func pause() {
        cond.lock()
        if !paused && !finished && !cancelled {
            paused = true
            log("Paused")
        }
        cond.unlock()
    }

    public func resume() {
        cond.lock()
        if paused {
            paused = false
            refreshProgressClocksLocked()
            log("Resumed")
            cond.broadcast()
        }
        cond.unlock()
    }

    public func cancel() {
        cond.lock()
        if !cancelled && !finished {
            cancelled = true
            endTime = monotonicNow()
            log("Cancelled. Partially copied files are kept and will be resumed next time.")
            cond.broadcast()
        }
        cond.unlock()
    }

    public func setParallelCopies(_ count: Int) {
        cond.lock()
        targetWorkers = max(1, count)
        if started && !cancelled && !finished {
            while workerCount < targetWorkers { spawnWorkerLocked() }
            log("Parallel copies set to \(targetWorkers)")
        }
        cond.broadcast()
        cond.unlock()
    }

    public func snapshot() -> MergeSnapshot {
        cond.lock()
        defer { cond.unlock() }
        var snap = stats
        if finished {
            snap.state = .finished
        } else if cancelled {
            snap.state = (workerCount == 0 && scannersAlive == 0) ? .cancelled : .stopping
        } else if paused {
            snap.state = .paused
        } else if networkDown {
            snap.state = .waitingForNetwork
        } else {
            snap.state = .running
        }
        snap.scanComplete = scanDone
        snap.active = activeCopies.values.sorted { $0.id < $1.id }.map {
            ActiveFileInfo(id: $0.id, path: $0.job.rel, size: $0.job.size, done: $0.counted, attempt: $0.job.attempt + 1)
        }
        snap.elapsed = (endTime ?? monotonicNow()) - startTime
        return snap
    }

    public func failureList() -> [MergeFailure] {
        cond.lock()
        defer { cond.unlock() }
        return failures
    }

    /// Blocks until the merge finishes or a cancel has fully stopped. Returns false on timeout.
    @discardableResult
    public func waitUntilDone(timeout: TimeInterval = .infinity) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        cond.lock()
        defer { cond.unlock() }
        while !(finished || (cancelled && workerCount == 0 && scannersAlive == 0)) {
            if !cond.wait(until: min(deadline, Date().addingTimeInterval(1))) && Date() >= deadline { return false }
        }
        return true
    }

    // MARK: - Threads

    private func spawn(_ name: String, _ body: @escaping () -> Void) {
        let thread = Thread(block: body)
        thread.name = "SpeedMerge.\(name)"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func spawnWorkerLocked() {
        workerCount += 1
        spawn("copy") { self.workerLoop() }
    }

    private var isStoppingLocked: Bool { cancelled || finished }

    // MARK: - Scanning

    private func scannerLoop() {
        while true {
            cond.lock()
            var next: DirJob?
            while next == nil {
                if isStoppingLocked || (dirStack.isEmpty && scannersBusy == 0) {
                    if !isStoppingLocked && !scanDone {
                        scanDone = true
                        log("Scan complete: \(stats.filesFound) files (\(Self.bytes(stats.bytesFound))), \(stats.filesSkipped) already up to date")
                        checkFinishedLocked()
                    }
                    scannersAlive -= 1
                    cond.broadcast()
                    cond.unlock()
                    return
                }
                if !paused && !networkDown, let dir = dirStack.popLast() {
                    next = dir
                    scannersBusy += 1
                } else {
                    cond.wait()
                }
            }
            cond.unlock()

            processDirectory(next!)

            cond.lock()
            scannersBusy -= 1
            cond.broadcast()
            cond.unlock()
        }
    }

    private struct DestEntry {
        let isDirectory: Bool
        let size: Int64
        let mtime: Double
    }

    private func processDirectory(_ dir: DirJob) {
        let fm = FileManager()
        let srcPath = joinPath(sourceRoot, dir.rel)
        let dstPath = joinPath(destinationRoot, dir.rel)

        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(at: URL(fileURLWithPath: srcPath, isDirectory: true),
                                                 includingPropertiesForKeys: Self.resourceKeys, options: [])
        } catch {
            directoryFailed(dir, code: posixCode(of: error), message: "Couldn't read source folder: \(error.localizedDescription)")
            return
        }

        // Make sure the matching destination folder exists, and index what is already in it.
        var existing: [String: DestEntry] = [:]
        var st = stat()
        if lstat(dstPath, &st) != 0 {
            let code = errno
            guard code == ENOENT else {
                directoryFailed(dir, code: code, message: "Couldn't read destination folder: \(errnoDescription(code))")
                return
            }
            // Never create the destination root itself: if it is missing, the share has gone away.
            guard !dir.rel.isEmpty, mkdir(dstPath, 0o777) == 0 || errno == EEXIST, lstat(dstPath, &st) == 0 else {
                let code = errno
                directoryFailed(dir, code: code, message: "Couldn't create destination folder: \(errnoDescription(code))")
                return
            }
        } else if (st.st_mode & S_IFMT) != S_IFDIR {
            directoryFailed(dir, code: nil, message: "A file with this name already exists in the destination, so the folder can't be created there")
            return
        } else {
            do {
                let destEntries = try fm.contentsOfDirectory(at: URL(fileURLWithPath: dstPath, isDirectory: true),
                                                             includingPropertiesForKeys: Self.resourceKeys, options: [])
                for url in destEntries {
                    guard let values = try? url.resourceValues(forKeys: Self.resourceKeySet) else { continue }
                    existing[url.lastPathComponent] = DestEntry(
                        isDirectory: values.isDirectory == true && values.isSymbolicLink != true,
                        size: Int64(values.fileSize ?? -1),
                        mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0)
                }
            } catch {
                directoryFailed(dir, code: posixCode(of: error), message: "Couldn't read destination folder: \(error.localizedDescription)")
                return
            }
        }
        // If the destination share dropped and left an empty mount-point folder behind, writes would land on the local disk.
        if let device = currentDestinationDevice(), st.st_dev != device {
            directoryFailed(dir, code: ENXIO, message: "The destination share is no longer mounted")
            return
        }

        var jobs: [FileJob] = []
        var subdirs: [DirJob] = []
        var conflicts: [MergeFailure] = []
        var found = 0, foundBytes: Int64 = 0, skipped = 0, skippedBytes: Int64 = 0
        for url in entries {
            let name = url.lastPathComponent
            if options.excludedNames.contains(name) || name.hasSuffix(Self.partialSuffix) { continue }
            guard let values = try? url.resourceValues(forKeys: Self.resourceKeySet) else { continue }
            let rel = dir.rel.isEmpty ? name : dir.rel + "/" + name
            if values.isSymbolicLink == true {
                found += 1
                jobs.append(FileJob(rel: rel, size: 0, mtime: 0, isSymlink: true))
            } else if values.isDirectory == true {
                subdirs.append(DirJob(rel: rel))
            } else if values.isRegularFile == true {
                let size = Int64(values.fileSize ?? 0)
                let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                found += 1
                foundBytes += size
                if let dest = existing[name] {
                    if dest.isDirectory {
                        conflicts.append(MergeFailure(path: rel, message: "A folder with this name already exists in the destination"))
                        continue
                    }
                    if dest.size == size && abs(dest.mtime - mtime) < 2 {
                        skipped += 1
                        skippedBytes += size
                        continue
                    }
                }
                jobs.append(FileJob(rel: rel, size: size, mtime: mtime, isSymlink: false))
            }
        }

        cond.lock()
        stats.foldersScanned += 1
        stats.filesFound += found
        stats.bytesFound += foundBytes
        stats.filesSkipped += skipped
        stats.bytesSkipped += skippedBytes
        stats.filesFailed += conflicts.count
        for conflict in conflicts {
            failures.append(conflict)
            log("FAILED \(conflict.path): \(conflict.message)")
        }
        dirStack.append(contentsOf: subdirs.reversed())
        queue.append(contentsOf: jobs)
        cond.broadcast()
        // Don't let the scan run too far ahead of the copying.
        while queue.count > Self.maxQueuedFiles && !isStoppingLocked {
            scannersWaitingForRoom += 1
            cond.wait()
            scannersWaitingForRoom -= 1
        }
        cond.unlock()
    }

    private func directoryFailed(_ dir: DirJob, code: Int32?, message: String) {
        let networkSuspect = (code.map { Self.networkErrnos.contains($0) } ?? false) || !rootsAvailable()
        cond.lock()
        defer { cond.broadcast(); cond.unlock() }
        var dir = dir
        if networkSuspect && dir.networkRetries < Self.maxNetworkRetries {
            dir.networkRetries += 1
            markNetworkDownLocked()
            dirStack.append(dir)
        } else if dir.attempt + 1 < options.maxAttempts {
            dir.attempt += 1
            log("RETRY folder \(dir.rel.isEmpty ? "(top)" : dir.rel): \(message)")
            dirStack.insert(dir, at: 0)
        } else {
            let label = dir.rel.isEmpty ? "(top folder)" : dir.rel + "/"
            stats.foldersFailed += 1
            failures.append(MergeFailure(path: label, message: message))
            log("FAILED folder \(label): \(message)")
        }
    }

    // MARK: - Copying

    private func workerLoop() {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: options.chunkSize, alignment: 16384)
        defer { buffer.deallocate() }
        while true {
            cond.lock()
            var job: FileJob?
            while job == nil {
                if isStoppingLocked || workerCount > targetWorkers {
                    workerCount -= 1
                    cond.broadcast()
                    cond.unlock()
                    return
                }
                if !paused && !networkDown {
                    job = retryQueue.isEmpty ? queue.popFirst() : retryQueue.removeFirst()
                }
                if job == nil { cond.wait() }
            }
            if scannersWaitingForRoom > 0 && queue.count <= Self.maxQueuedFiles { cond.broadcast() }
            nextCopyID += 1
            let active = ActiveCopy(id: nextCopyID, job: job!, outagesAtStart: networkOutages)
            activeCopies[active.id] = active
            cond.unlock()

            let result = copy(active, buffer: buffer)
            if !completeCopy(active, result) { return }
        }
    }

    /// Records the outcome of a copy. Returns false if the calling worker should exit.
    private func completeCopy(_ active: ActiveCopy, _ result: CopyResult) -> Bool {
        var networkSuspect = false
        if case .failed(let code, _) = result {
            networkSuspect = Self.networkErrnos.contains(code) || !rootsAvailable()
        }
        cond.lock()
        defer { cond.broadcast(); cond.unlock() }
        if networkDown || networkOutages != active.outagesAtStart { networkSuspect = true }
        if active.abandoned {
            // The watchdog already gave up on this copy, requeued it and replaced this thread.
            stuckWorkers -= 1
            return false
        }
        activeCopies[active.id] = nil
        switch result {
        case .copied:
            stats.filesCopied += 1
            stats.bytesDone += active.job.size - active.counted
            log("COPIED \(active.job.rel) (\(Self.bytes(active.job.size)))")
        case .stopped:
            stats.bytesDone -= active.counted
        case .failed(_, let message):
            stats.bytesDone -= active.counted
            handleFailureLocked(active.job, message: message, networkSuspect: networkSuspect)
        }
        checkFinishedLocked()
        return true
    }

    private func handleFailureLocked(_ job: FileJob, message: String, networkSuspect: Bool) {
        var job = job
        if networkSuspect && job.networkRetries < Self.maxNetworkRetries {
            // Don't use up attempts while a share is unreachable; wait for it and try again.
            job.networkRetries += 1
            markNetworkDownLocked()
            retryQueue.append(job)
            return
        }
        job.attempt += 1
        if job.attempt < options.maxAttempts {
            stats.retries += 1
            log("RETRY \(job.rel) (attempt \(job.attempt + 1) of \(options.maxAttempts)): \(message)")
            pendingRetries += 1
            DispatchQueue.global().asyncAfter(deadline: .now() + options.retryDelay * Double(job.attempt)) { [self] in
                cond.lock()
                pendingRetries -= 1
                if !cancelled { retryQueue.append(job) }
                checkFinishedLocked()
                cond.broadcast()
                cond.unlock()
            }
        } else {
            stats.filesFailed += 1
            failures.append(MergeFailure(path: job.rel, message: message))
            log("FAILED \(job.rel): \(message)")
        }
    }

    private func checkFinishedLocked() {
        guard !finished, !cancelled, scanDone, queue.isEmpty, retryQueue.isEmpty,
              pendingRetries == 0, activeCopies.isEmpty else { return }
        finished = true
        endTime = monotonicNow()
        log("Merge finished in \(Int(endTime! - startTime))s: \(stats.filesCopied) copied (\(Self.bytes(stats.bytesTransferred)) sent), "
            + "\(stats.filesSkipped) already up to date, \(stats.filesFailed) files and \(stats.foldersFailed) folders failed")
        if !failures.isEmpty {
            log("Failed items:")
            for failure in failures { log("  \(failure.path): \(failure.message)") }
        }
        cond.broadcast()
        if let onFinish {
            let snap = stats
            DispatchQueue.global().async { onFinish(snap) }
        }
    }

    /// Blocks while paused or waiting for the network. Returns false if the copy should stop.
    private func gate(_ active: ActiveCopy) -> Bool {
        cond.lock()
        defer { cond.unlock() }
        while (paused || networkDown) && !cancelled && !active.abandoned { cond.wait() }
        return !cancelled && !active.abandoned
    }

    private func addProgress(_ active: ActiveCopy, _ count: Int64, transferred: Bool) {
        cond.lock()
        defer { cond.unlock() }
        guard !active.abandoned else { return }
        active.counted += count
        active.lastProgress = monotonicNow()
        stats.bytesDone += count
        if transferred { stats.bytesTransferred += count }
    }

    private func copy(_ active: ActiveCopy, buffer: UnsafeMutableRawPointer) -> CopyResult {
        let job = active.job
        let srcPath = joinPath(sourceRoot, job.rel)
        let dstPath = joinPath(destinationRoot, job.rel)
        if job.isSymlink { return copySymlink(from: srcPath, to: dstPath) }

        let dstDir = (dstPath as NSString).deletingLastPathComponent
        let name = (dstPath as NSString).lastPathComponent
        let partialPath = dstDir + "/" + Self.partialName(for: name, size: job.size, mtime: job.mtime)

        let src = open(srcPath, O_RDONLY | O_CLOEXEC)
        guard src >= 0 else { return failure("Couldn't open source file") }
        defer { close(src) }
        _ = fcntl(src, F_NOCACHE, 1)

        // Resume from an earlier partial copy, re-copying its tail in case that wasn't fully written.
        var offset: Int64 = 0
        var st = stat()
        if stat(partialPath, &st) == 0 && st.st_size > 0 {
            offset = max(0, min(st.st_size, job.size) - options.resumeOverlap)
        }
        let dst = open(partialPath, O_WRONLY | O_CREAT | O_CLOEXEC | (offset == 0 ? O_TRUNC : 0), 0o644)
        guard dst >= 0 else { return failure("Couldn't create file in destination") }
        var dstOpen = true
        defer { if dstOpen { close(dst) } }
        if fstat(dst, &st) == 0, let device = currentDestinationDevice(), st.st_dev != device {
            close(dst)
            dstOpen = false
            unlink(partialPath)
            return .failed(ENXIO, "The destination share is no longer mounted")
        }
        _ = fcntl(dst, F_NOCACHE, 1)
        if offset > 0 {
            log("RESUME \(job.rel) from \(Self.bytes(offset))")
            addProgress(active, offset, transferred: false)
        }

        while offset < job.size {
            options.chunkHook?(job.rel, job.attempt)
            guard gate(active) else { return .stopped }
            let want = Int(min(Int64(options.chunkSize), job.size - offset))
            var got = pread(src, buffer, want, off_t(offset))
            while got < 0 && errno == EINTR { got = pread(src, buffer, want, off_t(offset)) }
            if got < 0 { return failure("Couldn't read source file") }
            if got == 0 { return .failed(EIO, "The source file is shorter than expected (did it change during the copy?)") }
            var written = 0
            while written < got {
                let n = pwrite(dst, buffer + written, got - written, off_t(offset) + off_t(written))
                if n < 0 {
                    if errno == EINTR { continue }
                    return failure("Couldn't write to destination")
                }
                written += n
            }
            offset += Int64(got)
            addProgress(active, Int64(got), transferred: true)
        }

        if ftruncate(dst, off_t(job.size)) != 0 { return failure("Couldn't write to destination") }
        dstOpen = false
        if close(dst) != 0 { return failure("Couldn't finish writing to destination") }
        guard gate(active) else { return .stopped }

        // Move the finished copy into place, replacing any existing file.
        if rename(partialPath, dstPath) != 0 {
            let code = errno
            var existing = stat()
            if lstat(dstPath, &existing) == 0 && (existing.st_mode & S_IFMT) != S_IFDIR {
                unlink(dstPath)
                if rename(partialPath, dstPath) != 0 { return failure("Couldn't replace the existing file") }
            } else {
                return .failed(code, "Couldn't move the copied file into place: \(errnoDescription(code))")
            }
        }

        // Match the original's modification date so the next run can tell the file is up to date.
        let seconds = job.mtime.rounded(.down)
        var times = [
            timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
            timespec(tv_sec: Int(seconds), tv_nsec: Int((job.mtime - seconds) * 1_000_000_000)),
        ]
        if utimensat(AT_FDCWD, dstPath, &times, 0) != 0 {
            log("WARNING couldn't set the modification date on \(job.rel): \(errnoDescription(errno)). It will be copied again on the next run.")
        }
        return .copied
    }

    private func copySymlink(from srcPath: String, to dstPath: String) -> CopyResult {
        var target = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = readlink(srcPath, &target, Int(PATH_MAX))
        guard length >= 0 else { return failure("Couldn't read symbolic link") }
        target[length] = 0
        var st = stat()
        if lstat(dstPath, &st) == 0 {
            guard (st.st_mode & S_IFMT) != S_IFDIR else {
                return .failed(EEXIST, "A folder with this name already exists in the destination")
            }
            unlink(dstPath)
        }
        guard symlink(target, dstPath) == 0 else { return failure("Couldn't create symbolic link") }
        return .copied
    }

    private func failure(_ what: String) -> CopyResult {
        let code = errno
        return .failed(code, "\(what): \(errnoDescription(code))")
    }

    // MARK: - Stall and network monitoring

    private func watchdogLoop() {
        cond.lock()
        defer { cond.unlock() }
        while !isStoppingLocked {
            let deadline = Date().addingTimeInterval(1)
            while !isStoppingLocked && Date() < deadline { cond.wait(until: deadline) }
            if isStoppingLocked { break }
            let now = monotonicNow()
            if !networkDown && now - lastHealthyCheck > options.networkUnhealthyAfter {
                log("The shares stopped responding")
                markNetworkDownLocked()
            }
            guard !paused && !networkDown else { continue }
            for active in Array(activeCopies.values) where now - active.lastProgress > options.stallTimeout {
                abandonLocked(active)
            }
        }
    }

    private func abandonLocked(_ active: ActiveCopy) {
        active.abandoned = true
        activeCopies[active.id] = nil
        stats.bytesDone -= active.counted
        stats.stalls += 1
        workerCount -= 1
        stuckWorkers += 1
        log("STALLED \(active.job.rel): no progress for \(Int(options.stallTimeout))s")
        handleFailureLocked(active.job, message: "The transfer stalled (no progress for \(Int(options.stallTimeout)) seconds)",
                            networkSuspect: false)
        // Keep the requested number of copies running while the stuck thread waits for the OS to give up.
        while workerCount < targetWorkers && stuckWorkers <= Self.maxStuckThreads { spawnWorkerLocked() }
        checkFinishedLocked()
        cond.broadcast()
    }

    private func monitorLoop() {
        while true {
            cond.lock()
            let deadline = Date().addingTimeInterval(options.networkCheckInterval)
            while !isStoppingLocked && Date() < deadline { cond.wait(until: deadline) }
            if isStoppingLocked { cond.unlock(); return }
            cond.unlock()

            let ok = rootsAvailable()

            cond.lock()
            if ok {
                lastHealthyCheck = monotonicNow()
                if networkDown {
                    networkDown = false
                    refreshProgressClocksLocked()
                    log("Both shares are reachable again; continuing")
                    cond.broadcast()
                }
            } else if !networkDown {
                markNetworkDownLocked()
            }
            cond.unlock()
        }
    }

    private func markNetworkDownLocked() {
        guard !networkDown else { return }
        networkDown = true
        networkOutages += 1
        log("A share is unreachable; pausing until it comes back")
    }

    private func refreshProgressClocksLocked() {
        let now = monotonicNow()
        for active in activeCopies.values { active.lastProgress = now }
    }

    private static func rootInfo(_ path: String) -> RootInfo? {
        var fs = statfs()
        var st = stat()
        guard statfs(path, &fs) == 0, stat(path, &st) == 0 else { return nil }
        return RootInfo(path: path, mountPoint: mountPoint(fs), device: st.st_dev)
    }

    private static func mountPoint(_ fs: statfs) -> String {
        var fs = fs
        return withUnsafePointer(to: &fs.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    /// True if both folders are still on the volumes they started on and can be read.
    /// A share that dropped and was reconnected at the same place counts as available again.
    /// Must be called without `cond` held.
    private func rootsAvailable() -> Bool {
        var device: dev_t?
        for root in roots {
            guard let now = Self.rootInfo(root.path), now.mountPoint == root.mountPoint,
                  let handle = opendir(root.path) else { return false }
            closedir(handle)
            if root.path == destinationRoot { device = now.device }
        }
        if let device {
            cond.lock()
            destinationDevice = device
            cond.unlock()
        }
        return true
    }

    private func currentDestinationDevice() -> dev_t? {
        cond.lock()
        defer { cond.unlock() }
        return destinationDevice
    }

    // MARK: - Helpers

    private func log(_ message: String) { logger?.log(message) }

    public static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
