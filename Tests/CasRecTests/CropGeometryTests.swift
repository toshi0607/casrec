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

    @Test("A selection is clamped to the screenshot before converting")
    func clampsPreviewSelection() {
        let rect = CropGeometry.contentRect(
            from: CGRect(x: -20, y: -10, width: 2_040, height: 1_020),
            previewPixelSize: CGSize(width: 2_000, height: 1_000),
            contentSize: CGSize(width: 1_000, height: 500)
        )

        #expect(rect == CGRect(x: 0, y: 0, width: 1_000, height: 500))
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

    @Test("Crop output dimensions use the shared even-pixel rule after scaling")
    func roundsScaledCropDimensionsToEvenPixels() {
        let output = CaptureDimensions.outputSize(
            contentSize: CGSize(width: 321, height: 239),
            pointPixelScale: 2,
            scalePercent: 50
        )

        #expect(output.width == 322)
        #expect(output.height == 240)
    }
}
