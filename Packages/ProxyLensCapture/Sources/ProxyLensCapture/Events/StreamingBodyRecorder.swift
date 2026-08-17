import Foundation
import ProxyLensCore

actor StreamingBodyRecorder {
    private static let maximumDiscoveryByteCount = GraphQLBodyView.maximumDecodedByteCount

    private let bodyStore: any BodyStore
    private let metadata: BodyMetadata
    private let maximumByteCount: Int64
    private let discoversGraphQLOperation: Bool
    private var writer: (any BodyWriter)?
    private var discoveryBytes = Data()
    private var discoveryLimitExceeded = false
    private var isFinished = false

    init(
        bodyStore: any BodyStore,
        metadata: BodyMetadata,
        maximumByteCount: Int64,
        discoversGraphQLOperation: Bool = false
    ) {
        self.bodyStore = bodyStore
        self.metadata = metadata
        self.maximumByteCount = max(0, maximumByteCount)
        self.discoversGraphQLOperation =
            discoversGraphQLOperation && Self.isPotentialGraphQLContentType(metadata.contentType)
    }

    func append(_ data: Data) async throws {
        guard !isFinished, !data.isEmpty else {
            return
        }

        if discoversGraphQLOperation {
            let remainingDiscoveryBytes = max(
                0,
                Self.maximumDiscoveryByteCount - discoveryBytes.count
            )
            if remainingDiscoveryBytes > 0 {
                discoveryBytes.append(data.prefix(remainingDiscoveryBytes))
            }
            if data.count > remainingDiscoveryBytes {
                discoveryLimitExceeded = true
            }
        }

        let writer: any BodyWriter
        if let existingWriter = self.writer {
            writer = existingWriter
        } else {
            writer = try await bodyStore.beginWrite(
                metadata: metadata,
                maximumByteCount: maximumByteCount
            )
            self.writer = writer
        }
        try await writer.append(data)
    }

    func finalize() async throws -> BodyReference? {
        guard !isFinished else {
            return nil
        }
        isFinished = true
        guard let writer else {
            return nil
        }
        return try await writer.finalize()
    }

    func graphqlOperation(for reference: BodyReference) -> GraphQLOperationMetadata? {
        guard discoversGraphQLOperation, !discoveryLimitExceeded, !reference.isTruncated else {
            return nil
        }
        return GraphQLBodyView.operationMetadata(
            data: discoveryBytes,
            contentType: metadata.contentType,
            contentEncoding: metadata.contentEncoding
        )
    }

    func cancel() async {
        guard !isFinished else {
            return
        }
        isFinished = true
        await writer?.cancel()
    }

    private static func isPotentialGraphQLContentType(_ contentType: String?) -> Bool {
        let mediaType =
            contentType?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return mediaType == "application/graphql"
            || mediaType == "application/json"
            || mediaType == "text/json"
            || mediaType?.hasSuffix("+json") == true
    }
}
