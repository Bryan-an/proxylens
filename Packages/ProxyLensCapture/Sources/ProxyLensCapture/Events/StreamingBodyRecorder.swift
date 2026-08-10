import Foundation
import ProxyLensCore

actor StreamingBodyRecorder {
    private let bodyStore: any BodyStore
    private let metadata: BodyMetadata
    private let maximumByteCount: Int64
    private var writer: (any BodyWriter)?
    private var isFinished = false

    init(
        bodyStore: any BodyStore,
        metadata: BodyMetadata,
        maximumByteCount: Int64
    ) {
        self.bodyStore = bodyStore
        self.metadata = metadata
        self.maximumByteCount = max(0, maximumByteCount)
    }

    func append(_ data: Data) async throws {
        guard !isFinished, !data.isEmpty else {
            return
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

    func cancel() async {
        guard !isFinished else {
            return
        }
        isFinished = true
        await writer?.cancel()
    }
}
