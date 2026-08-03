import AppKit
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// `CaptureServicing` implementation: owns `SCShareableContent` enumeration (via
/// `ShareableContentProvider`), `SCContentFilter`/`SCStreamConfiguration` construction,
/// and the active `SCStream`'s start/stop/error relay (DESIGN.md §4).
///
/// `CaptureServicing` is a plain, non-isolated protocol, and this type stays a plain,
/// unisolated class to match: it is driven from `RecordingSession`, which is itself
/// unisolated, and there is nothing here that belongs on the main actor. It is
/// `@unchecked Sendable` because its `SCStream`/`StreamRelay` state is non-Sendable
/// ScreenCaptureKit/ObjC state, manually protected by `lock` instead of actor isolation.
/// `observeSources()` runs its periodic `ShareableContentProvider.fetchSources()` polling
/// loop inside a `Task { @MainActor in }`, producing the source list on the same isolation
/// domain its `@MainActor` SwiftUI consumer reads it on.
///
/// The hot per-frame path (`SCStreamOutput`) also stays off any actor: `StreamRelay`
/// below is a plain, immutable-after-init, genuinely `Sendable` `NSObject` that forwards
/// samples to `sink` (itself `Sendable`, per `SampleConsuming`) on whatever queue
/// ScreenCaptureKit calls it on, per §5.3.
final class CaptureService: CaptureServicing, @unchecked Sendable {

    private let lock = NSLock()
    private var activeStream: SCStream?
    private var activeRelay: StreamRelay?
    /// Identifies the current capture. Each `startCapture` claims the next value, and a
    /// `didStopWithError` callback carries the generation it was created with, so a late
    /// callback from a superseded stream cannot tear down its successor.
    private var activeGeneration = 0
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

    func observeSources() -> AsyncStream<CaptureSourcesUpdate> {
        AsyncStream { continuation in
            let pollTask = Task { @MainActor in
                while !Task.isCancelled {
                    do {
                        let sources = try await ShareableContentProvider.fetchSources()
                        continuation.yield(.sources(sources))
                    } catch {
                        // Polling continues either way: a permission grant or a transient
                        // failure clears itself, and the reason travels to the UI rather
                        // than being flattened into an empty list (§5.5).
                        continuation.yield(.unavailable(Self.classifyEnumerationFailure(error)))
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

    func capturePreview(for source: CaptureSource) async throws -> CapturePreview {
        guard source.kind == .window, let window = source.scWindow else {
            throw CaptureServiceError.sourceUnavailable
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let contentSize = filter.contentRect.size.width > 0 && filter.contentRect.size.height > 0
            ? filter.contentRect.size
            : source.frame.size
        let scale = Self.resolvedPixelScale(filter: filter, source: source)
        let outputSize = CaptureDimensions.outputSize(
            contentSize: contentSize,
            pointPixelScale: scale,
            scalePercent: 100
        )
        let configuration = SCStreamConfiguration()
        configuration.width = outputSize.width
        configuration.height = outputSize.height
        configuration.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        return CapturePreview(image: image, contentSize: contentSize)
    }

    func startCapture(source: CaptureSource, settings: RecordingSettings, sink: any SampleConsuming) async throws {
        // Restarting mid-flight is treated as "replace the active capture" rather
        // than an error; `RecordingSessionControlling`'s state machine is what
        // actually prevents calling this while already recording (DESIGN.md §4).
        await stopActiveStream()

        let filter = try await Self.makeFilter(for: source)
        let configuration = try Self.makeConfiguration(source: source, filter: filter, settings: settings)

        let generation = withLock { () -> Int in
            activeGeneration += 1
            return activeGeneration
        }
        let newRelay = StreamRelay(sink: sink) { [weak self] error in
            self?.handleStreamStopped(error: error, generation: generation)
        }

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: newRelay)
        // Published before `startCapture()` rather than after: `didStopWithError` can fire
        // while that call is still in flight, and a callback that arrives before the stream
        // is on record would be discarded, leaving the session stuck in `recording` (§4).
        withLock {
            activeStream = newStream
            activeRelay = newRelay
        }
        do {
            try newStream.addStreamOutput(newRelay, type: .screen, sampleHandlerQueue: Self.videoQueue)
            try newStream.addStreamOutput(newRelay, type: .audio, sampleHandlerQueue: Self.audioQueue)
            if settings.captureMicrophone {
                try newStream.addStreamOutput(newRelay, type: .microphone, sampleHandlerQueue: Self.microphoneQueue)
            }
            try await newStream.startCapture()
        } catch {
            withLock {
                guard activeGeneration == generation else { return }
                activeStream = nil
                activeRelay = nil
            }
            throw error
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

    private func handleStreamStopped(error: Error, generation: Int) {
        // A `didStopWithError` callback can race a manual `stopCapture()`, and a stream
        // that has already been replaced can still call back afterwards; report only when
        // this is the capture currently on record.
        let continuation = withLock { () -> AsyncStream<CaptureEndReason>.Continuation? in
            guard activeGeneration == generation, activeStream != nil else { return nil }
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
    ) throws -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()

        let scale = resolvedPixelScale(filter: filter, source: source)
        let contentSize = contentSize(filter: filter, source: source)
        let cropRect: CGRect?
        if let sourceCropRect = settings.sourceCropRect {
            guard source.kind == .window,
                  let validCrop = CropGeometry.clampedContentRect(sourceCropRect, contentSize: contentSize) else {
                throw CaptureServiceError.invalidCrop
            }
            cropRect = validCrop
            configuration.sourceRect = validCrop
        } else {
            cropRect = nil
        }
        let outputSize = CaptureDimensions.outputSize(
            contentSize: cropRect?.size ?? contentSize,
            pointPixelScale: scale,
            scalePercent: settings.scalePercent
        )
        configuration.width = outputSize.width
        configuration.height = outputSize.height

        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.fps))
        // Bi-planar 4:2:0 is what the HEVC/H.264 encoders want: half the bytes per pixel of
        // BGRA and no colour conversion on every frame of a multi-hour recording (R5).
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        // Mandatory once the format is YCbCr: the matrix is what the RGB→YCbCr conversion
        // is done with, and a 601/709 mismatch tints the whole recording in a way no
        // post-processing can undo. Stated explicitly rather than left to a default,
        // because this file is written once and played back forever.
        configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
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

    /// Content size of what the filter will actually deliver. `contentRect` is the
    /// authority here, not the up-to-two-seconds-old source-list frame.
    private static func contentSize(filter: SCContentFilter, source: CaptureSource) -> CGSize {
        let contentSize = filter.contentRect.size
        // Only if ScreenCaptureKit has no rect to give (a source that vanished between
        // enumeration and here) is the stale frame better than nothing.
        return contentSize.width > 0 && contentSize.height > 0 ? contentSize : source.frame.size
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

    // MARK: - Error classification (DESIGN.md §5.5)

    /// Classifies a `didStopWithError` callback into `CaptureEndReason` from the
    /// `SCStreamError` code alone. Matching on `localizedDescription` is not an option:
    /// it is localized, so any keyword rule is both blind in Japanese and prone to calling
    /// a real failure a normal ending — which would end a recording with no message at all.
    ///
    /// Only codes that mean "the capture was ended, not broken" map to `.sourceEnded`;
    /// every other code, and every other error domain, becomes `.failed` carrying the raw
    /// domain/code so the cause survives into the UI (§5.5).
    private static func classifyStopReason(_ error: Error) -> CaptureEndReason {
        let nsError = error as NSError
        if nsError.domain == SCStreamError.errorDomain,
           let code = SCStreamError.Code(rawValue: nsError.code),
           code == .userStopped {
            return .sourceEnded
        }
        return .failed(message: describe(nsError))
    }

    /// Why `SCShareableContent` refused to enumerate. ScreenCaptureKit reports a missing
    /// screen-recording grant as `SCStreamError.userDeclined`; everything else is passed
    /// through verbatim rather than being presented to the user as a permission problem.
    private static func classifyEnumerationFailure(_ error: Error) -> CaptureUnavailableReason {
        let nsError = error as NSError
        if nsError.domain == SCStreamError.errorDomain,
           let code = SCStreamError.Code(rawValue: nsError.code),
           code == .userDeclined {
            return .permissionDenied
        }
        return .failed(message: describe(nsError))
    }

    private static func describe(_ error: NSError) -> String {
        "\(error.domain)#\(error.code): \(error.localizedDescription)"
    }
}

private enum CaptureServiceError: Error, LocalizedError {
    case sourceUnavailable
    case invalidCrop

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            "The selected capture source is no longer available."
        case .invalidCrop:
            "The selected crop is no longer within the window's content area."
        }
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
