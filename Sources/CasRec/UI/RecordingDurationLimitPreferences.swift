import Foundation

/// A UI and scheduling policy, deliberately separate from `RecordingSettings`, which is
/// the capture engine's contract.
enum RecordingDurationLimit: String, CaseIterable, Identifiable {
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

    var pickerLabel: String {
        switch self {
        case .none: "なし"
        case .thirtyMinutes: "30分"
        case .oneHour: "1時間"
        case .twoHours: "2時間"
        case .threeHours: "3時間"
        }
    }

    var hudLabel: String {
        switch self {
        case .none: ""
        case .thirtyMinutes: "00:30"
        case .oneHour: "01:00"
        case .twoHours: "02:00"
        case .threeHours: "03:00"
        }
    }

    static func label(for duration: TimeInterval) -> String {
        allCases.first(where: { $0.duration == duration })?.pickerLabel
            ?? Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes]))
    }
}

/// Persists the duration limit independently from capture settings so the Recording/Capture
/// layer never needs to know about a UI-level stop policy.
struct RecordingDurationLimitPreferences {
    static let userDefaultsKey = "recordingDurationLimit"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> RecordingDurationLimit {
        guard let rawValue = defaults.string(forKey: Self.userDefaultsKey),
              let limit = RecordingDurationLimit(rawValue: rawValue)
        else {
            return .none
        }
        return limit
    }

    func save(_ limit: RecordingDurationLimit) {
        defaults.set(limit.rawValue, forKey: Self.userDefaultsKey)
    }
}
