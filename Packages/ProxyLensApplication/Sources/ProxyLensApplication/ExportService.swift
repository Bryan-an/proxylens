import Foundation
import ProxyLensCore

/// Serializes a captured flow as cURL or HAR 1.2 from authoritative body bytes.
public struct ExportService: Sendable {
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

    private func read(_ reference: BodyReference?) async throws -> Data? {
        guard let reference else {
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
