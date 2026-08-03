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
}
