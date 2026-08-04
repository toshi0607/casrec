import AppKit
import Observation
import SwiftUI

@main
struct CasRecApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// A single `Window`, not a `WindowGroup`: the app is one recording session with one
    /// set of controls, and ⌘N opening a second copy of it would let two views drive the
    /// same session (§7).
    var body: some Scene {
        Window("CasRec", id: "main") {
            MainView(
                session: appDelegate.session,
                captureService: appDelegate.captureService,
                controls: appDelegate.controls
            )
        }

        MenuBarExtra {
            MenuBarControls(controls: appDelegate.controls)
        } label: {
            MenuBarIcon(state: appDelegate.controls.currentState)
        }
    }
}

/// Owns the object graph and the two application-level rules of DESIGN.md §5.4: closing
/// the window must not end the process, and ⌘Q during a recording must finish writing the
/// file before the process goes away.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let captureService: CaptureService
    let session: RecordingSession
    let scheduler: RecordingScheduler
    let controls: RecordingControls

    /// Mirror of the session's published state, so the synchronous
    /// `applicationShouldTerminate` can decide without awaiting.
    private var currentState: RecordingState = .idle
    private var stateObserver: Task<Void, Never>?
    private var globalHotKey: GlobalHotKey?

    override init() {
        let captureService = CaptureService()
        self.captureService = captureService
        self.session = RecordingSession(captureService: captureService)
        self.scheduler = RecordingScheduler()
        self.controls = RecordingControls(
            session: session,
            captureService: captureService,
            scheduler: scheduler
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controls.startObserving()
        stateObserver = Task {
            for await state in session.observeState() {
                currentState = state
            }
        }
        globalHotKey = GlobalHotKey { [weak self] in
            Task { @MainActor [weak self] in
                await self?.controls.toggleQuickRecording()
            }
        }
        globalHotKey?.register()
    }

    /// The menu-bar item remains the visible control surface after the main window closes,
    /// so closing the window must never terminate the process.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch currentState {
        case .idle, .failed:
            return .terminateNow
        case .preparing, .recording, .finishing:
            break
        }

        let alert = NSAlert()
        alert.messageText = "録画中です"
        alert.informativeText = "録画を停止してから終了します。ファイルの書き出しが完了するまで少し時間がかかることがあります。"
        alert.addButton(withTitle: "停止して終了")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return .terminateCancel
        }

        Task {
            await stopThenTerminate()
        }
        return .terminateLater
    }

    /// Quitting must not cut `finishWriting` short, so this follows the state machine to
    /// its end rather than assuming one `stop()` is enough — `stop()` is a no-op while the
    /// session is still `preparing`, and the file is only safe once it reaches `idle`.
    private func stopThenTerminate() async {
        for await state in session.observeState() {
            switch state {
            case .recording:
                await session.stop()
            case .idle, .failed:
                NSApp.reply(toApplicationShouldTerminate: true)
                return
            case .preparing, .finishing:
                continue
            }
        }
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}
