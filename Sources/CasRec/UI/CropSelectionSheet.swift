import SwiftUI

/// A sheet-local editor for one fresh window screenshot. It only produces a content-space
/// crop rect; `MainView` owns the recording settings and decides when to persist or clear it.
struct CropSelectionSheet: View {
    let preview: CapturePreview
    let onConfirm: (CGRect, CGSize) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectionInPreviewPixels: CGRect?

    init(
        preview: CapturePreview,
        initialContentRect: CGRect?,
        onConfirm: @escaping (CGRect, CGSize) -> Void
    ) {
        self.preview = preview
        self.onConfirm = onConfirm
        let previewPixelSize = CGSize(width: preview.image.width, height: preview.image.height)
        _selectionInPreviewPixels = State(initialValue: initialContentRect.flatMap {
            CropGeometry.previewRect(
                from: $0,
                previewPixelSize: previewPixelSize,
                contentSize: preview.contentSize
            )
        })
    }

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
                .cardTitleStyle()

            CropPreviewCanvas(
                image: preview.image,
                previewPixelSize: previewPixelSize,
                selectionInPreviewPixels: $selectionInPreviewPixels
            )
            .frame(minWidth: 640, minHeight: 360, maxHeight: 620)

            HStack {
                if let selectedPixelSize {
                    Text("領域 \(Int(selectedPixelSize.width))×\(Int(selectedPixelSize.height))")
                        .font(.machine(11))
                        .foregroundStyle(Theme.accent)
                } else {
                    Text("最小 2 pt × 2 pt の領域を選択してください")
                        .metaStyle()
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
    private static let coordinateSpaceName = "cropCanvas"

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
                    Path { path in
                        path.addRect(imageFrame)
                        path.addRect(selection)
                    }
                    .fill(Color.black.opacity(0.18), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)

                    Rectangle()
                        .stroke(Theme.accent, lineWidth: 2)
                        .frame(width: selection.width, height: selection.height)
                        .position(x: selection.midX, y: selection.midY)
                        .allowsHitTesting(false)
                }

                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: imageFrame.width, height: imageFrame.height)
                    .position(x: imageFrame.midX, y: imageFrame.midY)
                    .gesture(selectionGesture(imageFrame: imageFrame))
            }
            .coordinateSpace(name: Self.coordinateSpaceName)
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

    private func selectionGesture(imageFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName))
            .onChanged { value in
                let viewSelection = CropGeometry.imageLocalSelectionRect(
                    from: value.startLocation,
                    to: value.location,
                    imageFrame: imageFrame
                )
                selectionInPreviewPixels = CropGeometry.previewPixelRect(
                    from: viewSelection,
                    imageDisplaySize: imageFrame.size,
                    previewPixelSize: previewPixelSize
                )
            }
    }
}
