import ProxyLensCore

/// A default sink for callers that only need proxying and do not yet have a UI or store.
public struct NoOpFlowEventSink: FlowEventSink {
    public init() {}

    public func publish(_ event: FlowEvent) async {}
}
