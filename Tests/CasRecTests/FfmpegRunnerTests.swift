import Foundation
import Testing
@testable import CasRec

@Suite("ffmpeg runner")
struct FfmpegRunnerTests {
    @Test("adaptive timeout clamps unknown, short, long, and pathological durations")
    func adaptiveTimeoutPolicyIsBounded() {
        #expect(FfmpegExecutionPolicy.forMediaDuration(nil).timeout == .seconds(30 * 60))
        #expect(FfmpegExecutionPolicy.forMediaDuration(10).timeout == .seconds(30 * 60))
        #expect(FfmpegExecutionPolicy.forMediaDuration(3 * 60 * 60).timeout == .seconds(6 * 60 * 60))
        #expect(FfmpegExecutionPolicy.forMediaDuration(100 * 60 * 60).timeout == .seconds(12 * 60 * 60))
    }

    @Test("final output collisions preserve the externally created final file")
    func temporaryOutputCommitDoesNotOverwriteFinalFile() throws {
        let directory = URL(filePath: NSTemporaryDirectory()).appending(path: "casrec-output-\(UUID().uuidString)", directoryHint: .isDirectory)
        let finalOutput = directory.appending(path: "recording.gif", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data("external-final".utf8).write(to: finalOutput)
        let temporaryOutput = PostProcessTemporaryOutput.makeURL(for: finalOutput)
        try Data("partial-output".utf8).write(to: temporaryOutput)
        defer { PostProcessTemporaryOutput.removeIfPresent(temporaryOutput) }

        let error = #expect(throws: PostProcessError.self) {
            try PostProcessTemporaryOutput.moveWithoutOverwrite(temporaryOutput, to: finalOutput)
        }
        #expect(error != nil)
        #expect(try String(contentsOf: finalOutput, encoding: .utf8) == "external-final")
        #expect(FileManager.default.fileExists(atPath: temporaryOutput.path))
    }

    @Test("temporary output is published once without leaving the staging file")
    func temporaryOutputCommitPublishesAtomically() throws {
        let directory = URL(filePath: NSTemporaryDirectory()).appending(
            path: "casrec-output-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let finalOutput = directory.appending(path: "recording.mov", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let temporaryOutput = PostProcessTemporaryOutput.makeURL(for: finalOutput)
        try Data("completed-output".utf8).write(to: temporaryOutput)
        try PostProcessTemporaryOutput.moveWithoutOverwrite(temporaryOutput, to: finalOutput)

        #expect(try String(contentsOf: finalOutput, encoding: .utf8) == "completed-output")
        #expect(!FileManager.default.fileExists(atPath: temporaryOutput.path))
    }

    @Test("large stderr succeeds without waiting for EOF before draining")
    func drainsHeavyStderr() async throws {
        let runner = FfmpegRunner(
            executableURL: URL(filePath: "/bin/sh"),
            policy: .init(timeout: .seconds(10), terminationGracePeriod: .milliseconds(100), stderrTailLimit: 256)
        )

        try await runner.run(arguments: ["-c", "i=0; while [ $i -lt 12000 ]; do printf 'diagnostic line %s\\n' \"$i\" >&2; i=$((i + 1)); done"])
    }

    @Test("failed processes retain only a bounded stderr suffix")
    func reportsBoundedStderrTail() async {
        let runner = FfmpegRunner(
            executableURL: URL(filePath: "/bin/sh"),
            policy: .init(timeout: .seconds(2), terminationGracePeriod: .milliseconds(100), stderrTailLimit: 96)
        )

        let error = await #expect(throws: PostProcessError.self) {
            try await runner.run(arguments: ["-c", "i=0; while [ $i -lt 100 ]; do printf 'discard-%s\\n' \"$i\" >&2; i=$((i + 1)); done; printf 'TAIL-MARKER\\n' >&2; exit 17"])
        }
        guard let error else { return }
        guard case .ffmpegFailed(let code, let stderr) = error else {
            Issue.record("Expected an ffmpeg exit error, got \(error)")
            return
        }
        #expect(code == 17)
        #expect(stderr.contains("TAIL-MARKER"))
        #expect(stderr.utf8.count <= 96)
    }

    @Test("timeout escalates past a process that ignores TERM")
    func timeoutKillsUncooperativeProcess() async {
        let runner = FfmpegRunner(
            executableURL: URL(filePath: "/bin/sh"),
            policy: .init(timeout: .milliseconds(100), terminationGracePeriod: .milliseconds(100), stderrTailLimit: 256)
        )

        let error = await #expect(throws: PostProcessError.self) {
            try await runner.run(arguments: ["-c", "trap '' TERM; while :; do :; done"])
        }
        guard let error else { return }
        guard case .ffmpegTimedOut = error else {
            Issue.record("Expected a timeout error, got \(error)")
            return
        }
    }

    @Test("cancellation waits for termination and propagates CancellationError")
    func cancellationStopsChild() async throws {
        let runner = FfmpegRunner(
            executableURL: URL(filePath: "/bin/sh"),
            policy: .init(timeout: .seconds(2), terminationGracePeriod: .milliseconds(100), stderrTailLimit: 256)
        )
        let task = Task {
            try await runner.run(arguments: ["-c", "trap '' TERM; while :; do :; done"])
        }

        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}
