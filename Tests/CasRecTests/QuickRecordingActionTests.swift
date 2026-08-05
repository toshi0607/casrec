import Foundation
import Testing
@testable import CasRec

@Suite("Quick recording action")
struct QuickRecordingActionTests {
    @Test("Idle starts a recording")
    func idleStarts() {
        #expect(quickRecordingAction(for: .idle) == .start)
    }

    @Test("Recording stops the recording")
    func recordingStops() {
        #expect(quickRecordingAction(for: .recording(progress)) == .stop)
    }

    @Test("Preparing and finishing do nothing")
    func transitionsDoNothing() {
        #expect(quickRecordingAction(for: .preparing) == .none)
        #expect(quickRecordingAction(for: .finishing) == .none)
    }

    @Test("A failed session does nothing")
    func failureDoesNothing() {
        #expect(quickRecordingAction(for: .failed(message: "failure")) == .none)
    }

    @Test("An unacknowledged notice blocks starts but never blocks a stop")
    func usageNoticeBlocksOnlyStarts() {
        #expect(quickRecordingAction(for: .idle, allowsRecordingStart: false) == .none)
        #expect(quickRecordingAction(for: .recording(progress), allowsRecordingStart: false) == .stop)
    }

    private var progress: RecordingProgress {
        RecordingProgress(
            startedAt: .now,
            bytesWritten: 0,
            droppedFrames: 0,
            isStalled: false
        )
    }
}
