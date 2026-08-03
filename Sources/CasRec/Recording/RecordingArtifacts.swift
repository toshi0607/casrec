import Foundation
import OSLog

/// The on-disk pair a recording owns: the `.mov` being written and the `.recording`
/// sidecar that marks it as not-yet-finalized (DESIGN.md §5.5).
///
/// The sidecar is created before the first byte is written and deleted only when
/// `finishWriting` succeeds. Anything left behind — because the app crashed, was
/// force-quit, or lost power — is therefore a `.mov` with a surviving sidecar, which the
/// library layer reports as "未finalize" and offers to repair.
struct RecordingArtifacts: Sendable, Equatable {
    /// The `.mov` the `AVAssetWriter` writes to.
    let outputURL: URL
    /// `<output file name>.recording` — present only while the recording is unfinalized.
    let sidecarURL: URL

    static let sidecarExtension = "recording"

    private static let log = Logger(subsystem: "dev.toshi0607.casrec", category: "artifacts")

    /// Creates `directory` if needed, picks a collision-free file name, and writes the
    /// sidecar. Throws if the destination is not writable — the caller turns that into
    /// `RecordingState.failed`.
    static func create(displayName: String, in directory: URL, at date: Date) throws -> RecordingArtifacts {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let base = "\(sanitize(displayName))-\(timestamp(for: date))"
        let outputURL = availableOutputURL(base: base, in: directory)
        let sidecarURL = outputURL.appendingPathExtension(sidecarExtension)

        // Written before any media data so a crash at any later point leaves the marker behind.
        try Data().write(to: sidecarURL, options: .atomic)

        log.info("prepared recording artifacts at \(outputURL.lastPathComponent, privacy: .public)")
        return RecordingArtifacts(outputURL: outputURL, sidecarURL: sidecarURL)
    }

    /// Called only after `finishWriting` reports success — the `.mov` is now self-contained.
    func removeSidecar() {
        do {
            try FileManager.default.removeItem(at: sidecarURL)
        } catch CocoaError.fileNoSuchFile {
            // Already gone; the recording is finalized either way.
        } catch {
            Self.log.error("failed to remove sidecar: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes the `.mov` and its sidecar when nothing was ever recorded, so a failed
    /// start does not leave a zero-byte file that the library would flag for repair.
    func discardIfEmpty() {
        guard Self.fileSize(of: outputURL) == 0 else { return }
        try? FileManager.default.removeItem(at: outputURL)
        removeSidecar()
    }

    /// Current size of the output file, or 0 when it does not exist yet.
    var bytesWritten: Int64 { Self.fileSize(of: outputURL) }

    private static func fileSize(of url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - Naming (DESIGN.md §7)

    /// The recording's human-readable subject: the owning app for a window, the display
    /// name otherwise. Read synchronously so the non-`Sendable` `CaptureSource` never has
    /// to outlive the call.
    static func displayName(for source: CaptureSource) -> String {
        if let appName = source.appName, !appName.trimmingCharacters(in: .whitespaces).isEmpty {
            return appName
        }
        return source.title
    }

    /// Strips characters that are illegal or awkward in a file name (`/`, `:`, control
    /// characters) and bounds the length, per §7.
    static func sanitize(_ raw: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
            .union(.controlCharacters)
            .union(.newlines)
        let collapsed = raw
            .components(separatedBy: illegal)
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        // A leading dot would make the recording invisible in Finder.
        let visible = collapsed.hasPrefix(".") ? String(collapsed.dropFirst()) : collapsed
        let bounded = String(visible.prefix(60)).trimmingCharacters(in: .whitespaces)
        return bounded.isEmpty ? "Recording" : bounded
    }

    private static func timestamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// `AVAssetWriter` refuses to write to an existing file, and silently overwriting one
    /// would destroy a recording that cannot be retaken — so suffix until the name is free.
    private static func availableOutputURL(base: String, in directory: URL) -> URL {
        for suffix in 1...999 {
            let name = suffix == 1 ? "\(base).mov" : "\(base)-\(suffix).mov"
            let candidate = directory.appending(path: name, directoryHint: .notDirectory)
            if isNameAvailable(candidate) { return candidate }
        }
        return directory.appending(path: "\(base)-\(UUID().uuidString).mov", directoryHint: .notDirectory)
    }

    /// A name is taken if either the movie or its sidecar is present. Checking the sidecar
    /// matters because `AVAssetWriter` does not create the `.mov` until the first sample
    /// arrives, so for the first moments of a recording the sidecar is the only evidence
    /// that the name is spoken for.
    private static func isNameAvailable(_ outputURL: URL) -> Bool {
        let manager = FileManager.default
        let sidecar = outputURL.appendingPathExtension(sidecarExtension)
        return !manager.fileExists(atPath: outputURL.path(percentEncoded: false))
            && !manager.fileExists(atPath: sidecar.path(percentEncoded: false))
    }
}
