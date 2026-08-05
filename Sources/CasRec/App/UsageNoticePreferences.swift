import Foundation

/// Persists the version of the non-contractual usage guidance a person has viewed.
/// Storing the version rather than a Boolean lets a future, materially revised notice be
/// shown again by raising `currentVersion`.
struct UsageNoticePreferences {
    static let userDefaultsKey = "casRecUsageNoticeAcknowledgedVersion"
    static let currentVersion = 2

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func shouldPresentNotice() -> Bool {
        defaults.integer(forKey: Self.userDefaultsKey) < Self.currentVersion
    }

    func acknowledgeCurrentVersion() {
        defaults.set(Self.currentVersion, forKey: Self.userDefaultsKey)
    }
}
