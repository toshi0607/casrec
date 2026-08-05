import AppKit
import SwiftUI

private func dynamicColor(
    light: (red: Double, green: Double, blue: Double),
    dark: (red: Double, green: Double, blue: Double)
) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
    })
}

enum Theme {
    static let signal = dynamicColor(
        light: (0.788, 0.145, 0.106),
        dark: (1.000, 0.294, 0.243)
    )
    static let accent = dynamicColor(
        light: (0.055, 0.557, 0.600),
        dark: (0.243, 0.796, 0.847)
    )
    static let caution = dynamicColor(
        light: (0.663, 0.455, 0.102),
        dark: (0.878, 0.651, 0.235)
    )
    static let cardFill = Color(nsColor: .controlBackgroundColor)
    static let hairline = Color(nsColor: .separatorColor)

    enum Metric {
        static let cardRadius: CGFloat = 12
        static let cardPadding: CGFloat = 14
        static let cardSpacing: CGFloat = 14
        static let gutter: CGFloat = 16
        static let contentMaxWidth: CGFloat = 760
        static let controlRadius: CGFloat = 8
        static let chipRadius: CGFloat = 6
    }
}

extension Font {
    static func machine(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

struct SectionCard<Accessory: View, Content: View>: View {
    private let title: String
    private let accessory: Accessory
    private let content: Content

    init(
        _ title: String,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).cardTitleStyle()
                Spacer()
                accessory
            }
            content
        }
        .padding(Theme.Metric.cardPadding)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.Metric.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Metric.cardRadius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
    }
}

extension SectionCard where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
    }
}

struct NoticeBanner<Extra: View>: View {
    enum Severity {
        case info
        case caution
        case critical
    }

    private let severity: Severity
    private let title: String?
    private let message: String
    private let extra: Extra

    init(
        _ severity: Severity,
        title: String? = nil,
        message: String,
        @ViewBuilder extra: () -> Extra
    ) {
        self.severity = severity
        self.title = title
        self.message = message
        self.extra = extra()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbolName)
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: 4) {
                if let title {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                extra
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Metric.controlRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Metric.controlRadius, style: .continuous)
                .strokeBorder(color.opacity(0.28), lineWidth: 1)
        }
    }

    private var color: Color {
        switch severity {
        case .info:
            Theme.accent
        case .caution:
            Theme.caution
        case .critical:
            Theme.signal
        }
    }

    private var symbolName: String {
        switch severity {
        case .info:
            "info.circle.fill"
        case .caution:
            "exclamationmark.triangle.fill"
        case .critical:
            "exclamationmark.octagon.fill"
        }
    }
}

extension NoticeBanner where Extra == EmptyView {
    init(_ severity: Severity, title: String? = nil, message: String) {
        self.init(severity, title: title, message: message, extra: { EmptyView() })
    }
}

struct FieldRow<Control: View>: View {
    private let label: String
    private let control: Control

    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).fieldLabelStyle()
            control
        }
    }
}

extension View {
    func cardTitleStyle() -> some View {
        font(.system(size: 12, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
    }

    func fieldLabelStyle() -> some View {
        font(.system(size: 11))
            .foregroundStyle(.secondary)
    }

    func metaStyle() -> some View {
        font(.system(size: 11))
            .foregroundStyle(.secondary)
    }
}
