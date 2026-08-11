import AVFoundation
import Foundation
import ImageIO

/// A display-ready recording or conversion output found directly in the configured
/// directory.  Sidecars are intentionally not entries; they only annotate their media.
struct LibraryEntry: Identifiable, Equatable {
    let url: URL
    let createdAt: Date
    let duration: TimeInterval?
    let fileSize: Int64
    let isUnfinalized: Bool

    var id: URL { url }
    var fileName: String { url.lastPathComponent }
    var fileExtension: String { url.pathExtension.lowercased() }
    var isGIF: Bool { fileExtension == "gif" }

    var dateText: String {
        createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    var durationText: String {
        guard let duration, duration.isFinite, duration >= 0 else { return "—" }
        let seconds = Int(duration.rounded(.down))
        if seconds >= 3_600 {
            return String(format: "%d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var fileSizeText: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}

/// Filesystem-backed listing service.  Media duration is loaded asynchronously so a slow or
/// malformed movie cannot block SwiftUI's main actor while the directory is being refreshed.
struct LibraryScanner {
    private static let supportedExtensions: Set<String> = ["mov", "mp4", "gif"]

    typealias DurationLoader = @Sendable (URL) async -> TimeInterval?

    struct Limits: Sendable {
        let maximumConcurrentMetadataLoads: Int
        let maximumGIFFrames: Int

        init(maximumConcurrentMetadataLoads: Int = 4, maximumGIFFrames: Int = 10_000) {
            self.maximumConcurrentMetadataLoads = max(1, maximumConcurrentMetadataLoads)
            self.maximumGIFFrames = max(0, maximumGIFFrames)
        }
    }

    let fileManager: FileManager
    let limits: Limits
    let durationLoader: DurationLoader

    init(
        fileManager: FileManager = .default,
        limits: Limits = .init(),
        durationLoader: DurationLoader? = nil
    ) {
        self.fileManager = fileManager
        self.limits = limits
        self.durationLoader = durationLoader ?? { url in
            await Self.duration(of: url, maximumGIFFrames: limits.maximumGIFFrames)
        }
    }

    func scan(directory: URL) async -> [LibraryEntry] {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .contentModificationDateKey,
            .fileSizeKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let maximumConcurrentLoads = limits.maximumConcurrentMetadataLoads
        let durationLoader = durationLoader
        return await withTaskGroup(of: LibraryEntry?.self, returning: [LibraryEntry].self) { group in
            var entries: [LibraryEntry] = []
            var inFlightLoads = 0

            while let url = enumerator.nextObject() as? URL {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                guard let values = try? url.resourceValues(forKeys: keys) else { continue }
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                    continue
                }
                guard Self.supportedExtensions.contains(url.pathExtension.lowercased()),
                      values.isRegularFile == true else {
                    continue
                }
                if inFlightLoads == maximumConcurrentLoads, let entry = await group.next() {
                    inFlightLoads -= 1
                    if let entry {
                        entries.append(entry)
                    }
                }

                let date = values.contentModificationDate ?? .distantPast
                let size = Int64(values.fileSize ?? 0)
                let sidecar = url.appendingPathExtension(RecordingArtifacts.sidecarExtension)
                let isUnfinalized = fileManager.fileExists(atPath: sidecar.path(percentEncoded: false))
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    return LibraryEntry(
                        url: url,
                        createdAt: date,
                        duration: await durationLoader(url),
                        fileSize: size,
                        isUnfinalized: isUnfinalized
                    )
                }
                inFlightLoads += 1
            }

            if Task.isCancelled {
                group.cancelAll()
            }
            while inFlightLoads > 0, let entry = await group.next() {
                inFlightLoads -= 1
                if let entry, !Task.isCancelled {
                    entries.append(entry)
                }
            }
            guard !Task.isCancelled else { return [] }
            return entries.sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.fileName.localizedStandardCompare(rhs.fileName) == .orderedAscending
            }
        }
    }

    private static func duration(of url: URL, maximumGIFFrames: Int) async -> TimeInterval? {
        if url.pathExtension.lowercased() == "gif" {
            return gifDuration(of: url, maximumGIFFrames: maximumGIFFrames)
        }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.isNumeric else { return nil }
        return duration.seconds
    }

    private static func gifDuration(of url: URL, maximumGIFFrames: Int) -> TimeInterval? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount <= maximumGIFFrames else { return nil }
        let duration = (0..<frameCount).reduce(0.0) { total, index in
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
                return total
            }
            let delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
                ?? (gif[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
                ?? 0
            return total + delay
        }
        return duration > 0 ? duration : nil
    }
}
