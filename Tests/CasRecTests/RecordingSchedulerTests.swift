import Foundation
import Synchronization
import Testing
@testable import CasRec

@Suite("Recording scheduler")
struct RecordingSchedulerTests {
    @Test("Firing a reservation starts the recording")
    func firingStartsRecording() async {
        let clock = ManualSchedulingClock(now: referenceDate)
        let recorder = SchedulerCallRecorder()
        let scheduler = RecordingScheduler(clock: clock.makeClock())

        await scheduler.schedule(
            reservation(at: referenceDate.addingTimeInterval(60)),
            stateProvider: { .idle },
            start: { _ in recorder.recordStart(); return .started },
            stop: { recorder.recordStop() }
        )

        await clock.waitForSleepCalls(1)
        clock.advance(to: referenceDate.addingTimeInterval(60))
        await waitFor { recorder.startCount == 1 }

        #expect(recorder.startCount == 1)
        #expect(recorder.stopCount == 0)
    }

    @Test("Cancelling a reservation prevents its start action")
    func cancellingPreventsStart() async {
        let clock = ManualSchedulingClock(now: referenceDate)
        let recorder = SchedulerCallRecorder()
        let scheduler = RecordingScheduler(clock: clock.makeClock())

        await scheduler.schedule(
            reservation(at: referenceDate.addingTimeInterval(60)),
            stateProvider: { .idle },
            start: { _ in recorder.recordStart(); return .started },
            stop: { recorder.recordStop() }
        )
        await clock.waitForSleepCalls(1)
        await scheduler.cancel()
        clock.advance(to: referenceDate.addingTimeInterval(60))
        await Task.yield()

        #expect(recorder.startCount == 0)
    }

    @Test("A non-idle session consumes the reservation without starting")
    func nonIdleSessionIsSkipped() async {
        let clock = ManualSchedulingClock(now: referenceDate)
        let recorder = SchedulerCallRecorder()
        let scheduler = RecordingScheduler(clock: clock.makeClock())

        await scheduler.schedule(
            reservation(at: referenceDate.addingTimeInterval(60)),
            stateProvider: { .failed(message: "previous recording failed") },
            start: { _ in recorder.recordStart(); return .started },
            stop: { recorder.recordStop() }
        )

        await clock.waitForSleepCalls(1)
        clock.advance(to: referenceDate.addingTimeInterval(60))
        await Task.yield()

        #expect(recorder.startCount == 0)
    }

    @Test("A duration-limited reservation calls the normal stop action")
    func maximumDurationStopsRecording() async {
        let clock = ManualSchedulingClock(now: referenceDate)
        let recorder = SchedulerCallRecorder()
        let scheduler = RecordingScheduler(clock: clock.makeClock())
        let startAt = referenceDate.addingTimeInterval(60)

        await scheduler.schedule(
            reservation(at: startAt, maximumDuration: 30),
            stateProvider: { .idle },
            start: { _ in recorder.recordStart(); return .started },
            stop: { recorder.recordStop() }
        )

        await clock.waitForSleepCalls(1)
        clock.advance(to: startAt)
        await waitFor { recorder.startCount == 1 }
        await clock.waitForSleepCalls(2)
        clock.advance(to: startAt.addingTimeInterval(30))
        await waitFor { recorder.stopCount == 1 }

        #expect(recorder.stopCount == 1)
    }

    @Test("A new reservation replaces and cancels the old one")
    func newReservationReplacesOldReservation() async {
        let clock = ManualSchedulingClock(now: referenceDate)
        let recorder = SchedulerCallRecorder()
        let scheduler = RecordingScheduler(clock: clock.makeClock())
        let first = referenceDate.addingTimeInterval(60)
        let second = referenceDate.addingTimeInterval(120)

        await scheduler.schedule(
            reservation(at: first),
            stateProvider: { .idle },
            start: { _ in recorder.recordStart(); return .started },
            stop: { recorder.recordStop() }
        )
        await clock.waitForSleepCalls(1)
        await scheduler.schedule(
            reservation(at: second),
            stateProvider: { .idle },
            start: { _ in recorder.recordStart(); return .started },
            stop: { recorder.recordStop() }
        )
        await clock.waitForSleepCalls(2)

        clock.advance(to: first)
        await Task.yield()
        #expect(recorder.startCount == 0)

        clock.advance(to: second)
        await waitFor { recorder.startCount == 1 }
        #expect(recorder.startCount == 1)
    }
}

@Suite("Capture source resolver")
struct CaptureSourceResolverTests {
    @Test("Uses the same ID first")
    func matchesID() {
        let saved = source(id: "window-10", title: "Live", appName: "Safari")
        let current = source(id: "window-10", title: "Different", appName: "Other")
        #expect(CaptureSourceResolver.resolve(saved: saved, in: [current])?.id == current.id)
    }

    @Test("Falls back to same app and title")
    func matchesAppAndTitle() {
        let saved = source(id: "window-old", title: "Live", appName: "Safari")
        let current = source(id: "window-new", title: "Live", appName: "Safari")
        #expect(CaptureSourceResolver.resolve(saved: saved, in: [current])?.id == current.id)
    }

    @Test("Falls back to the first window of the same app")
    func matchesAppOnly() {
        let saved = source(id: "window-old", title: "Live", appName: "Safari")
        let current = source(id: "window-new", title: "Other tab", appName: "Safari")
        #expect(CaptureSourceResolver.resolve(saved: saved, in: [current])?.id == current.id)
    }

    @Test("Returns nil when every matching source disappeared")
    func returnsNilWhenSourceIsGone() {
        let saved = source(id: "window-old", title: "Live", appName: "Safari")
        let other = source(id: "window-other", title: "Live", appName: "Chrome")
        #expect(CaptureSourceResolver.resolve(saved: saved, in: [other]) == nil)
    }
}

private let referenceDate = Date(timeIntervalSinceReferenceDate: 1_000_000)

private func reservation(at startAt: Date, maximumDuration: TimeInterval? = nil) -> ScheduledRecording {
    ScheduledRecording(
        startAt: startAt,
        source: source(id: "window-1", title: "Live", appName: "Safari"),
        settings: .default,
        maximumDuration: maximumDuration
    )
}

private func source(id: String, title: String, appName: String) -> CaptureSource {
    CaptureSource(
        id: id,
        kind: .window,
        title: title,
        appName: appName,
        frame: .zero,
        scWindow: nil,
        scDisplay: nil,
        thumbnail: nil
    )
}

private final class SchedulerCallRecorder: @unchecked Sendable {
    private let state = Mutex((starts: 0, stops: 0))
    var startCount: Int { state.withLock { $0.starts } }
    var stopCount: Int { state.withLock { $0.stops } }
    func recordStart() { state.withLock { $0.starts += 1 } }
    func recordStop() { state.withLock { $0.stops += 1 } }
}

/// A lock-backed virtual clock lets tests advance scheduled work instantly.  It is marked
/// unchecked because continuations are retained under the lock and resumed only after the
/// lock has been released.
private final class ManualSchedulingClock: @unchecked Sendable {
    private struct SleepRequest {
        let date: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    private let state: Mutex<(now: Date, requests: [SleepRequest], sleepCalls: Int)>

    init(now: Date) {
        state = Mutex((now, [], 0))
    }

    func makeClock() -> SchedulingClock {
        SchedulingClock(
            now: { [weak self] in self?.state.withLock(\.now) ?? .distantPast },
            sleepUntil: { [weak self] date in
                guard let self else { throw CancellationError() }
                try await self.sleep(until: date)
            }
        )
    }

    func advance(to date: Date) {
        let ready = state.withLock { current -> [SleepRequest] in
            current.now = date
            let ready = current.requests.filter { $0.date <= date }
            current.requests.removeAll { $0.date <= date }
            return ready
        }
        for request in ready {
            request.continuation.resume()
        }
    }

    func waitForSleepCalls(_ expected: Int) async {
        await waitFor { self.state.withLock(\.sleepCalls) >= expected }
    }

    private func sleep(until date: Date) async throws {
        let shouldReturn = state.withLock { current -> Bool in
            current.sleepCalls += 1
            return date <= current.now
        }
        guard !shouldReturn else { return }
        try await withCheckedThrowingContinuation { continuation in
            state.withLock { $0.requests.append(SleepRequest(date: date, continuation: continuation)) }
        }
    }
}

private func waitFor(_ predicate: @escaping @Sendable () -> Bool) async {
    for _ in 0..<100 {
        if predicate() { return }
        await Task.yield()
    }
}
