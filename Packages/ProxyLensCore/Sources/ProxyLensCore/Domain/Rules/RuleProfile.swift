import Foundation

public struct RuleProfile: Codable, Equatable, Hashable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public let name: String
    public let rules: RuleSet
    public let mappedLocals: [MapLocalSpec]
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        schemaVersion: Int = RuleProfile.currentSchemaVersion,
        id: UUID = UUID(),
        name: String,
        rules: RuleSet,
        mappedLocals: [MapLocalSpec] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.rules = rules
        self.mappedLocals = mappedLocals
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
