import Foundation
import ProxyLensCore

struct TrafficNetworkConditionProfile: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let profile: ThrottleProfile

    init(id: UUID = UUID(), name: String, profile: ThrottleProfile) {
        self.id = id
        self.name = name
        self.profile = profile
    }
}

enum TrafficNetworkConditionProfileStoreError: LocalizedError, Equatable {
    case invalidName

    var errorDescription: String? {
        switch self {
        case .invalidName:
            "Profile name must contain 1 through 80 characters."
        }
    }
}

@MainActor
protocol TrafficNetworkConditionProfileStoring: AnyObject {
    var profiles: [TrafficNetworkConditionProfile] { get }

    @discardableResult
    func save(name: String, profile: ThrottleProfile) throws -> TrafficNetworkConditionProfile
    func remove(id: UUID)
}

@MainActor
final class InMemoryTrafficNetworkConditionProfileStore:
    TrafficNetworkConditionProfileStoring
{
    private(set) var profiles: [TrafficNetworkConditionProfile]

    init(profiles: [TrafficNetworkConditionProfile] = []) {
        self.profiles = normalizedNetworkConditionProfiles(profiles)
    }

    @discardableResult
    func save(name: String, profile: ThrottleProfile) throws -> TrafficNetworkConditionProfile {
        let result = try upsertingNetworkConditionProfile(
            name: name,
            profile: profile,
            into: profiles
        )
        profiles = result.profiles
        return result.saved
    }

    func remove(id: UUID) {
        profiles.removeAll { $0.id == id }
    }
}

@MainActor
final class UserDefaultsTrafficNetworkConditionProfileStore:
    TrafficNetworkConditionProfileStoring
{
    static let defaultKey = "TrafficConsole.networkConditionProfiles"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    var profiles: [TrafficNetworkConditionProfile] {
        guard let data = defaults.data(forKey: key),
            let decoded = try? JSONDecoder().decode(
                [TrafficNetworkConditionProfile].self,
                from: data
            )
        else {
            return []
        }
        return normalizedNetworkConditionProfiles(decoded)
    }

    @discardableResult
    func save(name: String, profile: ThrottleProfile) throws -> TrafficNetworkConditionProfile {
        let result = try upsertingNetworkConditionProfile(
            name: name,
            profile: profile,
            into: profiles
        )
        persist(result.profiles)
        return result.saved
    }

    func remove(id: UUID) {
        persist(profiles.filter { $0.id != id })
    }

    private func persist(_ profiles: [TrafficNetworkConditionProfile]) {
        defaults.set(try? JSONEncoder().encode(profiles), forKey: key)
    }
}

private func upsertingNetworkConditionProfile(
    name: String,
    profile: ThrottleProfile,
    into profiles: [TrafficNetworkConditionProfile]
) throws -> (saved: TrafficNetworkConditionProfile, profiles: [TrafficNetworkConditionProfile]) {
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...80).contains(normalizedName.count) else {
        throw TrafficNetworkConditionProfileStoreError.invalidName
    }

    let existing = profiles.first { profile in
        profile.name.compare(
            normalizedName,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame
    }
    let saved = TrafficNetworkConditionProfile(
        id: existing?.id ?? UUID(),
        name: normalizedName,
        profile: profile
    )
    let retained = profiles.filter { $0.id != saved.id }
    return (saved, normalizedNetworkConditionProfiles(retained + [saved]))
}

private func normalizedNetworkConditionProfiles(
    _ profiles: [TrafficNetworkConditionProfile]
) -> [TrafficNetworkConditionProfile] {
    profiles.sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
}
