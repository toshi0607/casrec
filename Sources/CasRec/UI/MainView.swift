import AppKit
import SwiftUI

struct MainView: View {
    private enum SidebarItem: Hashable {
        case recording
        case library
    }

    /// Deep link to System Settings › Privacy & Security › Screen Recording (§5.5).
    private static let screenRecordingSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )

    let session: any RecordingSessionControlling
    let captureService: any CaptureServicing
    @Bindable var controls: RecordingControls
    let postProcessQueue: PostProcessQueue
    @Bindable var usageNotice: UsageNoticeController

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
    @State private var cropErrorMessage: String?
    @State private var showingCropError = false
    @State private var sidebarSelection: SidebarItem? = .recording

    init(
        session: any RecordingSessionControlling,
        captureService: any CaptureServicing,
        controls: RecordingControls,
        postProcessQueue: PostProcessQueue,
        usageNotice: UsageNoticeController
    ) {
        self.session = session
        self.captureService = captureService
        self.controls = controls
        self.postProcessQueue = postProcessQueue
        self.usageNotice = usageNotice
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
        NavigationSplitView {
            List(selection: $sidebarSelection) {
                Label("録画", systemImage: "record.circle")
                    .tag(SidebarItem.recording)
                Label("ライブラリ", systemImage: "film.stack")
                    .tag(SidebarItem.library)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 168, ideal: 176, max: 220)
        } detail: {
            Group {
                if sidebarSelection == .library {
                    LibraryView(
                        directory: controls.settings.destinationDirectory,
                        refreshToken: libraryRefreshToken,
                        allowsDeletion: !isRecording && !isTransitioning,
                        jobQueue: postProcessQueue
                    )
                    .navigationSubtitle("ライブラリ")
                } else {
                    recordingPane
                }
            }
            // Keeping the inset outside the pane switch exposes failures while browsing the library.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                TransportDeck(
                    state: currentState,
                    maximumDuration: controls.activeRecordingMaximumDuration,
                    sourceTitle: selectedSource.map { $0.appName ?? $0.title },
                    canStart: selectedSource != nil && usageNotice.allowsRecordingStart,
                    start: {
                        Task {
                            await controls.startManually(source: selectedSource)
                        }
                    },
                    stop: {
                        Task {
                            await session.stop()
                        }
                    },
                    dismissFailure: {
                        // The state machine intentionally remains failed until the person has seen the error.
                        Task {
                            await session.acknowledgeFailure()
                        }
                    }
                )
            }
        }
        .tint(Theme.accent)
        .navigationTitle("CasRec")
        .frame(minWidth: 780, minHeight: 580)
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
        .sheet(isPresented: $usageNotice.isPresented) {
            UsageNoticeSheet(
                acknowledge: usageNotice.acknowledge,
                exit: { NSApp.terminate(nil) }
            )
            .interactiveDismissDisabled()
        }
        .alert("領域選択エラー", isPresented: $showingCropError) {
            Button("OK") {
                showingCropError = false
            }
        } message: {
            Text(cropErrorMessage ?? "領域選択用の画面を取得できませんでした")
        }
    }

    private var recordingPane: some View {
        ScrollView {
            VStack(spacing: Theme.Metric.cardSpacing) {
                if let quickStartBannerMessage = controls.quickStartBannerMessage {
                    quickStartBanner(quickStartBannerMessage)
                }
                if let durationLimitBannerMessage = controls.durationLimitBannerMessage {
                    durationLimitBanner(durationLimitBannerMessage)
                }
                sourceSelectionSection
                audioSettingsSection
                captureSettingsSection
                savePathSection
                scheduleSection
            }
            .frame(maxWidth: Theme.Metric.contentMaxWidth)
            .frame(maxWidth: .infinity)
            .padding(Theme.Metric.gutter)
        }
        .navigationSubtitle("録画")
    }

    private func quickStartBanner(_ message: String) -> some View {
        NoticeBanner(.caution, message: message)
    }

    private func durationLimitBanner(_ message: String) -> some View {
        NoticeBanner(.info, message: message)
    }

    private var sourceSelectionSection: some View {
        SectionCard("対象", accessory: {
            Picker("対象の種類", selection: $captureMode) {
                Text("ウィンドウ").tag(CaptureSourceKind.window)
                Text("画面全体").tag(CaptureSourceKind.display)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("対象の種類")
            .frame(maxWidth: 200)
            .onChange(of: captureMode) {
                syncSelection()
            }
        }) {
            VStack(alignment: .leading, spacing: 12) {
                if let reason = sourcesUnavailable {
                    sourcesUnavailableBanner(reason: reason)
                } else if visibleSources.isEmpty {
                    Text("録画できるウィンドウがありません")
                        .metaStyle()
                } else {
                    SourcePickerView(
                        sources: visibleSources,
                        selectedSourceId: $selectedSourceId
                    )
                }

                cropSelectionSection
            }
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
                    Text("領域 \(Int(cropPixelSize.width))×\(Int(cropPixelSize.height))")
                        .font(.machine(11))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.accent.opacity(0.14))
                        .clipShape(Capsule())

                    Button("クリア") {
                        clearCrop()
                    }
                }

                Spacer()
            }

        }
    }

    @ViewBuilder
    private func sourcesUnavailableBanner(reason: CaptureUnavailableReason) -> some View {
        switch reason {
        case .permissionDenied:
            NoticeBanner(
                .caution,
                title: "画面収録が許可されていません",
                message: "システム設定の「プライバシーとセキュリティ > 画面収録」で CasRec を許可してください。"
            ) {
                if let url = Self.screenRecordingSettingsURL {
                    Button("システム設定を開く") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Text("許可した後は、CasRec を再起動すると録画できるようになります。")
                    .metaStyle()
            }
        case .failed(let message):
            NoticeBanner(.caution, title: "録画対象を取得できません", message: message)
        }
    }

    private var audioSettingsSection: some View {
        SectionCard("音声") {
            HStack(spacing: 24) {
                Toggle("アプリの音声", isOn: $controls.settings.captureAppAudio)
                Toggle("マイク", isOn: $controls.settings.captureMicrophone)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Text("マイクには周囲の会話が含まれることがあります。必要に応じて参加者へ通知し、同意を得てください。")
                .metaStyle()
        }
    }

    private var captureSettingsSection: some View {
        SectionCard("画質と上限") {
            Grid(horizontalSpacing: 20, verticalSpacing: 12) {
                GridRow {
                    FieldRow("コーデック") {
                    Picker("コーデック", selection: $controls.settings.codec) {
                        Text("HEVC").tag(VideoCodec.hevc)
                        Text("H.264").tag(VideoCodec.h264)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    FieldRow("解像度") {
                        Picker("解像度", selection: $controls.settings.scalePercent) {
                            Text("100%").tag(100)
                            Text("50%").tag(50)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                GridRow {
                    FieldRow("フレームレート") {
                        Picker("フレームレート", selection: $controls.settings.fps) {
                            Text("30").tag(30)
                            Text("60").tag(60)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    FieldRow("録画時間の上限") {
                        Picker("録画時間の上限", selection: $controls.recordingDurationLimit) {
                            ForEach(RecordingDurationLimit.allCases) { limit in
                                Text(limit.pickerLabel).tag(limit)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var savePathSection: some View {
        SectionCard("保存先") {
            HStack(spacing: 8) {
                Text(controls.settings.destinationDirectory.path)
                    .font(.machine(11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("変更…") {
                    chooseOutputDirectory()
                }
                .disabled(isRecording || isTransitioning)
            }

            if let outputDirectoryWarning = controls.outputDirectoryWarning {
                NoticeBanner(.caution, message: outputDirectoryWarning)
            }
        }
    }

    private var scheduleSection: some View {
        SectionCard("予約") {
            if let scheduledRecording = controls.scheduledRecording {
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    let remainingMinutes = max(0, Int(ceil(scheduledRecording.startAt.timeIntervalSinceNow / 60)))
                    HStack(spacing: 6) {
                        Text("予約済み")
                        Text(scheduledRecording.startAt, format: .dateTime.hour().minute())
                            .font(.machine(11))
                        Text("開始")
                        Text("あと\(remainingMinutes)分")
                            .metaStyle()
                        Spacer()
                        Button("キャンセル") {
                            Task {
                                await controls.cancelScheduledRecording()
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.accent.opacity(0.10), in: Capsule())
                }
            } else {
                HStack(spacing: 12) {
                    DatePicker("開始時刻", selection: $scheduledStartAt)
                        .labelsHidden()

                    Button("予約する") {
                        Task {
                            await controls.scheduleRecording(
                                startAt: scheduledStartAt,
                                source: selectedSource
                            )
                        }
                    }
                    .disabled(selectedSource == nil || !usageNotice.allowsRecordingStart)
                }
            }

            if let scheduleBannerMessage = controls.scheduleBannerMessage {
                NoticeBanner(.caution, message: scheduleBannerMessage)
            }

            Text("予約はアプリ起動中のみ有効です。アプリを終了すると消えます。")
                .metaStyle()
        }
    }

    private func updateRecordingCompletion(_ state: RecordingState) {
        if case .recording = state {
            wasRecording = true
        } else if case .idle = state, wasRecording {
            wasRecording = false
            libraryRefreshToken += 1
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
            cropErrorMessage = "領域選択用の画面を取得できませんでした: \(error.localizedDescription)"
            showingCropError = true
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
