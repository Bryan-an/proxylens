import Foundation

public enum FlowSourceKind: String, Codable, Equatable, Hashable, Sendable {
    case desktopProxy
    case importedSession
    case replay
}

public struct FlowSource: Codable, Equatable, Hashable, Sendable {
    public let kind: FlowSourceKind
    public let label: String
    public let clientAddress: String?

    public init(kind: FlowSourceKind, label: String, clientAddress: String? = nil) {
        self.kind = kind
        self.label = label
        self.clientAddress = clientAddress
    }

    public static let desktopProxy = FlowSource(kind: .desktopProxy, label: "Desktop proxy")
}

public enum ConnectionProtocol: String, Codable, Equatable, Hashable, Sendable {
    case http
    case https
    case webSocket
    case secureWebSocket
}

public struct ConnectionInfo: Codable, Equatable, Hashable, Sendable {
    public let protocolKind: ConnectionProtocol
    public let upstreamHost: String
    public let upstreamPort: UInt16
    public let tlsIntercepted: Bool

    public init(
        protocolKind: ConnectionProtocol,
        upstreamHost: String,
        upstreamPort: UInt16,
        tlsIntercepted: Bool = false
    ) {
        self.protocolKind = protocolKind
        self.upstreamHost = upstreamHost
        self.upstreamPort = upstreamPort
        self.tlsIntercepted = tlsIntercepted
    }
}

public struct Flow: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: FlowID
    public let sessionID: SessionID
    public let source: FlowSource
    public let createdAt: Date
    public private(set) var request: HTTPRequest
    public let connection: ConnectionInfo?
    public private(set) var response: HTTPResponse?
    public private(set) var timing: FlowTiming
    public private(set) var ruleTraces: [RuleTrace]
    public private(set) var state: FlowState

    public init(
        id: FlowID = FlowID(),
        sessionID: SessionID,
        source: FlowSource = .desktopProxy,
        request: HTTPRequest,
        connection: ConnectionInfo? = nil,
        startedAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.source = source
        self.createdAt = startedAt
        self.request = request
        self.connection = connection
        self.response = nil
        self.timing = FlowTiming(startedAt: startedAt)
        self.ruleTraces = []
        self.state = .created
    }

    public mutating func transition(to nextState: FlowState) throws {
        guard state.canTransition(to: nextState) else {
            throw ProxyLensError.invalidFlowTransition(from: state, to: nextState)
        }

        state = nextState
    }

    public mutating func attachResponse(_ response: HTTPResponse) {
        self.response = response
    }

    public mutating func attachRequestBody(_ body: BodyReference) {
        request.attachBody(body)
    }

    public mutating func attachResponseBody(_ body: BodyReference) {
        response?.attachBody(body)
    }

    public mutating func appendRuleTrace(_ trace: RuleTrace) {
        ruleTraces.append(trace)
    }

    public mutating func appendRuleTraces(_ traces: [RuleTrace]) {
        ruleTraces.append(contentsOf: traces)
    }

    public mutating func replaceRequest(_ request: HTTPRequest) {
        self.request = request
    }

    public mutating func markRequestHeadersReceived(at date: Date) {
        timing.markRequestHeadersReceived(at: date)
    }

    public mutating func markRequestBodyCompleted(at date: Date) {
        timing.markRequestBodyCompleted(at: date)
    }

    public mutating func markUpstreamConnected(at date: Date) {
        timing.markUpstreamConnected(at: date)
    }

    public mutating func markTLSHandshakeCompleted(at date: Date) {
        timing.markTLSHandshakeCompleted(at: date)
    }

    public mutating func markResponseHeadersReceived(at date: Date) {
        timing.markResponseHeadersReceived(at: date)
    }

    public mutating func markResponseBodyCompleted(at date: Date) {
        timing.markResponseBodyCompleted(at: date)
    }

    public mutating func markCompleted(at date: Date) {
        timing.markCompleted(at: date)
    }

    public var summary: FlowSummary {
        FlowSummary(flow: self)
    }
}
