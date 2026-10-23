import Foundation
import Darwin

/// Append-only, timestamped log written straight to disk so it survives a crash.
public final class MergeLogger: @unchecked Sendable {
    public let url: URL
    private let handle: FileHandle
    private let lock = NSLock()
    private let formatter: DateFormatter

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        self.url = url
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    }

    /// A new log file in ~/Library/Logs/SpeedMerge named after the current time.
    public static func makeDefault() -> MergeLogger? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SpeedMerge")
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return try? MergeLogger(url: dir.appendingPathComponent("SpeedMerge-\(stamp.string(from: Date())).log"))
    }

    public func log(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        handle.write(Data(line.utf8))
    }

    deinit { try? handle.close() }
}

/// The last merge that was started, so an interrupted one can be resumed after a relaunch.
public struct SavedJob: Codable, Equatable, Sendable {
    public var source: String
    public var destination: String
    public var parallelCopies: Int
    public var startedAt: Date
    public var finished: Bool
    public var failedCount: Int
    public var logPath: String?

    public init(source: String, destination: String, parallelCopies: Int, startedAt: Date = Date(),
                finished: Bool = false, failedCount: Int = 0, logPath: String? = nil) {
        self.source = source
        self.destination = destination
        self.parallelCopies = parallelCopies
        self.startedAt = startedAt
        self.finished = finished
        self.failedCount = failedCount
        self.logPath = logPath
    }
}

public enum JobStore {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SpeedMerge/last-job.json")
    }

    public static func load() -> SavedJob? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SavedJob.self, from: data)
    }

    public static func save(_ job: SavedJob) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(job) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// FIFO queue with O(1) pops.
struct JobQueue<Element> {
    private var items: [Element] = []
    private var head = 0

    var count: Int { items.count - head }
    var isEmpty: Bool { count == 0 }

    mutating func append(contentsOf newItems: [Element]) { items.append(contentsOf: newItems) }

    mutating func popFirst() -> Element? {
        guard head < items.count else { return nil }
        let item = items[head]
        head += 1
        if head >= 4096 && head * 2 >= items.count {
            items.removeFirst(head)
            head = 0
        }
        return item
    }
}

func monotonicNow() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

func errnoDescription(_ code: Int32) -> String { String(cString: strerror(code)) }

/// The POSIX error code behind a Foundation error, if there is one.
func posixCode(of error: Error) -> Int32? {
    let ns = error as NSError
    if ns.domain == NSPOSIXErrorDomain { return Int32(ns.code) }
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
        return posixCode(of: underlying)
    }
    return nil
}

func joinPath(_ root: String, _ relative: String) -> String {
    relative.isEmpty ? root : root + "/" + relative
}
