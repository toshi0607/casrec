import Foundation
import Testing
@testable import CasRec

@Suite("Post-process executor")
struct PostProcessExecutorTests {
    @Test("compression publishes only its completed staging output")
    func compressionPublishesStagedOutput() async throws {
        try await withTemporaryOutput { source, output in
            let executor = PostProcessExecutor { _, temporaryOutput, _, _ in
                try Data("completed".utf8).write(to: temporaryOutput)
            }

            let result = try await executor.execute(job: compressionJob(source: source, output: output)) { _ in }

            #expect(result == output)
            #expect(try String(contentsOf: output, encoding: .utf8) == "completed")
            #expect(stagingOutputs(near: output).isEmpty)
        }
    }

    @Test("failed compression removes its staged partial output")
    func failedCompressionDoesNotPublishPartialOutput() async throws {
        try await withTemporaryOutput { source, output in
            let executor = PostProcessExecutor { _, temporaryOutput, _, _ in
                try Data("partial".utf8).write(to: temporaryOutput)
                throw CompressionTestError.failed
            }

            let error = await #expect(throws: CompressionTestError.self) {
                try await executor.execute(job: compressionJob(source: source, output: output)) { _ in }
            }

            #expect(error == .failed)
            #expect(!FileManager.default.fileExists(atPath: output.path))
            #expect(stagingOutputs(near: output).isEmpty)
        }
    }

    @Test("cancelled compression removes its staged partial output")
    func cancelledCompressionDoesNotPublishPartialOutput() async throws {
        try await withTemporaryOutput { source, output in
            let partialWritten = CompressionSignal()
            let executor = PostProcessExecutor { _, temporaryOutput, _, _ in
                try Data("partial".utf8).write(to: temporaryOutput)
                await partialWritten.record()
                await partialWritten.waitForRelease()
            }
            let task = Task {
                try await executor.execute(job: compressionJob(source: source, output: output)) { _ in }
            }

            await partialWritten.wait()
            task.cancel()
            await partialWritten.release()
            await #expect(throws: CancellationError.self) {
                try await task.value
            }

            #expect(!FileManager.default.fileExists(atPath: output.path))
            #expect(stagingOutputs(near: output).isEmpty)
        }
    }

    @Test("compression never overwrites a final file created while exporting")
    func compressionPreservesConcurrentFinalOutput() async throws {
        try await withTemporaryOutput { source, output in
            let executor = PostProcessExecutor { _, temporaryOutput, _, _ in
                try Data("partial".utf8).write(to: temporaryOutput)
                try Data("external-final".utf8).write(to: output)
            }

            let error = await #expect(throws: PostProcessError.self) {
                try await executor.execute(job: compressionJob(source: source, output: output)) { _ in }
            }

            guard let error else { return }
            guard case .outputAlreadyExists(let collidedOutput) = error else {
                Issue.record("Expected outputAlreadyExists, got \(error)")
                return
            }
            #expect(collidedOutput == output)
            let contents = try String(contentsOf: output, encoding: .utf8)
            #expect(contents == "external-final")
            #expect(stagingOutputs(near: output).isEmpty)
        }
    }
}

private enum CompressionTestError: Error, Equatable {
    case failed
}

private actor CompressionSignal {
    private var hasRecorded = false
    private var isReleased = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func record() {
        hasRecorded = true
        waiter?.resume()
        waiter = nil
    }

    func wait() async {
        guard !hasRecorded else { return }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func waitForRelease() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func release() {
        isReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private func compressionJob(source: URL, output: URL) -> PostProcessJob {
    PostProcessJob(sourceURL: source, outputURL: output, operation: .compress(.h264))
}

private func withTemporaryOutput(
    _ body: (URL, URL) async throws -> Void
) async throws {
    let directory = URL(filePath: NSTemporaryDirectory()).appending(
        path: "casrec-compression-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    let source = directory.appending(path: "recording.mov", directoryHint: .notDirectory)
    let output = directory.appending(path: "recording-compressed.mp4", directoryHint: .notDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(source, output)
}

private func stagingOutputs(near output: URL) -> [URL] {
    let directory = output.deletingLastPathComponent()
    return (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
        .filter { $0.lastPathComponent.hasPrefix(".casrec-output-") } ?? []
}
