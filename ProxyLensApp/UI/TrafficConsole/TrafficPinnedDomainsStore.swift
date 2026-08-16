import Foundation

@MainActor
protocol TrafficPinnedDomainsStoring: AnyObject {
    var domains: Set<String> { get }

    func save(_ domains: Set<String>)
}

@MainActor
final class InMemoryTrafficPinnedDomainsStore: TrafficPinnedDomainsStoring {
    private(set) var domains: Set<String>

    init(domains: Set<String> = []) {
        self.domains = Self.normalized(domains)
    }

    func save(_ domains: Set<String>) {
        self.domains = Self.normalized(domains)
    }

    private static func normalized(_ domains: Set<String>) -> Set<String> {
        Set(domains.compactMap(normalizedDomain))
    }
}

@MainActor
final class UserDefaultsTrafficPinnedDomainsStore: TrafficPinnedDomainsStoring {
    static let defaultKey = "TrafficConsole.pinnedDomains"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    var domains: Set<String> {
        Set((defaults.stringArray(forKey: key) ?? []).compactMap(normalizedDomain))
    }

    func save(_ domains: Set<String>) {
        defaults.set(domains.compactMap(normalizedDomain).sorted(), forKey: key)
    }
}

private func normalizedDomain(_ domain: String) -> String? {
    let normalized = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.isEmpty ? nil : normalized
}
