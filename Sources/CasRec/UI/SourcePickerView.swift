import SwiftUI

struct SourcePickerView: View {
    let sources: [CaptureSource]
    @Binding var selectedSourceId: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(sources) { source in
                    let isSelected = selectedSourceId == source.id

                    if isSelected {
                        sourceItem(for: source, isSelected: true)
                            .help(source.title)
                    } else {
                        sourceItem(for: source, isSelected: false)
                    }
                }
            }
        }
    }

    private func sourceItem(for source: CaptureSource, isSelected: Bool) -> some View {
        VStack(alignment: .center, spacing: 6) {
            thumbnail(for: source, isSelected: isSelected)

            Text(source.appName ?? source.title)
                .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 132)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedSourceId = source.id
        }
        .accessibilityLabel(source.appName ?? source.title)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func thumbnail(for source: CaptureSource, isSelected: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Metric.controlRadius, style: .continuous)
                .fill(Theme.hairline.opacity(0.5))

            if let thumbnail = source.thumbnail {
                Image(thumbnail, scale: 1.0, label: Text(source.title))
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: source.kind == .display ? "rectangle.and.hand.point.up.left" : "uiwindow.split.2x1")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 132, height: 82)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.controlRadius, style: .continuous))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: Theme.Metric.controlRadius, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 2)
            }
        }
        .shadow(color: isSelected ? Theme.accent.opacity(0.20) : .clear, radius: 3)
    }
}
