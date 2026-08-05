import AppKit
import Observation
import SwiftUI

struct MenuBarControls: View {
    @Bindable var controls: RecordingControls
    @Bindable var usageNotice: UsageNoticeController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            statusLabel

            Button(actionTitle) {
                Task {
                    await controls.toggleQuickRecording(
                        allowsRecordingStart: usageNotice.allowsRecordingStart
                    )
                }
            }
            .disabled(currentQuickRecordingAction == .none)

            Button("メインウィンドウを開く") {
                showMainWindow()
            }

            Divider()

            Button("CasRec を終了") {
                NSApp.terminate(nil)
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if let scheduledRecording = controls.scheduledRecording,
           currentQuickRecordingAction == .start {
            Text("予約済み \(scheduledRecording.startAt, format: .dateTime.hour().minute())")
        } else {
            switch controls.currentState {
            case .idle:
                Text("待機中")
            case .recording(let progress):
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("録画中 \(elapsedTime(since: progress.startedAt))")
                }
            case .preparing:
                Text("録画を準備中")
            case .finishing:
                Text("録画を終了中")
            case .failed:
                Text("録画エラー")
            }
        }
    }

    private var actionTitle: String {
        currentQuickRecordingAction == .stop ? "録画を停止" : "録画を開始"
    }

    private var currentQuickRecordingAction: QuickRecordingAction {
        quickRecordingAction(
            for: controls.currentState,
            allowsRecordingStart: usageNotice.allowsRecordingStart
        )
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MenuBarIcon: View {
    let state: RecordingState

    var body: some View {
        switch state {
        case .idle:
            Image(systemName: "record.circle")
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        case .recording:
            Image(systemName: "record.circle.fill")
                .foregroundStyle(.red)
        case .preparing:
            Image(systemName: "record.circle.dotted")
        case .finishing:
            Image(systemName: "record.circle.fill")
                .foregroundStyle(.secondary)
        }
    }
}

private func elapsedTime(since startedAt: Date) -> String {
    let seconds = max(0, Int(Date().timeIntervalSince(startedAt)))
    return String(format: "%02d:%02d:%02d", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
}
