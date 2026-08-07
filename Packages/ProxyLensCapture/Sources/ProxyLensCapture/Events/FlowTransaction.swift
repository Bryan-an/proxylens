import Foundation
import ProxyLensCore

actor FlowTransaction {
    private var flow: Flow
    private let eventSink: any FlowEventSink
    private var isFinished = false

    init(flow: Flow, eventSink: any FlowEventSink) {
        self.flow = flow
        self.eventSink = eventSink
    }

    func start(at date: Date) async {
        guard flow.state == .created else {
            return
        }

        do {
            try flow.transition(to: .receivingRequest)
            flow.markRequestHeadersReceived(at: date)
            await eventSink.publish(.started(flow))
        } catch {
            await fail(.protocolError(error.localizedDescription))
        }
    }

    func markRequestBodyCompleted(at date: Date) async {
        guard !isFinished else {
            return
        }

        flow.markRequestBodyCompleted(at: date)
        await eventSink.publish(.updated(flow))
    }

    func markUpstreamConnected(at date: Date) async {
        guard !isFinished else {
            return
        }

        if flow.state == .receivingRequest {
            try? flow.transition(to: .connectingUpstream)
        }

        flow.markUpstreamConnected(at: date)
        await eventSink.publish(.updated(flow))
    }

    func receiveResponse(_ response: HTTPResponse, at date: Date) async {
        guard !isFinished else {
            return
        }

        if flow.state == .receivingRequest {
            try? flow.transition(to: .connectingUpstream)
        }

        if flow.state == .connectingUpstream {
            try? flow.transition(to: .receivingResponse)
        }

        flow.attachResponse(response)
        flow.markResponseHeadersReceived(at: date)
        await eventSink.publish(.updated(flow))
    }

    func finishResponse(at date: Date) async {
        guard !isFinished else {
            return
        }

        flow.markResponseBodyCompleted(at: date)
        if !flow.state.isTerminal {
            try? flow.transition(to: .completed)
        }
        flow.markCompleted(at: date)
        isFinished = true
        await eventSink.publish(.finished(flow))
    }

    func fail(_ failure: FlowFailure) async {
        guard !isFinished else {
            return
        }

        try? flow.transition(to: .failed(failure))
        isFinished = true
        await eventSink.publish(.finished(flow))
    }
}
