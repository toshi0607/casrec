import Foundation
import Testing
@testable import CasRec

@Suite("Recording duration limit preferences")
struct RecordingDurationLimitPreferencesTests {
    @Test("The selected duration limit persists")
    func selectedLimitPersists() {
        let suiteName = "RecordingDurationLimitPreferencesTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Could not create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = RecordingDurationLimitPreferences(defaults: defaults)

        #expect(preferences.load() == .none)
        preferences.save(.twoHours)

        #expect(preferences.load() == .twoHours)
    }
}
