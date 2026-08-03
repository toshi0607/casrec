import Foundation

enum CompressionPreset: String, CaseIterable, Hashable, Sendable {
    case hevc
    case h264

    var label: String {
        switch self {
        case .hevc: "高圧縮HEVC"
        case .h264: "互換H.264"
        }
    }
}

enum PostProcessOperation: Hashable, Sendable {
    case compress(CompressionPreset)
    case gif
    case recover

    /// Different compression presets are still the same kind of job for duplicate
    /// suppression: only one output action may be in flight for a source at a time.
    var duplicateKind: String {
        switch self {
        case .compress: "compress"
        case .gif: "gif"
        case .recover: "recover"
        }
    }
}

struct PostProcessJob: Hashable, Sendable, Identifiable {
    let sourceURL: URL
    let outputURL: URL
    let operation: PostProcessOperation

    var id: String { "\(sourceURL.path(percentEncoded: false))|\(operation.duplicateKind)" }
}

enum PostProcessJobState: Equatable, Sendable {
    case waiting
    case running(progress: Double?)
    case completed(outputURL: URL)
    case failed(message: String)
}

struct PostProcessJobStatus: Equatable, Sendable, Identifiable {
    let job: PostProcessJob
    let state: PostProcessJobState

    var id: String { job.id }
}

/// A single-worker FIFO queue.  It deliberately has no recording-state dependency, so
/// finished recordings can be converted while a new recording is underway.
actor PostProcessQueue {
    typealias Executor = @Sendable (
        PostProcessJob,
        @escaping @Sendable (Double?) -> Void
    ) async throws -> URL

    private let execute: Executor
    private var waiting: [PostProcessJob] = []
    private var active: PostProcessJob?
    private var states: [String: PostProcessJobState] = [:]
    private var orderedIDs: [String] = []
    private var continuations: [UUID: AsyncStream<[PostProcessJobStatus]>.Continuation] = [:]

    init(execute: @escaping Executor = PostProcessExecutor.defaultExecute) {
        self.execute = execute
    }

    /// Returns false if an equal source/kind is waiting or running already.
    @discardableResult
    func enqueue(_ job: PostProcessJob) -> Bool {
        if let existingState = states[job.id] {
            switch existingState {
            case .waiting, .running:
                return false
            case .completed, .failed:
                states[job.id] = nil
                finishedJobs[job.id] = nil
                orderedIDs.removeAll { $0 == job.id }
            }
        }
        states[job.id] = .waiting
        orderedIDs.append(job.id)
        waiting.append(job)
        publish()
        startNextIfNeeded()
        return true
    }

    func statuses() -> [PostProcessJobStatus] {
        orderedIDs.compactMap { id in
            guard let state = states[id], let job = ([active].compactMap { $0 } + waiting).first(where: { $0.id == id })
                ?? completedJob(for: id) else {
                return nil
            }
            return PostProcessJobStatus(job: job, state: state)
        }
    }

    func observe() -> AsyncStream<[PostProcessJobStatus]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<[PostProcessJobStatus]>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuations[id] = continuation
        continuation.yield(statuses())
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    func removeFinished() {
        let finishedIDs = states.compactMap { id, state in
            switch state {
            case .completed, .failed: id
            case .waiting, .running: nil
            }
        }
        for id in finishedIDs {
            states[id] = nil
        }
        orderedIDs.removeAll { finishedIDs.contains($0) }
        publish()
    }

    private var finishedJobs: [String: PostProcessJob] = [:]

    private func completedJob(for id: String) -> PostProcessJob? {
        finishedJobs[id]
    }

    private func startNextIfNeeded() {
        guard active == nil, !waiting.isEmpty else { return }
        let job = waiting.removeFirst()
        active = job
        states[job.id] = .running(progress: nil)
        publish()

        Task { [execute] in
            do {
                let output = try await execute(job) { [weak self] progress in
                    Task { await self?.setProgress(progress, for: job.id) }
                }
                finish(job: job, state: .completed(outputURL: output))
            } catch {
                finish(job: job, state: .failed(message: Self.message(for: error)))
            }
        }
    }

    private func setProgress(_ progress: Double?, for id: String) {
        guard active?.id == id else { return }
        states[id] = .running(progress: progress)
        publish()
    }

    private func finish(job: PostProcessJob, state: PostProcessJobState) {
        guard active?.id == job.id else { return }
        active = nil
        finishedJobs[job.id] = job
        states[job.id] = state
        publish()
        startNextIfNeeded()
    }

    private func publish() {
        let snapshot = statuses()
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
