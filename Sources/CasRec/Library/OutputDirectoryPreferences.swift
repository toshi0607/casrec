import Foundation

/// The outcome of resolving the directory a recording should use.  The resolver is a
/// value type so its policy can be tested without touching the user's Movies directory.
struct OutputDirectoryResolution: Equatable {
    let directory: URL
    let didFallback: Bool
}

/// Chooses a configured directory only when the supplied validation says it is usable.
/// Filesystem access deliberately lives outside this type; the policy itself is pure.
struct OutputDirectoryResolver {
    let fallbackDirectory: URL

    func resolve(
        configuredDirectory: URL?,
        isUsable: (URL) -> Bool
    ) -> OutputDirectoryResolution {
        guard let configuredDirectory else {
            return OutputDirectoryResolution(directory: fallbackDirectory, didFallback: false)
        }
        guard isUsable(configuredDirectory) else {
            return OutputDirectoryResolution(directory: fallbackDirectory, didFallback: true)
        }
        return OutputDirectoryResolution(directory: configuredDirectory, didFallback: false)
    }
}

/// Persists the user's chosen directory and supplies the checked value used by the UI.
/// The default directory is created on demand; a user-selected directory is never created
/// implicitly, since a missing external volume must be surfaced rather than recreated.
struct OutputDirectoryPreferences {
    static let userDefaultsKey = "outputDirectoryPath"

    let defaults: UserDefaults
    let fileManager: FileManager
    let fallbackDirectory: URL

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        fallbackDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Movies/CasRec", directoryHint: .isDirectory)
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.fallbackDirectory = fallbackDirectory
    }

    func load() -> OutputDirectoryResolution {
        let configured = defaults.string(forKey: Self.userDefaultsKey).map {
            URL(filePath: $0, directoryHint: .isDirectory)
        }
        let resolver = OutputDirectoryResolver(fallbackDirectory: fallbackDirectory)
        let resolution = resolver.resolve(configuredDirectory: configured, isUsable: isUsable)
        if resolution.didFallback || configured == nil {
            ensureFallbackDirectory()
        }
        if resolution.didFallback {
            defaults.set(fallbackDirectory.path(percentEncoded: false), forKey: Self.userDefaultsKey)
        }
        return resolution
    }

    /// Saves only a directory that is usable now.  The caller shows the supplied error to
    /// explain a rejected selection instead of silently accepting a broken destination.
    func save(directory: URL) -> Bool {
        guard isUsable(directory) else { return false }
        defaults.set(directory.path(percentEncoded: false), forKey: Self.userDefaultsKey)
        return true
    }

    private func ensureFallbackDirectory() {
        do {
            try fileManager.createDirectory(at: fallbackDirectory, withIntermediateDirectories: true)
        } catch {
            // `load()` still returns the fallback so recording start can perform its own
            // validation and present an actionable error rather than writing elsewhere.
        }
    }

    func isUsable(_ directory: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: directory.path(percentEncoded: false),
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return false
        }
        guard fileManager.isWritableFile(atPath: directory.path(percentEncoded: false)) else {
            return false
        }
        let probe = directory.appending(path: ".casrec-write-check-\(UUID().uuidString)", directoryHint: .notDirectory)
        guard fileManager.createFile(atPath: probe.path(percentEncoded: false), contents: Data()) else {
            return false
        }
        do {
            try fileManager.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }
}
