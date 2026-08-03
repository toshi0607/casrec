import SwiftUI

struct SourcePickerView: View {
    let sources: [CaptureSource]
    @Binding var selectedSourceId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sources")
                .font(.caption)
                .foregroundColor(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(sources) { source in
                        VStack(alignment: .center, spacing: 6) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.gray.opacity(0.2))

                                if let thumbnail = source.thumbnail {
                                    Image(thumbnail, scale: 1.0, label: Text(source.title))
                                        .resizable()
                                        .scaledToFill()
                                        .clipped()
                                } else {
                                    VStack {
                                        Image(systemName: source.kind == .display ? "rectangle.and.hand.point.up.left" : "uiwindow.split.2x1")
                                            .font(.title3)
                                            .foregroundColor(.secondary)
                                    }
                                }

                                if selectedSourceId == source.id {
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(Color.blue, lineWidth: 2)
                                }
                            }
                            .frame(width: 100, height: 75)

                            Text(source.appName ?? source.title)
                                .font(.caption2)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 100)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedSourceId = source.id
                        }
                    }
                }
                .padding(.horizontal, 0)
            }
        }
    }
}
