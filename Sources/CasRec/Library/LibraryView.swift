import AppKit
import AVFoundation
import Quartz
import SwiftUI

struct LibraryView: View {
    let directory: URL
    let refreshToken: Int
    let allowsDeletion: Bool

    @State private var entries: [LibraryEntry] = []
    @State private var entryToDelete: LibraryEntry?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ライブラリ")
                    .font(.title2)
                Spacer()
                Button {
                    Task { await reload() }
                } label: {
                    Label("更新", systemImage: "arrow.clockwise")
                }
            }
            .padding()

            if entries.isEmpty {
                ContentUnavailableView(
                    "録画はまだありません",
                    systemImage: "film",
                    description: Text("保存先: \(directory.path(percentEncoded: false))")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    LibraryRow(entry: entry, allowsDeletion: allowsDeletion) {
                        QuickLookPreviewer.shared.show(entry.url)
                    } showInFinder: {
                        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                    } delete: {
                        entryToDelete = entry
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
}

private struct LibraryRow: View {
    let entry: LibraryEntry
    let allowsDeletion: Bool
    let quickLook: () -> Void
    let showInFinder: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            LibraryThumbnail(entry: entry)
                .frame(width: 100, height: 56)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(entry.fileName)
                        .lineLimit(1)
                    if entry.isUnfinalized {
                        Text("未finalize")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.16))
                            .clipShape(Capsule())
                    }
                }
                Text("\(entry.dateText)  ・  \(entry.durationText)  ・  \(entry.fileSizeText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Menu {
                Button("Quick Look", action: quickLook)
                Button("Finderで表示", action: showInFinder)
                Divider()
                Button("ゴミ箱に移動", role: .destructive, action: delete)
                    .disabled(!allowsDeletion)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
        }
        .padding(.vertical, 4)
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
                    .scaledToFill()
            } else {
                Image(systemName: entry.isGIF ? "photo" : "film")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 5))
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
