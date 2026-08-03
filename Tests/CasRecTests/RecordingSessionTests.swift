import Foundation
import Testing
@testable import CasRec

/// The §4 state machine and its central invariant: every exit from `recording` runs the
/// teardown exactly once, however many stop paths fire at the same time.
@Suite("Recording session")
struct RecordingSessionTests {

    // MARK: - Converging stop paths

    @Test("A manual stop racing a stream failure tears down exactly once")
    func manualStopRacingStreamFailure() async {
        let directory = TempDirectory()
        defer { directory.remove() }
        let capture = FakeCaptureService()
        let session = RecordingSession(captureService: capture)

        await session.start(source: makeTestSource(), settings: directory.settings())
        #expect(await currentState(session).isTerminal == false, "the session should be recording")

        // Both paths of §4 fire together: the stop button and ScreenCaptureKit reporting the
        // stream died. `finalize` calls `stopCapture()` once per teardown, so the fake's
        // counter is a direct reading of how many teardowns actually ran.
        async let stopped: Void = session.stop()
        capture.endCapture(.failed(message: "stream died"))
        await stopped

        let final = await awaitState(session) { $0.isTerminal }
        #expect(final != nil, "the session must reach a terminal state")
        #expect(capture.stopCallCount == 1, "the losing stop path must be a no-op")
        #expect(directory.contents().isEmpty, "nothing was recorded, so no artifacts may linger")
    }

    @Test("A stream failure racing a second stream failure tears down exactly once")
    func repeatedCaptureEndedEventsAreIdempotent() async {
        let directory = TempDirectory()
        defer { directory.remove() }
        let capture = FakeCaptureService()
        let session = RecordingSession(captureService: capture)

        await session.start(source: makeTestSource(), settings: directory.settings())

        capture.endCapture(.sourceEnded)
        capture.endCapture(.failed(message: "and again"))

        let final = await awaitState(session) { $0.isTerminal }
        #expect(final != nil)
        #expect(capture.stopCallCount == 1)
    }

    @Test("Losing the capture source ends the session cleanly, not as an error")
    func sourceEndedFinishesWithoutFailing() async {
        let directory = TempDirectory()
        defer { directory.remove() }
        let capture = FakeCaptureService()
        let session = RecordingSession(captureService: capture)

        await session.start(source: makeTestSource(), settings: directory.settings())
        capture.endCapture(.sourceEnded)

        // R10: a window that closes is a normal ending; the user gets no error for it.
        let final = await awaitState(session) { $0.isTerminal }
        #expect(final == .idle)
    }

    @Test("A stream failure surfaces as a failure the user is told about")
    func streamFailureSurfacesMessage() async {
        let directory = TempDirectory()
        defer { directory.remove() }
        let capture = FakeCaptureService()
        let session = RecordingSession(captureService: capture)

        await session.start(source: makeTestSource(), settings: directory.settings())
        capture.endCapture(.failed(message: "SCStreamErrorDomain#-3811"))

        let final = await awaitState(session) { $0.isTerminal }
        guard case .failed(let message) = final else {
            Issue.record("expected a failed state, got \(String(describing: final))")
            return
        }
        #expect(message.contains("SCStreamErrorDomain#-3811"), "the cause must survive into the UI")
        #expect(!message.contains("保存されています"), "an empty recording must not be presented as saved")
    }

    // MARK: - failed -> idle

    @Test("A start that cannot begin lands in failed, and acknowledging returns to idle")
    func failedStateIsAcknowledgeable() async {
        let directory = TempDirectory()
        defer { directory.remove() }
        let capture = FakeCaptureService(startError: FakeCaptureError.startRefused)
        let session = RecordingSession(captureService: capture)

        await session.start(source: makeTestSource(), settings: directory.settings())

        let failed = await currentState(session)
        guard case .failed = failed else {
            Issue.record("expected failed, got \(failed)")
            return
        }
        #expect(directory.contents().isEmpty, "a start that never captured must not leave a file behind")

        // Synchronous on the concrete type; it satisfies the protocol's `async` requirement
        // unchanged, which is how the UI calls it.
        session.acknowledgeFailure()

        #expect(await currentState(session) == .idle, "§4: failed -> idle once the message is shown")
    }

    @Test("Starting again is ignored until the failure is acknowledged")
    func startIsIgnoredWhileFailed() async {
        let directory = TempDirectory()
        defer { directory.remove() }
        let capture = FakeCaptureService(startError: FakeCaptureError.startRefused)
        let session = RecordingSession(captureService: capture)

        await session.start(source: makeTestSource(), settings: directory.settings())
        #expect(capture.startCallCount == 1)

        await session.start(source: makeTestSource(), settings: directory.settings())

        #expect(capture.startCallCount == 1, "a failed session must not silently start capturing again")
        guard case .failed = await currentState(session) else {
            Issue.record("the session should still be failed")
            return
        }
    }

    @Test("Stopping an idle session does nothing")
    func stopWhileIdleIsNoOp() async {
        let capture = FakeCaptureService()
        let session = RecordingSession(captureService: capture)

        await session.stop()

        #expect(capture.stopCallCount == 0)
        #expect(await currentState(session) == .idle)
    }

    // MARK: - State publishing

    @Test("A late subscriber is handed the current state immediately")
    func lateSubscriberSeesCurrentState() async {
        let directory = TempDirectory()
        defer { directory.remove() }
        let capture = FakeCaptureService()
        let session = RecordingSession(captureService: capture)

        await session.start(source: makeTestSource(), settings: directory.settings())

        // Subscribing after the transition must not leave the view on a blank screen.
        guard case .recording = await currentState(session) else {
            Issue.record("a subscriber joining mid-recording should be told it is recording")
            return
        }

        capture.endCapture(.sourceEnded)
        _ = await awaitState(session) { $0.isTerminal }
    }
}
