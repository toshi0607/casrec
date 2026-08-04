import Foundation
import Observation
import AppKit

/// The action shared by the menu-bar item and the global hot key.  Keeping this decision
/// free of UI and side effects makes transition states deliberately harmless.
enum QuickRecordingAction: Equatable {
    case start
    case stop
    case none
}

func quickRecordingAction(for state: RecordingState) -> QuickRecordingAction {
    switch state {
    case .idle:
        .start
    case .recording:
        .stop
    case .preparing, .finishing, .failed:
        .none
    }
}

/// UI-lifetime state and operations that must remain available after the main window has
/// closed.  It intentionally coordinates existing Recording/Capture APIs without changing
/// either layer.
@MainActor
@Observable
final class RecordingControls {
    private(set) var currentState: RecordingState = .idle
    private(set) var scheduledRecording: ScheduledRecording?
    var settings = RecordingSettings.default
    var recordingDurationLimit: RecordingDurationLimit = .none {
        didSet {
            durationLimitPreferences.save(recordingDurationLimit)
        }
    }
    private(set) var outputDirectoryWarning: String?
    private(set) var scheduleBannerMessage: String?
    private(set) var quickStartBannerMessage: String?
    private(set) var durationLimitBannerMessage: String?
    private(set) var activeRecordingMaximumDuration: TimeInterval?
    private(set) var selectedSourceID: String?

    private let session: any RecordingSessionControlling
    private let captureService: any CaptureServicing
    private let scheduler: RecordingScheduler
    private let outputDirectoryPreferences = OutputDirectoryPreferences()
    private let durationLimitPreferences: RecordingDurationLimitPreferences
    private var selectedSourceSnapshot: CaptureSource?
    private var stateObserver: Task<Void, Never>?
    private var reservationObserver: Task<Void, Never>?
    private var scheduleEventObserver: Task<Void, Never>?

    init(
        session: any RecordingSessionControlling,
        captureService: any CaptureServicing,
        scheduler: RecordingScheduler,
        durationLimitPreferences: RecordingDurationLimitPreferences = RecordingDurationLimitPreferences()
    ) {
        self.session = session
        self.captureService = captureService
        self.scheduler = scheduler
        self.durationLimitPreferences = durationLimitPreferences
        self.recordingDurationLimit = durationLimitPreferences.load()
    }

    func startObserving() {
        refreshOutputDirectory()
        stateObserver = Task { [weak self] in
            guard let self else { return }
            for await state in self.session.observeState() {
                self.currentState = state
                if case .recording = state {
                    continue
                }
                self.activeRecordingMaximumDuration = nil
            }
        }
        reservationObserver = Task { [weak self] in
            guard let self else { return }
            for await reservation in await self.scheduler.observeReservation() {
                self.scheduledRecording = reservation
            }
        }
        scheduleEventObserver = Task { [weak self] in
            guard let self else { return }
            for await event in await self.scheduler.observeEvents() {
                switch event {
                case .skippedBecauseSessionWasNotIdle:
                    self.scheduleBannerMessage = "予約時刻になりましたが、録画状態が待機中ではないため開始しませんでした。"
                case .couldNotStart(let message):
                    self.scheduleBannerMessage = message
                case .maximumDurationReached(let duration):
                    self.durationLimitBannerMessage = "録画時間の上限(\(RecordingDurationLimit.label(for: duration)))に達したため停止しました"
                }
            }
        }
    }

    func selectSource(_ source: CaptureSource?) {
        selectedSourceSnapshot = source
        selectedSourceID = source?.id
    }

    func refreshOutputDirectory() {
        let resolution = outputDirectoryPreferences.load()
        settings.destinationDirectory = resolution.directory
        outputDirectoryWarning = resolution.didFallback
            ? "設定されていた保存先を利用できないため、既定の保存先に戻しました。"
            : nil
    }

    func saveOutputDirectory(_ directory: URL) -> Bool {
        guard outputDirectoryPreferences.save(directory: directory) else {
            outputDirectoryWarning = "選択した保存先に書き込めません。別のフォルダを選択してください。"
            return false
        }
        settings.destinationDirectory = directory
        outputDirectoryWarning = nil
        return true
    }

    func startManually(source: CaptureSource?) async {
        refreshOutputDirectory()
        guard let source else { return }
        switch await startRecordingIfReady(
            source: source,
            settings: settings,
            session: session
        ) {
        case .started(let recordingStartedAt):
            quickStartBannerMessage = nil
            await configureMaximumDurationStop(recordingStartedAt: recordingStartedAt)
        case .couldNotStart(let message):
            quickStartBannerMessage = message
        }
    }

    func toggleQuickRecording() async {
        switch quickRecordingAction(for: currentState) {
        case .start:
            await startQuickly()
        case .stop:
            await session.stop()
        case .none:
            return
        }
    }

    func scheduleRecording(startAt: Date, source: CaptureSource?) async {
        refreshOutputDirectory()
        guard startAt > Date() else {
            scheduleBannerMessage = "開始時刻には現在より後の時刻を指定してください。"
            return
        }
        guard outputDirectoryPreferences.isUsable(settings.destinationDirectory) else {
            scheduleBannerMessage = "保存先を利用できません。保存先を変更してから予約してください。"
            return
        }
        guard let source else { return }

        scheduleBannerMessage = nil
        let reservation = ScheduledRecording(
            startAt: startAt,
            source: source,
            settings: settings,
            maximumDuration: recordingDurationLimit.duration
        )
        await scheduler.schedule(
            reservation,
            stateProvider: { [session] in await recordingState(of: session) },
            start: { [captureService, session] reservation in
                await startScheduledRecording(
                    reservation,
                    captureService: captureService,
                    session: session
                )
            },
            stop: { [session] in
                await session.stop()
            },
            didStart: { [weak self] _, maximumDuration in
                await self?.setActiveRecordingMaximumDuration(maximumDuration)
            }
        )
    }

    func cancelScheduledRecording() async {
        await scheduler.cancel()
    }

    private func startQuickly() async {
        guard let savedSource = selectedSourceSnapshot else {
            presentQuickStartFailure("録画対象が選択されていません。対象を選択してから録画を開始してください。")
            return
        }

        for await update in captureService.observeSources() {
            switch update {
            case .sources(let sources):
                guard let source = CaptureSourceResolver.resolve(saved: savedSource, in: sources) else {
                    presentQuickStartFailure("選択中の録画対象が見つかりません。対象を選択し直してください。")
                    return
                }
                refreshOutputDirectory()
                switch await startRecordingIfReady(
                    source: source,
                    settings: settings,
                    session: session
                ) {
                case .started(let recordingStartedAt):
                    quickStartBannerMessage = nil
                    await configureMaximumDurationStop(recordingStartedAt: recordingStartedAt)
                case .couldNotStart(let message):
                    presentQuickStartFailure(message)
                }
                return
            case .unavailable(let reason):
                presentQuickStartFailure("録画対象を再取得できないため、録画を開始しませんでした: \(sourceErrorMessage(reason))")
                return
            }
        }
        presentQuickStartFailure("録画対象を再取得できないため、録画を開始しませんでした。")
    }

    private func presentQuickStartFailure(_ message: String) {
        quickStartBannerMessage = message
        NSApp.activate(ignoringOtherApps: true)
        if let mainWindow = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            mainWindow.makeKeyAndOrderFront(nil)
        }
    }

    private func configureMaximumDurationStop(recordingStartedAt: Date) async {
        let maximumDuration = recordingDurationLimit.duration
        activeRecordingMaximumDuration = maximumDuration
        await scheduler.scheduleAutoStop(
            maximumDuration: maximumDuration,
            recordingStartedAt: recordingStartedAt,
            stateProvider: { [session] in await recordingState(of: session) },
            stop: { [session] in await session.stop() }
        )
    }

    private func setActiveRecordingMaximumDuration(_ maximumDuration: TimeInterval?) {
        activeRecordingMaximumDuration = maximumDuration
    }
}

private enum RecordingStartResult {
    case started(recordingStartedAt: Date)
    case couldNotStart(message: String)
}

/// The manual button, scheduled firing, and quick start all pass this gate.  `start` is
/// still protected by RecordingSession's own atomic state machine; this check provides the
/// actionable UI-level reason before asking it to do work.
private func startRecordingIfReady(
    source: CaptureSource,
    settings: RecordingSettings,
    session: any RecordingSessionControlling
) async -> RecordingStartResult {
    guard await recordingState(of: session) == .idle else {
        return .couldNotStart(message: "録画状態が待機中ではないため、録画を開始しませんでした。")
    }
    guard OutputDirectoryPreferences().isUsable(settings.destinationDirectory) else {
        return .couldNotStart(message: "保存先を利用できません。保存先を変更してから録画を開始してください。")
    }
    await session.start(source: source, settings: settings)
    guard case .recording(let progress) = await recordingState(of: session) else {
        return .couldNotStart(message: "録画を開始できませんでした。")
    }
    return .started(recordingStartedAt: progress.startedAt)
}

private func recordingState(of session: any RecordingSessionControlling) async -> RecordingState {
    for await state in session.observeState() {
        return state
    }
    return .idle
}

/// Source enumeration is intentionally restarted at the instant a reservation fires.  The
/// window ID stored in the reservation can be stale, so it is re-resolved before the shared
/// preflight check starts the session.
private func startScheduledRecording(
    _ reservation: ScheduledRecording,
    captureService: any CaptureServicing,
    session: any RecordingSessionControlling
) async -> ScheduledRecordingStartResult {
    for await update in captureService.observeSources() {
        switch update {
        case .sources(let sources):
            guard let source = CaptureSourceResolver.resolve(saved: reservation.source, in: sources) else {
                return .couldNotStart(message: "予約時の録画対象が見つからないため、録画を開始しませんでした。")
            }
            switch await startRecordingIfReady(
                source: source,
                settings: reservation.settings,
                session: session
            ) {
            case .started(let recordingStartedAt):
                return .started(recordingStartedAt: recordingStartedAt)
            case .couldNotStart(let message):
                return .couldNotStart(message: message)
            }
        case .unavailable(let reason):
            return .couldNotStart(message: "録画対象を再取得できないため、録画を開始しませんでした: \(sourceErrorMessage(reason))")
        }
    }
    return .couldNotStart(message: "録画対象を再取得できないため、録画を開始しませんでした。")
}

private func sourceErrorMessage(_ reason: CaptureUnavailableReason) -> String {
    switch reason {
    case .permissionDenied:
        "画面収録が許可されていません"
    case .failed(let message):
        message
    }
}
