import Foundation

@MainActor
protocol TrafficSourceListVisibilityStoring: AnyObject {
    var isVisible: Bool { get }

    func save(isVisible: Bool)
}

@MainActor
final class InMemoryTrafficSourceListVisibilityStore: TrafficSourceListVisibilityStoring {
    private(set) var isVisible: Bool

    init(isVisible: Bool = true) {
        self.isVisible = isVisible
    }

    func save(isVisible: Bool) {
        self.isVisible = isVisible
    }
}

@MainActor
final class UserDefaultsTrafficSourceListVisibilityStore: TrafficSourceListVisibilityStoring {
    static let defaultKey = "TrafficConsole.isSourceListVisible"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    var isVisible: Bool {
        guard defaults.object(forKey: key) != nil else {
            return true
        }
        return defaults.bool(forKey: key)
    }

    func save(isVisible: Bool) {
        defaults.set(isVisible, forKey: key)
    }
}
