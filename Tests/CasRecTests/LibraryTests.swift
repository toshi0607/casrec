import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CasRec

private actor MetadataLoadTracker {
    private var activeLoads = 0
    private var peakLoads = 0

    func loadDuration(of _: URL) async -> TimeInterval? {
        activeLoads += 1
        peakLoads = max(peakLoads, activeLoads)
        try? await Task.sleep(for: .milliseconds(25))
        activeLoads -= 1
        return 1
    }

    func peakConcurrency() -> Int {
        peakLoads
    }
}

@Suite("Library and output directories")
struct LibraryTests {
    @Test("Library scan bounds concurrent metadata loads without dropping entries")
    func scanBoundsMetadataConcurrency() async throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let fileCount = 24
        for index in 0..<fileCount {
            try Data([0]).write(to: directory.url.appending(path: "recording-\(index).mov", directoryHint: .notDirectory))
        }

        let tracker = MetadataLoadTracker()
        let limits = LibraryScanner.Limits(maximumConcurrentMetadataLoads: 2)
        let scanner = LibraryScanner(limits: limits) { url in
            await tracker.loadDuration(of: url)
        }

        let entries = await scanner.scan(directory: directory.url)

        #expect(entries.count == fileCount)
        #expect(await tracker.peakConcurrency() <= limits.maximumConcurrentMetadataLoads)
    }

    @Test("Library scan retains and sorts a large complete result set")
    func scanRetainsLargeSortedLibrary() async throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let fileCount = 80
        let baseDate = Date(timeIntervalSinceReferenceDate: 1_000)
        for index in 0..<fileCount {
            let url = directory.url.appending(path: String(format: "recording-%03d.mp4", index), directoryHint: .notDirectory)
            try Data([0]).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: baseDate.addingTimeInterval(TimeInterval(index))],
                ofItemAtPath: url.path(percentEncoded: false)
            )
        }

        let scanner = LibraryScanner { _ in 1 }
        let entries = await scanner.scan(directory: directory.url)

        #expect(entries.count == fileCount)
        #expect(entries.map(\.fileName) == (0..<fileCount).reversed().map { String(format: "recording-%03d.mp4", $0) })
    }

    @Test("Library scan retains GIFs above the frame limit without a duration")
    func scanRetainsGIFAboveFrameLimit() async throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let gif = directory.url.appending(path: "animated.gif", directoryHint: .notDirectory)
        try writeAnimatedGIF(frameCount: 2, to: gif)

        let scanner = LibraryScanner(limits: .init(maximumGIFFrames: 1))
        let entries = await scanner.scan(directory: directory.url)

        #expect(entries.count == 1)
        #expect(entries.first?.fileName == "animated.gif")
        #expect(entries.first?.duration == nil)
    }

    @Test("Library scan sorts supported media newest first and ignores other files")
    func scanSortsAndFiltersFiles() async throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let older = directory.url.appending(path: "older.mov", directoryHint: .notDirectory)
        let newer = directory.url.appending(path: "newer.mp4", directoryHint: .notDirectory)
        let gif = directory.url.appending(path: "converted.gif", directoryHint: .notDirectory)
        let image = directory.url.appending(path: "ignored.png", directoryHint: .notDirectory)
        try Data([0]).write(to: older)
        try Data([0, 1]).write(to: newer)
        try Data([0]).write(to: gif)
        try Data([0]).write(to: image)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceReferenceDate: 10)],
            ofItemAtPath: older.path(percentEncoded: false)
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceReferenceDate: 20)],
            ofItemAtPath: newer.path(percentEncoded: false)
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceReferenceDate: 15)],
            ofItemAtPath: gif.path(percentEncoded: false)
        )

        let entries = await LibraryScanner().scan(directory: directory.url)

        #expect(entries.map(\.fileName) == ["newer.mp4", "converted.gif", "older.mov"])
        #expect(entries.map(\.fileSize) == [2, 1, 1])
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

        let longEntry = LibraryEntry(
            url: URL(filePath: "/tmp/long.mov"),
            createdAt: .now,
            duration: 3_661,
            fileSize: 0,
            isUnfinalized: false
        )
        #expect(longEntry.durationText == "1:01:01")
    }

    private func writeAnimatedGIF(frameCount: Int, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let pixelData = Data([0, 0, 0, 255])
        guard let provider = CGDataProvider(data: pixelData as CFData),
              let image = CGImage(
                  width: 1,
                  height: 1,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let frameProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1],
        ]
        for _ in 0..<frameCount {
            CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
