@preconcurrency import AVFoundation
import Foundation

enum PostProcessError: LocalizedError {
    case ffmpegUnavailable
    case unsupportedCompressionPreset
    case exportFailed(String)
    case ffmpegFailed(exitCode: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .ffmpegUnavailable:
            return "ffmpeg が見つかりません。`brew install ffmpeg` を実行してからもう一度お試しください。"
        case .unsupportedCompressionPreset:
            return "この動画は選択された圧縮プリセットで書き出せません。"
        case .exportFailed(let message):
            return "圧縮に失敗しました: \(message)"
        case .ffmpegFailed(let exitCode, let stderr):
            let summary = stderr.isEmpty ? "stderr はありません" : stderr
            return "ffmpeg が終了コード \(exitCode) で失敗しました: \(summary)"
        }
    }
}

/// Dispatches the work types in `PostProcessQueue` to their concrete media tools.
/// Output paths are chosen before enqueueing, so a queued job can never clobber a file
/// created by an earlier job.
struct PostProcessExecutor: Sendable {
    static func defaultExecute(
        job: PostProcessJob,
        reportProgress: @escaping @Sendable (Double?) -> Void
    ) async throws -> URL {
        try await PostProcessExecutor().execute(job: job, reportProgress: reportProgress)
    }

    func execute(
        job: PostProcessJob,
        reportProgress: @escaping @Sendable (Double?) -> Void
    ) async throws -> URL {
        switch job.operation {
        case .compress(let preset):
            return try await Compressor().compress(
                input: job.sourceURL,
                output: job.outputURL,
                preset: preset,
                reportProgress: reportProgress
            )
        case .gif:
            guard let ffmpegURL = FfmpegLocator().locate() else {
                throw PostProcessError.ffmpegUnavailable
            }
            return try await GifConverter(ffmpegURL: ffmpegURL).convert(
                input: job.sourceURL,
                output: job.outputURL,
                reportProgress: reportProgress
            )
        case .recover:
            guard let ffmpegURL = FfmpegLocator().locate() else {
                throw PostProcessError.ffmpegUnavailable
            }
            return try await RecoveryConverter(ffmpegURL: ffmpegURL).recover(
                input: job.sourceURL,
                output: job.outputURL,
                reportProgress: reportProgress
            )
        }
    }
}

/// AVFoundation-only movie compression.  HEVC is intentionally capped at 1080p for a
/// materially smaller file, while H.264 uses the matching broadly-compatible preset.
private struct Compressor: Sendable {
    func compress(
        input: URL,
        output: URL,
        preset: CompressionPreset,
        reportProgress: @escaping @Sendable (Double?) -> Void
    ) async throws -> URL {
        let exportPreset: String = switch preset {
        case .hevc: AVAssetExportPresetHEVC1920x1080
        case .h264: AVAssetExportPreset1920x1080
        }
        let asset = AVURLAsset(url: input)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: exportPreset) else {
            throw PostProcessError.unsupportedCompressionPreset
        }

        let sessionBox = ExportSessionBox(exportSession)
        let progressTask = Task { @Sendable in
            while !Task.isCancelled {
                reportProgress(Double(sessionBox.session.progress) * 100)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { progressTask.cancel() }

        do {
            try await exportSession.export(to: output, as: .mp4)
            reportProgress(100)
            return output
        } catch {
            throw PostProcessError.exportFailed(error.localizedDescription)
        }
    }
}

/// AVAssetExportSession is marked non-Sendable by AVFoundation even though this app only
/// reads its documented thread-safe progress value while its own export operation runs.
private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}

/// Runs ffmpeg only through the executable URL returned by `FfmpegLocator`; arguments are
/// passed as an array and no shell is involved.  `-n` in the command builders is the final
/// overwrite safeguard in addition to output-name collision avoidance.
private struct GifConverter: Sendable {
    let ffmpegURL: URL

    func convert(
        input: URL,
        output: URL,
        reportProgress: @escaping @Sendable (Double?) -> Void
    ) async throws -> URL {
        let palette = output.deletingLastPathComponent().appending(
            path: ".casrec-palette-\(UUID().uuidString).png",
            directoryHint: .notDirectory
        )
        defer { try? FileManager.default.removeItem(at: palette) }

        let runner = FfmpegRunner(executableURL: ffmpegURL)
        reportProgress(nil)
        try await runner.run(arguments: FfmpegCommandBuilder.paletteGeneration(input: input, palette: palette))
        try await runner.run(arguments: FfmpegCommandBuilder.paletteUse(input: input, palette: palette, output: output))
        reportProgress(100)
        return output
    }
}

private struct RecoveryConverter: Sendable {
    let ffmpegURL: URL

    func recover(
        input: URL,
        output: URL,
        reportProgress: @escaping @Sendable (Double?) -> Void
    ) async throws -> URL {
        reportProgress(nil)
        try await FfmpegRunner(executableURL: ffmpegURL).run(
            arguments: FfmpegCommandBuilder.remux(input: input, output: output)
        )
        reportProgress(100)
        return output
    }
}

private struct FfmpegRunner: Sendable {
    let executableURL: URL

    func run(arguments: [String]) async throws {
        let result = try await Task.detached(priority: .utility) { [executableURL, arguments] () throws -> (Int32, String) in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            let stderr = Pipe()
            process.standardError = stderr
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            // Reading to EOF starts immediately and drains while ffmpeg is still writing.
            // Waiting first would deadlock a long conversion once stderr fills its pipe.
            let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let message = String(data: stderrData, encoding: .utf8) ?? ""
            return (process.terminationStatus, Self.summary(of: message))
        }.value

        guard result.0 == 0 else {
            throw PostProcessError.ffmpegFailed(exitCode: result.0, stderr: result.1)
        }
    }

    private static func summary(of stderr: String) -> String {
        let collapsed = stderr.split(whereSeparator: \.isNewline).suffix(3).joined(separator: " ")
        return String(collapsed.prefix(600))
    }
}
