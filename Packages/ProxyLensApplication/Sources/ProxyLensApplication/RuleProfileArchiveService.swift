import Foundation
import ProxyLensCore

public enum RuleProfileArchiveError: Error, Equatable, LocalizedError, Sendable {
    case invalidName
    case archiveTooLarge(byteCount: Int, maximumByteCount: Int)
    case unsupportedSchema(Int)
    case invalidDocument(String)
    case unreadableFile(String)
    case unwritableFile(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName:
            "Profile name must contain 1 through 80 characters."
        case .archiveTooLarge(let byteCount, let maximumByteCount):
            "Rule profile is \(byteCount) bytes; the limit is \(maximumByteCount) bytes."
        case .unsupportedSchema(let version):
            "Rule profile schema version \(version) is unsupported."
        case .invalidDocument(let message):
            "The selected file is not a valid ProxyLens rule profile: \(message)"
        case .unreadableFile(let message):
            "Could not read the rule profile: \(message)"
        case .unwritableFile(let message):
            "Could not export the rule profile: \(message)"
        }
    }
}

public actor RuleProfileArchiveService {
    public static let defaultMaximumArchiveByteCount = 64 * 1_024 * 1_024

    private let maximumArchiveByteCount: Int

    public init(
        maximumArchiveByteCount: Int = RuleProfileArchiveService.defaultMaximumArchiveByteCount
    ) {
        self.maximumArchiveByteCount = max(1, maximumArchiveByteCount)
    }

    public func export(_ profile: RuleProfile, to fileURL: URL) throws {
        try validate(profile)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(profile)
        } catch {
            throw RuleProfileArchiveError.invalidDocument(error.localizedDescription)
        }
        try validateArchiveSize(data.count)

        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw RuleProfileArchiveError.unwritableFile(error.localizedDescription)
        }
    }

    public func importProfile(from fileURL: URL) throws -> RuleProfile {
        let values: URLResourceValues
        do {
            values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            throw RuleProfileArchiveError.unreadableFile(error.localizedDescription)
        }
        guard values.isRegularFile == true else {
            throw RuleProfileArchiveError.unreadableFile("the selected item is not a regular file")
        }
        try validateArchiveSize(values.fileSize ?? 0)

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw RuleProfileArchiveError.unreadableFile(error.localizedDescription)
        }
        defer { try? handle.close() }

        let data: Data
        do {
            let readLimit =
                maximumArchiveByteCount == Int.max
                ? Int.max : maximumArchiveByteCount + 1
            data = try handle.read(upToCount: readLimit) ?? Data()
        } catch {
            throw RuleProfileArchiveError.unreadableFile(error.localizedDescription)
        }
        try validateArchiveSize(data.count)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let profile: RuleProfile
        do {
            profile = try decoder.decode(RuleProfile.self, from: data)
        } catch {
            throw RuleProfileArchiveError.invalidDocument(error.localizedDescription)
        }
        try validate(profile)
        return profile
    }

    private func validate(_ profile: RuleProfile) throws {
        do {
            try RuleEngine.validate(profile)
        } catch RuleEngineError.unsupportedRuleProfileSchema(let version) {
            throw RuleProfileArchiveError.unsupportedSchema(version)
        }
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(name.count) else {
            throw RuleProfileArchiveError.invalidName
        }
    }

    private func validateArchiveSize(_ byteCount: Int) throws {
        guard byteCount <= maximumArchiveByteCount else {
            throw RuleProfileArchiveError.archiveTooLarge(
                byteCount: byteCount,
                maximumByteCount: maximumArchiveByteCount
            )
        }
    }
}
