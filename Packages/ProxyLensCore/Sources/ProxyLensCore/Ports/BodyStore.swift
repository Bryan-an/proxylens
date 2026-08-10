import Foundation

public protocol BodyWriter: Sendable {
    /// Appends raw bytes in wire order. Implementations must enforce their configured size limit.
    func append(_ data: Data) async throws
    func finalize() async throws -> BodyReference
    func cancel() async
}

public protocol BodyStore: Sendable {
    /// Starts a bounded streaming write. Bytes beyond `maximumByteCount` are discarded and the
    /// finalized reference is marked truncated.
    func beginWrite(
        metadata: BodyMetadata,
        maximumByteCount: Int64?
    ) async throws -> any BodyWriter

    func read(_ reference: BodyReference) async throws -> Data
    func remove(_ reference: BodyReference) async throws
}

extension BodyStore {
    public func put(_ data: Data, metadata: BodyMetadata) async throws -> BodyReference {
        let writer = try await beginWrite(metadata: metadata, maximumByteCount: nil)
        do {
            try await writer.append(data)
            return try await writer.finalize()
        } catch {
            await writer.cancel()
            throw error
        }
    }
}
