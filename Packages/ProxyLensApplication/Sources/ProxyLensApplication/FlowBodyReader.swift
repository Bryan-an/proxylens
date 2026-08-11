import Foundation
import ProxyLensCore

/// Reads authoritative captured body bytes without exposing the storage adapter to the UI.
public struct FlowBodyReader: Sendable {
    private let bodyStore: any BodyStore

    public init(bodyStore: any BodyStore) {
        self.bodyStore = bodyStore
    }

    public func read(_ reference: BodyReference) async throws -> Data {
        try await bodyStore.read(reference)
    }
}
