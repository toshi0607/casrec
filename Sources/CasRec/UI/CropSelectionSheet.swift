import SwiftUI

/// A sheet-local editor for one fresh window screenshot. It only produces a content-space
/// crop rect; `MainView` owns the recording settings and decides when to persist or clear it.
struct CropSelectionSheet: View {
    let preview: CapturePreview
    let onConfirm: (CGRect, CGSize) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectionInPreviewPixels: CGRect?

    private var previewPixelSize: CGSize {
        CGSize(width: preview.image.width, height: preview.image.height)
    }

    private var selectedContentRect: CGRect? {
        guard let selectionInPreviewPixels else { return nil }
        return CropGeometry.contentRect(
            from: selectionInPreviewPixels,
            previewPixelSize: previewPixelSize,
            contentSize: preview.contentSize
        )
    }

    private var selectedPixelSize: CGSize? {
        guard let selectedContentRect,
              preview.contentSize.width > 0,
              preview.contentSize.height > 0 else {
            return nil
        }
        let scale = CGSize(
            width: previewPixelSize.width / preview.contentSize.width,
            height: previewPixelSize.height / preview.contentSize.height
        )
        let outputSize = CaptureDimensions.outputSize(
            contentSize: selectedContentRect.size,
            pointPixelScale: scale,
            scalePercent: 100
        )
        return CGSize(width: outputSize.width, height: outputSize.height)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("録画する領域をドラッグで選択")
                .font(.headline)

            CropPreviewCanvas(
                image: preview.image,
                previewPixelSize: previewPixelSize,
                selectionInPreviewPixels: $selectionInPreviewPixels
            )
            .frame(minWidth: 640, minHeight: 360, maxHeight: 620)

            HStack {
                if let selectedPixelSize {
                    Text("領域: \(Int(selectedPixelSize.width))×\(Int(selectedPixelSize.height))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("最小 2 pt × 2 pt の領域を選択してください")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("クリア") {
                    selectionInPreviewPixels = nil
                }
                .disabled(selectionInPreviewPixels == nil)

                Button("キャンセル") {
                    dismiss()
                }

                Button("決定") {
                    guard let selectedContentRect, let selectedPixelSize else { return }
                    onConfirm(selectedContentRect, selectedPixelSize)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedContentRect == nil)
            }
        }
        .padding(20)
    }
}

/// Draws the screenshot at its fitted size and maps the local drag back to native preview
/// pixels. The only coordinate conversion that reaches capture setup remains in
/// `CropGeometry`, which is unit-tested independently of SwiftUI.
private struct CropPreviewCanvas: View {
    let image: CGImage
    let previewPixelSize: CGSize
    @Binding var selectionInPreviewPixels: CGRect?

    var body: some View {
        GeometryReader { proxy in
            let imageFrame = fittedImageFrame(in: proxy.size)

            ZStack(alignment: .topLeading) {
                Color.black

                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .frame(width: imageFrame.width, height: imageFrame.height)
                    .position(x: imageFrame.midX, y: imageFrame.midY)

                if let selectionInPreviewPixels {
                    let selection = selectionFrame(
                        for: selectionInPreviewPixels,
                        in: imageFrame
                    )
                    Rectangle()
                        .fill(Color.black.opacity(0.18))
                        .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 2))
                        .frame(width: selection.width, height: selection.height)
                        .position(x: selection.midX, y: selection.midY)
                        .allowsHitTesting(false)
                }

                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: imageFrame.width, height: imageFrame.height)
                    .position(x: imageFrame.midX, y: imageFrame.midY)
                    .gesture(selectionGesture(imageDisplaySize: imageFrame.size))
            }
        }
    }

    private func fittedImageFrame(in containerSize: CGSize) -> CGRect {
        guard previewPixelSize.width > 0, previewPixelSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else {
            return .zero
        }
        let scale = min(
            containerSize.width / previewPixelSize.width,
            containerSize.height / previewPixelSize.height
        )
        let size = CGSize(width: previewPixelSize.width * scale, height: previewPixelSize.height * scale)
        return CGRect(
            x: (containerSize.width - size.width) / 2,
            y: (containerSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func selectionFrame(for selection: CGRect, in imageFrame: CGRect) -> CGRect {
        CGRect(
            x: imageFrame.minX + selection.minX / previewPixelSize.width * imageFrame.width,
            y: imageFrame.minY + selection.minY / previewPixelSize.height * imageFrame.height,
            width: selection.width / previewPixelSize.width * imageFrame.width,
            height: selection.height / previewPixelSize.height * imageFrame.height
        )
    }

    private func selectionGesture(imageDisplaySize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let viewSelection = CGRect(
                    x: min(value.startLocation.x, value.location.x),
                    y: min(value.startLocation.y, value.location.y),
                    width: abs(value.location.x - value.startLocation.x),
                    height: abs(value.location.y - value.startLocation.y)
                )
                selectionInPreviewPixels = CropGeometry.previewPixelRect(
                    from: viewSelection,
                    imageDisplaySize: imageDisplaySize,
                    previewPixelSize: previewPixelSize
                )
            }
    }
}
