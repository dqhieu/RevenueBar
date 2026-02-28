import Combine
import Foundation

@MainActor
final class AppSettingsStore: ObservableObject {
    static let supportedRefreshIntervals = [1, 5, 10, 15, 30, 60]

    @Published var refreshIntervalMinutes: Int {
        didSet {
            let normalized = Self.normalizedRefreshInterval(refreshIntervalMinutes)
            if normalized != refreshIntervalMinutes {
                refreshIntervalMinutes = normalized
                return
            }
            userDefaults.set(normalized, forKey: Self.refreshIntervalKey)
        }
    }

    private let userDefaults: UserDefaults

    private static let refreshIntervalKey = "settings.autoRefreshIntervalMinutes"
    private static let defaultRefreshIntervalMinutes = 10

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        let storedInterval = userDefaults.integer(forKey: Self.refreshIntervalKey)
        if storedInterval == 0 {
            refreshIntervalMinutes = Self.defaultRefreshIntervalMinutes
        } else {
            refreshIntervalMinutes = Self.normalizedRefreshInterval(storedInterval)
        }
    }

    private static func normalizedRefreshInterval(_ minutes: Int) -> Int {
        if supportedRefreshIntervals.contains(minutes) {
            return minutes
        }
        return defaultRefreshIntervalMinutes
    }
}
