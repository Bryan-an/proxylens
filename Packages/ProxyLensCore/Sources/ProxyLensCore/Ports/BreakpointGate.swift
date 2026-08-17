import Foundation

/// The transport-safe subset of a server WebSocket frame exposed at a breakpoint.
///
/// Raw captured bytes remain authoritative. Payload replacement is intentionally
/// limited to complete, uncompressed UTF-8 text frames so editing cannot silently
/// invalidate fragmentation or extension semantics.
public struct WebSocketBreakpointFrame: Equatable, Sendable {
    public let sequenceNumber: Int
    public let opcode: WebSocketFrameOpcode
    public let isFinal: Bool
    public let reservedBits: WebSocketReservedBits
    public let payload: Data?
    public let originalPayloadByteCount: Int
    public let maximumEditablePayloadBytes: Int

    public init(
        sequenceNumber: Int,
        opcode: WebSocketFrameOpcode,
        isFinal: Bool,
        reservedBits: WebSocketReservedBits = [],
        payload: Data?,
        originalPayloadByteCount: Int,
        maximumEditablePayloadBytes: Int
    ) {
        self.sequenceNumber = max(0, sequenceNumber)
        self.opcode = opcode
        self.isFinal = isFinal
        self.reservedBits = reservedBits
        self.payload = payload
        self.originalPayloadByteCount = max(0, originalPayloadByteCount)
        self.maximumEditablePayloadBytes = max(0, maximumEditablePayloadBytes)
    }

    public static func isEligibleDataOpcode(_ opcode: WebSocketFrameOpcode) -> Bool {
        switch opcode {
        case .text, .binary, .continuation:
            true
        case .close, .ping, .pong, .unknown:
            false
        }
    }

    public var canEditPayload: Bool {
        editingUnavailableReason == nil
    }

    public var editingUnavailableReason: String? {
        guard opcode == .text else {
            return "Only complete text frames can be edited"
        }
        guard isFinal else {
            return "Fragmented WebSocket messages are read-only"
        }
        guard reservedBits.isEmpty else {
            return "Compressed or extended WebSocket frames are read-only"
        }
        guard let payload else {
            return "The frame payload is too large to edit"
        }
        guard payload.count <= maximumEditablePayloadBytes else {
            return "The frame payload is too large to edit"
        }
        guard String(data: payload, encoding: .utf8) != nil else {
            return "Invalid UTF-8 text frames are read-only"
        }
        return nil
    }

    public func replacingPayload(_ replacement: Data) throws -> Self {
        guard canEditPayload else {
            throw ProxyLensError.unsupportedOperation(
                editingUnavailableReason ?? "This WebSocket frame cannot be edited"
            )
        }
        guard replacement.count <= maximumEditablePayloadBytes else {
            throw ProxyLensError.unsupportedOperation(
                "WebSocket breakpoint payload exceeds the editable size limit"
            )
        }
        guard String(data: replacement, encoding: .utf8) != nil else {
            throw ProxyLensError.unsupportedOperation(
                "WebSocket breakpoint text must be valid UTF-8"
            )
        }

        return Self(
            sequenceNumber: sequenceNumber,
            opcode: opcode,
            isFinal: isFinal,
            reservedBits: reservedBits,
            payload: replacement,
            originalPayloadByteCount: originalPayloadByteCount,
            maximumEditablePayloadBytes: maximumEditablePayloadBytes
        )
    }
}

/// A paused request or response waiting for the user to continue or abort.
public struct BreakpointHit: Equatable, Sendable {
    public let flowID: FlowID
    public let phase: BreakpointPhase
    public let request: HTTPRequest
    public let response: HTTPResponse?
    public let webSocketFrame: WebSocketBreakpointFrame?

    public init(
        flowID: FlowID,
        phase: BreakpointPhase,
        request: HTTPRequest,
        response: HTTPResponse? = nil,
        webSocketFrame: WebSocketBreakpointFrame? = nil
    ) {
        self.flowID = flowID
        self.phase = phase
        self.request = request
        self.response = response
        self.webSocketFrame = webSocketFrame
    }
}

public enum BreakpointDecision: Equatable, Sendable {
    case abort
    case `continue`(BreakpointHit)
}

/// Waits for a breakpoint decision without blocking a NIO event loop.
public protocol BreakpointGate: Sendable {
    func pause(_ hit: BreakpointHit) async -> BreakpointDecision
}

/// Continues immediately with the captured request or response.
public struct ImmediateBreakpointGate: BreakpointGate {
    public init() {}

    public func pause(_ hit: BreakpointHit) async -> BreakpointDecision {
        .continue(hit)
    }
}
