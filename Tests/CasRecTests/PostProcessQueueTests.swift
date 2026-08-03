import Foundation
import Testing
@testable import CasRec

@Suite("Post-processing queue")
struct PostProcessQueueTests {
    @Test("queue runs jobs one at a time and suppresses duplicate source kinds")
    func queueIsSerialAndDeduplicates() async throws {
        let recorder = JobRecorder()
        let queue = PostProcessQueue { job, _ in
            await recorder.record("start:\(job.sourceURL.lastPathComponent)")
            try await Task.sleep(for: .milliseconds(40))
            await recorder.record("end:\(job.sourceURL.lastPathComponent)")
            return job.outputURL
        }
        let first = PostProcessJob(
            sourceURL: URL(filePath: "/tmp/first.mov"),
            outputURL: URL(filePath: "/tmp/first.gif"),
            operation: .gif
        )
        let second = PostProcessJob(
            sourceURL: URL(filePath: "/tmp/second.mov"),
            outputURL: URL(filePath: "/tmp/second.gif"),
            operation: .gif
        )
        let duplicate = PostProcessJob(
            sourceURL: first.sourceURL,
            outputURL: URL(filePath: "/tmp/first-2.gif"),
            operation: .gif
        )

        #expect(await queue.enqueue(first))
        #expect(await queue.enqueue(second))
        #expect(!(await queue.enqueue(duplicate)))

        let settled = await waitForQueueToSettle(queue)
        #expect(settled)
        #expect(await recorder.events == [
            "start:first.mov",
            "end:first.mov",
            "start:second.mov",
            "end:second.mov",
        ])
    }
}

private actor JobRecorder {
    private var recordedEvents: [String] = []

    func record(_ event: String) {
        recordedEvents.append(event)
    }

    var events: [String] { recordedEvents }
}

private func waitForQueueToSettle(_ queue: PostProcessQueue) async -> Bool {
    for _ in 0..<100 {
        let statuses = await queue.statuses()
        if statuses.count == 2, statuses.allSatisfy({ status in
            if case .completed = status.state { return true }
            return false
        }) {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}
