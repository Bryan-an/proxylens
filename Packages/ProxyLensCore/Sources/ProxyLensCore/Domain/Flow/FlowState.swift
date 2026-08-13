import Foundation

public enum FlowFailure: Codable, Equatable, Hashable, Sendable {
    case clientDisconnected
    case upstreamUnavailable
    case timeout
    case tlsHandshakeFailed
    case protocolError(String)
    case persistenceError(String)
    case unknown(String)
}

public enum BreakpointPhase: String, Codable, Equatable, Hashable, Sendable {
    case request
    case response
}

public enum FlowState: Codable, Equatable, Hashable, Sendable {
    case created
    case receivingRequest
    case connectingUpstream
    case receivingResponse
    case paused(BreakpointPhase)
    case completed
    case cancelled
    case failed(FlowFailure)

    public var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failed:
            true
        case .created, .receivingRequest, .connectingUpstream, .receivingResponse, .paused:
            false
        }
    }

    public var breakpointPhase: BreakpointPhase? {
        if case .paused(let phase) = self {
            return phase
        }
        return nil
    }

    public func canTransition(to nextState: FlowState) -> Bool {
        switch self {
        case .created:
            switch nextState {
            case .receivingRequest, .cancelled, .failed:
                true
            case .created, .connectingUpstream, .receivingResponse, .paused, .completed:
                false
            }
        case .receivingRequest:
            switch nextState {
            case .connectingUpstream, .receivingResponse, .paused(.request), .cancelled, .failed:
                true
            case .created, .receivingRequest, .paused(.response), .completed:
                false
            }
        case .paused(.request):
            switch nextState {
            case .connectingUpstream, .receivingResponse, .cancelled, .failed:
                true
            case .created, .receivingRequest, .paused, .completed:
                false
            }
        case .connectingUpstream:
            switch nextState {
            case .receivingResponse, .cancelled, .failed:
                true
            case .created, .receivingRequest, .connectingUpstream, .paused, .completed:
                false
            }
        case .receivingResponse:
            switch nextState {
            case .paused(.response), .completed, .cancelled, .failed:
                true
            case .created, .receivingRequest, .connectingUpstream, .receivingResponse,
                .paused(.request):
                false
            }
        case .paused(.response):
            switch nextState {
            case .completed, .cancelled, .failed:
                true
            case .created, .receivingRequest, .connectingUpstream, .receivingResponse, .paused:
                false
            }
        case .completed, .cancelled, .failed:
            false
        }
    }
}
