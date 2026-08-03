import Foundation

/// Finds an executable ffmpeg without making the detection policy depend on the real
/// filesystem.  Tests supply `isExecutable`; production uses the FileManager adapter.
struct FfmpegLocator {
    static let preferredPaths = [
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
    ]

    func locate() -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"]
        return Self.locate(path: path, currentDirectory: FileManager.default.currentDirectoryPath) {
            FileManager.default.isExecutableFile(atPath: $0)
        }.map { URL(filePath: $0) }
    }

    /// Returns an absolute path so callers can hand it directly to `Process.executableURL`.
    static func locate(
        path: String?,
        currentDirectory: String = "/",
        isExecutable: (String) -> Bool
    ) -> String? {
        let pathCandidates = (path ?? "").split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
            .map { directory in
                let base = directory.isEmpty ? currentDirectory : directory
                return absolutePath(for: base, currentDirectory: currentDirectory) + "/ffmpeg"
            }
        let candidates = Self.preferredPaths + pathCandidates
        var seen = Set<String>()
        for candidate in candidates {
            let absoluteCandidate = absolutePath(for: candidate, currentDirectory: currentDirectory)
            guard seen.insert(absoluteCandidate).inserted else { continue }
            if isExecutable(absoluteCandidate) {
                return absoluteCandidate
            }
        }
        return nil
    }

    private static func absolutePath(for path: String, currentDirectory: String) -> String {
        let resolved = path.hasPrefix("/") ? path : currentDirectory + "/" + path
        return (resolved as NSString).standardizingPath
    }
}

/// Builds unique output paths without touching the filesystem itself.  The requested
/// `fileExists` adapter keeps tests fast and means conversions never overwrite originals.
struct PostProcessOutputNamer {
    func nextAvailableURL(
        sourceURL: URL,
        suffix: String,
        fileExtension: String,
        fileExists: (URL) -> Bool
    ) -> URL {
        let directory = sourceURL.deletingLastPathComponent()
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let extensionSuffix = ".\(fileExtension)"
        let baseName = stem + suffix
        var attempt = 1
        while true {
            let numbering = attempt == 1 ? "" : "-\(attempt)"
            let candidate = directory.appending(path: baseName + numbering + extensionSuffix, directoryHint: .notDirectory)
            if !fileExists(candidate) {
                return candidate
            }
            attempt += 1
        }
    }
}

enum FfmpegCommandBuilder {
    static let gifFilter = "fps=10,scale=640:-1:flags=lanczos"

    static func paletteGeneration(input: URL, palette: URL) -> [String] {
        [
            "-i", input.path(percentEncoded: false),
            "-vf", "\(gifFilter),palettegen",
            "-frames:v", "1",
            "-n", palette.path(percentEncoded: false),
        ]
    }

    static func paletteUse(input: URL, palette: URL, output: URL) -> [String] {
        [
            "-i", input.path(percentEncoded: false),
            "-i", palette.path(percentEncoded: false),
            "-lavfi", "\(gifFilter)[scaled];[scaled][1:v]paletteuse",
            "-n", output.path(percentEncoded: false),
        ]
    }

    static func remux(input: URL, output: URL) -> [String] {
        [
            "-i", input.path(percentEncoded: false),
            "-c", "copy",
            "-n", output.path(percentEncoded: false),
        ]
    }
}
