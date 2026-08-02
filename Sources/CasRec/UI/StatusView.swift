import SwiftUI

struct StatusView: View {
    let progress: RecordingProgress

    private var elapsedTime: String {
        let elapsed = Date().timeIntervalSince(progress.startedAt)
        let hours = Int(elapsed) / 3600
        let minutes = (Int(elapsed) % 3600) / 60
        let seconds = Int(elapsed) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    private var fileSize: String {
        let bytes = Double(progress.bytesWritten)
        if bytes >= 1_000_000_000 {
            return String(format: "%.1f GB", bytes / 1_000_000_000)
        } else {
            return String(format: "%.1f MB", bytes / 1_000_000)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            if progress.isStalled {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.yellow)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Stalled")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text("10秒以上フレームが届いていません。対象ウィンドウが最小化されていないか確認してください")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(8)
                .background(Color.yellow.opacity(0.1))
                .cornerRadius(6)
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Elapsed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(elapsedTime)
                        .font(.system(.body, design: .monospaced))
                }

                Divider()

                VStack(alignment: .leading, spacing: 2) {
                    Text("Size")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(fileSize)
                        .font(.system(.body, design: .monospaced))
                }

                Divider()

                VStack(alignment: .leading, spacing: 2) {
                    Text("Drops")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(progress.droppedFrames)")
                        .font(.system(.body, design: .monospaced))
                }

                Spacer()
            }
            .font(.system(.caption, design: .monospaced))
        }
    }
}
