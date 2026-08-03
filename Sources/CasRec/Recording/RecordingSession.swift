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

    /// How long `finalize` waits for the capture stream to stop before writing the file out
    /// regardless. `stopCapture()` normally returns in milliseconds; the bound exists so a
    /// wedged `SCStream` cannot hold `finishWriting` hostage (§4).
    static let stopCaptureTimeout: Duration = .seconds(5)

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
    ///
    /// Only the newest state is buffered: this is a state feed, not an event log, and a
    /// consumer that falls behind wants where the session is now, not a queue of ticks it
    /// has to walk through to find out.
    func observeState() -> AsyncStream<RecordingState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<RecordingState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.observers.removeValue(forKey: id) }
        }
        state.withLock { current in
            current.observers[id] = continuation
            // Yielded under the same lock that registers the continuation, not after it.
            // An `emit` that gets the lock first cannot see this continuation at all, and
            // one that gets it second cannot run until this yield is done — so the newer
            // state always arrives second. Outside the lock, an `emit` landing in between
            // would deliver the new state first and `.bufferingNewest(1)` would keep the
            // stale one, pinning the subscriber to a state the session has already left.
            continuation.yield(current.lastState)
        }
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
            // This can be self-cancellation: the ticker finalizes the session itself when
            // it sees a latched write failure. Harmless, because everything `finalize`
            // awaits from here on is cancellation-immune by construction — see
            // `stopCaptureWithinTimeout`, which exists for exactly this reason. The capture
            // and disk observers can equally be the caller; they are cancelled at the end
            // of the teardown instead, where nothing is left to await at all.
            current.ticker?.cancel()
            current.ticker = nil
            return (current.writer, current.artifacts)
        }
        guard let (writer, artifacts) = claimed else { return }
        emit(.finishing)

        await stopCaptureWithinTimeout()
        let result = await writer?.finish() ?? .nothingRecorded
        // Only now: finalizing a long recording takes time, and sleeping through it is
        // the failure this whole layer exists to prevent (§5.4).
        guards.stop()

        let recordingRemains: Bool
        switch result {
        case .finalized:
            // The sidecar means "not finalized"; the file now is, whatever ended the
            // session, so the badge must not linger on a healthy recording (§5.5).
            artifacts?.removeSidecar()
            recordingRemains = true
        case .nothingRecorded:
            let discarded = artifacts?.discardIfEmpty() ?? true
            recordingRemains = Self.hasSavedRecording(artifacts, afterDiscardingEmpty: discarded)
        case .failed:
            // A .mov with fragments in it is kept, sidecar included — that pair is what the
            // repair flow looks for (§5.5). A failure that produced no bytes at all (an
            // encoder that never initialised) leaves nothing to repair, only a sidecar that
            // would masquerade as an unfinalized recording, so that pair goes.
            let discarded = artifacts?.discardIfEmpty() ?? true
            recordingRemains = Self.hasSavedRecording(artifacts, afterDiscardingEmpty: discarded)
        }

        // The session is over; nothing is left for these to observe. Claimed now rather
        // than at the top of `finalize` because either of them can be the caller, and both
        // are past their last suspension point by the time control gets here.
        let observers = state.withLock { current -> [Task<Void, Never>] in
            current.writer = nil
            current.artifacts = nil
            current.startedAt = nil
            let ended = [current.captureEndedObserver, current.diskObserver].compactMap { $0 }
            current.captureEndedObserver = nil
            current.diskObserver = nil
            return ended
        }
        // Outside the lock: cancelling runs the streams' termination handlers inline, and
        // those take locks of their own (`SessionGuards`').
        for observer in observers {
            observer.cancel()
        }

        if let message = Self.failureMessage(
            reason: reason,
            result: result,
            recordingRemains: recordingRemains
        ) {
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

    /// Stops the capture, but never waits longer than `stopCaptureTimeout`.
    ///
    /// The §4 invariant is that every exit from `recording` reaches `finishWriting`, and an
    /// unbounded wait here is the one thing that can break it: a stream that never returns
    /// would leave the session in `finishing` forever, taking ⌘Q down with it (§5.4).
    /// Giving up is safe — `AssetWriterCoordinator.finish()` marks itself finishing before
    /// closing the file, so a sample from a still-running stream is discarded, not appended.
    ///
    /// The race runs inside its own task on purpose: `finalize` is reachable from a task
    /// that has just been cancelled (the ticker cancels itself on its way in), and
    /// `AsyncStream` iteration ends immediately under cancellation, which would collapse the
    /// timeout to zero.
    private func stopCaptureWithinTimeout() async {
        let stoppedInTime = await Task { [captureService] () -> Bool in
            let (outcome, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
            Task {
                await captureService.stopCapture()
                continuation.yield(true)
            }
            let deadline = Task {
                try? await Task.sleep(for: Self.stopCaptureTimeout)
                guard !Task.isCancelled else { return }
                continuation.yield(false)
            }
            var stopped = false
            for await value in outcome {
                stopped = value
                break
            }
            deadline.cancel()
            return stopped
        }.value

        if !stoppedInTime {
            Self.log.error("capture did not stop within the timeout; finalizing the file anyway")
        }
    }

    /// `nil` when the session ended normally; otherwise what the user needs to be told.
    private static func failureMessage(
        reason: EndReason,
        result: RecordingFinishResult,
        recordingRemains: Bool
    ) -> String? {
        if case .failed(let message) = result {
            return "録画の保存中にエラーが発生しました: \(message)\(recordingAvailabilityMessage(recordingRemains))"
        }
        switch reason {
        case .manual, .sourceEnded:
            return nil
        case .streamFailed(let message):
            return "画面キャプチャが停止しました: \(message)\(recordingAvailabilityMessage(recordingRemains))"
        case .diskCritical:
            return "ディスクの空き容量が2GB未満になったため録画を停止しました。\(recordingAvailabilityMessage(recordingRemains))"
        case .writeFailed(let message):
            return "録画ファイルへの書き込みができなくなったため停止しました: \(message)\(recordingAvailabilityMessage(recordingRemains))"
        }
    }

    private static func recordingAvailabilityMessage(_ recordingRemains: Bool) -> String {
        recordingRemains
            ? "\nそこまでの録画は保存されています。"
            : "\n録画ファイルを保存できませんでした。"
    }

    /// A failed attempt to remove a zero-byte placeholder must not be presented as a
    /// partially saved recording. The removal result alone cannot tell those two cases
    /// apart, so the on-disk byte count remains the authority.
    private static func hasSavedRecording(
        _ artifacts: RecordingArtifacts?,
        afterDiscardingEmpty discarded: Bool
    ) -> Bool {
        !discarded && (artifacts?.bytesWritten ?? 0) > 0
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
            audioAppendFailures: stats.audioAppendFailures,
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
