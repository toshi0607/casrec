import Foundation
import Testing
@testable import CasRec

@Suite("Usage notice preferences")
struct UsageNoticePreferencesTests {
    @Test("The notice is shown until the current version is acknowledged")
    func currentVersionMustBeAcknowledged() {
        let suiteName = "UsageNoticePreferencesTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Could not create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = UsageNoticePreferences(defaults: defaults)

        #expect(preferences.shouldPresentNotice())
        preferences.acknowledgeCurrentVersion()

        #expect(!preferences.shouldPresentNotice())
        #expect(defaults.integer(forKey: UsageNoticePreferences.userDefaultsKey) == UsageNoticePreferences.currentVersion)
    }

    @Test("An earlier acknowledged version shows the revised notice")
    func earlierVersionRequiresAcknowledgement() {
        let suiteName = "UsageNoticePreferencesTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Could not create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(UsageNoticePreferences.currentVersion - 1, forKey: UsageNoticePreferences.userDefaultsKey)

        #expect(UsageNoticePreferences(defaults: defaults).shouldPresentNotice())
    }
}
