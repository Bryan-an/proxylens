import Foundation

public protocol BodyStore: Sendable {
    func put(_ data: Data, metadata: BodyMetadata) async throws -> BodyReference
    func read(_ reference: BodyReference) async throws -> Data
    func remove(_ reference: BodyReference) async throws
}
