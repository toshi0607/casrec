import Foundation
import Testing
@testable import CasRec

@Suite("Output directory resolver")
struct OutputDirectoryPreferencesTests {
    @Test("Resolver keeps a usable configured directory")
    func resolverUsesUsableConfiguredDirectory() {
        let fallback = URL(filePath: "/fallback", directoryHint: .isDirectory)
        let configured = URL(filePath: "/recordings", directoryHint: .isDirectory)

        let resolution = OutputDirectoryResolver(fallbackDirectory: fallback).resolve(
            configuredDirectory: configured,
            isUsable: { $0 == configured }
        )

        #expect(resolution == OutputDirectoryResolution(directory: configured, didFallback: false))
    }

    @Test("Resolver falls back when configured directory is missing")
    func resolverFallsBackForMissingDirectory() {
        let fallback = URL(filePath: "/fallback", directoryHint: .isDirectory)
        let configured = URL(filePath: "/missing", directoryHint: .isDirectory)

        let resolution = OutputDirectoryResolver(fallbackDirectory: fallback).resolve(
            configuredDirectory: configured,
            isUsable: { _ in false }
        )

        #expect(resolution == OutputDirectoryResolution(directory: fallback, didFallback: true))
    }

    @Test("Resolver falls back when configured directory is not writable")
    func resolverFallsBackForUnwritableDirectory() {
        let fallback = URL(filePath: "/fallback", directoryHint: .isDirectory)
        let configured = URL(filePath: "/read-only", directoryHint: .isDirectory)

        let resolution = OutputDirectoryResolver(fallbackDirectory: fallback).resolve(
            configuredDirectory: configured,
            isUsable: { _ in false }
        )

        #expect(resolution == OutputDirectoryResolution(directory: fallback, didFallback: true))
    }

    @Test("Filesystem validation accepts writable directories and rejects missing ones")
    func filesystemValidationChecksDirectoryExistenceAndWriteProbe() throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let preferences = OutputDirectoryPreferences(fallbackDirectory: directory.url)
        let missing = directory.url.appending(path: "missing", directoryHint: .isDirectory)

        #expect(preferences.isUsable(directory.url))
        #expect(!preferences.isUsable(missing))
    }

    @Test("Filesystem validation rejects a directory without write permission")
    func filesystemValidationRejectsUnwritableDirectory() throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let protectedDirectory = directory.url.appending(path: "read-only", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: protectedDirectory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: protectedDirectory.path(percentEncoded: false)
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: protectedDirectory.path(percentEncoded: false)
            )
        }

        let preferences = OutputDirectoryPreferences(fallbackDirectory: directory.url)

        #expect(!preferences.isUsable(protectedDirectory))
    }
}
