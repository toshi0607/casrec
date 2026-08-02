import AVFoundation
import CoreMedia
import Foundation
import OSLog
import ScreenCaptureKit

/// How a recording's `finishWriting` turned out.
enum RecordingFinishResult: Sendable, Equatable {
    /// `finishWriting` completed — the `.mov` is self-contained and playable.
    case finalized
    /// No video sample ever arrived, so the writer was never started and no media reached
    /// disk. There is nothing to finalize and nothing to repair.
    case nothingRecorded
    /// The writer failed. Whatever fragments already reached disk are still there, and the
    /// `.recording` sidecar stays behind for the repair flow (DESIGN.md §5.5).
    case failed(message: String)
}

/// A snapshot of write progress, polled once per second by `RecordingSession`.
struct WriterStats: Sendable, Equatable {
    var bytesWritten: Int64
    var droppedFrames: Int
    /// When the most recent video sample was *received* — the basis for stall detection.
    /// Receipt, not a successful append, is what proves the stream is still alive: a
    /// perfectly static screen delivers `.idle` frames that are never appended (§5.3).
    var lastVideoSampleAt: Date?
    /// Set once the writer has entered a terminal failure state; nothing more can be written.
    var writeFailure: String?
}

/// Writes capture samples into a fragmented QuickTime movie (DESIGN.md §5.3).
///
/// Crash resilience is the reason this layer exists at all: `movieFragmentInterval`
/// flushes a playable fragment every 10 seconds, so a `kill -9` costs at most the samples
/// since the last fragment boundary rather than the whole file.
///
/// ## Thread safety
///
/// `SCStreamOutput` delivers samples synchronously on a queue this type does not own, so
/// `append(_:of:)` can be called from any thread. Every piece of mutable state — the
/// `AVAssetWriter`, its inputs, the session clock, and the counters — is touched only
/// inside `queue`, a serial dispatch queue, which is what makes the `@unchecked Sendable`
/// conformance sound. `append` uses `queue.sync` rather than `queue.async` on purpose:
/// synchronous hand-off applies backpressure to the capture queue instead of letting an
/// unbounded backlog of full-resolution frames accumulate in memory over a multi-hour
/// recording (R5), and it keeps each `CMSampleBuffer` non-escaping.
final class AssetWriterCoordinator: SampleConsuming, @unchecked Sendable {
    /// Fragment cadence. Every 10 seconds the writer closes a fragment that stands on its
    /// own, bounding how much a crash can cost (§5.3).
    static let fragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

    /// Reference point for bitrate scaling: 1080p.
    private static let referencePixelCount = 1920 * 1080
    private static let hevcReferenceBitrate = 4_000_000
    private static let h264ReferenceBitrate = 8_000_000
    /// Floor so that capturing a small window still produces a usable picture.
    private static let minimumBitrate = 500_000

    private static let log = Logger(subsystem: "dev.toshi0607.casrec", category: "writer")

    /// Where the recording is being written.
    let outputURL: URL

    private let settings: RecordingSettings
    private let queue = DispatchQueue(label: "dev.toshi0607.casrec.assetwriter", qos: .userInitiated)

    // MARK: - State owned exclusively by `queue`

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var appAudioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    /// Set once the first video sample has defined the session clock.
    private var sessionStartTime: CMTime?
    private var droppedFrames = 0
    private var lastVideoSampleAt: Date?
    private var writeFailure: String?
    private var isFinishing = false
    /// Memoised so concurrent callers share one `finishWriting`, not two.
    private var finishTask: Task<RecordingFinishResult, Never>?

    /// Creates the writer and its audio inputs. The video input cannot be built yet: its
    /// dimensions come from the first sample's format description, so it is added lazily
    /// (and necessarily before `startWriting`, which is deferred to that same moment).
    init(outputURL: URL, settings: RecordingSettings) throws {
        self.outputURL = outputURL
        self.settings = settings

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        writer.movieFragmentInterval = Self.fragmentInterval
        self.writer = writer

        if settings.captureAppAudio {
            let input = Self.makeAudioInput()
            if writer.canAdd(input) {
                writer.add(input)
                appAudioInput = input
            } else {
                Self.log.error("writer rejected the app-audio input")
            }
        }
        if settings.captureMicrophone {
            let input = Self.makeAudioInput()
            if writer.canAdd(input) {
                writer.add(input)
                microphoneInput = input
            } else {
                Self.log.error("writer rejected the microphone input")
            }
        }
    }

    // MARK: - SampleConsuming

    func append(_ sampleBuffer: CMSampleBuffer, of kind: SampleKind) {
        queue.sync {
            guard !isFinishing, writeFailure == nil else { return }
            switch kind {
            case .video:
                appendVideo(sampleBuffer)
            case .appAudio:
                appendAudio(sampleBuffer, to: appAudioInput)
            case .microphone:
                appendAudio(sampleBuffer, to: microphoneInput)
            }
        }
    }

    // MARK: - Stats

    /// A consistent snapshot for the recording HUD.
    var stats: WriterStats {
        let snapshot = queue.sync { (droppedFrames, lastVideoSampleAt, writeFailure) }
        // Queried outside the lock: the file system is the source of truth for size, and
        // this must not contend with sample appends.
        let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path(percentEncoded: false))
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return WriterStats(
            bytesWritten: size,
            droppedFrames: snapshot.0,
            lastVideoSampleAt: snapshot.1,
            writeFailure: snapshot.2
        )
    }

    // MARK: - Finishing

    /// Marks every input finished and awaits `finishWriting`.
    ///
    /// Safe to call any number of times and from any number of tasks at once: the first
    /// call creates the finishing task and every other call awaits that same task, so
    /// `finishWriting` runs exactly once and all callers observe the same result.
    func finish() async -> RecordingFinishResult {
        let task: Task<RecordingFinishResult, Never> = queue.sync {
            if let existing = finishTask { return existing }
            isFinishing = true
            let created = Task { [self] in await performFinish() }
            finishTask = created
            return created
        }
        return await task.value
    }

    private func performFinish() async -> RecordingFinishResult {
        let pending: (writer: AVAssetWriter?, didStart: Bool, failure: String?) = queue.sync {
            let didStart = sessionStartTime != nil
            if didStart {
                videoInput?.markAsFinished()
                appAudioInput?.markAsFinished()
                microphoneInput?.markAsFinished()
            }
            return (writer, didStart, writeFailure)
        }

        guard let writer = pending.writer, pending.didStart else {
            // `startWriting` was never reached, so `finishWriting` would be invalid here.
            if let failure = pending.failure {
                Self.log.error("recording produced no media: \(failure, privacy: .public)")
                return .failed(message: failure)
            }
            Self.log.notice("recording finished before any video sample arrived")
            return .nothingRecorded
        }

        await writer.finishWriting()

        if writer.status == .completed {
            Self.log.info("finalized \(self.outputURL.lastPathComponent, privacy: .public)")
            return .finalized
        }
        let message = writer.error?.localizedDescription
            ?? pending.failure
            ?? "録画ファイルの書き込みを完了できませんでした。"
        Self.log.error("finishWriting failed: \(message, privacy: .public)")
        return .failed(message: message)
    }

    // MARK: - Video path (queue-confined)

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        // Recorded on receipt, before any filtering: an `.idle` frame is not written but
        // still proves frames are flowing, so it must not read as a stall (§5.3).
        lastVideoSampleAt = Date()

        switch Self.frameHealth(of: sampleBuffer) {
        case .idle:
            // Screen unchanged. Normal, and deliberately not counted as a drop.
            return
        case .abnormal:
            droppedFrames += 1
            return
        case .usable:
            break
        }

        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            droppedFrames += 1
            return
        }
        guard startSessionIfNeeded(with: sampleBuffer), let videoInput else {
            droppedFrames += 1
            return
        }
        // Realtime beats completeness: if the encoder is behind, drop this frame rather
        // than block the capture queue and fall further behind.
        guard videoInput.isReadyForMoreMediaData else {
            droppedFrames += 1
            return
        }
        if !videoInput.append(sampleBuffer) {
            droppedFrames += 1
            recordWriterFailure()
        }
    }

    /// Builds the video input from the first sample's dimensions, then starts the writer
    /// and pins the session clock to that sample's presentation timestamp — the A/V sync
    /// reference for everything that follows (§5.3).
    private func startSessionIfNeeded(with sampleBuffer: CMSampleBuffer) -> Bool {
        if sessionStartTime != nil { return true }
        guard let writer else { return false }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            recordWriterFailure(message: "映像フォーマットを取得できませんでした。")
            return false
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        guard dimensions.width > 0, dimensions.height > 0 else {
            recordWriterFailure(message: "映像サイズが不正です (\(dimensions.width)x\(dimensions.height))。")
            return false
        }

        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: Self.videoOutputSettings(
                width: Int(dimensions.width),
                height: Int(dimensions.height),
                codec: settings.codec
            )
        )
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            recordWriterFailure(message: "映像トラックを作成できませんでした。別のコーデックをお試しください。")
            return false
        }
        writer.add(input)
        videoInput = input

        guard writer.startWriting() else {
            recordWriterFailure()
            return false
        }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        writer.startSession(atSourceTime: presentationTime)
        sessionStartTime = presentationTime

        Self.log.info(
            "started \(dimensions.width)x\(dimensions.height) \(String(describing: self.settings.codec), privacy: .public)"
        )
        return true
    }

    // MARK: - Audio path (queue-confined)

    private func appendAudio(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        // Video defines t0. Audio that arrives before the first video sample — or that is
        // timestamped before it — has nowhere to go on the session timeline (§5.3).
        guard let sessionStartTime, let input else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard CMTimeCompare(presentationTime, sessionStartTime) >= 0 else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer), input.isReadyForMoreMediaData else { return }
        if !input.append(sampleBuffer) {
            recordWriterFailure()
        }
    }

    // MARK: - Helpers (queue-confined)

    private func recordWriterFailure(message: String? = nil) {
        guard writeFailure == nil else { return }
        let resolved = message
            ?? writer?.error?.localizedDescription
            ?? "録画ファイルへの書き込みに失敗しました。"
        writeFailure = resolved
        Self.log.error("write failure: \(resolved, privacy: .public)")
    }

    private enum FrameHealth {
        /// Contains picture data worth writing.
        case usable
        /// Nothing on screen changed — expected, and not a defect.
        case idle
        /// `.blank`, `.suspended`, `.stopped` and friends: surfaced to the UI as drops.
        case abnormal
    }

    /// Classifies a frame from its `SCStreamFrameInfo` attachment (§5.3). When the
    /// attachment is missing the frame is treated as usable — dropping real footage
    /// because metadata was unavailable would be the worse failure.
    private static func frameHealth(of sampleBuffer: CMSampleBuffer) -> FrameHealth {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus)
        else {
            return .usable
        }
        switch status {
        case .complete:
            return .usable
        // `.started` marks the stream's first frame; it carries picture data and counting
        // it as a drop would show "drops 1" at the top of every recording.
        case .started:
            return .usable
        case .idle:
            return .idle
        default:
            return .abnormal
        }
    }

    /// HEVC 4 Mbps / H.264 8 Mbps at 1080p, scaled linearly by pixel count (§5.3).
    static func videoOutputSettings(width: Int, height: Int, codec: VideoCodec) -> [String: Any] {
        let reference = codec == .hevc ? hevcReferenceBitrate : h264ReferenceBitrate
        let scaled = Double(reference) * Double(width * height) / Double(referencePixelCount)
        let bitrate = max(minimumBitrate, Int(scaled.rounded()))
        return [
            AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate
            ],
        ]
    }

    /// AAC 48 kHz stereo 160 kbps (§5.3).
    private static func makeAudioInput() -> AVAssetWriterInput {
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000,
            ]
        )
        input.expectsMediaDataInRealTime = true
        return input
    }
}
