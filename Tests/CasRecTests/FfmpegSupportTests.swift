import Foundation
import Testing
@testable import CasRec

@Suite("ffmpeg support")
struct FfmpegSupportTests {
    @Test("ffmpeg detection honors Homebrew precedence before PATH")
    func ffmpegLocatorUsesExpectedPrecedence() {
        let homebrew = "/opt/homebrew/bin/ffmpeg"
        let local = "/usr/local/bin/ffmpeg"
        let pathFFmpeg = "/custom/bin/ffmpeg"

        let first = FfmpegLocator.locate(path: "/custom/bin", isExecutable: { candidate in
            [homebrew, local, pathFFmpeg].contains(candidate)
        })
        #expect(first == homebrew)

        let second = FfmpegLocator.locate(path: "/custom/bin", isExecutable: { candidate in
            [local, pathFFmpeg].contains(candidate)
        })
        #expect(second == local)

        let third = FfmpegLocator.locate(path: "/custom/bin", isExecutable: { candidate in
            candidate == pathFFmpeg
        })
        #expect(third == pathFFmpeg)
    }

    @Test("ffmpeg detection returns nil when every candidate is absent")
    func ffmpegLocatorHandlesMissingExecutable() {
        let result = FfmpegLocator.locate(path: "/one:/two", isExecutable: { _ in false })
        #expect(result == nil)
    }

    @Test("output names avoid existing conversion files without overwriting")
    func outputNamerAvoidsCollisions() {
        let source = URL(filePath: "/tmp/recording.mov")
        let namer = PostProcessOutputNamer()

        let initial = namer.nextAvailableURL(
            sourceURL: source,
            suffix: "-compressed",
            fileExtension: "mp4",
            fileExists: { _ in false }
        )
        #expect(initial.lastPathComponent == "recording-compressed.mp4")

        let oneCollision = namer.nextAvailableURL(
            sourceURL: source,
            suffix: "-compressed",
            fileExtension: "mp4",
            fileExists: { $0.lastPathComponent == "recording-compressed.mp4" }
        )
        #expect(oneCollision.lastPathComponent == "recording-compressed-2.mp4")

        let continuedCollision = namer.nextAvailableURL(
            sourceURL: source,
            suffix: "-compressed",
            fileExtension: "mp4",
            fileExists: { ["recording-compressed.mp4", "recording-compressed-2.mp4"].contains($0.lastPathComponent) }
        )
        #expect(continuedCollision.lastPathComponent == "recording-compressed-3.mp4")
    }

    @Test("GIF commands use palettegen then paletteuse at the selected defaults")
    func gifCommandsUseTwoPassPaletteWorkflow() {
        let input = URL(filePath: "/tmp/input.mov")
        let palette = URL(filePath: "/tmp/palette.png")
        let output = URL(filePath: "/tmp/output.gif")

        let generation = FfmpegCommandBuilder.paletteGeneration(input: input, palette: palette)
        let use = FfmpegCommandBuilder.paletteUse(input: input, palette: palette, output: output)

        #expect(generation == [
            "-i", "/tmp/input.mov",
            "-vf", "fps=10,scale=640:-1:flags=lanczos,palettegen",
            "-frames:v", "1",
            "-n", "/tmp/palette.png",
        ])
        #expect(use == [
            "-i", "/tmp/input.mov",
            "-i", "/tmp/palette.png",
            "-lavfi", "fps=10,scale=640:-1:flags=lanczos[scaled];[scaled][1:v]paletteuse",
            "-n", "/tmp/output.gif",
        ])
    }

    @Test("recovery command remuxes with stream copy and distinct paths")
    func recoveryCommandUsesStreamCopy() {
        let input = URL(filePath: "/tmp/interrupted.mov")
        let output = URL(filePath: "/tmp/interrupted-recovered.mov")

        let command = FfmpegCommandBuilder.remux(input: input, output: output)

        #expect(command == [
            "-i", "/tmp/interrupted.mov",
            "-c", "copy",
            "-n", "/tmp/interrupted-recovered.mov",
        ])
    }
}
