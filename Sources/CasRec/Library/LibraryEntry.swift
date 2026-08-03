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

    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func scan(directory: URL) async -> [LibraryEntry] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .contentModificationDateKey,
            .fileSizeKey,
        ]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let candidates = urls.compactMap { url -> (URL, Date, Int64, Bool)? in
            guard Self.supportedExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else {
                return nil
            }
            let date = values.contentModificationDate ?? .distantPast
            let size = Int64(values.fileSize ?? 0)
            let sidecar = url.appendingPathExtension(RecordingArtifacts.sidecarExtension)
            return (url, date, size, fileManager.fileExists(atPath: sidecar.path(percentEncoded: false)))
        }
        let sorted = candidates.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.lastPathComponent.localizedStandardCompare(rhs.0.lastPathComponent) == .orderedAscending
        }

        return await withTaskGroup(of: LibraryEntry.self, returning: [LibraryEntry].self) { group in
            for candidate in sorted {
                group.addTask {
                    LibraryEntry(
                        url: candidate.0,
                        createdAt: candidate.1,
                        duration: await Self.duration(of: candidate.0),
                        fileSize: candidate.2,
                        isUnfinalized: candidate.3
                    )
                }
            }
            var entries: [LibraryEntry] = []
            for await entry in group {
                entries.append(entry)
            }
            return entries.sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.fileName.localizedStandardCompare(rhs.fileName) == .orderedAscending
            }
        }
    }

    private static func duration(of url: URL) async -> TimeInterval? {
        if url.pathExtension.lowercased() == "gif" {
            return gifDuration(of: url)
        }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.isNumeric else { return nil }
        return duration.seconds
    }

    private static func gifDuration(of url: URL) -> TimeInterval? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let duration = (0..<CGImageSourceGetCount(source)).reduce(0.0) { total, index in
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
