import SwiftUI

struct SendableCaptureSourceRef: @unchecked Sendable {
    let value: CaptureSource
}

struct MainView: View {
    nonisolated(unsafe) let session: any RecordingSessionControlling
    nonisolated(unsafe) let captureService: any CaptureServicing

    @State private var currentState: RecordingState = .idle
    @State private var sources: [CaptureSource] = []
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

    var selectedSource: CaptureSource? {
        sources.first { $0.id == selectedSourceId }
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
        .task {
            await observeSources()
        }
    }

    private var sourceSelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
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

                Spacer()
            }

            SourcePickerView(
                sources: sources.filter { $0.kind == captureMode },
                selectedSourceId: $selectedSourceId
            )
        }
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
                }) {
                    HStack {
                        Image(systemName: "play.circle.fill")
                        Text("Start Recording")
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
                    let sendableSource = SendableCaptureSourceRef(value: source)
                    let capturedSettings = settings
                    Task {
                        await session.start(source: sendableSource.value, settings: capturedSettings)
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
        for await sourcesUpdate in stream {
            sources = sourcesUpdate
            if selectedSourceId == nil, let first = sourcesUpdate.first {
                selectedSourceId = first.id
            }
        }
    }
}
