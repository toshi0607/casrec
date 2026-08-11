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
                controls: appDelegate.controls,
                postProcessQueue: appDelegate.postProcessQueue,
                usageNotice: appDelegate.usageNotice
            )
        }

        MenuBarExtra {
            MenuBarControls(
                controls: appDelegate.controls,
                usageNotice: appDelegate.usageNotice
            )
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
    let postProcessQueue: PostProcessQueue
    let usageNotice: UsageNoticeController

    private var globalHotKey: GlobalHotKey?
    private var terminationTask: Task<Void, Never>?

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
        self.postProcessQueue = PostProcessQueue()
        self.usageNotice = UsageNoticeController()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controls.startObserving()
        globalHotKey = GlobalHotKey { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.controls.toggleQuickRecording(
                    allowsRecordingStart: self.usageNotice.allowsRecordingStart
                )
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
        guard terminationTask == nil else { return .terminateLater }
        switch controls.currentState {
        case .idle, .failed:
            return beginTermination(stoppingRecording: false)
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

        return beginTermination(stoppingRecording: true)
    }

    private func beginTermination(stoppingRecording: Bool) -> NSApplication.TerminateReply {
        terminationTask = Task { [weak self] in
            guard let self else { return }
            if stoppingRecording {
                await stopRecordingForTermination()
            }
            await postProcessQueue.cancelAllAndWait()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Quitting must not cut `finishWriting` short, so this follows the state machine to
    /// its end rather than assuming one `stop()` is enough — `stop()` is a no-op while the
    /// session is still `preparing`, and the file is only safe once it reaches `idle`.
    private func stopRecordingForTermination() async {
        for await state in session.observeState() {
            switch state {
            case .recording:
                await session.stop()
            case .idle, .failed:
                return
            case .preparing, .finishing:
                continue
            }
        }
    }
}
