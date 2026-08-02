import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

// MARK: - Recording state machine (DESIGN.md §4)
//
//   idle -> preparing -> recording -> finishing -> idle
//                      -> failed   -> idle
//
// `recording -> finishing` is reached via manual stop, target-window loss (R10),
// a stream error, or a disk-space guard tripping — see RecordingSessionControlling.

/// The lifecycle state of one recording session.
enum RecordingState: Sendable, Equatable {
    case idle
    case preparing
    case recording(RecordingProgress)
    case finishing
    case failed(message: String)
}

/// Point-in-time stats for an in-progress recording, carried by `RecordingState.recording`.
struct RecordingProgress: Sendable, Equatable {
    var startedAt: Date
    var bytesWritten: Int64
    var droppedFrames: Int
    var isStalled: Bool
}

// MARK: - Recording settings (DESIGN.md §5.1)

/// Video codec choice for `AVAssetWriterInput`. HEVC is the default (hardware-encoded,
/// smaller files); H.264 trades size for wider compatibility.
enum VideoCodec: Sendable, Equatable, CaseIterable {
    case hevc
    case h264
}

/// User-configurable capture/encode settings for a single recording.
struct RecordingSettings: Sendable, Equatable {
    var codec: VideoCodec
    /// Percentage of the source's native pixel size to capture at: 100 or 50.
    var scalePercent: Int
    /// Capture frame rate: 30 or 60.
    var fps: Int
    /// Capture the target app's own audio (R8). Maps to `SCStreamConfiguration.capturesAudio`.
    var captureAppAudio: Bool
    /// Additionally record the microphone into a second audio track.
    var captureMicrophone: Bool
    /// Directory recordings are written to.
    var destinationDirectory: URL

    static let `default` = RecordingSettings(
        codec: .hevc,
        scalePercent: 100,
        fps: 30,
        captureAppAudio: true,
        captureMicrophone: false,
        destinationDirectory: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Movies/CasRec", directoryHint: .isDirectory)
    )
}

// MARK: - Capture sources (DESIGN.md §5.2)

/// Whether a `CaptureSource` represents a whole display or a single window.
enum CaptureSourceKind: Sendable, Equatable, CaseIterable {
    case display
    case window
}

/// One entry in the source picker: a display or window available to capture, with the
/// underlying ScreenCaptureKit object needed to build an `SCContentFilter` (§5.2).
struct CaptureSource: Identifiable {
    let id: String
    let kind: CaptureSourceKind
    let title: String
    let appName: String?
    let frame: CGRect
    let scWindow: SCWindow?
    let scDisplay: SCDisplay?
    let thumbnail: CGImage?
}

// MARK: - Sample routing (DESIGN.md §5.3)

/// The three sample streams a capture can produce.
enum SampleKind: Sendable, Equatable, CaseIterable {
    case video
    case appAudio
    case microphone
}

/// A sink that accepts sample buffers as they arrive from the capture layer.
/// `SCStreamOutput` delivers samples synchronously on a caller-chosen queue, so
/// conformers (e.g. `AssetWriterCoordinator`) must be safe to call from any isolation
/// domain — hence `Sendable`.
protocol SampleConsuming: Sendable {
    func append(_ sampleBuffer: CMSampleBuffer, of kind: SampleKind)
}

// MARK: - Capture layer contract (DESIGN.md §4, §5.1, §5.2)

/// Why an active capture ended without the caller invoking `stopCapture()`.
enum CaptureEndReason: Sendable, Equatable {
    /// The capture source itself disappeared (e.g. the target window closed — R10).
    case sourceEnded
    /// The underlying stream failed.
    case failed(message: String)
}

/// Owns `SCShareableContent` enumeration, `SCContentFilter` construction, and
/// `SCStream` start/stop/error relay. The UI layer is decoupled from this via
/// `AsyncStream`, per §4.
protocol CaptureServicing {
    /// Available displays and windows, refreshed periodically with thumbnails.
    func observeSources() -> AsyncStream<[CaptureSource]>

    /// Builds the content filter for `source` (§5.2), starts an `SCStream` configured
    /// per `settings` (§5.1), and relays samples to `sink` until the stream ends.
    /// Throws if the stream fails to start (e.g. screen-recording permission not granted).
    func startCapture(source: CaptureSource, settings: RecordingSettings, sink: any SampleConsuming) async throws

    /// Stops the active capture, if any.
    func stopCapture() async

    /// Fires once when an active capture ends on its own — see `CaptureEndReason`.
    func observeCaptureEnded() -> AsyncStream<CaptureEndReason>
}

// MARK: - Recording session contract (DESIGN.md §4 state diagram)

/// Owns one recording's lifecycle and state machine (see the diagram above), including
/// starting/stopping `SessionGuards` (sleep prevention, disk monitoring).
protocol RecordingSessionControlling {
    /// The current state, observable by the UI layer.
    func observeState() -> AsyncStream<RecordingState>

    /// idle -> preparing -> (recording | failed). No-op unless currently idle.
    func start(source: CaptureSource, settings: RecordingSettings) async

    /// recording -> finishing -> idle. No-op unless currently recording.
    func stop() async
}
