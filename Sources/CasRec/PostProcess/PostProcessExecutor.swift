@preconcurrency import AVFoundation
import Darwin
import Foundation
import Synchronization

enum PostProcessError: LocalizedError, Sendable {
    case ffmpegUnavailable
    case unsupportedCompressionPreset
    case exportFailed(String)
    case ffmpegFailed(exitCode: Int32, stderr: String)
    case ffmpegTimedOut(timeout: Duration, stderr: String)
    case outputAlreadyExists(URL)

    var errorDescription: String? {
        switch self {
        case .ffmpegUnavailable:
            return "ffmpeg が見つかりません。`brew install ffmpeg` を実行してからもう一度お試しください。"
        case .unsupportedCompressionPreset:
            return "この動画は選択された圧縮プリセットで書き出せません。"
        case .exportFailed(let message):
            return "圧縮に失敗しました: \(message)"
        case .ffmpegFailed(let exitCode, let stderr):
            let summary = stderr.isEmpty ? "stderr はありません" : stderr
            return "ffmpeg が終了コード \(exitCode) で失敗しました: \(summary)"
        case .ffmpegTimedOut(let timeout, let stderr):
            let summary = stderr.isEmpty ? "stderr はありません" : stderr
            return "ffmpeg が \(timeout) 以内に終了しなかったため停止しました: \(summary)"
        case .outputAlreadyExists(let output):
            return "出力先は既に存在します: \(output.lastPathComponent)"
        }
    }
}

/// Dispatches the work types in `PostProcessQueue` to their concrete media tools.
/// Output paths are chosen before enqueueing, so a queued job can never clobber a file
/// created by an earlier job.
struct PostProcessExecutor: Sendable {
    static func defaultExecute(
        job: PostProcessJob,
        reportProgress: @escaping @Sendable (Double?) -> Void
    ) async throws -> URL {
        try await PostProcessExecutor().execute(job: job, reportProgress: reportProgress)
    }

    func execute(
        job: PostProcessJob,
        reportProgress: @escaping @Sendable (Double?) -> Void
    ) async throws -> URL {
        switch job.operation {
        case .compress(let preset):
            return try await Compressor().compress(
                input: job.sourceURL,
                output: job.outputURL,
                preset: preset,
                reportProgress: reportProgress
            )
        case .gif:
            guard let ffmpegURL = FfmpegLocator().locate() else {
                throw PostProcessError.ffmpegUnavailable
            }
            return try await GifConverter(ffmpegURL: ffmpegURL).convert(
                input: job.sourceURL,
                output: job.outputURL,
                reportProgress: reportProgress
            )
        case .recover:
            guard let ffmpegURL = FfmpegLocator().locate() else {
                throw PostProcessError.ffmpegUnavailable
            }
            return try await RecoveryConverter(ffmpegURL: ffmpegURL).recover(
                input: job.sourceURL,
                output: job.outputURL,
                reportProgress: reportProgress
            )
        }
    }
}

/// AVFoundation-only movie compression.  HEVC is intentionally capped at 1080p for a
/// materially smaller file, while H.264 uses the matching broadly-compatible preset.
private struct Compressor: Sendable {
    func compress(
        input: URL,
        output: URL,
        preset: CompressionPreset,
        reportProgress: @escaping @Sendable (Double?) -> Void
    ) async throws -> URL {
        let exportPreset: String = switch preset {
        case .hevc: AVAssetExportPresetHEVC1920x1080
        case .h264: AVAssetExportPreset1920x1080
        }
        let asset = AVURLAsset(url: input)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: exportPreset) else {
            throw PostProcessError.unsupportedCompressionPreset
        }

        let sessionBox = ExportSessionBox(exportSession)
        let progressTask = Task { @Sendable in
            while !Task.isCancelled {
                reportProgress(Double(sessionBox.session.progress) * 100)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { progressTask.cancel() }

        do {
            try await withTaskCancellationHandler {
                try await sessionBox.session.export(to: output, as: .mp4)
            } onCancel: {
                sessionBox.session.cancelExport()
            }
            reportProgress(100)
            return output
        } catch {
            throw PostProcessError.exportFailed(error.localizedDescription)
        }
    }
}

/// AVAssetExportSession is marked non-Sendable by AVFoundation even though this app only
/// reads its documented thread-safe progress value while its own export operation runs.
private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}

/// Runs ffmpeg only through the executable URL returned by `FfmpegLocator`; arguments are
/// passed as an array and no shell is involved.  `-n` in the command builders is the final
/// overwrite safeguard in addition to output-name collision avoidance.
private struct GifConverter: Sendable {
    let ffmpegURL: URL

    func convert(
        input: URL,
        output: URL,
        reportProgress: @escaping @Sendable (Double?) -> Void
    ) async throws -> URL {
        let palette = output.deletingLastPathComponent().appending(
            path: ".casrec-palette-\(UUID().uuidString).png",
            directoryHint: .notDirectory
        )
        let temporaryOutput = PostProcessTemporaryOutput.makeURL(for: output)
        defer {
            PostProcessTemporaryOutput.removeIfPresent(palette)
            PostProcessTemporaryOutput.removeIfPresent(temporaryOutput)
        }

        let policy = FfmpegExecutionPolicy.forMediaDuration(await mediaDuration(of: input))
        let startedAt = ContinuousClock.now
        reportProgress(nil)
        try await FfmpegRunner(executableURL: ffmpegURL, policy: policy).run(
            arguments: FfmpegCommandBuilder.paletteGeneration(input: input, palette: palette)
        )
        let elapsed = startedAt.duration(to: .now)
        guard let remainingPolicy = policy.withRemainingTimeout(after: elapsed) else {
            throw PostProcessError.ffmpegTimedOut(timeout: policy.timeout, stderr: "")
        }
        try await FfmpegRunner(executableURL: ffmpegURL, policy: remainingPolicy).run(
            arguments: FfmpegCommandBuilder.paletteUse(input: input, palette: palette, output: temporaryOutput)
        )
        try PostProcessTemporaryOutput.moveWithoutOverwrite(temporaryOutput, to: output)
        reportProgress(100)
        return output
    }
}

private struct RecoveryConverter: Sendable {
    let ffmpegURL: URL

    func recover(
        input: URL,
        output: URL,
        reportProgress: @escaping @Sendable (Double?) -> Void
    ) async throws -> URL {
        let temporaryOutput = PostProcessTemporaryOutput.makeURL(for: output)
        defer {
            PostProcessTemporaryOutput.removeIfPresent(temporaryOutput)
        }
        reportProgress(nil)
        let policy = FfmpegExecutionPolicy.forMediaDuration(await mediaDuration(of: input))
        try await FfmpegRunner(executableURL: ffmpegURL, policy: policy).run(
            arguments: FfmpegCommandBuilder.remux(input: input, output: temporaryOutput)
        )
        try PostProcessTemporaryOutput.moveWithoutOverwrite(temporaryOutput, to: output)
        reportProgress(100)
        return output
    }
}

private func mediaDuration(of input: URL) async -> TimeInterval? {
    let asset = AVURLAsset(url: input)
    guard let duration = try? await asset.load(.duration),
          duration.isNumeric,
          duration.seconds.isFinite,
          duration.seconds >= 0
    else {
        return nil
    }
    return duration.seconds
}

enum PostProcessTemporaryOutput {
    static func makeURL(for finalOutput: URL) -> URL {
        let fileExtension = finalOutput.pathExtension
        let fileName = ".casrec-output-\(UUID().uuidString)" + (fileExtension.isEmpty ? "" : ".\(fileExtension)")
        return finalOutput.deletingLastPathComponent().appending(path: fileName, directoryHint: .notDirectory)
    }

    static func moveWithoutOverwrite(_ temporaryOutput: URL, to finalOutput: URL) throws {
        let result = temporaryOutput.withUnsafeFileSystemRepresentation { sourcePath in
            finalOutput.withUnsafeFileSystemRepresentation { destinationPath in
                renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            let errorCode = errno
            if errorCode == EEXIST {
                throw PostProcessError.outputAlreadyExists(finalOutput)
            }
            throw POSIXError(POSIXErrorCode(rawValue: errorCode) ?? .EIO)
        }
    }

    static func removeIfPresent(_ temporaryOutput: URL) {
        try? FileManager.default.removeItem(at: temporaryOutput)
    }
}

struct FfmpegExecutionPolicy: Sendable {
    static let minimumTimeout: Duration = .seconds(30 * 60)
    static let maximumTimeout: Duration = .seconds(12 * 60 * 60)

    /// A fallback for callers that do not have media metadata. Production conversion
    /// derives the same finite value through `forMediaDuration(_:)`.
    static let `default` = Self(
        timeout: minimumTimeout,
        terminationGracePeriod: .seconds(2),
        stderrTailLimit: 16 * 1024
    )

    let timeout: Duration
    let terminationGracePeriod: Duration
    let stderrTailLimit: Int

    init(timeout: Duration, terminationGracePeriod: Duration, stderrTailLimit: Int) {
        precondition(timeout > .zero, "ffmpeg timeout must be positive")
        precondition(terminationGracePeriod > .zero, "ffmpeg termination grace period must be positive")
        precondition(stderrTailLimit >= 0, "ffmpeg stderr tail limit cannot be negative")
        self.timeout = timeout
        self.terminationGracePeriod = terminationGracePeriod
        self.stderrTailLimit = stderrTailLimit
    }

    /// Gives ffmpeg two times the source duration, clamped so unknown/short recordings
    /// still get a practical 30 minutes and pathological metadata cannot exceed 12 hours.
    static func forMediaDuration(_ duration: TimeInterval?) -> Self {
        let candidate: Duration
        if let duration, duration.isFinite, duration >= 0 {
            candidate = .seconds(duration * 2)
        } else {
            candidate = minimumTimeout
        }
        return Self(
            timeout: min(max(candidate, minimumTimeout), maximumTimeout),
            terminationGracePeriod: .seconds(2),
            stderrTailLimit: 16 * 1024
        )
    }

    func withRemainingTimeout(after elapsed: Duration) -> Self? {
        let remaining = timeout - elapsed
        guard remaining > .zero else { return nil }
        return Self(
            timeout: remaining,
            terminationGracePeriod: terminationGracePeriod,
            stderrTailLimit: stderrTailLimit
        )
    }
}

/// Runs ffmpeg with finite execution, cancellation, and bounded diagnostics.  Every
/// mutable Process/FileHandle reference is serialized by `state`; the lock is never held
/// while waiting for child termination.
struct FfmpegRunner: Sendable {
    let executableURL: URL
    let policy: FfmpegExecutionPolicy

    init(executableURL: URL, policy: FfmpegExecutionPolicy = .default) {
        self.executableURL = executableURL
        self.policy = policy
    }

    func run(arguments: [String]) async throws {
        let controller = FfmpegProcessController(policy: policy)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                controller.start(executableURL: executableURL, arguments: arguments, continuation: continuation)
            }
        } onCancel: {
            controller.cancel()
        }
    }
}

private final class FfmpegProcessController: @unchecked Sendable {
    private enum StopReason {
        case cancelled
        case timedOut
    }

    private struct State {
        var process: Process?
        var stderrReader: FileHandle?
        var continuation: CheckedContinuation<Void, Error>?
        var timeoutTask: Task<Void, Never>?
        var stopReason: StopReason?
        var escalationScheduled = false
        var finished = false
        var stderrTail = Data()
    }

    private let policy: FfmpegExecutionPolicy
    private let state = Mutex(State())

    init(policy: FfmpegExecutionPolicy) {
        self.policy = policy
    }

    func start(
        executableURL: URL,
        arguments: [String],
        continuation: CheckedContinuation<Void, Error>
    ) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice

        let stderr = Pipe()
        let stderrReader = stderr.fileHandleForReading
        process.standardError = stderr
        stderrReader.readabilityHandler = { [weak self] handle in
            self?.appendStderr(handle.availableData)
        }
        process.terminationHandler = { [self] terminatedProcess in
            finish(process: terminatedProcess)
        }

        state.withLock { current in
            current.process = process
            current.stderrReader = stderrReader
            current.continuation = continuation
        }

        do {
            try process.run()
        } catch {
            stderrReader.readabilityHandler = nil
            complete(with: .failure(error))
            return
        }

        let timeoutTask = Task.detached(priority: .utility) { [weak self, policy] in
            do {
                try await Task.sleep(for: policy.timeout)
            } catch {
                return
            }
            self?.stop(reason: .timedOut)
        }
        let cancelTimeout = state.withLock { current -> Bool in
            guard !current.finished else { return true }
            current.timeoutTask = timeoutTask
            return false
        }
        if cancelTimeout {
            timeoutTask.cancel()
        }
        terminateIfStopping()
    }

    func cancel() {
        stop(reason: .cancelled)
    }

    private func stop(reason: StopReason) {
        let shouldTerminate = state.withLock { current -> Bool in
            guard !current.finished, current.stopReason == nil else { return false }
            current.stopReason = reason
            return true
        }
        if shouldTerminate {
            terminateIfStopping()
        }
    }

    private func terminateIfStopping() {
        let process = state.withLock { current -> Process? in
            guard !current.finished, current.stopReason != nil else { return nil }
            return current.process
        }
        guard let process, process.isRunning else { return }

        process.terminate()
        scheduleEscalation(for: process.processIdentifier)
    }

    private func scheduleEscalation(for processID: Int32) {
        let shouldSchedule = state.withLock { current -> Bool in
            guard !current.finished, !current.escalationScheduled else { return false }
            current.escalationScheduled = true
            return true
        }
        guard shouldSchedule else { return }

        Task.detached(priority: .utility) { [weak self, policy] in
            do {
                try await Task.sleep(for: policy.terminationGracePeriod)
            } catch {
                return
            }
            self?.forceKillIfStillRunning(processID: processID)
        }
    }

    private func forceKillIfStillRunning(processID: Int32) {
        state.withLock { current in
            guard !current.finished,
                  let process = current.process,
                  process.processIdentifier == processID,
                  process.isRunning
            else {
                return
            }
            _ = Darwin.kill(processID, SIGKILL)
        }
    }

    private func finish(process: Process) {
        let stderrReader = state.withLock { current -> FileHandle? in
            guard !current.finished, current.process === process else { return nil }
            return current.stderrReader
        }
        guard let stderrReader else { return }
        stderrReader.readabilityHandler = nil
        drainStderrAfterExit(from: stderrReader)

        let result = state.withLock { current -> Result<Void, Error>? in
            guard !current.finished, current.process === process else { return nil }
            let stderr = Self.summary(of: String(data: current.stderrTail, encoding: .utf8) ?? "")
            let result: Result<Void, Error>
            switch current.stopReason {
            case .cancelled:
                result = .failure(CancellationError())
            case .timedOut:
                result = .failure(PostProcessError.ffmpegTimedOut(timeout: policy.timeout, stderr: stderr))
            case nil where process.terminationStatus == 0:
                result = .success(())
            case nil:
                result = .failure(PostProcessError.ffmpegFailed(exitCode: process.terminationStatus, stderr: stderr))
            }
            return result
        }
        guard let result else { return }
        complete(with: result)
    }

    private func drainStderrAfterExit(from reader: FileHandle) {
        while true {
            let chunk = reader.availableData
            guard !chunk.isEmpty else { return }
            appendStderr(chunk)
        }
    }

    private func appendStderr(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        state.withLock { current in
            current.stderrTail.append(chunk)
            let excess = current.stderrTail.count - policy.stderrTailLimit
            if excess > 0 {
                current.stderrTail.removeFirst(excess)
            }
        }
    }

    private func complete(with result: Result<Void, Error>) {
        let completion = state.withLock { current -> (CheckedContinuation<Void, Error>?, Task<Void, Never>?) in
            guard !current.finished else { return (nil, nil) }
            current.finished = true
            let continuation = current.continuation
            let timeoutTask = current.timeoutTask
            current.process = nil
            current.stderrReader = nil
            current.continuation = nil
            current.timeoutTask = nil
            return (continuation, timeoutTask)
        }
        completion.1?.cancel()
        completion.0?.resume(with: result)
    }

    private static func summary(of stderr: String) -> String {
        let collapsed = stderr.split(whereSeparator: \.isNewline).suffix(3).joined(separator: " ")
        return String(collapsed.prefix(600))
    }
}
