import CoreGraphics

/// Pure coordinate and sizing rules for a window crop. SwiftUI supplies drag positions in
/// screenshot pixels; ScreenCaptureKit's `sourceRect` expects points in the filter's
/// content coordinate space.
enum CropGeometry {
    /// Two points keeps a drag from becoming a degenerate source rect while staying below
    /// any useful video dimension. Encoders impose their own even-pixel constraint later.
    static let minimumContentSize = CGSize(width: 2, height: 2)

    /// Converts a selection on a preview image (pixels, upper-left origin) into the
    /// selected window filter's content coordinates (points, upper-left origin).
    static func contentRect(
        from previewSelection: CGRect,
        previewPixelSize: CGSize,
        contentSize: CGSize
    ) -> CGRect? {
        guard previewPixelSize.width > 0, previewPixelSize.height > 0,
              contentSize.width > 0, contentSize.height > 0 else {
            return nil
        }

        let previewBounds = CGRect(origin: .zero, size: previewPixelSize)
        let selection = previewSelection.standardized.intersection(previewBounds)
        guard !selection.isNull, !selection.isEmpty else { return nil }

        let pointScale = CGSize(
            width: contentSize.width / previewPixelSize.width,
            height: contentSize.height / previewPixelSize.height
        )
        let converted = CGRect(
            x: selection.minX * pointScale.width,
            y: selection.minY * pointScale.height,
            width: selection.width * pointScale.width,
            height: selection.height * pointScale.height
        )
        return clampedContentRect(converted, contentSize: contentSize)
    }

    /// Revalidates a persisted crop against the content size at capture start. This is
    /// needed when the user resized the target window after making the selection.
    static func clampedContentRect(_ rect: CGRect, contentSize: CGSize) -> CGRect? {
        guard contentSize.width > 0, contentSize.height > 0 else { return nil }
        let bounds = CGRect(origin: .zero, size: contentSize)
        let clipped = rect.standardized.intersection(bounds)
        guard !clipped.isNull,
              clipped.width >= minimumContentSize.width,
              clipped.height >= minimumContentSize.height else {
            return nil
        }
        return clipped
    }

    /// Maps a drag in a fitted SwiftUI image view into the image's native pixel space.
    /// Keeping this calculation here makes the UI's display scaling irrelevant to the
    /// `sourceRect` conversion above.
    static func previewPixelRect(
        from viewSelection: CGRect,
        imageDisplaySize: CGSize,
        previewPixelSize: CGSize
    ) -> CGRect? {
        guard imageDisplaySize.width > 0, imageDisplaySize.height > 0,
              previewPixelSize.width > 0, previewPixelSize.height > 0 else {
            return nil
        }
        let scale = CGSize(
            width: previewPixelSize.width / imageDisplaySize.width,
            height: previewPixelSize.height / imageDisplaySize.height
        )
        let converted = CGRect(
            x: viewSelection.minX * scale.width,
            y: viewSelection.minY * scale.height,
            width: viewSelection.width * scale.width,
            height: viewSelection.height * scale.height
        )
        return converted.standardized.intersection(CGRect(origin: .zero, size: previewPixelSize))
    }
}

/// Shared output sizing rule. Both whole-window and cropped capture use this exact
/// even-pixel rounding before the HEVC/H.264 writer receives samples.
enum CaptureDimensions {
    static func outputSize(
        contentSize: CGSize,
        pointPixelScale: CGFloat,
        scalePercent: Int
    ) -> (width: Int, height: Int) {
        let percent = CGFloat(scalePercent) / 100.0
        return (
            width: evenPixelCount(contentSize.width * pointPixelScale * percent),
            height: evenPixelCount(contentSize.height * pointPixelScale * percent)
        )
    }

    static func evenPixelCount(_ raw: CGFloat) -> Int {
        let value = max(2, Int(raw.rounded()))
        return value.isMultiple(of: 2) ? value : value + 1
    }
}
