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

public enum FlowState: Codable, Equatable, Hashable, Sendable {
    case created
    case receivingRequest
    case connectingUpstream
    case receivingResponse
    case completed
    case cancelled
    case failed(FlowFailure)

    public var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failed:
            true
        case .created, .receivingRequest, .connectingUpstream, .receivingResponse:
            false
        }
    }

    public func canTransition(to nextState: FlowState) -> Bool {
        switch self {
        case .created:
            switch nextState {
            case .receivingRequest, .cancelled, .failed:
                true
            case .created, .connectingUpstream, .receivingResponse, .completed:
                false
            }
        case .receivingRequest:
            switch nextState {
            case .connectingUpstream, .receivingResponse, .cancelled, .failed:
                true
            case .created, .receivingRequest, .completed:
                false
            }
        case .connectingUpstream:
            switch nextState {
            case .receivingResponse, .cancelled, .failed:
                true
            case .created, .receivingRequest, .connectingUpstream, .completed:
                false
            }
        case .receivingResponse:
            switch nextState {
            case .completed, .cancelled, .failed:
                true
            case .created, .receivingRequest, .connectingUpstream, .receivingResponse:
                false
            }
        case .completed, .cancelled, .failed:
            false
        }
    }
}
