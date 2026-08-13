import Foundation

public enum FlowEvent: Equatable, Sendable {
    case started(Flow)
    case updated(Flow)
    case finished(Flow)

    public var flow: Flow {
        switch self {
        case .started(let flow), .updated(let flow), .finished(let flow):
            flow
        }
    }
}

public protocol FlowEventSink: Sendable {
    func publish(_ event: FlowEvent) async
}
