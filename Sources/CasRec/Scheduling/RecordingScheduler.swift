import Foundation

/// A scheduled recording keeps a value snapshot of the user's selection.  In particular,
/// `RecordingSettings` includes the crop rectangle, so later edits in the UI cannot change
/// a reservation that is already waiting.
struct ScheduledRecording: Sendable, Identifiable {
    let id: UUID
    let startAt: Date
    let source: CaptureSource
    let settings: RecordingSettings
    let maximumDuration: TimeInterval?

    init(
        id: UUID = UUID(),
        startAt: Date,
        source: CaptureSource,
        settings: RecordingSettings,
        maximumDuration: TimeInterval?
    ) {
        self.id = id
        self.startAt = startAt
        self.source = source
        self.settings = settings
        self.maximumDuration = maximumDuration
    }
}

enum RecordingScheduleEvent: Sendable {
    case skippedBecauseSessionWasNotIdle(RecordingState)
    case couldNotStart(message: String)
}

enum ScheduledRecordingStartResult: Sendable {
    case started
    case couldNotStart(message: String)
}

/// The two wall-clock operations used by `RecordingScheduler`.  Keeping them injectable
/// makes scheduling deterministic in tests and avoids tests that wait in real time.
struct SchedulingClock: Sendable {
    let now: @Sendable () -> Date
    let sleepUntil: @Sendable (Date) async throws -> Void

    static let live = SchedulingClock(
        now: Date.init,
        sleepUntil: { date in
            let interval = date.timeIntervalSinceNow
            guard interval > 0 else { return }
            try await Task.sleep(for: .seconds(interval))
        }
    )
}

/// Owns one pending recording reservation and its optional post-start stop timer.
///
/// It deliberately knows nothing about SwiftUI, ScreenCaptureKit, or recording internals:
/// callers supply the state check and the operation that resolves a fresh source and starts
/// a recording.  This keeps timer cancellation, replacement, and auto-stop testable.
actor RecordingScheduler {
    typealias StateProvider = @Sendable () async -> RecordingState
    typealias StartAction = @Sendable (ScheduledRecording) async -> ScheduledRecordingStartResult
    typealias StopAction = @Sendable () async -> Void

    private struct PendingReservation {
        let reservation: ScheduledRecording
        let stateProvider: StateProvider
        let start: StartAction
        let stop: StopAction
        var firingTask: Task<Void, Never>?
    }

    private let clock: SchedulingClock
    private var pending: PendingReservation?
    private var autoStopTasks: [UUID: Task<Void, Never>] = [:]
    private var reservationContinuations: [UUID: AsyncStream<ScheduledRecording?>.Continuation] = [:]
    private var eventContinuations: [UUID: AsyncStream<RecordingScheduleEvent>.Continuation] = [:]

    init(clock: SchedulingClock = .live) {
        self.clock = clock
    }

    /// Replaces an existing reservation.  The previous timer is cancelled before the new
    /// reservation becomes observable, so only the newest reservation can fire.
    func schedule(
        _ reservation: ScheduledRecording,
        stateProvider: @escaping StateProvider,
        start: @escaping StartAction,
        stop: @escaping StopAction
    ) {
        cancelPendingReservation()
        pending = PendingReservation(
            reservation: reservation,
            stateProvider: stateProvider,
            start: start,
            stop: stop,
            firingTask: nil
        )
        publishReservation(reservation)

        let reservationID = reservation.id
        let firingTask = Task { [weak self] in
            guard let self else { return }
            await self.waitAndFire(reservationID: reservationID)
        }
        pending?.firingTask = firingTask
    }

    func cancel() {
        cancelPendingReservation()
    }

    func observeReservation() -> AsyncStream<ScheduledRecording?> {
        let (stream, continuation) = AsyncStream<ScheduledRecording?>.makeStream()
        let continuationID = UUID()
        reservationContinuations[continuationID] = continuation
        continuation.yield(pending?.reservation)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeReservationContinuation(continuationID) }
        }
        return stream
    }

    func observeEvents() -> AsyncStream<RecordingScheduleEvent> {
        let (stream, continuation) = AsyncStream<RecordingScheduleEvent>.makeStream()
        let continuationID = UUID()
        eventContinuations[continuationID] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEventContinuation(continuationID) }
        }
        return stream
    }

    private func waitAndFire(reservationID: UUID) async {
        guard let reservation = pending?.reservation, reservation.id == reservationID else { return }
        do {
            try await clock.sleepUntil(reservation.startAt)
        } catch {
            return // cancellation is normal when a reservation is replaced or cancelled.
        }

        guard let pending, pending.reservation.id == reservationID else { return }
        self.pending = nil
        publishReservation(nil)

        let state = await pending.stateProvider()
        guard state == .idle else {
            publishEvent(.skippedBecauseSessionWasNotIdle(state))
            return
        }

        let startedAt = clock.now()
        switch await pending.start(pending.reservation) {
        case .started:
            if let maximumDuration = pending.reservation.maximumDuration {
                scheduleAutoStop(
                    reservationID: reservationID,
                    at: startedAt.addingTimeInterval(maximumDuration),
                    stop: pending.stop
                )
            }
        case .couldNotStart(let message):
            publishEvent(.couldNotStart(message: message))
        }
    }

    private func scheduleAutoStop(reservationID: UUID, at stopAt: Date, stop: @escaping StopAction) {
        let task = Task { [weak self, clock] in
            do {
                try await clock.sleepUntil(stopAt)
            } catch {
                return
            }
            await stop()
            guard let self else { return }
            await self.removeAutoStopTask(reservationID)
        }
        autoStopTasks[reservationID] = task
    }

    private func cancelPendingReservation() {
        pending?.firingTask?.cancel()
        pending = nil
        publishReservation(nil)
    }

    private func publishReservation(_ reservation: ScheduledRecording?) {
        for continuation in reservationContinuations.values {
            continuation.yield(reservation)
        }
    }

    private func publishEvent(_ event: RecordingScheduleEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func removeReservationContinuation(_ id: UUID) {
        reservationContinuations[id] = nil
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations[id] = nil
    }

    private func removeAutoStopTask(_ id: UUID) {
        autoStopTasks[id] = nil
    }
}

/// Resolves a snapshot source against a newly enumerated source list.  Window IDs can
/// change between reservation and firing, hence the progressively weaker fallbacks.
enum CaptureSourceResolver {
    static func resolve(saved source: CaptureSource, in currentSources: [CaptureSource]) -> CaptureSource? {
        if let exactMatch = currentSources.first(where: { $0.id == source.id }) {
            return exactMatch
        }
        guard source.kind == .window, let appName = source.appName else { return nil }
        if let titleMatch = currentSources.first(where: {
            $0.kind == .window && $0.appName == appName && $0.title == source.title
        }) {
            return titleMatch
        }
        return currentSources.first(where: { $0.kind == .window && $0.appName == appName })
    }
}
