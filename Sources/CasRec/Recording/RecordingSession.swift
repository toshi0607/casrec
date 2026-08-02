import Foundation
import OSLog
import Synchronization

/// Owns one recording's lifecycle: the state machine of DESIGN.md §4, the artifacts on
/// disk, and the guards that keep a long unattended recording alive.
///
/// ```
/// idle -> preparing -> recording -> finishing -> idle
///           |                                 \-> failed -> idle
///           \-> failed -> idle
/// ```
///
/// The invariant this type exists to uphold: **every exit from `recording` runs
/// `finishWriting`.** Manual stop, the target window disappearing (R10), a stream error,
/// and the disk running out all converge on `finalize(reason:)`, which claims the
/// transition atomically so exactly one of them performs the teardown while the others
/// become no-ops.
///
/// ## Thread safety
///
/// `RecordingSessionControlling` is a non-isolated protocol, and this type stays
/// non-isolated with it: the capture callbacks it coordinates arrive on ScreenCaptureKit's
/// own queues, so hopping everything onto an actor would buy nothing. Instead all mutable
/// state lives in `state`, a `Mutex`, and the lock is never held across an `await`. State
/// transitions are compare-and-set operations inside a single `withLock`, which is what
/// makes the concurrent stop paths safe without an actor. The `@unchecked Sendable`
/// conformance rests on that, plus `captureService`, whose calls this type serialises
/// through the same state machine (at most one `startCapture`/`stopCapture` is in flight).
final class RecordingSession: RecordingSessionControlling, @unchecked Sendable {
    /// A recording is considered stalled when no video sample has arrived for this long
    /// (§5.3). The likeliest cause is the target window being minimised (§9).
    static let stallThreshold: TimeInterval = 10

    private static let log = Logger(subsystem: "dev.toshi0607.casrec", category: "session")

    /// The state machine's position, without the per-tick payload of `RecordingState`.
    private enum Phase {
        case idle
        case preparing
        case recording
        case finishing
        case failed
    }

    /// Why a recording left the `recording` state. Determines the terminal state and the
    /// message the user sees.
    private enum EndReason {
        /// The stop button (§4).
        case manual
        /// The captured window or display went away — a normal ending, not an error (R10).
        case sourceEnded
        /// The capture stream itself failed.
        case streamFailed(String)
        /// Free space fell below 2 GB (§5.4).
        case diskCritical
        /// The writer entered a terminal failure state; continuing would record nothing.
        case writeFailed(String)
    }

    private struct State {
        var phase: Phase = .idle
        var lastState: RecordingState = .idle
        var startedAt: Date?
        /// Latched by the disk observer below 5 GB, cleared when space recovers (§5.4).
        var diskWarning = false
        var writer: AssetWriterCoordinator?
        var artifacts: RecordingArtifacts?
        var ticker: Task<Void, Never>?
        var captureEndedObserver: Task<Void, Never>?
        var diskObserver: Task<Void, Never>?
        var observers: [UUID: AsyncStream<RecordingState>.Continuation] = [:]
    }

    private let captureService: any CaptureServicing
    private let guards: SessionGuards
    private let state = Mutex(State())

    init(captureService: any CaptureServicing, guards: SessionGuards = SessionGuards()) {
        self.captureService = captureService
        self.guards = guards
    }

    // MARK: - RecordingSessionControlling

    /// Each call returns an independent stream, and every new subscriber immediately
    /// receives the current state — so a view that re-subscribes (or subscribes late)
    /// never sits on a blank screen waiting for the next tick.
    func observeState() -> AsyncStream<RecordingState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<RecordingState>.makeStream()
        let current = state.withLock { current -> RecordingState in
            current.observers[id] = continuation
            return current.lastState
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.observers.removeValue(forKey: id) }
        }
        continuation.yield(current)
        return stream
    }

    func start(source: CaptureSource, settings: RecordingSettings) async {
        let claimed = state.withLock { current -> Bool in
            guard case .idle = current.phase else { return false }
            current.phase = .preparing
            current.diskWarning = false
            // Any observer left over from a previous session that never terminated.
            current.captureEndedObserver?.cancel()
            current.captureEndedObserver = nil
            current.diskObserver?.cancel()
            current.diskObserver = nil
            current.ticker?.cancel()
            current.ticker = nil
            return true
        }
        guard claimed else {
            Self.log.notice("start ignored: a session is already in progress")
            return
        }
        emit(.preparing)

        // Read out of the non-Sendable `CaptureSource` immediately so nothing but plain
        // values is retained past this point.
        let displayName = RecordingArtifacts.displayName(for: source)

        let artifacts: RecordingArtifacts
        let writer: AssetWriterCoordinator
        do {
            artifacts = try RecordingArtifacts.create(
                displayName: displayName,
                in: settings.destinationDirectory,
                at: Date()
            )
            writer = try AssetWriterCoordinator(outputURL: artifacts.outputURL, settings: settings)
        } catch {
            fail(message: "保存先を準備できませんでした: \(error.localizedDescription)")
            return
        }

        state.withLock { current in
            current.artifacts = artifacts
            current.writer = writer
        }

        // Subscribe before starting, so an event fired during start-up is buffered rather
        // than missed.
        let diskSpace = guards.observeDiskSpace()
        let captureEnded = captureService.observeCaptureEnded()
        guards.start(monitoring: settings.destinationDirectory)

        do {
            try await captureService.startCapture(source: source, settings: settings, sink: writer)
        } catch {
            // Nothing was captured, so there is nothing to finalize or repair: close the
            // writer, drop the empty file, and release the guards.
            _ = await writer.finish()
            guards.stop()
            artifacts.discardIfEmpty()
            state.withLock { current in
                current.writer = nil
                current.artifacts = nil
            }
            fail(message: "録画を開始できませんでした: \(error.localizedDescription)")
            return
        }

        let startedAt = Date()
        state.withLock { current in
            current.phase = .recording
            current.startedAt = startedAt
            current.ticker = Task { [self] in await runTicker() }
            current.captureEndedObserver = Task { [self] in
                for await reason in captureEnded {
                    switch reason {
                    case .sourceEnded:
                        Self.log.notice("capture source ended; finalizing")
                        await finalize(reason: .sourceEnded)
                    case .failed(let message):
                        Self.log.error("capture failed: \(message, privacy: .public)")
                        await finalize(reason: .streamFailed(message))
                    }
                    break
                }
            }
            current.diskObserver = Task { [self] in
                for await status in diskSpace {
                    switch status {
                    case .normal:
                        setDiskWarning(false)
                    case .warning:
                        setDiskWarning(true)
                    case .critical:
                        await finalize(reason: .diskCritical)
                        return
                    }
                }
            }
        }
        Self.log.info("recording \(artifacts.outputURL.lastPathComponent, privacy: .public)")
        emitProgress()
    }

    func stop() async {
        await finalize(reason: .manual)
    }

    /// Clears a `failed` state once the UI has shown the message, returning the session to
    /// `idle` so a new recording can start — the `failed -> idle` edge of §4. Synchronous
    /// because it is only a lock-guarded transition; it satisfies the protocol's `async`
    /// requirement unchanged.
    func acknowledgeFailure() {
        let cleared = state.withLock { current -> Bool in
            guard case .failed = current.phase else { return false }
            current.phase = .idle
            current.lastState = .idle
            return true
        }
        if cleared { emit(.idle) }
    }

    // MARK: - Termination

    /// The single exit from `recording`. Whoever claims the transition performs the whole
    /// teardown; concurrent callers return immediately.
    private func finalize(reason: EndReason) async {
        let claimed = state.withLock { current -> (AssetWriterCoordinator?, RecordingArtifacts?)? in
            guard case .recording = current.phase else { return nil }
            current.phase = .finishing
            // Safe to cancel: the ticker never calls finalize, so this is never self-
            // cancellation. The capture and disk observers are left alone precisely
            // because they *can* be the caller; both break out on their own.
            current.ticker?.cancel()
            current.ticker = nil
            return (current.writer, current.artifacts)
        }
        guard let (writer, artifacts) = claimed else { return }
        emit(.finishing)

        await captureService.stopCapture()
        let result = await writer?.finish() ?? .nothingRecorded
        // Only now: finalizing a long recording takes time, and sleeping through it is
        // the failure this whole layer exists to prevent (§5.4).
        guards.stop()

        switch result {
        case .finalized:
            // The sidecar means "not finalized"; the file now is, whatever ended the
            // session, so the badge must not linger on a healthy recording (§5.5).
            artifacts?.removeSidecar()
        case .nothingRecorded:
            artifacts?.discardIfEmpty()
        case .failed:
            // Leave the .mov and its sidecar in place — that pair is what the repair flow
            // looks for (§5.5).
            break
        }

        state.withLock { current in
            current.writer = nil
            current.artifacts = nil
            current.startedAt = nil
        }

        if let message = Self.failureMessage(reason: reason, result: result) {
            fail(message: message, from: .finishing)
        } else {
            state.withLock { current in
                current.phase = .idle
                current.lastState = .idle
            }
            Self.log.info("session finished cleanly")
            emit(.idle)
        }
    }

    /// `nil` when the session ended normally; otherwise what the user needs to be told.
    private static func failureMessage(reason: EndReason, result: RecordingFinishResult) -> String? {
        if case .failed(let message) = result {
            return "録画の保存中にエラーが発生しました: \(message)\n書き込み済みの部分はライブラリに残っています。"
        }
        switch reason {
        case .manual, .sourceEnded:
            return nil
        case .streamFailed(let message):
            return "画面キャプチャが停止しました: \(message)\nそこまでの録画は保存されています。"
        case .diskCritical:
            return "ディスクの空き容量が2GB未満になったため録画を停止しました。そこまでの録画は保存されています。"
        case .writeFailed(let message):
            return "録画ファイルへの書き込みができなくなったため停止しました: \(message)\nそこまでの録画は保存されています。"
        }
    }

    // MARK: - Progress

    private func runTicker() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            // A writer that has failed can never accept another sample, so stop here and
            // save what already reached disk rather than record nothing for an hour.
            if let failure = currentWriteFailure() {
                await finalize(reason: .writeFailed(failure))
                return
            }
            emitProgress()
        }
    }

    private func currentWriteFailure() -> String? {
        let writer = state.withLock { current -> AssetWriterCoordinator? in
            guard case .recording = current.phase else { return nil }
            return current.writer
        }
        return writer?.stats.writeFailure
    }

    /// Records the 5 GB warning and republishes at once, so the banner appears when the
    /// poll observes it rather than up to a tick later.
    private func setDiskWarning(_ warning: Bool) {
        let changed = state.withLock { current -> Bool in
            guard current.diskWarning != warning else { return false }
            current.diskWarning = warning
            return true
        }
        if changed { emitProgress() }
    }

    private func emitProgress() {
        let context = state.withLock { current -> (Date, AssetWriterCoordinator, Bool)? in
            guard case .recording = current.phase,
                  let startedAt = current.startedAt,
                  let writer = current.writer
            else { return nil }
            return (startedAt, writer, current.diskWarning)
        }
        guard let (startedAt, writer, diskWarning) = context else { return }

        let stats = writer.stats
        // Before the first frame arrives, measure the stall from the session start.
        let lastActivity = stats.lastVideoSampleAt ?? startedAt
        let progress = RecordingProgress(
            startedAt: startedAt,
            bytesWritten: stats.bytesWritten,
            droppedFrames: stats.droppedFrames,
            isStalled: Date().timeIntervalSince(lastActivity) > Self.stallThreshold,
            diskWarning: diskWarning
        )

        // Re-check the phase while publishing so a tick that raced with `finalize` cannot
        // push a stale `.recording` after `.finishing`.
        let observers = state.withLock { current -> [AsyncStream<RecordingState>.Continuation] in
            guard case .recording = current.phase else { return [] }
            current.lastState = .recording(progress)
            return Array(current.observers.values)
        }
        for observer in observers {
            observer.yield(.recording(progress))
        }
    }

    // MARK: - State publishing

    private func fail(message: String, from expected: Phase = .preparing) {
        let changed = state.withLock { current -> Bool in
            switch (current.phase, expected) {
            case (.preparing, .preparing), (.finishing, .finishing):
                current.phase = .failed
                current.lastState = .failed(message: message)
                return true
            default:
                return false
            }
        }
        guard changed else { return }
        Self.log.error("session failed: \(message, privacy: .public)")
        emit(.failed(message: message))
    }

    private func emit(_ newState: RecordingState) {
        let observers = state.withLock { current -> [AsyncStream<RecordingState>.Continuation] in
            current.lastState = newState
            return Array(current.observers.values)
        }
        for observer in observers {
            observer.yield(newState)
        }
    }
}
