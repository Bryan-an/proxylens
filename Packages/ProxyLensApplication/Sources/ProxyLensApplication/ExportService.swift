import Foundation
import ProxyLensCore

/// Serializes a captured flow as cURL or HAR 1.2 from authoritative body bytes.
public struct ExportService: Sendable {
    private static let maximumRequestCodeBodyBytes: Int64 = 8 * 1_024 * 1_024
    private let bodyStore: any BodyStore

    public init(bodyStore: any BodyStore) {
        self.bodyStore = bodyStore
    }

    public func curl(for flow: Flow) async throws -> String {
        let body = try await read(flow.request.body)
        return CURLCommand.serialize(
            request: flow.request,
            body: body,
            comments: FlowExportNotes.comments(for: flow)
        )
    }

    public func requestCode(
        for flow: Flow,
        language: RequestCodeLanguage
    ) async throws -> String {
        let body = try await readRequestCodeBody(flow.request.body)
        return RequestCodeGenerator.generate(
            request: flow.request,
            body: body,
            language: language,
            comments: FlowExportNotes.comments(for: flow)
        )
    }

    public func requestCodeSnippets(for flow: Flow) async throws -> [RequestCodeSnippet] {
        let body = try await readRequestCodeBody(flow.request.body)
        let comments = FlowExportNotes.comments(for: flow)
        return RequestCodeLanguage.allCases.map { language in
            RequestCodeSnippet(
                language: language,
                source: RequestCodeGenerator.generate(
                    request: flow.request,
                    body: body,
                    language: language,
                    comments: comments
                )
            )
        }
    }

    public func har(for flow: Flow) async throws -> Data {
        let requestBody = try await read(flow.request.body)
        let responseBody = try await read(flow.response?.body)
        return try HARDocument.serialize(
            flow: flow,
            requestBody: requestBody,
            responseBody: responseBody,
            comments: FlowExportNotes.comments(for: flow)
        )
    }

    public func openAPI(
        for flows: [Flow],
        options: OpenAPIExportOptions = OpenAPIExportOptions()
    ) async throws -> Data {
        guard !flows.isEmpty else {
            throw OpenAPIExportError.noFlows
        }

        var requestBodies: [FlowID: Data?] = [:]
        var responseBodies: [FlowID: Data?] = [:]
        for flow in flows {
            try Task.checkCancellation()
            requestBodies[flow.id] = try await readSchemaBody(flow.request.body)
            responseBodies[flow.id] = try await readSchemaBody(flow.response?.body)
        }
        return try OpenAPIDocument.serialize(
            flows: flows,
            requestBodies: requestBodies,
            responseBodies: responseBodies,
            options: options
        )
    }

    /// Streams a portable, versioned WebSocket frame document without retaining every payload.
    /// The destination is replaced only after the complete document has been written successfully.
    public func writeWebSocketFrames(
        _ frames: [CapturedWebSocketFrame],
        for flowID: FlowID,
        exportedAt: Date = Date(),
        to destinationURL: URL
    ) async throws {
        guard !frames.isEmpty else {
            throw ProxyLensError.unsupportedOperation("No WebSocket frames are available to export")
        }
        guard frames.allSatisfy({ $0.flowID == flowID }) else {
            throw ProxyLensError.unsupportedOperation(
                "A WebSocket frame export can contain only one flow"
            )
        }

        let orderedFrames = frames.sorted {
            if $0.sequenceNumber != $1.sequenceNumber {
                return $0.sequenceNumber < $1.sequenceNumber
            }
            return $0.receivedAt < $1.receivedAt
        }
        let fileManager = FileManager.default
        let stagingURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".\(destinationURL.lastPathComponent).proxylens-\(UUID().uuidString).partial"
        )
        guard fileManager.createFile(atPath: stagingURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        var handle: FileHandle?
        do {
            let output = try FileHandle(forWritingTo: stagingURL)
            handle = output
            try output.write(
                contentsOf: WebSocketFramesDocument.preamble(
                    flowID: flowID,
                    exportedAt: exportedAt
                )
            )
            for (index, frame) in orderedFrames.enumerated() {
                try Task.checkCancellation()
                if index > 0 {
                    try output.write(contentsOf: WebSocketFramesDocument.entrySeparator)
                }
                let payload = try await bodyStore.read(frame.payload)
                try output.write(
                    contentsOf: WebSocketFramesDocument.serializeEntry(
                        frame: frame,
                        payload: payload
                    )
                )
            }
            try output.write(contentsOf: WebSocketFramesDocument.epilogue)
            try output.synchronize()
            try output.close()
            handle = nil

            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagingURL)
            } else {
                try fileManager.moveItem(at: stagingURL, to: destinationURL)
            }
        } catch {
            try? handle?.close()
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
    }

    /// Streams a portable, versioned Server-Sent Event document without retaining every payload.
    /// The destination is replaced only after the complete document has been written successfully.
    public func writeServerSentEvents(
        _ events: [CapturedServerSentEvent],
        for flowID: FlowID,
        exportedAt: Date = Date(),
        to destinationURL: URL
    ) async throws {
        guard !events.isEmpty else {
            throw ProxyLensError.unsupportedOperation(
                "No Server-Sent Events are available to export"
            )
        }
        guard events.allSatisfy({ $0.flowID == flowID }) else {
            throw ProxyLensError.unsupportedOperation(
                "A Server-Sent Event export can contain only one flow"
            )
        }

        let orderedEvents = events.sorted {
            if $0.sequenceNumber != $1.sequenceNumber {
                return $0.sequenceNumber < $1.sequenceNumber
            }
            return $0.receivedAt < $1.receivedAt
        }
        let fileManager = FileManager.default
        let stagingURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".\(destinationURL.lastPathComponent).proxylens-\(UUID().uuidString).partial"
        )
        guard fileManager.createFile(atPath: stagingURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        var handle: FileHandle?
        do {
            let output = try FileHandle(forWritingTo: stagingURL)
            handle = output
            try output.write(
                contentsOf: ServerSentEventsDocument.preamble(
                    flowID: flowID,
                    exportedAt: exportedAt
                )
            )
            for (index, event) in orderedEvents.enumerated() {
                try Task.checkCancellation()
                if index > 0 {
                    try output.write(contentsOf: ServerSentEventsDocument.entrySeparator)
                }
                let data = try await bodyStore.read(event.data)
                try output.write(
                    contentsOf: ServerSentEventsDocument.serializeEntry(
                        event: event,
                        data: data
                    )
                )
            }
            try output.write(contentsOf: ServerSentEventsDocument.epilogue)
            try output.synchronize()
            try output.close()
            handle = nil

            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagingURL)
            } else {
                try fileManager.moveItem(at: stagingURL, to: destinationURL)
            }
        } catch {
            try? handle?.close()
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
    }

    /// Streams a collection of flows into one HAR file without retaining every represented body.
    /// The destination is replaced only after the complete document has been written successfully.
    public func writeHAR(for flows: [Flow], to destinationURL: URL) async throws {
        let fileManager = FileManager.default
        let stagingURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".\(destinationURL.lastPathComponent).proxylens-\(UUID().uuidString).partial"
        )
        guard fileManager.createFile(atPath: stagingURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        var handle: FileHandle?
        do {
            let output = try FileHandle(forWritingTo: stagingURL)
            handle = output
            try output.write(contentsOf: HARDocument.streamPreamble)

            for (index, flow) in flows.enumerated() {
                try Task.checkCancellation()
                if index > 0 {
                    try output.write(contentsOf: HARDocument.streamEntrySeparator)
                }
                let requestBody = try await read(flow.request.body)
                let responseBody = try await read(flow.response?.body)
                let entry = try HARDocument.serializeEntry(
                    flow: flow,
                    requestBody: requestBody,
                    responseBody: responseBody,
                    comments: FlowExportNotes.comments(for: flow)
                )
                try output.write(contentsOf: entry)
            }

            try output.write(contentsOf: HARDocument.streamEpilogue)
            try output.synchronize()
            try output.close()
            handle = nil

            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagingURL)
            } else {
                try fileManager.moveItem(at: stagingURL, to: destinationURL)
            }
        } catch {
            try? handle?.close()
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
    }

    private func read(_ reference: BodyReference?) async throws -> Data? {
        guard let reference else {
            return nil
        }

        return try await bodyStore.read(reference)
    }

    private func readRequestCodeBody(_ reference: BodyReference?) async throws -> Data? {
        guard let reference else {
            return nil
        }
        guard reference.byteCount <= Self.maximumRequestCodeBodyBytes else {
            throw ProxyLensError.unsupportedOperation(
                "Request code generation is limited to 8 MiB bodies"
            )
        }
        return try await bodyStore.read(reference)
    }

    private func readSchemaBody(_ reference: BodyReference?) async throws -> Data? {
        guard let reference, reference.byteCount <= 1_048_576 else {
            return nil
        }
        return try await bodyStore.read(reference)
    }
}

enum FlowExportNotes {
    static func comments(for flow: Flow) -> [String] {
        var notes: [String] = []

        if flow.request.body?.isTruncated == true {
            notes.append("Captured request body was truncated")
        }
        if flow.response?.body?.isTruncated == true {
            notes.append("Captured response body was truncated")
        }
        if flow.response == nil {
            notes.append("Response was not captured")
        }

        switch flow.state {
        case .cancelled:
            notes.append("Flow was cancelled")
        case .failed(let failure):
            notes.append("Flow failed: \(describe(failure))")
        case .created, .receivingRequest, .connectingUpstream, .receivingResponse, .paused,
            .completed:
            break
        }

        return notes
    }

    private static func describe(_ failure: FlowFailure) -> String {
        switch failure {
        case .clientDisconnected:
            "The client disconnected"
        case .simulatedNetworkFailure:
            "A network condition closed the connection"
        case .upstreamUnavailable:
            "The upstream was unavailable"
        case .timeout:
            "The request timed out"
        case .tlsHandshakeFailed:
            "The TLS handshake failed"
        case .protocolError(let message):
            "Protocol error: \(message)"
        case .persistenceError(let message):
            "Persistence error: \(message)"
        case .unknown(let message):
            message
        }
    }
}
