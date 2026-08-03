import Foundation
import Testing
@testable import CasRec

/// The rules that decide what survives on disk (DESIGN.md §5.5). Getting these wrong is
/// either a library full of zero-byte files flagged for repair, or a deleted recording.
@Suite("Recording artifacts")
struct RecordingArtifactsTests {

    @Test("A recording that never produced a file leaves nothing behind")
    func discardsWhenMovieWasNeverCreated() throws {
        let directory = TempDirectory()
        defer { directory.remove() }

        let artifacts = try RecordingArtifacts.create(displayName: "Safari", in: directory.url, at: Date())
        // AVAssetWriter does not create the .mov until the first sample, so this is the
        // state a session that failed before any media arrives actually leaves behind.
        #expect(directory.contents().count == 1, "only the sidecar should exist yet")

        artifacts.discardIfEmpty()

        #expect(directory.contents().isEmpty, "the orphan sidecar must not survive")
    }

    @Test("A zero-byte movie is removed together with its sidecar")
    func discardsEmptyMovie() throws {
        let directory = TempDirectory()
        defer { directory.remove() }

        let artifacts = try RecordingArtifacts.create(displayName: "Safari", in: directory.url, at: Date())
        try Data().write(to: artifacts.outputURL)
        #expect(directory.contents().count == 2)

        artifacts.discardIfEmpty()

        #expect(directory.contents().isEmpty)
    }

    @Test("A movie with bytes in it is kept, sidecar included, for the repair flow")
    func keepsPartialMovie() throws {
        let directory = TempDirectory()
        defer { directory.remove() }

        let artifacts = try RecordingArtifacts.create(displayName: "Safari", in: directory.url, at: Date())
        try Data(repeating: 0xAB, count: 2048).write(to: artifacts.outputURL)

        artifacts.discardIfEmpty()

        #expect(directory.contents().count == 2, "a written fragment is what the repair flow needs")
        #expect(FileManager.default.fileExists(atPath: artifacts.outputURL.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: artifacts.sidecarURL.path(percentEncoded: false)))
    }

    @Test("Finalizing clears the sidecar and keeps the recording")
    func removeSidecarKeepsMovie() throws {
        let directory = TempDirectory()
        defer { directory.remove() }

        let artifacts = try RecordingArtifacts.create(displayName: "Safari", in: directory.url, at: Date())
        try Data(repeating: 0xAB, count: 2048).write(to: artifacts.outputURL)

        artifacts.removeSidecar()

        #expect(FileManager.default.fileExists(atPath: artifacts.outputURL.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: artifacts.sidecarURL.path(percentEncoded: false)))
    }

    @Test("A second recording of the same subject in the same second does not overwrite the first")
    func avoidsNameCollisions() throws {
        let directory = TempDirectory()
        defer { directory.remove() }

        let date = Date()
        let first = try RecordingArtifacts.create(displayName: "Safari", in: directory.url, at: date)
        let second = try RecordingArtifacts.create(displayName: "Safari", in: directory.url, at: date)

        #expect(first.outputURL != second.outputURL, "a recording that cannot be retaken must not be clobbered")
    }
}
