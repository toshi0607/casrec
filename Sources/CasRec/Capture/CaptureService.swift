import AppKit
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// `CaptureServicing` implementation: owns `SCShareableContent` enumeration (via
/// `ShareableContentProvider`), `SCContentFilter`/`SCStreamConfiguration` construction,
/// and the active `SCStream`'s start/stop/error relay (DESIGN.md §4).
///
/// `CaptureServicing` is a plain, non-isolated protocol whose `startCapture` requirement
/// takes a non-`Sendable` `CaptureSource` without `sending`, so a globally-isolated
/// (`@MainActor` or custom actor) witness cannot accept it — the compiler rejects moving
/// a non-Sendable parameter into an isolated implementation. This type therefore stays a
/// plain, unisolated class and is `@unchecked Sendable`: its `SCStream`/`StreamRelay`
/// stream state is non-Sendable ScreenCaptureKit/ObjC state, manually protected by
/// `lock` instead of actor isolation. `observeSources()` runs its periodic
/// `ShareableContentProvider.fetchSources()` polling loop inside a `Task { @MainActor in }`
/// so the non-Sendable `CaptureSource` values it yields are produced on the same,
/// UI-friendly isolation domain their `@MainActor` SwiftUI consumer will read them on.
///
/// The hot per-frame path (`SCStreamOutput`) also stays off any actor: `StreamRelay`
/// below is a plain, immutable-after-init, genuinely `Sendable` `NSObject` that forwards
/// samples to `sink` (itself `Sendable`, per `SampleConsuming`) on whatever queue
/// ScreenCaptureKit calls it on, per §5.3.
final class CaptureService: CaptureServicing, @unchecked Sendable {

    private let lock = NSLock()
    private var activeStream: SCStream?
    private var activeRelay: StreamRelay?
    private var endedContinuation: AsyncStream<CaptureEndReason>.Continuation?

    private static let videoQueue = DispatchQueue(label: "dev.casrec.capture.video")
    private static let audioQueue = DispatchQueue(label: "dev.casrec.capture.audio")
    private static let microphoneQueue = DispatchQueue(label: "dev.casrec.capture.microphone")

    private func withLock<R>(_ body: () -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - CaptureServicing

    func observeSources() -> AsyncStream<[CaptureSource]> {
        AsyncStream { continuation in
            let pollTask = Task { @MainActor in
                while !Task.isCancelled {
                    do {
                        let sources = try await ShareableContentProvider.fetchSources()
                        continuation.yield(sources)
                    } catch {
                        // Most commonly: screen-recording permission not granted yet.
                        // Keep polling — the list will populate once the user grants it.
                        continuation.yield([])
                    }
                    try? await Task.sleep(for: .seconds(2))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                pollTask.cancel()
            }
        }
    }

    func startCapture(source: CaptureSource, settings: RecordingSettings, sink: any SampleConsuming) async throws {
        // Restarting mid-flight is treated as "replace the active capture" rather
        // than an error; `RecordingSessionControlling`'s state machine is what
        // actually prevents calling this while already recording (DESIGN.md §4).
        await stopActiveStream()

        let filter = try await Self.makeFilter(for: source)
        let configuration = Self.makeConfiguration(source: source, filter: filter, settings: settings)

        let newRelay = StreamRelay(sink: sink) { [weak self] error in
            self?.handleStreamStopped(error: error)
        }

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: newRelay)
        try newStream.addStreamOutput(newRelay, type: .screen, sampleHandlerQueue: Self.videoQueue)
        try newStream.addStreamOutput(newRelay, type: .audio, sampleHandlerQueue: Self.audioQueue)
        if settings.captureMicrophone {
            try newStream.addStreamOutput(newRelay, type: .microphone, sampleHandlerQueue: Self.microphoneQueue)
        }

        try await newStream.startCapture()

        withLock {
            activeStream = newStream
            activeRelay = newRelay
        }
    }

    func stopCapture() async {
        await stopActiveStream()
    }

    func observeCaptureEnded() -> AsyncStream<CaptureEndReason> {
        AsyncStream { continuation in
            // Only one capture is ever active at a time, so a fresh subscriber
            // supersedes the previous one; finish it so its consumer's `for await`
            // loop exits instead of hanging forever.
            let previous = withLock { () -> AsyncStream<CaptureEndReason>.Continuation? in
                let old = endedContinuation
                endedContinuation = continuation
                return old
            }
            previous?.finish()
        }
    }

    // MARK: - Stop

    private func stopActiveStream() async {
        let stream = withLock { () -> SCStream? in
            let current = activeStream
            activeStream = nil
            activeRelay = nil
            return current
        }
        guard let stream else { return }
        do {
            try await stream.stopCapture()
        } catch {
            // Already stopped/torn down under us — stopCapture() must be safe to
            // call repeatedly or before a capture ever started.
        }
    }

    private func handleStreamStopped(error: Error) {
        // A `didStopWithError` callback can race a manual `stopCapture()`; only
        // report it if this is still the active stream.
        let continuation = withLock { () -> AsyncStream<CaptureEndReason>.Continuation? in
            guard activeStream != nil else { return nil }
            activeStream = nil
            activeRelay = nil
            return endedContinuation
        }
        continuation?.yield(Self.classifyStopReason(error))
    }

    // MARK: - Filter construction (DESIGN.md §5.2)

    private static func makeFilter(for source: CaptureSource) async throws -> SCContentFilter {
        switch source.kind {
        case .window:
            guard let window = source.scWindow else {
                throw CaptureServiceError.sourceUnavailable
            }
            return SCContentFilter(desktopIndependentWindow: window)
        case .display:
            guard let display = source.scDisplay else {
                throw CaptureServiceError.sourceUnavailable
            }
            let ownWindows = (try? await ShareableContentProvider.ownApplicationWindows()) ?? []
            return SCContentFilter(display: display, excludingWindows: ownWindows)
        }
    }

    // MARK: - Configuration construction (DESIGN.md §5.1)

    private static func makeConfiguration(
        source: CaptureSource,
        filter: SCContentFilter,
        settings: RecordingSettings
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()

        let scale = resolvedPixelScale(filter: filter, source: source)
        let nativeSize = nativePixelSize(source: source, scale: scale)
        let percent = CGFloat(settings.scalePercent) / 100.0
        configuration.width = evenPixelCount(CGFloat(nativeSize.width) * percent)
        configuration.height = evenPixelCount(CGFloat(nativeSize.height) * percent)

        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.fps))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.capturesAudio = settings.captureAppAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = settings.captureMicrophone
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.showsCursor = false
        configuration.queueDepth = 5

        return configuration
    }

    /// Prefers the point→pixel scale ScreenCaptureKit itself resolved for this
    /// filter's content; only asks `NSScreen` when SCK doesn't have one.
    private static func resolvedPixelScale(filter: SCContentFilter, source: CaptureSource) -> CGFloat {
        if filter.pointPixelScale > 0 {
            return CGFloat(filter.pointPixelScale)
        }
        return fallbackPixelScale(for: source)
    }

    private static func nativePixelSize(source: CaptureSource, scale: CGFloat) -> (width: Int, height: Int) {
        switch source.kind {
        case .window:
            let width = source.frame.width * scale
            let height = source.frame.height * scale
            return (Int(width.rounded()), Int(height.rounded()))
        case .display:
            guard let display = source.scDisplay else {
                return (Int((source.frame.width * scale).rounded()), Int((source.frame.height * scale).rounded()))
            }
            return (Int((CGFloat(display.width) * scale).rounded()), Int((CGFloat(display.height) * scale).rounded()))
        }
    }

    /// Rounds up to an even pixel count — HEVC/H.264 encoders require even
    /// dimensions, and `settings.scalePercent` (e.g. 50%) can otherwise land on odd.
    private static func evenPixelCount(_ raw: CGFloat) -> Int {
        let value = max(2, Int(raw.rounded()))
        return value.isMultiple(of: 2) ? value : value + 1
    }

    /// Honest fallback when `SCContentFilter.pointPixelScale` isn't available:
    /// match the source to the `NSScreen` it's (mostly) on and use its backing
    /// scale factor, defaulting to the main screen if nothing matches.
    private static func fallbackPixelScale(for source: CaptureSource) -> CGFloat {
        switch source.kind {
        case .display:
            if let displayID = source.scDisplay?.displayID,
               let screen = NSScreen.screens.first(where: { screen in
                   (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
               }) {
                return screen.backingScaleFactor
            }
        case .window:
            let bestScreen = NSScreen.screens.max { lhs, rhs in
                area(of: lhs.frame.intersection(source.frame)) < area(of: rhs.frame.intersection(source.frame))
            }
            if let bestScreen, area(of: bestScreen.frame.intersection(source.frame)) > 0 {
                return bestScreen.backingScaleFactor
            }
        }
        return NSScreen.main?.backingScaleFactor ?? 2.0
    }

    private static func area(of rect: CGRect) -> CGFloat {
        max(0, rect.width) * max(0, rect.height)
    }

    /// Best-effort classification of a `didStopWithError` callback into
    /// `CaptureEndReason`. ScreenCaptureKit doesn't expose a stable, documented
    /// error-code taxonomy for "the source disappeared" vs. "something broke", so
    /// this inspects the bridged `NSError`'s domain/code/description for known
    /// signals and otherwise defers to `.failed`, carrying the raw domain/code so
    /// it can be refined later (see the Capture-layer task's Wave 2 note).
    private static func classifyStopReason(_ error: Error) -> CaptureEndReason {
        let nsError = error as NSError
        let signal = "\(nsError.domain)#\(nsError.code) \(nsError.localizedDescription)".lowercased()
        let sourceEndedKeywords = [
            "userstopped", "user stopped", "window", "display", "source",
            "no longer valid", "nolongervalid",
        ]
        if sourceEndedKeywords.contains(where: signal.contains) {
            return .sourceEnded
        }
        return .failed(message: "\(nsError.domain)#\(nsError.code): \(nsError.localizedDescription)")
    }
}

private enum CaptureServiceError: Error, LocalizedError {
    case sourceUnavailable

    var errorDescription: String? {
        "The selected capture source is no longer available."
    }
}

/// `SCStreamOutput`/`SCStreamDelegate` conformer. Deliberately dumb, immutable after
/// init, and genuinely `Sendable` (both stored properties are `Sendable`): ScreenCaptureKit
/// calls these on whatever queue was registered in `addStreamOutput`, at up to the
/// configured frame rate, so this just forwards to `sink` without interpreting frame
/// status — that's the Recording layer's job (DESIGN.md §5.3).
private final class StreamRelay: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
    private let sink: any SampleConsuming
    private let onStop: @Sendable (Error) -> Void

    init(sink: any SampleConsuming, onStop: @escaping @Sendable (Error) -> Void) {
        self.sink = sink
        self.onStop = onStop
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        switch outputType {
        case .screen:
            sink.append(sampleBuffer, of: .video)
        case .audio:
            sink.append(sampleBuffer, of: .appAudio)
        case .microphone:
            sink.append(sampleBuffer, of: .microphone)
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(error)
    }
}
