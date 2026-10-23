import SwiftUI
import SpeedMergeCore

@main
enum Main {
    static func main() {
        if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--cli" {
            exit(CommandLineMerge.run(Array(CommandLine.arguments.dropFirst(2))))
        }
        SpeedMergeApp.main()
    }
}

struct SpeedMergeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("SpeedMerge", id: "main") {
            ContentView(model: MergeViewModel.shared)
        }
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = MergeViewModel.shared
        guard model.isBusy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A merge is still running"
        alert.informativeText = "If you quit now, you can resume it the next time you open SpeedMerge. Finished files won't be copied again."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Quit")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        model.prepareToQuit()
        return .terminateNow
    }
}

/// Headless mode: `SpeedMerge --cli <source> <destination> [--parallel N]`
enum CommandLineMerge {
    static func run(_ args: [String]) -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        var paths: [String] = []
        var options = MergeOptions()
        var i = 0
        while i < args.count {
            if args[i] == "--parallel", i + 1 < args.count, let n = Int(args[i + 1]) {
                options.parallelCopies = n
                i += 2
            } else {
                paths.append(args[i])
                i += 1
            }
        }
        guard paths.count == 2 else {
            print("usage: SpeedMerge --cli <source> <destination> [--parallel N]")
            return 2
        }
        let source = URL(fileURLWithPath: paths[0], isDirectory: true)
        let destination = URL(fileURLWithPath: paths[1], isDirectory: true)
        if let problem = MergeEngine.validate(source: source, destination: destination) {
            print(problem)
            return 2
        }
        let logger = MergeLogger.makeDefault()
        if let logger { print("Log: \(logger.url.path)") }
        let engine = MergeEngine(source: source, destination: destination, options: options, logger: logger)
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Merging folders")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        engine.start()

        var lastBytes: Int64 = 0
        var lastTime = Date()
        while !engine.waitUntilDone(timeout: 2) {
            let snap = engine.snapshot()
            let now = Date()
            let speed = Double(snap.bytesTransferred - lastBytes) / now.timeIntervalSince(lastTime)
            lastBytes = snap.bytesTransferred
            lastTime = now
            print(String(format: "%5.1f%%  %@ of %@  %@/s  copied %d  skipped %d  failed %d  [%@]",
                         snap.fraction * 100, MergeEngine.bytes(snap.bytesSkipped + snap.bytesDone),
                         MergeEngine.bytes(snap.bytesFound), MergeEngine.bytes(Int64(speed)),
                         snap.filesCopied, snap.filesSkipped, snap.filesFailed + snap.foldersFailed, snap.state.rawValue))
        }
        let snap = engine.snapshot()
        print("Done in \(Int(snap.elapsed))s: copied \(snap.filesCopied) (\(MergeEngine.bytes(snap.bytesTransferred))), "
              + "skipped \(snap.filesSkipped), failed \(snap.filesFailed + snap.foldersFailed)")
        for failure in engine.failureList() { print("FAILED \(failure.path): \(failure.message)") }
        return snap.filesFailed + snap.foldersFailed == 0 ? 0 : 1
    }
}
