import Foundation
import ProxyLensCore

public enum RuleProfileStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidName
    case tooManyProfiles(maximum: Int)
    case archiveTooLarge(byteCount: Int, maximumByteCount: Int)
    case corruptProfile(fileName: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidName:
            "Profile name must contain 1 through 80 characters."
        case .tooManyProfiles(let maximum):
            "Rule profiles are limited to \(maximum)."
        case .archiveTooLarge(let byteCount, let maximumByteCount):
            "Rule profile is \(byteCount) bytes; the limit is \(maximumByteCount) bytes."
        case .corruptProfile(let fileName, let message):
            "Could not read rule profile \(fileName): \(message)"
        }
    }
}

public actor FileRuleProfileStore: RuleProfileStoring {
    public static let defaultMaximumProfiles = 50
    public static let defaultMaximumArchiveByteCount = 64 * 1_024 * 1_024

    private let directoryURL: URL
    private let fileManager: FileManager
    private let maximumProfiles: Int
    private let maximumArchiveByteCount: Int

    public init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        maximumProfiles: Int = FileRuleProfileStore.defaultMaximumProfiles,
        maximumArchiveByteCount: Int = FileRuleProfileStore.defaultMaximumArchiveByteCount
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.maximumProfiles = max(1, maximumProfiles)
        self.maximumArchiveByteCount = max(1, maximumArchiveByteCount)
    }

    public func list() throws -> [RuleProfile] {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return []
        }
        return try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "json" }
        .map(decodeProfile)
        .sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public func save(_ profile: RuleProfile) throws -> RuleProfile {
        let normalizedName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(normalizedName.count) else {
            throw RuleProfileStoreError.invalidName
        }

        let profiles = try list()
        let existing =
            profiles.first { $0.id == profile.id }
            ?? profiles.first {
                $0.name.compare(
                    normalizedName,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
            }
        guard existing != nil || profiles.count < maximumProfiles else {
            throw RuleProfileStoreError.tooManyProfiles(maximum: maximumProfiles)
        }

        let saved = RuleProfile(
            id: existing?.id ?? profile.id,
            name: normalizedName,
            rules: profile.rules,
            mappedLocals: profile.mappedLocals,
            createdAt: existing?.createdAt ?? profile.createdAt,
            updatedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(saved)
        guard data.count <= maximumArchiveByteCount else {
            throw RuleProfileStoreError.archiveTooLarge(
                byteCount: data.count,
                maximumByteCount: maximumArchiveByteCount
            )
        }

        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try data.write(to: profileURL(id: saved.id), options: .atomic)
        return saved
    }

    public func remove(id: UUID) throws {
        let url = profileURL(id: id)
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try fileManager.removeItem(at: url)
    }

    private func decodeProfile(at url: URL) throws -> RuleProfile {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                throw RuleProfileStoreError.corruptProfile(
                    fileName: url.lastPathComponent,
                    message: "not a regular file"
                )
            }
            let byteCount = values.fileSize ?? 0
            guard byteCount <= maximumArchiveByteCount else {
                throw RuleProfileStoreError.archiveTooLarge(
                    byteCount: byteCount,
                    maximumByteCount: maximumArchiveByteCount
                )
            }
            return try JSONDecoder().decode(RuleProfile.self, from: Data(contentsOf: url))
        } catch let error as RuleProfileStoreError {
            throw error
        } catch {
            throw RuleProfileStoreError.corruptProfile(
                fileName: url.lastPathComponent,
                message: error.localizedDescription
            )
        }
    }

    private func profileURL(id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }
}
