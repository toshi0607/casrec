import AVFoundation
import Foundation
import Testing
@testable import CasRec

@Suite("Asset writer coordinator")
struct AssetWriterCoordinatorTests {

    // MARK: - Finishing

    @Test("Concurrent finishes run finishWriting exactly once")
    func concurrentFinishesShareOneFinishWriting() async throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let output = directory.url.appending(path: "concurrent.mov", directoryHint: .notDirectory)
        let coordinator = try AssetWriterCoordinator(outputURL: output, settings: directory.settings())

        for frame in 0..<3 {
            coordinator.append(makeVideoSample(at: Double(frame) / 30.0), of: .video)
        }

        // Both stop paths of §4 can converge here at once. If `finishWriting` ran twice the
        // second call would land on an already-completed writer and report a failure, so two
        // `.finalized` results *are* the evidence that it ran once.
        async let first = coordinator.finish()
        async let second = coordinator.finish()
        let results = await [first, second]

        #expect(results == [.finalized, .finalized])
        #expect(FileManager.default.fileExists(atPath: output.path(percentEncoded: false)))
    }

    @Test("A session with no samples reports nothing recorded and writes no file")
    func noSamplesProducesNothingRecorded() async throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let output = directory.url.appending(path: "empty.mov", directoryHint: .notDirectory)
        let coordinator = try AssetWriterCoordinator(outputURL: output, settings: directory.settings())

        let result = await coordinator.finish()

        #expect(result == .nothingRecorded)
        #expect(!FileManager.default.fileExists(atPath: output.path(percentEncoded: false)))
    }

    // MARK: - Failure detection (the N6 gap)

    @Test("A writer that fails while samples have stopped is still detected")
    func detectsFailureAfterSamplesStop() throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let output = directory.url.appending(path: "starved.mov", directoryHint: .notDirectory)
        let failure = WriterFailureSwitch()
        let coordinator = try AssetWriterCoordinator(
            outputURL: output,
            settings: directory.settings(),
            writerHasFailed: { _ in failure.hasFailed }
        )

        for frame in 0..<3 {
            coordinator.append(makeVideoSample(at: Double(frame) / 30.0), of: .video)
        }
        #expect(coordinator.stats.writeFailure == nil, "a healthy writer must not be latched as failed")

        // From here on the recording is starved exactly as it would be by a minimised window
        // (idle frames are never appended) or a silent app: no `append` will be called again.
        // The writer dies anyway — disk full, volume unplugged.
        failure.fail()

        let stats = coordinator.stats
        #expect(stats.writeFailure != nil, "the ticker's poll is the only thing that can notice this")
        #expect(stats.droppedFrames == 0, "detection must not depend on the append path")
    }

    @Test("A writer that fails before any sample arrives is detected too")
    func detectsFailureWithoutAnyAppend() throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let output = directory.url.appending(path: "never-appended.mov", directoryHint: .notDirectory)
        let failure = WriterFailureSwitch()
        let coordinator = try AssetWriterCoordinator(
            outputURL: output,
            settings: directory.settings(),
            writerHasFailed: { _ in failure.hasFailed }
        )

        #expect(coordinator.stats.writeFailure == nil)
        failure.fail()

        #expect(coordinator.stats.writeFailure != nil)
    }

    @Test("Bitrate scales with pixel count and never falls below the floor")
    func videoSettingsScaleWithResolution() {
        let large = AssetWriterCoordinator.videoOutputSettings(width: 1920, height: 1080, codec: .hevc)
        let small = AssetWriterCoordinator.videoOutputSettings(width: 160, height: 120, codec: .hevc)

        let largeBitrate = (large[AVVideoCompressionPropertiesKey] as? [String: Any])?[AVVideoAverageBitRateKey] as? Int
        let smallBitrate = (small[AVVideoCompressionPropertiesKey] as? [String: Any])?[AVVideoAverageBitRateKey] as? Int

        #expect(largeBitrate == 4_000_000)
        #expect(smallBitrate == 500_000, "a small window still has to be watchable")
    }
}
