import Foundation
import SwiftUI

let mockSourcesList: [CaptureSource] = [
    CaptureSource(
        id: "display-0",
        kind: .display,
        title: "Display 1",
        appName: nil,
        frame: CGRect(x: 0, y: 0, width: 3456, height: 2234),
        scWindow: nil,
        scDisplay: nil,
        thumbnail: nil
    ),
    CaptureSource(
        id: "window-safari",
        kind: .window,
        title: "twicas.com — Safari",
        appName: "Safari",
        frame: CGRect(x: 100, y: 100, width: 1280, height: 720),
        scWindow: nil,
        scDisplay: nil,
        thumbnail: nil
    ),
    CaptureSource(
        id: "window-chrome",
        kind: .window,
        title: "Twitch — Google Chrome",
        appName: "Google Chrome",
        frame: CGRect(x: 200, y: 200, width: 1920, height: 1080),
        scWindow: nil,
        scDisplay: nil,
        thumbnail: nil
    ),
]

/// Walks the §4 state machine on a timer, without ScreenCaptureKit or a writer, so the
/// recording screen can be exercised without the screen-recording permission.
///
/// `@unchecked Sendable`: every mutable member is read and written under `lock`.
final class MockRecordingSession: RecordingSessionControlling, @unchecked Sendable {
    private var state: RecordingState = .idle
    private let lock = NSLock()

    func observeState() -> AsyncStream<RecordingState> {
        AsyncStream { continuation in
            let initialState = getState()
            continuation.yield(initialState)

            let task = Task {
                var lastState = initialState
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    let currentState = getState()
                    if currentState != lastState {
                        lastState = currentState
                        continuation.yield(currentState)
                    }
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func start(source: CaptureSource, settings: RecordingSettings) async {
        setState(.preparing)
        try? await Task.sleep(nanoseconds: 500_000_000)
        setState(.recording(RecordingProgress(
            startedAt: Date(),
            bytesWritten: 0,
            droppedFrames: 0,
            isStalled: false
        )))

        var progress = 0
        while true {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            progress += 1
            let shouldContinue = updateRecordingProgress(progress: progress)
            if !shouldContinue {
                break
            }
        }
    }

    func stop() async {
        setState(.finishing)
        try? await Task.sleep(nanoseconds: 500_000_000)
        setState(.idle)
    }

    func acknowledgeFailure() {
        lock.withLock {
            if case .failed = state {
                state = .idle
            }
        }
    }

    private func getState() -> RecordingState {
        lock.withLock { state }
    }

    private func setState(_ newState: RecordingState) {
        lock.withLock { state = newState }
    }

    private func updateRecordingProgress(progress: Int) -> Bool {
        lock.withLock { () -> Bool in
            if case .recording(var recordingProgress) = state {
                recordingProgress.bytesWritten = Int64(progress) * 5_000_000
                recordingProgress.droppedFrames = progress > 30 ? 2 : 0
                state = .recording(recordingProgress)
                return true
            }
            return false
        }
    }
}

/// Serves a fixed source list and captures nothing. Stateless, hence genuinely `Sendable`.
final class MockCaptureService: CaptureServicing {
    func observeSources() -> AsyncStream<CaptureSourcesUpdate> {
        AsyncStream { continuation in
            continuation.yield(.sources(mockSourcesList))
            let task = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continuation.yield(.sources(mockSourcesList))
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func startCapture(source: CaptureSource, settings: RecordingSettings, sink: any SampleConsuming) async throws {
    }

    func stopCapture() async {
    }

    func observeCaptureEnded() -> AsyncStream<CaptureEndReason> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}
