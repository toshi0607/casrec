import CoreGraphics
import Testing
@testable import CasRec

@Suite("Crop geometry")
struct CropGeometryTests {
    @Test("Preview pixels convert to content points with origin and scale preserved")
    func convertsPreviewPixelsToContentPoints() {
        let rect = CropGeometry.contentRect(
            from: CGRect(x: 600, y: 120, width: 1_200, height: 600),
            previewPixelSize: CGSize(width: 3_000, height: 1_200),
            contentSize: CGSize(width: 1_500, height: 400)
        )

        #expect(rect == CGRect(x: 300, y: 40, width: 600, height: 200))
    }

    @Test("Content crops round-trip through preview pixels")
    func roundTripsContentCropThroughPreviewPixels() {
        let original = CGRect(x: 240, y: 80, width: 720, height: 240)
        let previewPixelSize = CGSize(width: 3_000, height: 1_200)
        let contentSize = CGSize(width: 1_500, height: 400)

        let preview = CropGeometry.previewRect(
            from: original,
            previewPixelSize: previewPixelSize,
            contentSize: contentSize
        )
        let restored = preview.flatMap {
            CropGeometry.contentRect(
                from: $0,
                previewPixelSize: previewPixelSize,
                contentSize: contentSize
            )
        }

        #expect(restored == original)
    }

    @Test("An out-of-bounds content crop has no preview selection")
    func rejectsOutOfBoundsContentCropForPreview() {
        let preview = CropGeometry.previewRect(
            from: CGRect(x: 900, y: 100, width: 200, height: 100),
            previewPixelSize: CGSize(width: 2_000, height: 1_000),
            contentSize: CGSize(width: 1_000, height: 500)
        )

        #expect(preview == nil)
    }

    @Test("A selection is clamped to the screenshot before converting")
    func clampsPreviewSelection() {
        let rect = CropGeometry.contentRect(
            from: CGRect(x: -20, y: -10, width: 2_040, height: 1_020),
            previewPixelSize: CGSize(width: 2_000, height: 1_000),
            contentSize: CGSize(width: 1_000, height: 500)
        )

        #expect(rect == CGRect(x: 0, y: 0, width: 1_000, height: 500))
    }

    @Test("Canvas drag locations map to preview pixels without letterboxing")
    func mapsCanvasDragWithoutLetterboxing() {
        let localSelection = CropGeometry.imageLocalSelectionRect(
            from: CGPoint(x: 100, y: 50),
            to: CGPoint(x: 400, y: 250),
            imageFrame: CGRect(x: 0, y: 0, width: 500, height: 300)
        )
        let previewSelection = CropGeometry.previewPixelRect(
            from: localSelection,
            imageDisplaySize: CGSize(width: 500, height: 300),
            previewPixelSize: CGSize(width: 1_000, height: 600)
        )

        #expect(previewSelection == CGRect(x: 200, y: 100, width: 600, height: 400))
    }

    @Test("Canvas drag locations map to preview pixels with left and right letterboxing")
    func mapsCanvasDragWithHorizontalLetterboxing() {
        let imageFrame = CGRect(x: 250, y: 0, width: 500, height: 1_000)
        let localSelection = CropGeometry.imageLocalSelectionRect(
            from: CGPoint(x: 300, y: 200),
            to: CGPoint(x: 700, y: 800),
            imageFrame: imageFrame
        )
        let previewSelection = CropGeometry.previewPixelRect(
            from: localSelection,
            imageDisplaySize: imageFrame.size,
            previewPixelSize: CGSize(width: 1_000, height: 2_000)
        )

        #expect(previewSelection == CGRect(x: 100, y: 400, width: 800, height: 1_200))
    }

    @Test("Canvas drag locations map to preview pixels with top and bottom letterboxing")
    func mapsCanvasDragWithVerticalLetterboxing() {
        let imageFrame = CGRect(x: 0, y: 250, width: 1_000, height: 500)
        let localSelection = CropGeometry.imageLocalSelectionRect(
            from: CGPoint(x: 200, y: 300),
            to: CGPoint(x: 800, y: 600),
            imageFrame: imageFrame
        )
        let previewSelection = CropGeometry.previewPixelRect(
            from: localSelection,
            imageDisplaySize: imageFrame.size,
            previewPixelSize: CGSize(width: 2_000, height: 1_000)
        )

        #expect(previewSelection == CGRect(x: 400, y: 100, width: 1_200, height: 600))
    }

    @Test("Selections smaller than the minimum content size are rejected")
    func rejectsTooSmallSelection() {
        let rect = CropGeometry.contentRect(
            from: CGRect(x: 10, y: 10, width: 3, height: 3),
            previewPixelSize: CGSize(width: 2_000, height: 1_000),
            contentSize: CGSize(width: 1_000, height: 500)
        )

        #expect(rect == nil)
    }

    @Test("A content crop that partly leaves the window is clipped to its intersection")
    func clipsPartiallyOutOfBoundsContentCrop() {
        let rect = CropGeometry.clampedContentRect(
            CGRect(x: -10, y: 100, width: 30, height: 80),
            contentSize: CGSize(width: 1_000, height: 500)
        )

        #expect(rect == CGRect(x: 0, y: 100, width: 20, height: 80))
    }

    @Test("Crop output dimensions use the shared even-pixel rule after scaling")
    func roundsScaledCropDimensionsToEvenPixels() {
        let output = CaptureDimensions.outputSize(
            contentSize: CGSize(width: 321, height: 239),
            pointPixelScale: 2,
            scalePercent: 50
        )

        #expect(output.width == 322)
        #expect(output.height == 240)

        let nonUniformOutput = CaptureDimensions.outputSize(
            contentSize: CGSize(width: 321, height: 239),
            pointPixelScale: CGSize(width: 1.5, height: 2),
            scalePercent: 50
        )
        #expect(nonUniformOutput.width == 242)
        #expect(nonUniformOutput.height == 240)
    }
}
