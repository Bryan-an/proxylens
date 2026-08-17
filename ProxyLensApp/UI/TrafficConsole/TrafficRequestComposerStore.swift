import Foundation

enum TrafficRequestComposerStoreLimits {
    static let maximumHistoryEntries = 50
    static let maximumPresetEntries = 25
    static let maximumPresetNameCharacters = 80
    static let maximumStoredBytes = 512 * 1_024
}

enum TrafficRequestComposerEntryKind: String, Codable, Sendable {
    case history
    case preset
}

struct TrafficRequestComposerEntry: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: UUID
    let kind: TrafficRequestComposerEntryKind
    let name: String
    let headersText: String
    let bodyText: String
    let updatedAt: Date

    init(
        id: UUID = UUID(),
        kind: TrafficRequestComposerEntryKind,
        name: String,
        headersText: String,
        bodyText: String,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.headersText = headersText
        self.bodyText = bodyText
        self.updatedAt = updatedAt
    }
}

enum TrafficRequestComposerStoreError: LocalizedError, Equatable {
    case invalidPresetName
    case contentTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidPresetName:
            "Preset name must contain 1 through 80 characters."
        case .contentTooLarge:
            "This request is too large to store in local composer history or presets."
        }
    }
}

@MainActor
protocol TrafficRequestComposerStoring: AnyObject {
    var history: [TrafficRequestComposerEntry] { get }
    var presets: [TrafficRequestComposerEntry] { get }

    @discardableResult
    func recordHistory(headersText: String, bodyText: String) -> TrafficRequestComposerEntry?

    @discardableResult
    func savePreset(
        name: String,
        headersText: String,
        bodyText: String
    ) throws -> TrafficRequestComposerEntry

    func removePreset(id: UUID)
    func clearHistory()
}

@MainActor
final class InMemoryTrafficRequestComposerStore: TrafficRequestComposerStoring {
    private(set) var history: [TrafficRequestComposerEntry]
    private(set) var presets: [TrafficRequestComposerEntry]

    init(
        history: [TrafficRequestComposerEntry] = [],
        presets: [TrafficRequestComposerEntry] = []
    ) {
        self.history = normalizedComposerHistory(history)
        self.presets = normalizedComposerPresets(presets)
    }

    @discardableResult
    func recordHistory(headersText: String, bodyText: String) -> TrafficRequestComposerEntry? {
        guard canStoreComposerContent(headersText: headersText, bodyText: bodyText) else {
            return nil
        }
        let normalizedHeaders = headersText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHeaders.isEmpty else {
            return nil
        }

        let entry = TrafficRequestComposerEntry(
            kind: .history,
            name: composerHistoryName(headersText: normalizedHeaders),
            headersText: headersText,
            bodyText: bodyText
        )
        history.removeAll {
            $0.headersText == entry.headersText && $0.bodyText == entry.bodyText
        }
        history.insert(entry, at: 0)
        history = Array(history.prefix(TrafficRequestComposerStoreLimits.maximumHistoryEntries))
        return entry
    }

    @discardableResult
    func savePreset(
        name: String,
        headersText: String,
        bodyText: String
    ) throws -> TrafficRequestComposerEntry {
        let result = try upsertComposerPreset(
            name: name,
            headersText: headersText,
            bodyText: bodyText,
            into: presets
        )
        presets = result.presets
        return result.saved
    }

    func removePreset(id: UUID) {
        presets.removeAll { $0.id == id }
    }

    func clearHistory() {
        history.removeAll()
    }
}

@MainActor
final class UserDefaultsTrafficRequestComposerStore: TrafficRequestComposerStoring {
    static let defaultHistoryKey = "TrafficConsole.requestComposerHistory"
    static let defaultPresetsKey = "TrafficConsole.requestComposerPresets"

    private let defaults: UserDefaults
    private let historyKey: String
    private let presetsKey: String

    init(
        defaults: UserDefaults = .standard,
        historyKey: String = defaultHistoryKey,
        presetsKey: String = defaultPresetsKey
    ) {
        self.defaults = defaults
        self.historyKey = historyKey
        self.presetsKey = presetsKey
    }

    var history: [TrafficRequestComposerEntry] {
        normalizedComposerHistory(load(forKey: historyKey))
    }

    var presets: [TrafficRequestComposerEntry] {
        normalizedComposerPresets(load(forKey: presetsKey))
    }

    @discardableResult
    func recordHistory(headersText: String, bodyText: String) -> TrafficRequestComposerEntry? {
        let store = InMemoryTrafficRequestComposerStore(history: history, presets: presets)
        let entry = store.recordHistory(headersText: headersText, bodyText: bodyText)
        persist(store.history, forKey: historyKey)
        return entry
    }

    @discardableResult
    func savePreset(
        name: String,
        headersText: String,
        bodyText: String
    ) throws -> TrafficRequestComposerEntry {
        let result = try upsertComposerPreset(
            name: name,
            headersText: headersText,
            bodyText: bodyText,
            into: presets
        )
        persist(result.presets, forKey: presetsKey)
        return result.saved
    }

    func removePreset(id: UUID) {
        persist(presets.filter { $0.id != id }, forKey: presetsKey)
    }

    func clearHistory() {
        persist([], forKey: historyKey)
    }

    private func load(forKey key: String) -> [TrafficRequestComposerEntry] {
        guard let data = defaults.data(forKey: key) else {
            return []
        }
        return (try? JSONDecoder().decode([TrafficRequestComposerEntry].self, from: data)) ?? []
    }

    private func persist(_ entries: [TrafficRequestComposerEntry], forKey key: String) {
        defaults.set(try? JSONEncoder().encode(entries), forKey: key)
    }
}

private func upsertComposerPreset(
    name: String,
    headersText: String,
    bodyText: String,
    into presets: [TrafficRequestComposerEntry]
) throws -> (
    saved: TrafficRequestComposerEntry,
    presets: [TrafficRequestComposerEntry]
) {
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
        (1...TrafficRequestComposerStoreLimits.maximumPresetNameCharacters).contains(
            normalizedName.count
        )
    else {
        throw TrafficRequestComposerStoreError.invalidPresetName
    }
    guard canStoreComposerContent(headersText: headersText, bodyText: bodyText) else {
        throw TrafficRequestComposerStoreError.contentTooLarge
    }

    let existing = presets.first { preset in
        preset.name.compare(
            normalizedName,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame
    }
    let saved = TrafficRequestComposerEntry(
        id: existing?.id ?? UUID(),
        kind: .preset,
        name: normalizedName,
        headersText: headersText,
        bodyText: bodyText
    )
    let retained = presets.filter { $0.id != saved.id }
    return (
        saved,
        normalizedComposerPresets(retained + [saved])
    )
}

private func canStoreComposerContent(headersText: String, bodyText: String) -> Bool {
    headersText.utf8.count + bodyText.utf8.count
        <= TrafficRequestComposerStoreLimits.maximumStoredBytes
}

private func composerHistoryName(headersText: String) -> String {
    let firstLine =
        headersText.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Request"
    if firstLine.count <= TrafficRequestComposerStoreLimits.maximumPresetNameCharacters {
        return firstLine
    }
    let end = firstLine.index(
        firstLine.startIndex,
        offsetBy: TrafficRequestComposerStoreLimits.maximumPresetNameCharacters - 1
    )
    return String(firstLine[..<end]) + "…"
}

private func normalizedComposerHistory(
    _ entries: [TrafficRequestComposerEntry]
) -> [TrafficRequestComposerEntry] {
    var seen: Set<String> = []
    let filtered =
        entries
        .filter { $0.kind == .history }
        .filter { canStoreComposerContent(headersText: $0.headersText, bodyText: $0.bodyText) }
        .sorted { $0.updatedAt > $1.updatedAt }
        .filter { entry in
            let key = entry.headersText + "\u{0}" + entry.bodyText
            return seen.insert(key).inserted
        }
    return Array(filtered.prefix(TrafficRequestComposerStoreLimits.maximumHistoryEntries))
}

private func normalizedComposerPresets(
    _ entries: [TrafficRequestComposerEntry]
) -> [TrafficRequestComposerEntry] {
    var seenNames: Set<String> = []
    let filtered =
        entries
        .filter { $0.kind == .preset }
        .filter { canStoreComposerContent(headersText: $0.headersText, bodyText: $0.bodyText) }
        .filter {
            (1...TrafficRequestComposerStoreLimits.maximumPresetNameCharacters).contains(
                $0.name.count
            )
        }
        .sorted { $0.updatedAt > $1.updatedAt }
        .filter { entry in
            let key = entry.name.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
            return seenNames.insert(key).inserted
        }
    return Array(filtered.prefix(TrafficRequestComposerStoreLimits.maximumPresetEntries))
}
