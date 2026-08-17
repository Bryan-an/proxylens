import Foundation
import ProxyLensCore

public enum WebSocketComposePayloadEncoding: String, CaseIterable, Equatable, Sendable {
    case text
    case base64
}

public struct WebSocketComposeRequest: Equatable, Sendable {
    public let flowID: FlowID
    public let direction: WebSocketFrameDirection
    public let payloadEncoding: WebSocketComposePayloadEncoding
    public let payload: String

    public init(
        flowID: FlowID,
        direction: WebSocketFrameDirection,
        payloadEncoding: WebSocketComposePayloadEncoding,
        payload: String
    ) {
        self.flowID = flowID
        self.direction = direction
        self.payloadEncoding = payloadEncoding
        self.payload = payload
    }
}

public struct WebSocketReplayPayload: Equatable, Sendable {
    public let encoding: WebSocketComposePayloadEncoding
    public let payload: String

    public init(encoding: WebSocketComposePayloadEncoding, payload: String) {
        self.encoding = encoding
        self.payload = payload
    }
}

public struct WebSocketReconnectRequest: Equatable, Sendable {
    public let url: URL
    public let headers: HTTPHeaders
    public let replayPayload: WebSocketReplayPayload?

    public init(
        url: URL,
        headers: HTTPHeaders = HTTPHeaders(),
        replayPayload: WebSocketReplayPayload? = nil
    ) {
        self.url = url
        self.headers = headers
        self.replayPayload = replayPayload
    }
}

public enum WebSocketReconnectError: Error, Equatable, LocalizedError, Sendable {
    case headersTooLarge(maximumBytes: Int)
    case invalidURL
    case unavailable
    case unsupportedScheme(String)

    public var errorDescription: String? {
        switch self {
        case .headersTooLarge(let maximumBytes):
            "WebSocket request headers cannot exceed \(maximumBytes) bytes."
        case .invalidURL:
            "Enter an absolute WebSocket URL without credentials or a fragment."
        case .unavailable:
            "Opening a new WebSocket connection is unavailable."
        case .unsupportedScheme(let scheme):
            "WebSocket connections require a ws:// or wss:// URL, not \(scheme)."
        }
    }
}

public enum WebSocketComposeError: Error, Equatable, LocalizedError, Sendable {
    case invalidBase64
    case payloadTooLarge(maximumBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidBase64:
            "Binary WebSocket payloads must contain valid Base64."
        case .payloadTooLarge(let maximumBytes):
            "WebSocket payloads cannot exceed \(maximumBytes) bytes."
        }
    }
}

public struct WebSocketComposeService: Sendable {
    public static let defaultMaximumPayloadBytes = 1_024 * 1_024
    public static let defaultMaximumReconnectHeaderBytes = 64 * 1_024

    private let transmitters: [any WebSocketFrameTransmitter]
    private let connectionClient: (any WebSocketConnectionClient)?
    private let maximumPayloadBytes: Int
    private let maximumReconnectHeaderBytes: Int

    public init(
        transmitter: any WebSocketFrameTransmitter,
        maximumPayloadBytes: Int = Self.defaultMaximumPayloadBytes
    ) {
        transmitters = [transmitter]
        connectionClient = nil
        self.maximumPayloadBytes = max(0, maximumPayloadBytes)
        maximumReconnectHeaderBytes = Self.defaultMaximumReconnectHeaderBytes
    }

    public init(
        transmitters: [any WebSocketFrameTransmitter],
        connectionClient: (any WebSocketConnectionClient)? = nil,
        maximumPayloadBytes: Int = Self.defaultMaximumPayloadBytes,
        maximumReconnectHeaderBytes: Int = Self.defaultMaximumReconnectHeaderBytes
    ) {
        self.transmitters = transmitters
        self.connectionClient = connectionClient
        self.maximumPayloadBytes = max(0, maximumPayloadBytes)
        self.maximumReconnectHeaderBytes = max(0, maximumReconnectHeaderBytes)
    }

    public func isConnectionOpen(for flowID: FlowID) async -> Bool {
        for transmitter in transmitters
        where await transmitter.isConnectionOpen(for: flowID) {
            return true
        }
        return false
    }

    public func send(_ request: WebSocketComposeRequest) async throws {
        let message = try decodedMessage(
            encoding: request.payloadEncoding,
            payload: request.payload
        )
        let transmission = WebSocketFrameTransmission(
            flowID: request.flowID,
            direction: request.direction,
            opcode: message.opcode,
            payload: message.payload
        )

        for transmitter in transmitters
        where await transmitter.isConnectionOpen(for: request.flowID) {
            try await transmitter.send(transmission)
            return
        }
        throw ProxyLensError.unsupportedOperation(
            "The selected WebSocket connection is no longer open"
        )
    }

    public func reconnect(
        _ request: WebSocketReconnectRequest,
        sessionID: SessionID
    ) async throws -> Flow {
        guard let connectionClient else {
            throw WebSocketReconnectError.unavailable
        }
        try validate(url: request.url)
        guard Self.headerByteCount(request.headers) <= maximumReconnectHeaderBytes else {
            throw WebSocketReconnectError.headersTooLarge(
                maximumBytes: maximumReconnectHeaderBytes
            )
        }
        let initialMessage = try request.replayPayload.map {
            try decodedMessage(encoding: $0.encoding, payload: $0.payload)
        }
        return try await connectionClient.connect(
            HTTPRequest(
                method: .get,
                url: request.url,
                headers: request.headers,
                version: .http11
            ),
            initialMessage: initialMessage,
            sessionID: sessionID
        )
    }

    public func disconnect(flowID: FlowID) async {
        await connectionClient?.disconnect(flowID: flowID)
    }

    private func decodedMessage(
        encoding: WebSocketComposePayloadEncoding,
        payload: String
    ) throws -> WebSocketClientMessage {
        let message: WebSocketClientMessage
        switch encoding {
        case .text:
            message = WebSocketClientMessage(opcode: .text, payload: Data(payload.utf8))
        case .base64:
            guard let data = Data(base64Encoded: payload) else {
                throw WebSocketComposeError.invalidBase64
            }
            message = WebSocketClientMessage(opcode: .binary, payload: data)
        }
        guard message.payload.count <= maximumPayloadBytes else {
            throw WebSocketComposeError.payloadTooLarge(maximumBytes: maximumPayloadBytes)
        }
        return message
    }

    private func validate(url: URL) throws {
        guard let scheme = url.scheme?.lowercased() else {
            throw WebSocketReconnectError.invalidURL
        }
        guard scheme == "ws" || scheme == "wss" else {
            throw WebSocketReconnectError.unsupportedScheme(scheme)
        }
        guard let host = url.host, !host.isEmpty,
            url.user == nil,
            url.password == nil,
            url.fragment == nil,
            url.port.map({ (1...65_535).contains($0) }) ?? true
        else {
            throw WebSocketReconnectError.invalidURL
        }
    }

    private static func headerByteCount(_ headers: HTTPHeaders) -> Int {
        headers.reduce(into: 0) { total, header in
            let fieldBytes = header.name.utf8.count + 2 + header.value.utf8.count + 2
            let (sum, overflow) = total.addingReportingOverflow(fieldBytes)
            total = overflow ? Int.max : sum
        }
    }
}
