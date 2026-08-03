import Foundation
import OSLog
import Synchronization

/// How much room is left on the volume a recording is being written to.
enum DiskSpaceStatus: Sendable, Equatable {
    case normal(availableBytes: Int64)
    /// Below 5 GB — the UI should warn, but recording continues.
    case warning(availableBytes: Int64)
    /// Below 2 GB — the session must stop through `finishing` while there is still room
    /// to close the file cleanly.
    case critical(availableBytes: Int64)

    var availableBytes: Int64 {
        switch self {
        case .normal(let bytes), .warning(let bytes), .critical(let bytes):
            return bytes
        }
    }
}

/// The two ambient hazards of a multi-hour unattended recording (DESIGN.md §5.4, R9):
/// the Mac going to sleep, and the disk filling up.
///
/// Sleep prevention is held for exactly as long as the activity is alive, and the caller
/// must keep it alive until `finishWriting` returns — finalizing a two-hour movie is not
/// instant, and sleeping partway through is precisely the failure this guards against.
///
/// `@unchecked Sendable` is sound because every stored property lives inside `state`, a
/// `Mutex`; the activity token is opaque and only ever handed back to `ProcessInfo` from
/// inside that lock.
final class SessionGuards: @unchecked Sendable {
    /// Warn below 5 GB (§5.4).
    static let warningThreshold: Int64 = 5 * 1024 * 1024 * 1024
    /// Force a clean stop below 2 GB (§5.4).
    static let criticalThreshold: Int64 = 2 * 1024 * 1024 * 1024
    /// Poll cadence (§5.4).
    static let pollInterval: Duration = .seconds(30)

    private static let log = Logger(subsystem: "dev.toshi0607.casrec", category: "guards")

    /// `beginActivity` hands back an opaque, non-`Sendable` token. Wrapping it makes it
    /// storable inside the `Mutex`; the wrapper is sound because the token is never
    /// inspected or mutated — it is only handed straight back to `endActivity`. `stop()`
    /// claims it and clears it in one `withLock`, so however many callers race, exactly one
    /// of them ends up with the token and the activity is never ended twice.
    private struct ActivityToken: @unchecked Sendable {
        let value: any NSObjectProtocol
    }

    private struct State {
        var activityToken: ActivityToken?
        var monitor: Task<Void, Never>?
        var observers: [UUID: AsyncStream<DiskSpaceStatus>.Continuation] = [:]
    }

    private let state = Mutex(State())

    /// Disk-space updates for the current recording. Each call returns an independent
    /// stream; `stop()` finishes them all, so a consumer's `for await` loop always ends.
    ///
    /// Only the newest reading is buffered — free space is a level, not a series of
    /// events, and a stale one is of no use to anybody.
    func observeDiskSpace() -> AsyncStream<DiskSpaceStatus> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<DiskSpaceStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        state.withLock { $0.observers[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.observers.removeValue(forKey: id) }
        }
        return stream
    }

    /// Suppresses idle display and system sleep (and App Nap) and begins polling the
    /// volume that holds `destinationDirectory`. Idempotent.
    func start(monitoring destinationDirectory: URL) {
        let alreadyRunning = state.withLock { $0.activityToken != nil }
        guard !alreadyRunning else { return }

        let token = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .userInitiated],
            reason: "CasRec is recording"
        )
        state.withLock { current in
            current.activityToken = ActivityToken(value: token)
            current.monitor = Task { [self] in
                await runDiskMonitor(at: destinationDirectory)
            }
        }
        Self.log.info("sleep prevention engaged; monitoring disk space")
    }

    /// Ends the activity, stops polling, and closes the disk-space streams. Idempotent.
    ///
    /// Call this only after `finishWriting` has returned, so sleep stays suppressed for
    /// the whole finalize.
    func stop() {
        let teardown = state.withLock { current -> (token: ActivityToken?, monitor: Task<Void, Never>?, observers: [AsyncStream<DiskSpaceStatus>.Continuation]) in
            let token = current.activityToken
            let monitor = current.monitor
            let observers = Array(current.observers.values)
            current.activityToken = nil
            current.monitor = nil
            current.observers.removeAll()
            return (token, monitor, observers)
        }

        teardown.monitor?.cancel()
        if let token = teardown.token {
            ProcessInfo.processInfo.endActivity(token.value)
            Self.log.info("sleep prevention released")
        }
        for observer in teardown.observers {
            observer.finish()
        }
    }

    // MARK: - Disk monitoring

    private func runDiskMonitor(at directory: URL) async {
        while !Task.isCancelled {
            if let status = Self.diskSpaceStatus(at: directory) {
                broadcast(status)
                if case .critical(let bytes) = status {
                    Self.log.error("disk critically low (\(bytes) bytes); stopping poll")
                    // The session is about to finalize; further polling adds nothing.
                    return
                }
            }
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    private func broadcast(_ status: DiskSpaceStatus) {
        let observers = state.withLock { Array($0.observers.values) }
        for observer in observers {
            observer.yield(status)
        }
    }

    /// Free space on the volume backing `directory`, or `nil` when it cannot be read —
    /// which happens when the destination volume has been unplugged. That case surfaces
    /// as a write failure from the writer rather than as a disk-space reading.
    static func diskSpaceStatus(at directory: URL) -> DiskSpaceStatus? {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return nil }
        if available < criticalThreshold {
            return .critical(availableBytes: available)
        }
        if available < warningThreshold {
            return .warning(availableBytes: available)
        }
        return .normal(availableBytes: available)
    }
}
