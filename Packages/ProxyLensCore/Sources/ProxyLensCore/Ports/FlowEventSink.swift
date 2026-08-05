import Foundation

public enum FlowEvent: Equatable, Sendable {
    case started(Flow)
    case updated(Flow)
    case finished(Flow)
}

public protocol FlowEventSink: Sendable {
    func publish(_ event: FlowEvent) async
}
