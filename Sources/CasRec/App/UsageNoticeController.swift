import Observation

/// View state for a non-contractual confirmation that the person has viewed the usage
/// guidance. Recording and capture components do not depend on this controller, which
/// keeps the confirmation policy independently testable.
@MainActor
@Observable
final class UsageNoticeController {
    private let preferences: UsageNoticePreferences
    var isPresented: Bool

    init(preferences: UsageNoticePreferences = UsageNoticePreferences()) {
        self.preferences = preferences
        self.isPresented = preferences.shouldPresentNotice()
    }

    var allowsRecordingStart: Bool {
        !isPresented
    }

    func acknowledge() {
        preferences.acknowledgeCurrentVersion()
        isPresented = false
    }
}
