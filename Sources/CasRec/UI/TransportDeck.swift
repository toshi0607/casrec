import SwiftUI

struct TransportDeck: View {
    let state: RecordingState
    let maximumDuration: TimeInterval?
    /// 録画対象の表示名。`source.appName ?? source.title`。
    let sourceTitle: String?
    let canStart: Bool
    let start: () -> Void
    let stop: () -> Void
    let dismissFailure: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false
    @State private var frozenElapsed: TimeInterval = 0

    private var progress: RecordingProgress? {
        guard case .recording(let progress) = state else { return nil }
        return progress
    }

    private var stateKey: String {
        switch state {
        case .idle:
            "idle"
        case .preparing:
            "preparing"
        case .recording:
            "recording"
        case .finishing:
            "finishing"
        case .failed:
            "failed"
        }
    }

    private var isRecording: Bool { progress != nil }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 0) {
                progressTrack(at: context.date)
                warningStrip
                mainRow(at: context.date)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
        }
        .background {
            Rectangle()
                .fill(.bar)
                .overlay {
                    if isRecording || isFailure {
                        Theme.signal.opacity(0.07)
                    }
                }
        }
        .animation(.snappy(duration: 0.25), value: stateKey)
        .onAppear {
            updatePulsing()
        }
        .onChange(of: stateKey) {
            updatePulsing()
        }
        .onChange(of: state) { oldState, _ in
            if case .recording(let progress) = oldState {
                frozenElapsed = max(0, Date().timeIntervalSince(progress.startedAt))
            }
        }
        .onChange(of: reduceMotion) {
            updatePulsing()
        }
    }

    @ViewBuilder
    private func progressTrack(at date: Date) -> some View {
        if let progress, let maximumDuration {
            let ratio = min(1, max(0, date.timeIntervalSince(progress.startedAt) / maximumDuration))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.hairline)
                    Rectangle()
                        .fill(Theme.signal)
                        .frame(width: geometry.size.width * ratio)
                }
            }
            .frame(height: 2)
        } else {
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var warningStrip: some View {
        if let progress, progress.diskWarning || progress.isStalled {
            VStack(spacing: 6) {
                if progress.diskWarning {
                    NoticeBanner(
                        .caution,
                        title: "空き容量が少なくなっています",
                        message: "保存先の空き容量が5GB未満です。2GB未満になると録画を自動停止します"
                    )
                }
                if progress.isStalled {
                    NoticeBanner(
                        .caution,
                        title: "フレームが届いていません",
                        message: "10秒以上フレームが届いていません。対象ウィンドウが最小化されていないか確認してください"
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
        }
    }

    private func mainRow(at date: Date) -> some View {
        HStack(alignment: .center, spacing: 16) {
            recordingButton

            VStack(alignment: .leading, spacing: 2) {
                Text(timeCode(at: date))
                    .font(.machine(34, weight: .light).monospacedDigit())
                    .foregroundStyle(timeCodeStyle)
                subline
            }

            Spacer(minLength: 12)

            if let progress {
                measurementRail(progress)
            } else if isFailure {
                Button("閉じる", action: dismissFailure)
                    .buttonStyle(.borderless)
            }

            if let maximumDuration {
                durationBadge(maximumDuration, at: date)
            }
        }
    }

    private var recordingButton: some View {
        Button(action: buttonAction) {
            ZStack {
                Circle().fill(Theme.cardFill)
                Circle().strokeBorder(Theme.hairline, lineWidth: 1)
                buttonGlyph
            }
            .frame(width: 52, height: 52)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled((isIdle && !canStart) || (!isRecording && !isIdle))
        .help(buttonHelp)
        .accessibilityLabel(buttonAccessibilityLabel)
    }

    @ViewBuilder
    private var buttonGlyph: some View {
        switch state {
        case .idle, .failed:
            Circle()
                .fill(Theme.signal.opacity(canStart && isIdle ? 1 : 0.3))
                .frame(width: 20, height: 20)
        case .preparing, .finishing:
            ProgressView()
                .controlSize(.small)
        case .recording:
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Theme.signal)
                .frame(width: 18, height: 18)
                .opacity(reduceMotion ? 1 : (isPulsing ? 0.5 : 1))
                .shadow(color: Theme.signal.opacity(0.45), radius: 8)
        }
    }

    @ViewBuilder
    private var subline: some View {
        let label = Text(sublineText)
            .font(.system(size: 11))
            .foregroundStyle(isFailure ? Theme.signal : .secondary)
            .lineLimit(1)

        if let failureMessage {
            label.help(failureMessage)
        } else {
            label
        }
    }

    private func measurementRail(_ progress: RecordingProgress) -> some View {
        HStack(spacing: 10) {
            measurement(label: "サイズ", value: fileSize(progress.bytesWritten))
            railDivider
            measurement(label: "ドロップ", value: "\(progress.droppedFrames)")
            if progress.audioAppendFailures > 0 {
                railDivider
                measurement(label: "音声エラー", value: "\(progress.audioAppendFailures)")
            }
        }
    }

    private func measurement(label: String, value: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .tracking(0.4)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.machine(13, weight: .medium))
                .foregroundStyle(.primary)
        }
    }

    private var railDivider: some View {
        Divider().frame(height: 22)
    }

    private func durationBadge(_ maximumDuration: TimeInterval, at date: Date) -> some View {
        let ratio: Double
        if let progress {
            ratio = min(1, max(0, date.timeIntervalSince(progress.startedAt) / maximumDuration))
        } else {
            ratio = 0
        }
        let label = RecordingDurationLimit.allCases.first { $0.duration == maximumDuration }?.hudLabel ?? ""

        return HStack(spacing: 5) {
            ZStack {
                Circle().stroke(Theme.hairline, lineWidth: 2)
                if isRecording {
                    Circle()
                        .trim(from: 0, to: ratio)
                        .stroke(Theme.signal, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
            .frame(width: 18, height: 18)

            Text(label)
                .font(.machine(11))
                .foregroundStyle(.secondary)
        }
    }

    private var isIdle: Bool {
        if case .idle = state { return true }
        return false
    }

    private var isFailure: Bool {
        if case .failed = state { return true }
        return false
    }

    private var failureMessage: String? {
        guard case .failed(let message) = state else { return nil }
        return message
    }

    private var sublineText: String {
        switch state {
        case .idle:
            guard let sourceTitle else { return "録画対象を選択してください" }
            return "\(sourceTitle) ・ ⌥⌘R でも開始できます"
        case .preparing:
            return "録画を開始しています"
        case .recording:
            return sourceTitle ?? ""
        case .finishing:
            return "ファイルを書き出しています"
        case .failed(let message):
            return "録画に失敗しました: \(message)"
        }
    }

    private var timeCodeStyle: AnyShapeStyle {
        switch state {
        case .recording:
            AnyShapeStyle(.primary)
        case .preparing, .finishing:
            AnyShapeStyle(.secondary)
        case .idle, .failed:
            AnyShapeStyle(.tertiary)
        }
    }

    private var buttonHelp: String {
        isRecording ? "録画を停止 (⌥⌘R)" : "録画を開始 (⌥⌘R)"
    }

    private var buttonAccessibilityLabel: String {
        isRecording ? "録画を停止" : "録画を開始"
    }

    private func buttonAction() {
        if isRecording {
            stop()
        } else if isIdle {
            start()
        }
    }

    private func timeCode(at date: Date) -> String {
        let elapsed: TimeInterval
        switch state {
        case .recording(let progress):
            elapsed = max(0, date.timeIntervalSince(progress.startedAt))
        case .finishing:
            elapsed = frozenElapsed
        case .idle, .preparing, .failed:
            elapsed = 0
        }
        let totalSeconds = Int(elapsed)
        return String(format: "%02d:%02d:%02d", totalSeconds / 3600, (totalSeconds % 3600) / 60, totalSeconds % 60)
    }

    private func fileSize(_ bytesWritten: Int64) -> String {
        let bytes = Double(bytesWritten)
        if bytes >= 1_000_000_000 {
            return String(format: "%.1f GB", bytes / 1_000_000_000)
        }
        return String(format: "%.1f MB", bytes / 1_000_000)
    }

    private func updatePulsing() {
        guard isRecording, !reduceMotion else {
            isPulsing = false
            return
        }
        isPulsing = false
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
            isPulsing = true
        }
    }
}
