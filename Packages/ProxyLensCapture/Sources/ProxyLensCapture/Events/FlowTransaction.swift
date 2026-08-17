import Foundation
import ProxyLensCore

actor FlowTransaction {
    private var flow: Flow
    private let eventSink: any FlowEventSink
    private var isFinished = false
    private var requestBodyIsComplete = false
    private var responseBodyIsComplete = false

    init(flow: Flow, eventSink: any FlowEventSink) {
        self.flow = flow
        self.eventSink = eventSink
    }

    func flowID() -> FlowID {
        flow.id
    }

    func currentRequest() -> HTTPRequest {
        flow.request
    }

    func currentResponse() -> HTTPResponse? {
        flow.response
    }

    func snapshot() -> Flow {
        flow
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

    func finishRequestBody(
        _ body: BodyReference?,
        graphqlOperation: GraphQLOperationMetadata? = nil,
        at date: Date
    ) async {
        guard !isFinished else {
            return
        }

        if let body {
            flow.attachRequestBody(body, graphqlOperation: graphqlOperation)
        }
        flow.markRequestBodyCompleted(at: date)
        requestBodyIsComplete = true

        if responseBodyIsComplete {
            await complete(at: date)
        } else {
            await eventSink.publish(.updated(flow))
        }
    }

    func appendRuleTraces(_ traces: [RuleTrace]) async {
        guard !isFinished, !traces.isEmpty else {
            return
        }

        flow.appendRuleTraces(traces)
        await eventSink.publish(.updated(flow))
    }

    func replaceRequest(_ request: HTTPRequest) async {
        guard !isFinished else {
            return
        }

        flow.replaceRequest(request)
        await eventSink.publish(.updated(flow))
    }

    func replaceUpstreamConnection(host: String, port: UInt16, usesTLS: Bool) async {
        guard !isFinished else {
            return
        }

        flow.replaceConnection(
            ConnectionInfo(
                protocolKind: usesTLS ? .https : .http,
                upstreamHost: host,
                upstreamPort: port,
                tlsIntercepted: flow.connection?.tlsIntercepted ?? false,
                upstreamHTTPVersion: flow.connection?.upstreamHTTPVersion,
                isUpstreamConnectionReused: flow.connection?.isUpstreamConnectionReused
            )
        )
        await eventSink.publish(.updated(flow))
    }

    func serveLocalResponse(_ response: HTTPResponse, at date: Date) async {
        guard !isFinished else {
            return
        }

        if flow.state == .created {
            try? flow.transition(to: .receivingRequest)
            flow.markRequestHeadersReceived(at: date)
        }
        if !requestBodyIsComplete {
            flow.markRequestBodyCompleted(at: date)
            requestBodyIsComplete = true
        }
        if flow.state == .receivingRequest {
            try? flow.transition(to: .receivingResponse)
        }

        flow.attachResponse(response)
        flow.markResponseHeadersReceived(at: date)
        flow.markResponseBodyCompleted(at: date)
        responseBodyIsComplete = true
        await complete(at: date)
    }

    func markUpstreamConnected(
        at date: Date,
        upstreamHTTPVersion: HTTPVersion? = nil,
        isConnectionReused: Bool? = nil
    ) async {
        guard !isFinished else {
            return
        }

        if flow.state == .receivingRequest || flow.state == .paused(.request) {
            try? flow.transition(to: .connectingUpstream)
        }

        if let connection = flow.connection,
            upstreamHTTPVersion != nil || isConnectionReused != nil
        {
            flow.replaceConnection(
                connection.replacingTransport(
                    upstreamHTTPVersion: upstreamHTTPVersion,
                    isUpstreamConnectionReused: isConnectionReused
                )
            )
        }
        flow.markUpstreamConnected(at: date)
        await eventSink.publish(.updated(flow))
    }

    func markTLSHandshakeCompleted(at date: Date) async {
        guard !isFinished else {
            return
        }

        flow.markTLSHandshakeCompleted(at: date)
        await eventSink.publish(.updated(flow))
    }

    func receiveResponse(_ response: HTTPResponse, at date: Date) async {
        guard !isFinished else {
            return
        }

        if flow.state == .receivingRequest || flow.state == .paused(.request) {
            try? flow.transition(to: .connectingUpstream)
        }

        if flow.state == .connectingUpstream {
            try? flow.transition(to: .receivingResponse)
        }

        flow.attachResponse(response)
        flow.markResponseHeadersReceived(at: date)
        await eventSink.publish(.updated(flow))
    }

    func finishResponse(_ body: BodyReference?, at date: Date) async {
        guard !isFinished else {
            return
        }

        if let body {
            flow.attachResponseBody(body)
        }
        flow.markResponseBodyCompleted(at: date)
        responseBodyIsComplete = true

        if flow.state == .paused(.response) {
            await eventSink.publish(.updated(flow))
            return
        }

        if requestBodyIsComplete {
            await complete(at: date)
        } else {
            await eventSink.publish(.updated(flow))
        }
    }

    func beginWebSocket(secure: Bool, at date: Date) async {
        guard !isFinished else {
            return
        }

        if let connection = flow.connection {
            flow.replaceConnection(
                ConnectionInfo(
                    protocolKind: secure ? .secureWebSocket : .webSocket,
                    upstreamHost: connection.upstreamHost,
                    upstreamPort: connection.upstreamPort,
                    tlsIntercepted: connection.tlsIntercepted,
                    upstreamHTTPVersion: connection.upstreamHTTPVersion,
                    isUpstreamConnectionReused: connection.isUpstreamConnectionReused
                )
            )
        }
        flow.markResponseBodyCompleted(at: date)
        responseBodyIsComplete = true
        await eventSink.publish(.updated(flow))
    }

    func finishWebSocket(at date: Date) async {
        guard !isFinished else {
            return
        }
        await complete(at: date)
    }

    func completePausedResponse(at date: Date) async {
        guard !isFinished else {
            return
        }

        responseBodyIsComplete = true
        await complete(at: date)
    }

    func pause(_ phase: BreakpointPhase) async {
        guard !isFinished else {
            return
        }

        let nextState = FlowState.paused(phase)
        guard flow.state.canTransition(to: nextState) else {
            return
        }

        try? flow.transition(to: nextState)
        await eventSink.publish(.updated(flow))
    }

    func resumeWebSocketBreakpoint() async {
        guard !isFinished, flow.state == .paused(.webSocketResponse) else {
            return
        }

        try? flow.transition(to: .receivingResponse)
        await eventSink.publish(.updated(flow))
    }

    func replaceResponse(_ response: HTTPResponse) async {
        guard !isFinished else {
            return
        }

        flow.replaceResponse(response)
        await eventSink.publish(.updated(flow))
    }

    func cancel() async {
        guard !isFinished else {
            return
        }

        try? flow.transition(to: .cancelled)
        isFinished = true
        await eventSink.publish(.finished(flow))
    }

    private func complete(at date: Date) async {
        if flow.state == .paused(.request) {
            try? flow.transition(to: .connectingUpstream)
        }
        if flow.state == .receivingRequest {
            try? flow.transition(to: .receivingResponse)
        }
        if flow.state == .connectingUpstream {
            try? flow.transition(to: .receivingResponse)
        }
        if flow.state == .paused(.response) || !flow.state.isTerminal {
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
