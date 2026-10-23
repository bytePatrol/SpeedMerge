import XCTest
@testable import SpeedMergeCore

final class MergeEngineTests: XCTestCase {
    var root: URL!
    var src: URL!
    var dst: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SpeedMergeTests-\(UUID().uuidString)")
        src = root.appendingPathComponent("Folder-A")
        dst = root.appendingPathComponent("Folder-B")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: helpers

    @discardableResult
    func write(_ base: URL, _ rel: String, _ data: Data, mtime: Date? = nil) throws -> URL {
        let url = base.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        if let mtime { try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path) }
        return url
    }

    func randomData(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return Data(bytes)
    }

    func fastOptions() -> MergeOptions {
        var options = MergeOptions()
        options.chunkSize = 64 * 1024
        options.resumeOverlap = 1024
        options.retryDelay = 0.05
        options.stallTimeout = 1
        options.networkCheckInterval = 0.2
        return options
    }

    func merge(_ options: MergeOptions? = nil) -> (MergeEngine, MergeSnapshot) {
        let engine = MergeEngine(source: src, destination: dst, options: options ?? fastOptions())
        engine.start()
        XCTAssertTrue(engine.waitUntilDone(timeout: 60), "merge did not finish")
        return (engine, engine.snapshot())
    }

    /// Relative path -> (size, mtime, contents hash) for every file under a folder.
    func tree(_ base: URL) -> [String: String] {
        var result: [String: String] = [:]
        for rel in try! FileManager.default.subpathsOfDirectory(atPath: base.path) {
            let url = base.appendingPathComponent(rel)
            let values = try! url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            if values.isRegularFile == true {
                let data = try! Data(contentsOf: url)
                result[rel] = "\(data.count)|\(values.contentModificationDate!.timeIntervalSince1970)|\(data.hashValue)"
            } else {
                result[rel + "/"] = "dir"
            }
        }
        return result
    }

    // MARK: tests

    func testMergesNestedStructureIntoExistingDestination() throws {
        let episode = randomData(300_000)
        try write(src, "Media/Plex/TV/Simpsons/S01/Episode1.mp4", episode)
        try write(src, "Media/Plex/TV/Simpsons/S01/Episode2.mp4", randomData(10))
        try write(src, "Media/Plex/Movies/Empty.txt", Data())
        try FileManager.default.createDirectory(at: src.appendingPathComponent("Media/EmptyFolder"), withIntermediateDirectories: true)
        let existing = try write(dst, "Media/Plex/TV/Futurama/S01/Episode1.mp4", Data("keep me".utf8))

        let (_, snap) = merge()

        XCTAssertEqual(snap.state, .finished)
        XCTAssertEqual(snap.filesCopied, 3)
        XCTAssertEqual(snap.filesFailed, 0)
        XCTAssertEqual(try Data(contentsOf: dst.appendingPathComponent("Media/Plex/TV/Simpsons/S01/Episode1.mp4")), episode)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("Media/Plex/Movies/Empty.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("Media/EmptyFolder").path))
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep me")
        XCTAssertEqual(snap.bytesDone + snap.bytesSkipped, snap.bytesFound)
    }

    func testSourceIsNeverModified() throws {
        try write(src, "a/b/c.bin", randomData(200_000))
        try write(src, "a/d.bin", randomData(5))
        try write(dst, "a/d.bin", randomData(50))
        let before = tree(src)
        _ = merge()
        XCTAssertEqual(tree(src), before)
    }

    func testCopiedFilesKeepModificationDate() throws {
        let date = Date(timeIntervalSince1970: 1_500_000_000.25)
        try write(src, "x/file.bin", randomData(1000), mtime: date)
        _ = merge()
        let values = try dst.appendingPathComponent("x/file.bin").resourceValues(forKeys: [.contentModificationDateKey])
        XCTAssertEqual(values.contentModificationDate!.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
    }

    func testOverwritesFilesThatDiffer() throws {
        let fresh = randomData(4000)
        try write(src, "f.bin", fresh, mtime: Date(timeIntervalSince1970: 1_600_000_000))
        try write(dst, "f.bin", randomData(4000), mtime: Date(timeIntervalSince1970: 1_500_000_000))
        let (_, snap) = merge()
        XCTAssertEqual(snap.filesCopied, 1)
        XCTAssertEqual(try Data(contentsOf: dst.appendingPathComponent("f.bin")), fresh)
    }

    func testSkipsFilesWithSameSizeAndDate() throws {
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try write(src, "same.bin", randomData(4000), mtime: date)
        let marker = randomData(4000)
        try write(dst, "same.bin", marker, mtime: date)
        let (_, snap) = merge()
        XCTAssertEqual(snap.filesSkipped, 1)
        XCTAssertEqual(snap.filesCopied, 0)
        XCTAssertEqual(try Data(contentsOf: dst.appendingPathComponent("same.bin")), marker, "identical file should not be re-copied")
    }

    func testSecondRunSkipsEverything() throws {
        for i in 0..<20 { try write(src, "d\(i % 4)/f\(i).bin", randomData(1000 + i)) }
        _ = merge()
        let (_, snap) = merge()
        XCTAssertEqual(snap.filesSkipped, 20)
        XCTAssertEqual(snap.filesCopied, 0)
        XCTAssertEqual(snap.bytesTransferred, 0)
    }

    func testResumesFromPartialFile() throws {
        let data = randomData(1_000_000)
        let mtime = Date(timeIntervalSince1970: 1_600_000_000)
        try write(src, "big/movie.mkv", data, mtime: mtime)
        // Simulate a crash after 700 KB, with a corrupted last few bytes.
        let partialName = MergeEngine.partialName(for: "movie.mkv", size: Int64(data.count), mtime: mtime.timeIntervalSince1970)
        var partial = data.prefix(700_000)
        partial.replaceSubrange(699_900..<700_000, with: Data(repeating: 0, count: 100))
        try write(dst, "big/" + partialName, Data(partial))

        let (_, snap) = merge()

        XCTAssertEqual(snap.filesCopied, 1)
        XCTAssertEqual(try Data(contentsOf: dst.appendingPathComponent("big/movie.mkv")), data)
        XCTAssertEqual(snap.bytesTransferred, Int64(data.count - 700_000 + 1024), "should only send the remainder plus the overlap")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst.appendingPathComponent("big/" + partialName).path))
    }

    func testPartialFromOlderVersionIsNotReused() throws {
        let data = randomData(100_000)
        try write(src, "f.bin", data, mtime: Date(timeIntervalSince1970: 1_600_000_000))
        let staleName = MergeEngine.partialName(for: "f.bin", size: Int64(data.count), mtime: 1_500_000_000)
        try write(dst, staleName, randomData(80_000))
        let (_, snap) = merge()
        XCTAssertEqual(try Data(contentsOf: dst.appendingPathComponent("f.bin")), data)
        XCTAssertEqual(snap.bytesTransferred, Int64(data.count))
    }

    func testStalledTransferIsRetried() throws {
        let data = randomData(500_000)
        try write(src, "slow.bin", data)
        try write(src, "fast.bin", randomData(1000))
        var options = fastOptions()
        options.chunkHook = { rel, attempt in
            if rel == "slow.bin" && attempt == 0 { Thread.sleep(forTimeInterval: 2.5) }
        }
        let (_, snap) = merge(options)
        XCTAssertEqual(snap.state, .finished)
        XCTAssertEqual(snap.stalls, 1)
        XCTAssertEqual(snap.filesCopied, 2)
        XCTAssertEqual(snap.filesFailed, 0)
        XCTAssertEqual(try Data(contentsOf: dst.appendingPathComponent("slow.bin")), data)
    }

    func testFileThatKeepsFailingIsReportedAndOthersContinue() throws {
        try write(src, "ok.bin", randomData(100))
        try write(src, "locked/bad.bin", randomData(100))
        // A destination folder we can't write into.
        let locked = dst.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let (engine, snap) = merge()

        XCTAssertEqual(snap.state, .finished)
        XCTAssertEqual(snap.filesCopied, 1)
        XCTAssertEqual(snap.filesFailed, 1)
        XCTAssertEqual(snap.retries, 2)
        XCTAssertEqual(engine.failureList().first?.path, "locked/bad.bin")
    }

    func testExcludedAndTemporaryFilesAreNotCopied() throws {
        try write(src, ".DS_Store", randomData(10))
        try write(src, "Show/@eaDir/thumb.jpg", randomData(10))
        try write(src, "Show/.ep.mkv.0123456789abcdef.smpartial", randomData(10))
        try write(src, "Show/ep.mkv", randomData(10))
        let (_, snap) = merge()
        XCTAssertEqual(snap.filesCopied, 1)
        XCTAssertEqual(Set(tree(dst).keys), ["Show/", "Show/ep.mkv"])
    }

    func testCancelLeavesPartialThatNextRunResumes() throws {
        let data = randomData(2_000_000)
        try write(src, "movie.mkv", data)
        var options = fastOptions()
        options.parallelCopies = 1
        options.chunkHook = { _, _ in Thread.sleep(forTimeInterval: 0.01) }
        let engine = MergeEngine(source: src, destination: dst, options: options)
        engine.start()
        while engine.snapshot().bytesDone < 1_000_000 { Thread.sleep(forTimeInterval: 0.01) }
        engine.cancel()
        XCTAssertTrue(engine.waitUntilDone(timeout: 10))
        XCTAssertEqual(engine.snapshot().state, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst.appendingPathComponent("movie.mkv").path),
                       "an unfinished file must never appear under its real name")

        let (_, snap) = merge()
        XCTAssertEqual(try Data(contentsOf: dst.appendingPathComponent("movie.mkv")), data)
        XCTAssertLessThan(snap.bytesTransferred, Int64(data.count), "second run should resume, not restart")
    }

    func testPauseStopsProgressUntilResumed() throws {
        try write(src, "movie.mkv", randomData(2_000_000))
        var options = fastOptions()
        options.parallelCopies = 1
        options.chunkHook = { _, _ in Thread.sleep(forTimeInterval: 0.01) }
        let engine = MergeEngine(source: src, destination: dst, options: options)
        engine.start()
        while engine.snapshot().bytesDone == 0 { Thread.sleep(forTimeInterval: 0.01) }
        engine.pause()
        Thread.sleep(forTimeInterval: 0.1)
        let pausedAt = engine.snapshot().bytesDone
        Thread.sleep(forTimeInterval: 1.5) // longer than the stall timeout: a pause must not count as a stall
        XCTAssertEqual(engine.snapshot().state, .paused)
        XCTAssertEqual(engine.snapshot().bytesDone, pausedAt)
        engine.resume()
        XCTAssertTrue(engine.waitUntilDone(timeout: 30))
        XCTAssertEqual(engine.snapshot().stalls, 0)
        XCTAssertEqual(engine.snapshot().filesCopied, 1)
    }

    func testManyFilesInParallel() throws {
        var expected: [String: Data] = [:]
        for i in 0..<400 {
            let rel = "Season\(i % 10)/Sub\(i % 3)/file\(i).bin"
            let data = randomData(Int.random(in: 0...50_000))
            expected[rel] = data
            try write(src, rel, data)
        }
        var options = fastOptions()
        options.parallelCopies = 16
        let (_, snap) = merge(options)
        XCTAssertEqual(snap.filesCopied, 400)
        for (rel, data) in expected {
            XCTAssertEqual(try Data(contentsOf: dst.appendingPathComponent(rel)), data, rel)
        }
    }

    func testValidationRejectsNestedOrSameFolders() {
        XCTAssertNotNil(MergeEngine.validate(source: src, destination: src))
        XCTAssertNotNil(MergeEngine.validate(source: src, destination: src.appendingPathComponent("inner")))
        XCTAssertNil(MergeEngine.validate(source: src, destination: dst))
        XCTAssertNotNil(MergeEngine.validate(source: root.appendingPathComponent("missing"), destination: dst))
    }
}
