import SwiftUI
import SpeedMergeCore

struct ContentView: View {
    @ObservedObject var model: MergeViewModel
    @State private var showingFailures = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let job = model.resumableJob, !model.isBusy {
                ResumeBanner(job: job, resume: model.resumeSavedJob, dismiss: model.dismissSavedJob)
            }

            HStack(spacing: 12) {
                FolderDropZone(title: "Copy from", caption: "Source · only read, never changed",
                               symbol: "externaldrive", url: $model.source, enabled: !model.isBusy)
                Image(systemName: "arrow.right")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
                FolderDropZone(title: "Merge into", caption: "Destination · new and changed files are copied in",
                               symbol: "externaldrive.badge.plus", url: $model.destination, enabled: !model.isBusy)
            }

            controls

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }

            if let snap = model.snapshot {
                ProgressPanel(snap: snap, speed: model.speed)
                if !snap.active.isEmpty {
                    ActiveList(files: snap.active)
                }
                footer(snap)
            } else {
                Text("Drag a folder from Finder onto each box (or click Choose…), then press Start Merge. "
                     + "Files already in the destination with the same size and date are skipped; others are replaced.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 700)
        .sheet(isPresented: $showingFailures) {
            FailureList(failures: model.failures) { showingFailures = false }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Stepper(value: $model.parallelCopies, in: 1...32) {
                Text("Parallel copies: **\(model.parallelCopies)**")
            }
            .help("How many files are copied at the same time. Can be changed while a merge is running.")
            .fixedSize()

            Spacer()

            if model.isBusy {
                Button(model.state == .paused ? "Resume" : "Pause", action: model.togglePause)
                    .disabled(model.state == .stopping)
                Button("Cancel", role: .destructive, action: model.cancel)
                    .disabled(model.state == .stopping)
            } else {
                Button(action: model.start) {
                    Label("Start Merge", systemImage: "arrow.triangle.merge")
                        .padding(.horizontal, 6)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(!model.canStart)
            }
        }
    }

    private func footer(_ snap: MergeSnapshot) -> some View {
        HStack {
            if !model.failures.isEmpty {
                Button("Show \(model.failures.count) failed item\(model.failures.count == 1 ? "" : "s")…") {
                    showingFailures = true
                }
            }
            Spacer()
            if model.logURL != nil {
                Button("Show Log in Finder", action: model.revealLog)
            }
        }
    }
}

// MARK: - Folder boxes

struct FolderDropZone: View {
    let title: String
    let caption: String
    let symbol: String
    @Binding var url: URL?
    let enabled: Bool
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: url == nil ? symbol : "folder.fill")
                .font(.system(size: 30))
                .foregroundStyle(Color.accentColor)
                .frame(height: 36)
            Text(title).font(.headline)
            if let url {
                Text(url.lastPathComponent)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
            } else {
                Text("Drag a folder here")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            Button("Choose…", action: choose)
                .disabled(!enabled)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 190, maxHeight: 200)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(targeted ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: url == nil ? [6, 4] : []))
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard enabled, let dropped = urls.first, Self.isFolder(dropped) else { return false }
            url = dropped
            return true
        } isTargeted: { targeted = $0 && enabled }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder to \(title.lowercased())"
        if let url { panel.directoryURL = url }
        if panel.runModal() == .OK, let chosen = panel.url { url = chosen }
    }

    static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

// MARK: - Progress

struct ProgressPanel: View {
    let snap: MergeSnapshot
    let speed: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                statusLabel
                Spacer()
                Text(Format.percent(snap.fraction))
                    .font(.title2.monospacedDigit().weight(.semibold))
            }
            ProgressView(value: snap.fraction)
                .progressViewStyle(.linear)
                .tint(snap.state == .waitingForNetwork ? .orange : nil)
            HStack {
                Text("\(Format.bytes(snap.bytesSkipped + snap.bytesDone)) of \(Format.bytes(snap.bytesFound))\(snap.scanComplete ? "" : "+")")
                Spacer()
                Text(rateAndTime)
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)

            Divider()

            HStack(spacing: 24) {
                Stat(label: "Copied", value: snap.filesCopied.formatted())
                Stat(label: "Already up to date", value: snap.filesSkipped.formatted())
                Stat(label: "Found", value: snap.filesFound.formatted() + (snap.scanComplete ? "" : "…"))
                Stat(label: "Retries", value: snap.retries.formatted())
                Stat(label: "Failed", value: (snap.filesFailed + snap.foldersFailed).formatted(),
                     highlight: snap.filesFailed + snap.foldersFailed > 0)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    @ViewBuilder private var statusLabel: some View {
        switch snap.state {
        case .running:
            Label(snap.scanComplete ? "Copying" : "Scanning and copying", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)
        case .paused:
            Label("Paused", systemImage: "pause.circle.fill").font(.headline).foregroundStyle(.orange)
        case .waitingForNetwork:
            Label("A share is unreachable. Waiting for it to come back…", systemImage: "wifi.exclamationmark")
                .font(.headline).foregroundStyle(.orange)
        case .stopping:
            Label("Stopping…", systemImage: "stop.circle").font(.headline)
        case .cancelled:
            Label("Cancelled. Start again to pick up where it left off.", systemImage: "stop.circle.fill")
                .font(.headline).foregroundStyle(.secondary)
        case .finished:
            let failed = snap.filesFailed + snap.foldersFailed
            Label(failed == 0 ? "Merge complete in \(Format.duration(snap.elapsed))"
                              : "Finished in \(Format.duration(snap.elapsed)) with \(failed) failed item\(failed == 1 ? "" : "s")",
                  systemImage: failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(failed == 0 ? .green : .orange)
        }
    }

    private var rateAndTime: String {
        switch snap.state {
        case .running:
            guard speed > 0 else { return "Measuring speed…" }
            let eta = Double(snap.bytesRemaining) / speed
            return "\(Format.bytes(Int64(speed)))/s · " + (snap.scanComplete ? "about \(Format.duration(eta)) left" : "still scanning")
        case .finished, .cancelled:
            return "\(Format.bytes(snap.bytesTransferred)) sent in \(Format.duration(snap.elapsed))"
        default:
            return ""
        }
    }
}

struct Stat: View {
    let label: String
    let value: String
    var highlight = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.monospacedDigit().weight(.medium))
                .foregroundStyle(highlight ? .red : .primary)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ActiveList: View {
    let files: [ActiveFileInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("In progress").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(files) { file in
                        HStack(spacing: 10) {
                            Text(file.path)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.head)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if file.attempt > 1 {
                                Text("retry \(file.attempt - 1)").font(.caption2).foregroundStyle(.orange)
                            }
                            ProgressView(value: file.size > 0 ? min(1, Double(file.done) / Double(file.size)) : 0)
                                .frame(width: 120)
                            Text(Format.bytes(file.size))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .trailing)
                        }
                    }
                }
            }
            .frame(height: CGFloat(min(files.count, 8)) * 22)
        }
    }
}

struct ResumeBanner: View {
    let job: SavedJob
    let resume: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.finished ? "The last merge finished with \(job.failedCount) failed item\(job.failedCount == 1 ? "" : "s")"
                                  : "The last merge didn't finish")
                    .font(.headline)
                Text("\((job.source as NSString).lastPathComponent) → \((job.destination as NSString).lastPathComponent) · "
                     + "started \(job.startedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Dismiss", action: dismiss)
            Button(job.finished ? "Retry" : "Resume", action: resume)
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
    }
}

struct FailureList: View {
    let failures: [MergeFailure]
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Items that couldn't be copied").font(.headline)
            Text("Run the merge again to retry them. Everything that was copied successfully will be skipped.")
                .font(.callout)
                .foregroundStyle(.secondary)
            List(failures) { failure in
                VStack(alignment: .leading, spacing: 2) {
                    Text(failure.path).font(.callout).textSelection(.enabled)
                    Text(failure.message).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 260)
            HStack {
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
    }
}

enum Format {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(1)))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "–" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.day, .hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(1, seconds)) ?? "–"
    }
}
