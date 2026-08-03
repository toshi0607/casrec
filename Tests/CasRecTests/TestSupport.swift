import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Synchronization
@testable import CasRec

// MARK: - Filesystem

/// A scratch directory under the system temp area. Tests own it outright, so `remove()`
/// can delete it wholesale rather than tracking individual files.
struct TempDirectory {
    let url: URL

    init(name: String = UUID().uuidString) {
        url = FileManager.default.temporaryDirectory
            .appending(path: "casrec-tests/\(name)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Every file directly inside the directory, sorted for stable assertions.
    func contents() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? []
        return names.sorted()
    }

    func settings(codec: VideoCodec = .h264, captureAppAudio: Bool = false) -> RecordingSettings {
        RecordingSettings(
            codec: codec,
            scalePercent: 100,
            fps: 30,
            captureAppAudio: captureAppAudio,
            captureMicrophone: false,
            destinationDirectory: url
        )
    }
}

// MARK: - Capture doubles

enum FakeCaptureError: Error {
    case startRefused
}

/// Stands in for `CaptureService` so the session's state machine can be driven without
/// ScreenCaptureKit or the screen-recording permission. The test decides whether
/// `startCapture` succeeds and pushes capture-ended events by hand.
///
/// `@unchecked Sendable` on the same terms as the production types: all mutable state
/// lives behind `state`.
final class FakeCaptureService: CaptureServicing, @unchecked Sendable {
    private struct State {
        var startCalls = 0
        var stopCalls = 0
        var startError: Error?
        var endedContinuation: AsyncStream<CaptureEndReason>.Continuation?
    }

    private let state = Mutex(State())

    init(startError: Error? = nil) {
        state.withLock { $0.startError = startError }
    }

    /// How many times `finalize` has run: it calls `stopCapture()` exactly once per
    /// teardown, which makes this the cleanest observable for "the session ended once".
    var stopCallCount: Int { state.withLock { $0.stopCalls } }
    var startCallCount: Int { state.withLock { $0.startCalls } }

    /// Delivers a capture-ended event as ScreenCaptureKit's `didStopWithError` relay would.
    func endCapture(_ reason: CaptureEndReason) {
        let continuation = state.withLock { $0.endedContinuation }
        continuation?.yield(reason)
    }

    func observeSources() -> AsyncStream<CaptureSourcesUpdate> {
        AsyncStream { $0.finish() }
    }

    func startCapture(source: CaptureSource, settings: RecordingSettings, sink: any SampleConsuming) async throws {
        let error = state.withLock { current -> Error? in
            current.startCalls += 1
            return current.startError
        }
        if let error { throw error }
    }

    func stopCapture() async {
        state.withLock { $0.stopCalls += 1 }
    }

    func observeCaptureEnded() -> AsyncStream<CaptureEndReason> {
        let (stream, continuation) = AsyncStream<CaptureEndReason>.makeStream()
        state.withLock { $0.endedContinuation = continuation }
        return stream
    }
}

/// Test-controlled stand-in for `AVAssetWriter.status == .failed`. A real writer cannot be
/// asked to fail on demand — it fails when the disk fills or the volume disappears — so the
/// coordinator takes its failure check as an injectable predicate and this flips it.
final class WriterFailureSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false

    var hasFailed: Bool { lock.withLock { failed } }

    func fail() { lock.withLock { failed = true } }
}

/// A source the session can be started with. The ScreenCaptureKit members stay nil: the
/// session only reads the name out of it, and the fake capture service never builds a filter.
func makeTestSource(title: String = "Test Window", appName: String? = "TestApp") -> CaptureSource {
    CaptureSource(
        id: "window-test",
        kind: .window,
        title: title,
        appName: appName,
        frame: CGRect(x: 0, y: 0, width: 320, height: 240),
        scWindow: nil,
        scDisplay: nil,
        thumbnail: nil
    )
}

// MARK: - State observation

/// Waits for the first state matching `predicate`, giving up after `timeout` so a broken
/// expectation fails the test instead of hanging the whole suite. Returns nil on timeout.
///
/// Note the states themselves cannot be asserted on as a sequence: `observeState()` buffers
/// only the newest value, so a subscriber is entitled to miss intermediate transitions.
/// Assertions belong on terminal states and on side effects.
func awaitState(
    _ session: RecordingSession,
    timeout: Duration = .seconds(5),
    matching predicate: @escaping @Sendable (RecordingState) -> Bool
) async -> RecordingState? {
    await withTaskGroup(of: RecordingState?.self) { group in
        group.addTask {
            for await state in session.observeState() where predicate(state) {
                return state
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// The state the session is in right now — `observeState()` replays it to every new
/// subscriber, so the first element is by definition current.
func currentState(_ session: RecordingSession) async -> RecordingState {
    for await state in session.observeState() {
        return state
    }
    return .idle
}

extension RecordingState {
    var isTerminal: Bool {
        switch self {
        case .idle, .failed: return true
        case .preparing, .recording, .finishing: return false
        }
    }
}

// MARK: - Synthetic media

/// A blank video sample the writer will accept, so tests can start a real writing session
/// without ScreenCaptureKit. No `SCStreamFrameInfo` attachment is set, which
/// `AssetWriterCoordinator` treats as `.usable` by design.
func makeVideoSample(at seconds: Double, width: Int = 320, height: Int = 240) -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        fatalError("could not allocate a pixel buffer for the test: CVReturn \(status)")
    }

    var formatDescription: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &formatDescription
    )
    guard let formatDescription else {
        fatalError("could not derive a format description for the test sample")
    }

    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600),
        decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    CMSampleBufferCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: formatDescription,
        sampleTiming: &timing,
        sampleBufferOut: &sampleBuffer
    )
    guard let sampleBuffer else {
        fatalError("could not create the test sample buffer")
    }
    return sampleBuffer
}
