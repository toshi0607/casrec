import AppKit
import AVFoundation
import Quartz
import SwiftUI

struct LibraryView: View {
    let directory: URL
    let refreshToken: Int
    let allowsDeletion: Bool
    let jobQueue: PostProcessQueue

    @State private var entries: [LibraryEntry] = []
    @State private var entryToDelete: LibraryEntry?
    @State private var errorMessage: String?
    @State private var jobStatuses: [PostProcessJobStatus] = []
    @State private var handledTerminalJobIDs = Set<String>()

    private var ffmpegIsAvailable: Bool {
        FfmpegLocator().locate() != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if !ffmpegIsAvailable {
                NoticeBanner(
                    .info,
                    message: "GIF変換・修復には ffmpeg が必要です。`brew install ffmpeg` でインストールできます。"
                )
                    .padding(.horizontal, Theme.Metric.gutter)
                    .padding(.bottom, 8)
            }

            if entries.isEmpty {
                ContentUnavailableView(
                    "録画はまだありません",
                    systemImage: "film",
                    description: Text("保存先: \(directory.path(percentEncoded: false))")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    LibraryRow(
                        entry: entry,
                        allowsDeletion: allowsDeletion,
                        ffmpegIsAvailable: ffmpegIsAvailable,
                        jobStatus: jobStatuses.first { $0.job.sourceURL == entry.url }
                    ) {
                        QuickLookPreviewer.shared.show(entry.url)
                    } showInFinder: {
                        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                    } delete: {
                        entryToDelete = entry
                    } compress: { preset in
                        enqueue(entry: entry, operation: .compress(preset))
                    } makeGIF: {
                        enqueue(entry: entry, operation: .gif)
                    } recover: {
                        enqueue(entry: entry, operation: .recover)
                    }
                    .onTapGesture(count: 2) {
                        QuickLookPreviewer.shared.show(entry.url)
                    }
                }
                .listStyle(.inset)
            }
        }
        .task(id: "\(directory.path(percentEncoded: false))-\(refreshToken)") {
            await reload()
        }
        .task {
            await observeJobs()
        }
        .toolbar {
            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("一覧を更新")
            .help("一覧を更新")
        }
        .alert("録画をゴミ箱に移動しますか？", isPresented: Binding(
            get: { entryToDelete != nil },
            set: { if !$0 { entryToDelete = nil } }
        )) {
            Button("キャンセル", role: .cancel) {
                entryToDelete = nil
            }
            Button("ゴミ箱に移動", role: .destructive) {
                moveSelectedEntryToTrash()
            }
        } message: {
            Text(entryToDelete?.fileName ?? "")
        }
        .alert("ライブラリのエラー", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "不明なエラーが発生しました")
        }
    }

    private func reload() async {
        entries = await LibraryScanner().scan(directory: directory)
    }

    private func moveSelectedEntryToTrash() {
        guard let entry = entryToDelete else { return }
        entryToDelete = nil
        let sidecar = entry.url.appendingPathExtension(RecordingArtifacts.sidecarExtension)
        let items = [entry.url] + (FileManager.default.fileExists(atPath: sidecar.path(percentEncoded: false)) ? [sidecar] : [])
        NSWorkspace.shared.recycle(items) { _, error in
            Task { @MainActor in
                if let error {
                    errorMessage = "\(entry.fileName) をゴミ箱に移動できませんでした: \(error.localizedDescription)"
                } else {
                    await reload()
                }
            }
        }
    }

    private func enqueue(entry: LibraryEntry, operation: PostProcessOperation) {
        let outputNamer = PostProcessOutputNamer()
        let fileExists: (URL) -> Bool = { url in
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        }
        let output: URL
        switch operation {
        case .compress:
            output = outputNamer.nextAvailableURL(
                sourceURL: entry.url,
                suffix: "-compressed",
                fileExtension: "mp4",
                fileExists: fileExists
            )
        case .gif:
            output = outputNamer.nextAvailableURL(
                sourceURL: entry.url,
                suffix: "",
                fileExtension: "gif",
                fileExists: fileExists
            )
        case .recover:
            output = outputNamer.nextAvailableURL(
                sourceURL: entry.url,
                suffix: "-recovered",
                fileExtension: "mov",
                fileExists: fileExists
            )
        }
        let job = PostProcessJob(sourceURL: entry.url, outputURL: output, operation: operation)
        Task {
            _ = await jobQueue.enqueue(job)
        }
    }

    private func observeJobs() async {
        let stream = await jobQueue.observe()
        for await statuses in stream {
            jobStatuses = statuses
            let terminalStatuses = statuses.filter { status in
                !handledTerminalJobIDs.contains(status.id) && status.isTerminal
            }
            guard !terminalStatuses.isEmpty else { continue }
            handledTerminalJobIDs.formUnion(terminalStatuses.map(\.id))

            if terminalStatuses.contains(where: { status in
                if case .completed = status.state { return true }
                return false
            }) {
                await reload()
            }
            if let failure = terminalStatuses.first(where: { status in
                if case .failed = status.state { return true }
                return false
            }), case .failed(let message) = failure.state {
                errorMessage = "\(failure.job.sourceURL.lastPathComponent): \(message)"
            }
            await jobQueue.removeFinished()
            handledTerminalJobIDs.subtract(terminalStatuses.map(\.id))
        }
    }
}

private struct LibraryRow: View {
    let entry: LibraryEntry
    let allowsDeletion: Bool
    let ffmpegIsAvailable: Bool
    let jobStatus: PostProcessJobStatus?
    let quickLook: () -> Void
    let showInFinder: () -> Void
    let delete: () -> Void
    let compress: (CompressionPreset) -> Void
    let makeGIF: () -> Void
    let recover: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            LibraryThumbnail(entry: entry)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(entry.fileName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if entry.isUnfinalized {
                        Text("未finalize")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.caution.opacity(0.16))
                            .clipShape(Capsule())
                    }
                }
                HStack(spacing: 4) {
                    Text(entry.dateText)
                    Text("・")
                    Text(entry.durationText)
                        .font(.machine(11))
                    Text("・")
                    Text(entry.fileSizeText)
                        .font(.machine(11))
                }
                .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if let jobStatus {
                    JobStatusView(status: jobStatus)
                }
            }

            Spacer(minLength: 12)

            Menu {
                Button("Quick Look", action: quickLook)
                Button("Finderで表示", action: showInFinder)
                if !entry.isGIF {
                    Menu("圧縮") {
                        ForEach(CompressionPreset.allCases, id: \.self) { preset in
                            Button(preset.label) { compress(preset) }
                        }
                    }
                    Button("GIF変換", action: makeGIF)
                        .disabled(!ffmpegIsAvailable)
                        .help("ffmpeg が必要です。brew install ffmpeg")
                }
                if entry.isUnfinalized {
                    Button("修復を試す", action: recover)
                        .disabled(!ffmpegIsAvailable)
                        .help("ffmpeg が必要です。brew install ffmpeg")
                }
                Divider()
                Button("ゴミ箱に移動", role: .destructive, action: delete)
                    .disabled(!allowsDeletion)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
        }
        .padding(.vertical, 6)
    }
}

private struct JobStatusView: View {
    let status: PostProcessJobStatus

    var body: some View {
        switch status.state {
        case .waiting:
            Text("待機中")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .running(let progress):
            HStack(spacing: 5) {
                if let progress {
                    ProgressView(value: progress, total: 100)
                        .frame(width: 70)
                    Text("\(Int(progress.rounded()))%")
                } else {
                    ProgressView()
                    Text("変換中…")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        case .completed, .failed:
            EmptyView()
        }
    }
}

private extension PostProcessJobStatus {
    var isTerminal: Bool {
        switch state {
        case .completed, .failed: true
        case .waiting, .running: false
        }
    }
}

private struct LibraryThumbnail: View {
    let entry: LibraryEntry
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: entry.isGIF ? "photo" : "film")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 112, height: 63)
        .background(Theme.hairline.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.chipRadius, style: .continuous))
        .task(id: entry.url) {
            guard !entry.isGIF else { return }
            image = await ThumbnailGenerator.image(for: entry.url)
        }
    }
}

private enum ThumbnailGenerator {
    static func image(for url: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        guard let result = try? await generator.image(at: .zero) else { return nil }
        return result.image
    }
}

private final class QuickLookPreviewer: NSObject, QLPreviewPanelDataSource, @unchecked Sendable {
    static let shared = QuickLookPreviewer()
    private let lock = NSLock()
    private var item: NSURL?

    @MainActor
    func show(_ url: URL) {
        lock.withLock { item = url as NSURL }
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        lock.withLock { item == nil ? 0 : 1 }
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        lock.withLock { item }
    }
}
