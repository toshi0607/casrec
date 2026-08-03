import AppKit
import SwiftUI

struct MainView: View {
    /// Deep link to System Settings › Privacy & Security › Screen Recording (§5.5).
    private static let screenRecordingSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )

    let session: any RecordingSessionControlling
    let captureService: any CaptureServicing

    @State private var currentState: RecordingState = .idle
    @State private var sources: [CaptureSource] = []
    /// Non-nil while the source list cannot be read — most importantly when screen
    /// recording has not been granted, which is otherwise indistinguishable from
    /// "nothing is open to capture" (§5.5).
    @State private var sourcesUnavailable: CaptureUnavailableReason?
    @State private var selectedSourceId: String?

    @State private var settings = RecordingSettings.default
    @State private var captureMode: CaptureSourceKind = .window

    @State private var errorMessage: String?
    @State private var showingError = false

    var isRecording: Bool {
        if case .recording = currentState {
            return true
        }
        return false
    }

    var isTransitioning: Bool {
        if case .preparing = currentState {
            return true
        }
        if case .finishing = currentState {
            return true
        }
        return false
    }

    /// Enumerating sources screenshots every window every two seconds. During a recording
    /// that competes with the capture itself for the GPU for hours on end, so polling is
    /// suspended for the duration and resumed when the session returns to idle (R5).
    var isPollingSources: Bool {
        switch currentState {
        case .recording, .finishing:
            return false
        case .idle, .preparing, .failed:
            return true
        }
    }

    /// Only the sources matching the current mode are offered, so the selection must be
    /// resolved against that list — never against the full one.
    var visibleSources: [CaptureSource] {
        sources.filter { $0.kind == captureMode }
    }

    var selectedSource: CaptureSource? {
        visibleSources.first { $0.id == selectedSourceId }
    }

    var body: some View {
        VStack(spacing: 16) {
            ScrollView {
                VStack(spacing: 16) {
                    sourceSelectionSection
                    audioSettingsSection
                    captureSettingsSection
                    savePathSection
                }
                .padding(16)
            }

            Divider()

            recordingControlSection

            if isRecording, case .recording(let progress) = currentState {
                StatusView(progress: progress)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .padding(16)
        .alert("Recording Error", isPresented: $showingError) {
            Button("OK") {
                showingError = false
            }
        } message: {
            Text(errorMessage ?? "An unknown error occurred")
        }
        .task {
            await observeState()
        }
        .task(id: isPollingSources) {
            guard isPollingSources else { return }
            await observeSources()
        }
    }

    private var sourceSelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let reason = sourcesUnavailable {
                sourcesUnavailableBanner(reason: reason)
            }

            HStack(spacing: 16) {
                Text("Mode")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("Mode", selection: $captureMode) {
                    ForEach(CaptureSourceKind.allCases, id: \.self) { kind in
                        Text(kind == .display ? "Full Screen" : "Window")
                            .tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 250)
                .onChange(of: captureMode) {
                    syncSelection()
                }

                Spacer()
            }

            SourcePickerView(
                sources: visibleSources,
                selectedSourceId: $selectedSourceId
            )
        }
    }

    /// An empty picker is ambiguous — nothing open, or nothing allowed? — so the reason is
    /// stated, and the permission case gets the one action that resolves it (§5.5).
    @ViewBuilder
    private func sourcesUnavailableBanner(reason: CaptureUnavailableReason) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(reason == .permissionDenied ? "Screen Recording Not Allowed" : "Sources Unavailable")
                    .fontWeight(.semibold)
            }

            switch reason {
            case .permissionDenied:
                Text("システム設定の「プライバシーとセキュリティ > 画面収録」で CasRec を許可してください。")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let url = Self.screenRecordingSettingsURL {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(url)
                    }
                }

                Text("許可した後は、CasRec を再起動すると録画できるようになります。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
    }

    private var audioSettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Audio")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 20) {
                Toggle(isOn: $settings.captureAppAudio) {
                    Text("App Audio")
                        .font(.caption)
                }

                Toggle(isOn: $settings.captureMicrophone) {
                    Text("Microphone")
                        .font(.caption)
                }

                Spacer()
            }
        }
    }

    private var captureSettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Codec")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Picker("Codec", selection: $settings.codec) {
                        Text("HEVC").tag(VideoCodec.hevc)
                        Text("H.264").tag(VideoCodec.h264)
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Resolution")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Picker("Resolution", selection: $settings.scalePercent) {
                        Text("100%").tag(100)
                        Text("50%").tag(50)
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("FPS")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Picker("FPS", selection: $settings.fps) {
                        Text("30").tag(30)
                        Text("60").tag(60)
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer()
            }
        }
    }

    private var savePathSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Save to")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(settings.destinationDirectory.path)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
            }
        }
    }

    private var recordingControlSection: some View {
        VStack(spacing: 12) {
            if isRecording {
                Button(action: {
                    Task {
                        await session.stop()
                    }
                }) {
                    HStack {
                        Image(systemName: "stop.fill")
                        Text("Stop Recording")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(12)
                    .background(Color.red)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .disabled(isTransitioning)
            } else if isTransitioning {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text(currentState == .preparing ? "Starting..." : "Stopping...")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(Color.gray.opacity(0.2))
                .cornerRadius(8)
            } else if case .failed(let message) = currentState {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(.red)
                        Text("Recording Failed")
                            .fontWeight(.semibold)
                    }
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.red.opacity(0.1))
                .cornerRadius(8)

                Button(action: {
                    errorMessage = nil
                    // Without this the session stays `failed` forever and every later
                    // start is ignored (§4: failed -> idle).
                    Task {
                        await session.acknowledgeFailure()
                    }
                }) {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                        Text("Dismiss")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(12)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
            } else {
                Button(action: {
                    guard let source = selectedSource else { return }
                    let capturedSettings = settings
                    Task {
                        await session.start(source: source, settings: capturedSettings)
                    }
                }) {
                    HStack {
                        Image(systemName: "record.circle.fill")
                        Text("Start Recording")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(12)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .disabled(selectedSource == nil)
            }
        }
    }

    private func observeState() async {
        let stream = session.observeState()
        for await state in stream {
            currentState = state
            if case .failed(let message) = state {
                errorMessage = message
                showingError = true
            }
        }
    }

    private func observeSources() async {
        let stream = captureService.observeSources()
        for await update in stream {
            switch update {
            case .sources(let list):
                sources = list
                sourcesUnavailable = nil
            case .unavailable(let reason):
                sources = []
                sourcesUnavailable = reason
            }
            syncSelection()
        }
    }

    /// Keeps `selectedSourceId` pointing at something the user can actually see: the first
    /// entry of the current mode's list whenever the selection is empty or has dropped out
    /// of it (mode switch, or the selected window closing).
    private func syncSelection() {
        let visible = visibleSources
        guard !visible.contains(where: { $0.id == selectedSourceId }) else { return }
        selectedSourceId = visible.first?.id
    }
}
