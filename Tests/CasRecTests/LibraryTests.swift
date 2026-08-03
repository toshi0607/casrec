import Foundation
import Testing
@testable import CasRec

@Suite("Library and output directories")
struct LibraryTests {
    @Test("Library scan sorts supported media newest first and ignores other files")
    func scanSortsAndFiltersFiles() async throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let older = directory.url.appending(path: "older.mov", directoryHint: .notDirectory)
        let newer = directory.url.appending(path: "newer.mp4", directoryHint: .notDirectory)
        let image = directory.url.appending(path: "ignored.png", directoryHint: .notDirectory)
        try Data([0]).write(to: older)
        try Data([0, 1]).write(to: newer)
        try Data([0]).write(to: image)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceReferenceDate: 10)],
            ofItemAtPath: older.path(percentEncoded: false)
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceReferenceDate: 20)],
            ofItemAtPath: newer.path(percentEncoded: false)
        )

        let entries = await LibraryScanner().scan(directory: directory.url)

        #expect(entries.map(\.fileName) == ["newer.mp4", "older.mov"])
        #expect(entries.map(\.fileSize) == [2, 1])
    }

    @Test("Library scan marks a matching recording sidecar as unfinalized")
    func scanDetectsSidecar() async throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let movie = directory.url.appending(path: "interrupted.mov", directoryHint: .notDirectory)
        try Data([0]).write(to: movie)
        try Data().write(to: movie.appendingPathExtension(RecordingArtifacts.sidecarExtension))

        let entries = await LibraryScanner().scan(directory: directory.url)

        #expect(entries.count == 1)
        #expect(entries.first?.isUnfinalized == true)
    }

    @Test("Library scan returns no entries for an empty directory")
    func scanHandlesEmptyDirectory() async {
        let directory = TempDirectory()
        defer { directory.remove() }

        let entries = await LibraryScanner().scan(directory: directory.url)

        #expect(entries.isEmpty)
    }

    @Test("Library entry formats duration and file size for display")
    func entryFormatsMetadata() {
        let entry = LibraryEntry(
            url: URL(filePath: "/tmp/example.mov"),
            createdAt: .now,
            duration: 65.9,
            fileSize: 1_500_000,
            isUnfinalized: false
        )

        #expect(entry.durationText == "01:05")
        #expect(!entry.fileSizeText.isEmpty)
    }
}
