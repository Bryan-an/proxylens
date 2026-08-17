import Foundation

enum TrafficCustomFilterPresetError: Error, Equatable, LocalizedError {
    case emptyName
    case nameTooLong(maximum: Int)
    case searchTooLarge(maximumBytes: Int)
    case duplicateName
    case duplicateIdentifier
    case tooManyPresets(maximum: Int)
    case presetNotFound

    var errorDescription: String? {
        switch self {
        case .emptyName:
            "Enter a name for the custom filter."
        case .nameTooLong(let maximum):
            "Custom filter names are limited to \(maximum) characters."
        case .searchTooLarge(let maximumBytes):
            "The saved search is limited to \(maximumBytes) UTF-8 bytes."
        case .duplicateName:
            "A custom filter already uses that name."
        case .duplicateIdentifier:
            "The custom filter document contains duplicate identifiers."
        case .tooManyPresets(let maximum):
            "You can save at most \(maximum) custom filters."
        case .presetNotFound:
            "The custom filter is no longer available."
        }
    }
}

struct TrafficCustomFilterPreset: Codable, Equatable, Identifiable, Sendable {
    static let maximumPresetCount = 50
    static let maximumNameLength = 80
    static let maximumSearchByteCount = 2_048

    let id: UUID
    let name: String
    let filter: TrafficDisplayFilter

    init(id: UUID = UUID(), name: String, filter: TrafficDisplayFilter) throws {
        let name = Self.normalizedName(name)
        guard !name.isEmpty else {
            throw TrafficCustomFilterPresetError.emptyName
        }
        guard name.count <= Self.maximumNameLength else {
            throw TrafficCustomFilterPresetError.nameTooLong(maximum: Self.maximumNameLength)
        }
        guard filter.searchText.utf8.count <= Self.maximumSearchByteCount else {
            throw TrafficCustomFilterPresetError.searchTooLarge(
                maximumBytes: Self.maximumSearchByteCount
            )
        }
        self.id = id
        self.name = name
        self.filter = filter
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case filter
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            filter: container.decode(TrafficDisplayFilter.self, forKey: .filter)
        )
    }

    static func comparisonKey(_ name: String) -> String {
        normalizedName(name).folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func normalizedName(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

@MainActor
protocol TrafficCustomFilterPresetStoring: AnyObject {
    var presets: [TrafficCustomFilterPreset] { get }

    @discardableResult
    func save(name: String, filter: TrafficDisplayFilter) throws -> TrafficCustomFilterPreset

    @discardableResult
    func rename(id: UUID, name: String) throws -> TrafficCustomFilterPreset

    func remove(id: UUID)
}

@MainActor
final class InMemoryTrafficCustomFilterPresetStore: TrafficCustomFilterPresetStoring {
    private(set) var presets: [TrafficCustomFilterPreset]

    init(presets: [TrafficCustomFilterPreset] = []) {
        self.presets = (try? validatedPresets(presets)) ?? []
    }

    func save(name: String, filter: TrafficDisplayFilter) throws -> TrafficCustomFilterPreset {
        let update = try savingPreset(in: presets, name: name, filter: filter)
        presets = update.presets
        return update.saved
    }

    func rename(id: UUID, name: String) throws -> TrafficCustomFilterPreset {
        let update = try renamingPreset(in: presets, id: id, name: name)
        presets = update.presets
        return update.saved
    }

    func remove(id: UUID) {
        presets.removeAll { $0.id == id }
    }
}

@MainActor
final class UserDefaultsTrafficCustomFilterPresetStore: TrafficCustomFilterPresetStoring {
    static let defaultKey = "TrafficConsole.customFilterPresets"

    private struct Document: Codable {
        let version: Int
        let presets: [TrafficCustomFilterPreset]
    }

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    var presets: [TrafficCustomFilterPreset] {
        guard let data = defaults.data(forKey: key),
            let document = try? JSONDecoder().decode(Document.self, from: data),
            document.version == 1,
            let presets = try? validatedPresets(document.presets)
        else {
            return []
        }
        return presets
    }

    func save(name: String, filter: TrafficDisplayFilter) throws -> TrafficCustomFilterPreset {
        let update = try savingPreset(in: presets, name: name, filter: filter)
        try persist(update.presets)
        return update.saved
    }

    func rename(id: UUID, name: String) throws -> TrafficCustomFilterPreset {
        let update = try renamingPreset(in: presets, id: id, name: name)
        try persist(update.presets)
        return update.saved
    }

    func remove(id: UUID) {
        let remaining = presets.filter { $0.id != id }
        if remaining.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            try? persist(remaining)
        }
    }

    private func persist(_ presets: [TrafficCustomFilterPreset]) throws {
        let presets = try validatedPresets(presets)
        defaults.set(
            try JSONEncoder().encode(Document(version: 1, presets: presets)),
            forKey: key
        )
    }
}

@MainActor
private func savingPreset(
    in presets: [TrafficCustomFilterPreset],
    name: String,
    filter: TrafficDisplayFilter
) throws -> (presets: [TrafficCustomFilterPreset], saved: TrafficCustomFilterPreset) {
    var result = try validatedPresets(presets)
    let comparisonKey = TrafficCustomFilterPreset.comparisonKey(name)
    if let index = result.firstIndex(where: {
        TrafficCustomFilterPreset.comparisonKey($0.name) == comparisonKey
    }) {
        let updated = try TrafficCustomFilterPreset(
            id: result[index].id,
            name: name,
            filter: filter
        )
        result[index] = updated
        return (try validatedPresets(result), updated)
    }
    guard result.count < TrafficCustomFilterPreset.maximumPresetCount else {
        throw TrafficCustomFilterPresetError.tooManyPresets(
            maximum: TrafficCustomFilterPreset.maximumPresetCount
        )
    }
    let saved = try TrafficCustomFilterPreset(name: name, filter: filter)
    result.append(saved)
    return (try validatedPresets(result), saved)
}

@MainActor
private func renamingPreset(
    in presets: [TrafficCustomFilterPreset],
    id: UUID,
    name: String
) throws -> (presets: [TrafficCustomFilterPreset], saved: TrafficCustomFilterPreset) {
    var result = try validatedPresets(presets)
    guard let index = result.firstIndex(where: { $0.id == id }) else {
        throw TrafficCustomFilterPresetError.presetNotFound
    }
    let renamed = try TrafficCustomFilterPreset(
        id: result[index].id,
        name: name,
        filter: result[index].filter
    )
    let comparisonKey = TrafficCustomFilterPreset.comparisonKey(renamed.name)
    guard
        !result.enumerated().contains(where: { candidateIndex, candidate in
            candidateIndex != index
                && TrafficCustomFilterPreset.comparisonKey(candidate.name) == comparisonKey
        })
    else {
        throw TrafficCustomFilterPresetError.duplicateName
    }
    result[index] = renamed
    return (try validatedPresets(result), renamed)
}

@MainActor
private func validatedPresets(
    _ presets: [TrafficCustomFilterPreset]
) throws -> [TrafficCustomFilterPreset] {
    guard presets.count <= TrafficCustomFilterPreset.maximumPresetCount else {
        throw TrafficCustomFilterPresetError.tooManyPresets(
            maximum: TrafficCustomFilterPreset.maximumPresetCount
        )
    }
    var identifiers = Set<UUID>()
    var names = Set<String>()
    for preset in presets {
        _ = try TrafficCustomFilterPreset(
            id: preset.id,
            name: preset.name,
            filter: preset.filter
        )
        guard identifiers.insert(preset.id).inserted else {
            throw TrafficCustomFilterPresetError.duplicateIdentifier
        }
        guard names.insert(TrafficCustomFilterPreset.comparisonKey(preset.name)).inserted else {
            throw TrafficCustomFilterPresetError.duplicateName
        }
    }
    return presets
}
