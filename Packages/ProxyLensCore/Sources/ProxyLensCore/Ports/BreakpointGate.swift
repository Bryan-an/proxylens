import Foundation

/// A paused request or response waiting for the user to continue or abort.
public struct BreakpointHit: Equatable, Sendable {
    public let flowID: FlowID
    public let phase: BreakpointPhase
    public let request: HTTPRequest
    public let response: HTTPResponse?

    public init(
        flowID: FlowID,
        phase: BreakpointPhase,
        request: HTTPRequest,
        response: HTTPResponse? = nil
    ) {
        self.flowID = flowID
        self.phase = phase
        self.request = request
        self.response = response
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
