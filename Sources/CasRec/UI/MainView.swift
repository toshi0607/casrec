import AppKit
import SwiftUI

struct MainView: View {
    /// Deep link to System Settings › Privacy & Security › Screen Recording (§5.5).
    private static let screenRecordingSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )

    let session: any RecordingSessionControlling
    let captureService: any CaptureServicing
    @Bindable var controls: RecordingControls

    @State private var sources: [CaptureSource] = []
    /// Non-nil while the source list cannot be read — most importantly when screen
    /// recording has not been granted, which is otherwise indistinguishable from
    /// "nothing is open to capture" (§5.5).
    @State private var sourcesUnavailable: CaptureUnavailableReason?
    @State private var selectedSourceId: String?

    @State private var libraryRefreshToken = 0
    @State private var wasRecording = false
    @State private var captureMode: CaptureSourceKind = .window
    @State private var cropPreview: CapturePreview?
    @State private var cropPreviewSourceID: String?
    @State private var cropPixelSize: CGSize?
    @State private var isLoadingCropPreview = false
    @State private var scheduledStartAt = Date().addingTimeInterval(10 * 60)
    @State private var scheduledMaximumDuration: RecordingDurationLimit = .none
    @State private var errorMessage: String?
    @State private var showingError = false

    init(
        session: any RecordingSessionControlling,
        captureService: any CaptureServicing,
        controls: RecordingControls
    ) {
        self.session = session
        self.captureService = captureService
        self.controls = controls
        _selectedSourceId = State(initialValue: controls.selectedSourceID)
    }

    private var currentState: RecordingState { controls.currentState }

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
        TabView {
            recordingTab
                .tabItem {
                    Label("録画", systemImage: "record.circle")
                }

            LibraryView(
                directory: controls.settings.destinationDirectory,
                refreshToken: libraryRefreshToken,
                allowsDeletion: !isRecording && !isTransitioning
            )
            .tabItem {
                Label("ライブラリ", systemImage: "film.stack")
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .task(id: isPollingSources) {
            guard isPollingSources else { return }
            await observeSources()
        }
        .onChange(of: currentState) { _, state in
            updateRecordingCompletion(state)
        }
        .sheet(item: $cropPreview) { preview in
            CropSelectionSheet(
                preview: preview,
                initialContentRect: cropPreviewSourceID == selectedSourceId ? controls.settings.sourceCropRect : nil
            ) { rect, pixelSize in
                guard cropPreviewSourceID == selectedSourceId else { return }
                controls.settings.sourceCropRect = rect
                cropPixelSize = pixelSize
            }
        }
    }

    private var recordingTab: some View {
        VStack(spacing: 16) {
            ScrollView {
                VStack(spacing: 16) {
                    if let quickStartBannerMessage = controls.quickStartBannerMessage {
                        quickStartBanner(quickStartBannerMessage)
                    }
                    sourceSelectionSection
                    cropSelectionSection
                    audioSettingsSection
                    captureSettingsSection
                    savePathSection
                    scheduleSection
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
        .padding(16)
        .alert("Recording Error", isPresented: $showingError) {
            Button("OK") {
                showingError = false
            }
        } message: {
            Text(errorMessage ?? "An unknown error occurred")
        }
    }

    private func quickStartBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(6)
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
                .labelsHidden()
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
            .onChange(of: selectedSourceId) {
                clearCrop()
                controls.selectSource(selectedSource)
            }
        }
    }

    @ViewBuilder
    private var cropSelectionSection: some View {
        if captureMode == .window {
            HStack(spacing: 10) {
                Button(isLoadingCropPreview ? "領域を準備中…" : "領域を選択") {
                    Task {
                        await showCropSelector()
                    }
                }
                .disabled(selectedSource == nil || isRecording || isTransitioning || isLoadingCropPreview)

                if let cropPixelSize {
                    Text("領域: \(Int(cropPixelSize.width))×\(Int(cropPixelSize.height))")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(Capsule())

                    Button("クリア") {
                        clearCrop()
                    }
                }

                Spacer()
            }
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
                Toggle(isOn: $controls.settings.captureAppAudio) {
                    Text("App Audio")
                        .font(.caption)
                }

                Toggle(isOn: $controls.settings.captureMicrophone) {
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
                    Picker("Codec", selection: $controls.settings.codec) {
                        Text("HEVC").tag(VideoCodec.hevc)
                        Text("H.264").tag(VideoCodec.h264)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Resolution")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Picker("Resolution", selection: $controls.settings.scalePercent) {
                        Text("100%").tag(100)
                        Text("50%").tag(50)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("FPS")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Picker("FPS", selection: $controls.settings.fps) {
                        Text("30").tag(30)
                        Text("60").tag(60)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
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
                Text(controls.settings.destinationDirectory.path)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                Button("変更…") {
                    chooseOutputDirectory()
                }
                .disabled(isRecording || isTransitioning)
            }

            if let outputDirectoryWarning = controls.outputDirectoryWarning {
                HStack(spacing: 8) {
                    Image(systemName: "externaldrive.fill.badge.exclamationmark")
                        .foregroundColor(.yellow)
                    Text(outputDirectoryWarning)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(8)
                .background(Color.yellow.opacity(0.1))
                .cornerRadius(6)
            }
        }
    }

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("予約")
                .font(.caption)
                .foregroundColor(.secondary)

            if let scheduledRecording = controls.scheduledRecording {
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    let remainingMinutes = max(0, Int(ceil(scheduledRecording.startAt.timeIntervalSinceNow / 60)))
                    HStack {
                        Text("予約済み: \(scheduledRecording.startAt, format: .dateTime.hour().minute()) 開始 (あと\(remainingMinutes)分)")
                            .font(.caption)
                        Spacer()
                        Button("キャンセル") {
                            Task {
                                await controls.cancelScheduledRecording()
                            }
                        }
                    }
                }
            } else {
                HStack(spacing: 12) {
                    DatePicker("開始時刻", selection: $scheduledStartAt)
                        .labelsHidden()

                    Picker("録画時間の上限", selection: $scheduledMaximumDuration) {
                        ForEach(RecordingDurationLimit.allCases) { limit in
                            Text(limit.label).tag(limit)
                        }
                    }
                    .pickerStyle(.menu)

                    Button("予約する") {
                        Task {
                            await controls.scheduleRecording(
                                startAt: scheduledStartAt,
                                source: selectedSource,
                                maximumDuration: scheduledMaximumDuration.duration
                            )
                        }
                    }
                    .disabled(selectedSource == nil)
                }
            }

            if let scheduleBannerMessage = controls.scheduleBannerMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(scheduleBannerMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(6)
            }

            Text("予約はアプリ起動中のみ有効です。アプリを終了すると消えます。")
                .font(.caption2)
                .foregroundColor(.secondary)
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
                    Task {
                        await controls.startManually(source: selectedSource)
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

    private func updateRecordingCompletion(_ state: RecordingState) {
        if case .recording = state {
            wasRecording = true
        } else if case .idle = state, wasRecording {
            wasRecording = false
            libraryRefreshToken += 1
        }
        if case .failed(let message) = state {
            errorMessage = message
            showingError = true
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
            controls.selectSource(selectedSource)
        }
    }

    private func showCropSelector() async {
        guard let source = selectedSource, source.kind == .window else { return }
        isLoadingCropPreview = true
        defer { isLoadingCropPreview = false }
        do {
            let preview = try await captureService.capturePreview(for: source)
            guard selectedSourceId == source.id else { return }
            cropPreviewSourceID = source.id
            cropPreview = preview
        } catch {
            errorMessage = "領域選択用の画面を取得できませんでした: \(error.localizedDescription)"
            showingError = true
        }
    }

    private func clearCrop() {
        controls.settings.sourceCropRect = nil
        cropPixelSize = nil
    }

    /// Keeps `selectedSourceId` pointing at something the user can actually see: the first
    /// entry of the current mode's list whenever the selection is empty or has dropped out
    /// of it (mode switch, or the selected window closing).
    private func syncSelection() {
        let visible = visibleSources
        guard !visible.contains(where: { $0.id == selectedSourceId }) else { return }
        selectedSourceId = visible.first?.id
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = "保存先を選択"
        panel.prompt = "選択"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = controls.settings.destinationDirectory
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        guard controls.saveOutputDirectory(directory) else { return }
        libraryRefreshToken += 1
    }
}

private enum RecordingDurationLimit: CaseIterable, Identifiable {
    case none
    case thirtyMinutes
    case oneHour
    case twoHours
    case threeHours

    var id: Self { self }

    var duration: TimeInterval? {
        switch self {
        case .none: nil
        case .thirtyMinutes: 30 * 60
        case .oneHour: 60 * 60
        case .twoHours: 2 * 60 * 60
        case .threeHours: 3 * 60 * 60
        }
    }

    var label: String {
        switch self {
        case .none: "録画時間の上限: なし"
        case .thirtyMinutes: "録画時間の上限: 30分"
        case .oneHour: "録画時間の上限: 1時間"
        case .twoHours: "録画時間の上限: 2時間"
        case .threeHours: "録画時間の上限: 3時間"
        }
    }
}
