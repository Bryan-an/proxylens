import Foundation

public protocol RuleProfileStoring: Sendable {
    func list() async throws -> [RuleProfile]
    func save(_ profile: RuleProfile) async throws -> RuleProfile
    func remove(id: UUID) async throws
}
