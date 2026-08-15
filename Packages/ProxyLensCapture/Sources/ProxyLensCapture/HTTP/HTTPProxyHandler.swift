import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOTLS
import ProxyLensCore

final class HTTPProxyHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let sessionID: SessionID
    private let eventSink: any FlowEventSink
    private let maxPendingRequestBytes: Int
    private let bodyStore: (any BodyStore)?
    private let maximumCapturedBodyBytes: Int64
    private let interceptHTTPS: Bool
    private let certificateProvider: (any CertificateProvider)?
    private let upstreamTLSContext: NIOSSLContext?
    private let tunnelTarget: ConnectTarget?
    private let ruleSnapshot: (any RuleSnapshotSource)?
    private let breakpointGate: any BreakpointGate
    private let flowSource: FlowSource

    private var requestHead: HTTPRequestHead?
    private var upstreamChannel: Channel?
    private var pendingRequestParts: [HTTPClientRequestPart] = []
    private var pendingRequestBytes = 0
    private var requestEnded = false
    private var responseEnded = false
    private var responseStarted = false
    private var transaction: FlowTransaction?
    private var pendingConnectTarget: ConnectTarget?
    private var isPreparingTLSIntercept = false
    private var requestBodyRecorder: StreamingBodyRecorder?
    private var requestBodyWriteTask: Task<Void, Error>?
    private var captureWritesInFlight = 0
    private var captureFailureHandled = false
    private var didFinishLocally = false
    private var pendingTarget: ProxyTarget?
    private var pendingForwardedHead: HTTPRequestHead?
    private var pendingRequest: HTTPRequest?
    private var pendingRequestBreakpoint = false
    fileprivate var breakpointTask: Task<Void, Never>?

    init(
        sessionID: SessionID,
        eventSink: any FlowEventSink,
        maxPendingRequestBytes: Int,
        bodyStore: (any BodyStore)? = nil,
        maximumCapturedBodyBytes: Int64 = 50 * 1_024 * 1_024,
        interceptHTTPS: Bool = false,
        certificateProvider: (any CertificateProvider)? = nil,
        upstreamTLSContext: NIOSSLContext? = nil,
        tunnelTarget: ConnectTarget? = nil,
        ruleSnapshot: (any RuleSnapshotSource)? = nil,
        breakpointGate: any BreakpointGate = ImmediateBreakpointGate(),
        flowSource: FlowSource = .desktopProxy
    ) {
        self.sessionID = sessionID
        self.eventSink = eventSink
        self.maxPendingRequestBytes = max(1, maxPendingRequestBytes)
        self.bodyStore = bodyStore
        self.maximumCapturedBodyBytes = max(0, maximumCapturedBodyBytes)
        self.interceptHTTPS = interceptHTTPS
        self.certificateProvider = certificateProvider
        self.upstreamTLSContext = upstreamTLSContext
        self.tunnelTarget = tunnelTarget
        self.ruleSnapshot = ruleSnapshot
        self.breakpointGate = breakpointGate
        self.flowSource = flowSource
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let requestPart = Self.unwrapInboundIn(data)

        switch requestPart {
        case .head(let head):
            receiveRequestHead(head, context: context)
        case .body(var buffer):
            receiveRequestBody(&buffer, context: context)
        case .end(let trailers):
            receiveRequestEnd(trailers, context: context)
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        guard let transaction else {
            return
        }

        let upstreamChannel = self.upstreamChannel
        if responseEnded || didFinishLocally {
            upstreamChannel?.close(promise: nil)
            return
        }
        breakpointTask?.cancel()
        let requestBodyRecorder = self.requestBodyRecorder
        Task {
            await requestBodyRecorder?.cancel()
            await transaction.fail(.clientDisconnected)
            upstreamChannel?.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if didFinishLocally {
            context.close(promise: nil)
            return
        }

        let upstreamChannel = self.upstreamChannel
        let requestBodyRecorder = self.requestBodyRecorder
        breakpointTask?.cancel()
        if let transaction {
            Task {
                await requestBodyRecorder?.cancel()
                await transaction.fail(.protocolError(error.localizedDescription))
                upstreamChannel?.close(promise: nil)
            }
        }

        context.close(promise: nil)
    }

    private func receiveRequestHead(_ head: HTTPRequestHead, context: ChannelHandlerContext) {
        guard requestHead == nil else {
            sendError(
                statusCode: 400,
                reason: "Bad Request",
                message: "Multiple requests per connection are not supported yet.",
                context: context
            )
            return
        }

        guard head.version.major == 1, head.version.minor == 0 || head.version.minor == 1 else {
            sendError(
                statusCode: 505,
                reason: "HTTP Version Not Supported",
                message: "ProxyLens currently supports HTTP/1.0 and HTTP/1.1.",
                context: context
            )
            return
        }

        if head.method == .CONNECT {
            receiveConnectHead(head, context: context)
            return
        }

        let originalTarget: ProxyTarget
        do {
            originalTarget = try ProxyTarget(
                uri: head.uri,
                headers: head.headers,
                tunnelTarget: tunnelTarget
            )
        } catch {
            sendError(
                statusCode: 400, reason: "Bad Request", message: error.localizedDescription,
                context: context)
            return
        }

        let coreHeaders: ProxyLensCore.HTTPHeaders
        let coreVersion: ProxyLensCore.HTTPVersion
        do {
            coreHeaders = try HTTPConversion.coreHeaders(from: head.headers)
            coreVersion = try HTTPConversion.coreVersion(from: head.version)
        } catch {
            sendError(
                statusCode: 400, reason: "Bad Request", message: error.localizedDescription,
                context: context)
            return
        }

        var request = HTTPRequest(
            method: ProxyLensCore.HTTPMethod(rawValue: head.method.rawValue),
            url: originalTarget.url,
            headers: coreHeaders,
            version: coreVersion,
            rawTarget: head.uri
        )
        let requestPlan = RulePlanner.plan(
            rules: ruleSnapshot?.currentRules() ?? RuleSet(),
            context: RuleMatchContext(request: request, source: flowSource),
            phase: .requestHeaders
        )
        if requestPlan.applyNoCache {
            do {
                request = request.replacingHeaders(
                    try NoCacheHeaders.applyingToRequest(request.headers)
                )
            } catch {
                sendError(
                    statusCode: 500,
                    reason: "Internal Server Error",
                    message: error.localizedDescription,
                    context: context
                )
                return
            }
        }

        var target = originalTarget
        var mappedHostHeader: String?
        if !requestPlan.shouldBlock,
            requestPlan.mapLocalResourceID == nil,
            let destination = requestPlan.mapRemoteURL
        {
            do {
                let mapped = try MappedRemoteHTTPRequest.make(
                    originalURL: originalTarget.url,
                    destination: destination
                )
                target = ProxyTarget(mapped)
                mappedHostHeader = mapped.hostHeader
            } catch {
                sendError(
                    statusCode: 500,
                    reason: "Internal Server Error",
                    message: error.localizedDescription,
                    context: context
                )
                return
            }
        }

        let connection = ConnectionInfo(
            protocolKind: target.usesTLS ? .https : .http,
            upstreamHost: target.host,
            upstreamPort: UInt16(target.port),
            tlsIntercepted: originalTarget.usesTLS
        )
        let flow = Flow(
            sessionID: sessionID,
            source: flowSource,
            request: request,
            connection: connection
        )
        let transaction = FlowTransaction(flow: flow, eventSink: eventSink)
        if let bodyStore {
            requestBodyRecorder = StreamingBodyRecorder(
                bodyStore: bodyStore,
                metadata: BodyMetadata(
                    contentType: request.headers.firstValue(for: "Content-Type"),
                    contentEncoding: request.headers.firstValue(for: "Content-Encoding")
                ),
                maximumByteCount: maximumCapturedBodyBytes
            )
        }

        self.requestHead = head
        self.transaction = transaction
        self.pendingTarget = target
        self.pendingRequest = request

        if requestPlan.shouldBlock {
            let blockedResponse: HTTPResponse
            do {
                blockedResponse = try BlockedHTTPResponse.make(
                    reason: requestPlan.blockReason,
                    version: coreVersion
                )
            } catch {
                sendError(
                    statusCode: 500,
                    reason: "Internal Server Error",
                    message: error.localizedDescription,
                    context: context
                )
                return
            }

            finishWithLocalResponse(
                blockedResponse,
                traces: requestPlan.traces,
                transaction: transaction,
                channel: context.channel
            )
            return
        }

        if let resourceID = requestPlan.mapLocalResourceID {
            let mappedResponse: HTTPResponse
            do {
                let spec = try unwrapMappedLocalSpec(resourceID)
                var response = try MappedLocalHTTPResponse.make(spec: spec, version: coreVersion)
                if requestPlan.applyNoCache {
                    response = response.replacingHeaders(
                        try NoCacheHeaders.applyingToResponse(response.headers)
                    )
                }
                mappedResponse = response
            } catch {
                sendError(
                    statusCode: 500,
                    reason: "Internal Server Error",
                    message: error.localizedDescription,
                    context: context
                )
                return
            }

            finishWithLocalResponse(
                mappedResponse,
                traces: requestPlan.traces,
                transaction: transaction,
                channel: context.channel
            )
            return
        }

        Task {
            await transaction.start(at: Date())
            await transaction.appendRuleTraces(requestPlan.traces)
        }

        var forwardedHeaders: NIOHTTP1.HTTPHeaders
        if requestPlan.applyNoCache {
            forwardedHeaders = HTTPConversion.sanitizedRequestHeaders(
                HTTPConversion.nioHeaders(from: request.headers)
            )
        } else {
            forwardedHeaders = HTTPConversion.sanitizedRequestHeaders(head.headers)
        }
        if let mappedHostHeader {
            forwardedHeaders.remove(name: "Host")
            forwardedHeaders.add(name: "Host", value: mappedHostHeader)
        }
        let forwardedHead = HTTPRequestHead(
            version: head.version,
            method: head.method,
            uri: target.originForm,
            headers: forwardedHeaders
        )
        pendingForwardedHead = forwardedHead

        if requestPlan.shouldBreakpoint {
            pendingRequestBreakpoint = true
            return
        }

        connectUpstream(
            target: target,
            requestHead: forwardedHead,
            request: request,
            clientChannel: context.channel,
            transaction: transaction
        )
    }

    private func receiveConnectHead(_ head: HTTPRequestHead, context: ChannelHandlerContext) {
        guard tunnelTarget == nil else {
            sendError(
                statusCode: 400,
                reason: "Bad Request",
                message: "Nested CONNECT requests are not supported.",
                context: context
            )
            return
        }

        guard interceptHTTPS else {
            sendError(
                statusCode: 501,
                reason: "Not Implemented",
                message: "HTTPS interception is disabled for this proxy listener.",
                context: context
            )
            return
        }

        guard certificateProvider != nil, upstreamTLSContext != nil else {
            sendError(
                statusCode: 503,
                reason: "Service Unavailable",
                message: "HTTPS interception is not configured.",
                context: context
            )
            return
        }

        do {
            let target = try ConnectTarget(authority: head.uri)
            requestHead = head
            pendingConnectTarget = target
        } catch {
            sendError(
                statusCode: 400,
                reason: "Bad Request",
                message: error.localizedDescription,
                context: context
            )
        }
    }

    private func beginTLSIntercept(target: ConnectTarget, context: ChannelHandlerContext) {
        guard !isPreparingTLSIntercept, let certificateProvider, let upstreamTLSContext else {
            return
        }
        isPreparingTLSIntercept = true

        let channel = context.channel
        channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in
            channel.close(promise: nil)
        }

        let loopBoundSelf = NIOLoopBound(self, eventLoop: channel.eventLoop)
        Task {
            do {
                let identity = try await certificateProvider.leafCertificate(for: target.host)
                let serverTLSContext = try TLSContextFactory.serverContext(identity: identity)
                channel.eventLoop.execute {
                    loopBoundSelf.value.finishTLSIntercept(
                        target: target,
                        serverTLSContext: serverTLSContext,
                        upstreamTLSContext: upstreamTLSContext,
                        channel: channel
                    )
                }
            } catch {
                let message = error.localizedDescription
                channel.eventLoop.execute {
                    loopBoundSelf.value.failTLSIntercept(message: message, channel: channel)
                }
            }
        }
    }

    private func finishTLSIntercept(
        target: ConnectTarget,
        serverTLSContext: NIOSSLContext,
        upstreamTLSContext: NIOSSLContext,
        channel: Channel
    ) {
        let response = HTTPResponseHead(
            version: .http1_1,
            status: .ok,
            headers: NIOHTTP1.HTTPHeaders()
        )
        channel.write(HTTPServerResponsePart.head(response), promise: nil)
        let sessionID = self.sessionID
        let eventSink = self.eventSink
        let maxPendingRequestBytes = self.maxPendingRequestBytes
        let bodyStore = self.bodyStore
        let maximumCapturedBodyBytes = self.maximumCapturedBodyBytes
        let certificateProvider = self.certificateProvider
        let ruleSnapshot = self.ruleSnapshot
        let breakpointGate = self.breakpointGate
        let flowSource = self.flowSource
        channel.writeAndFlush(HTTPServerResponsePart.end(nil)).flatMap {
            HTTPServerPipeline.removePlaintextHTTPHandlers(from: channel)
        }.flatMapThrowing {
            let tlsHandler = NIOSSLServerHandler(context: serverTLSContext)
            try channel.pipeline.syncOperations.addHandler(
                tlsHandler,
                name: HTTPServerPipeline.tlsHandlerName
            )
            try HTTPServerPipeline.install(
                on: channel,
                handler: HTTPProxyHandler(
                    sessionID: sessionID,
                    eventSink: eventSink,
                    maxPendingRequestBytes: maxPendingRequestBytes,
                    bodyStore: bodyStore,
                    maximumCapturedBodyBytes: maximumCapturedBodyBytes,
                    interceptHTTPS: false,
                    certificateProvider: certificateProvider,
                    upstreamTLSContext: upstreamTLSContext,
                    tunnelTarget: target,
                    ruleSnapshot: ruleSnapshot,
                    breakpointGate: breakpointGate,
                    flowSource: flowSource
                )
            )
        }.flatMap {
            channel.setOption(ChannelOptions.autoRead, value: true)
        }.whenFailure { _ in
            channel.close(promise: nil)
        }
    }

    private func failTLSIntercept(message: String, channel: Channel) {
        sendError(
            statusCode: 500,
            reason: "Internal Server Error",
            message: "TLS interception setup failed: \(message)",
            channel: channel
        )
    }

    private func receiveRequestBody(_ buffer: inout ByteBuffer, context: ChannelHandlerContext) {
        if didFinishLocally {
            return
        }

        let byteCount = buffer.readableBytes

        if pendingConnectTarget != nil {
            if byteCount > 0 {
                sendError(
                    statusCode: 400,
                    reason: "Bad Request",
                    message: "CONNECT requests cannot contain a body.",
                    context: context
                )
            }
            return
        }
        recordRequestBody(buffer, context: context)

        if let upstreamChannel {
            upstreamChannel.write(
                HTTPClientRequestPart.body(.byteBuffer(buffer)),
                promise: nil
            )
            return
        }

        guard pendingRequestBytes + byteCount <= maxPendingRequestBytes else {
            sendError(
                statusCode: 413,
                reason: "Payload Too Large",
                message:
                    "The upstream connection was not ready before the request buffer limit was reached.",
                context: context
            )
            return
        }

        pendingRequestBytes += byteCount
        pendingRequestParts.append(.body(.byteBuffer(buffer)))
    }

    private func receiveRequestEnd(
        _ trailers: NIOHTTP1.HTTPHeaders?,
        context: ChannelHandlerContext
    ) {
        if let target = pendingConnectTarget {
            beginTLSIntercept(target: target, context: context)
            return
        }
        if didFinishLocally {
            return
        }

        requestEnded = true
        if pendingRequestBreakpoint {
            pendingRequestParts.append(HTTPClientRequestPart.end(trailers))
            beginRequestBreakpoint(channel: context.channel)
            return
        }

        finishRequestBodyCapture(context: context)

        let endPart = HTTPClientRequestPart.end(trailers)
        if let upstreamChannel {
            upstreamChannel.writeAndFlush(endPart, promise: nil)
        } else {
            pendingRequestParts.append(endPart)
        }

        if upstreamChannel == nil, requestHead == nil {
            context.close(promise: nil)
        }
    }

    private func recordRequestBody(_ buffer: ByteBuffer, context: ChannelHandlerContext) {
        guard buffer.readableBytes > 0, let requestBodyRecorder else {
            return
        }

        let data = Data(buffer.readableBytesView)
        let previousTask = requestBodyWriteTask
        let writeTask = Task<Void, Error> {
            try await previousTask?.value
            try await requestBodyRecorder.append(data)
        }
        requestBodyWriteTask = writeTask
        captureWritesInFlight += 1

        let channel = context.channel
        if captureWritesInFlight == 1 {
            channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in
                channel.close(promise: nil)
            }
        }

        let loopBoundSelf = NIOLoopBound(self, eventLoop: channel.eventLoop)
        Task {
            let result = await writeTask.result
            channel.eventLoop.execute {
                loopBoundSelf.value.completeRequestBodyWrite(result, channel: channel)
            }
        }
    }

    private func completeRequestBodyWrite(
        _ result: Result<Void, Error>,
        channel: Channel
    ) {
        captureWritesInFlight = max(0, captureWritesInFlight - 1)
        if case .failure(let error) = result, !captureFailureHandled {
            captureFailureHandled = true
            let transaction = self.transaction
            let requestBodyRecorder = self.requestBodyRecorder
            let upstreamChannel = self.upstreamChannel
            Task {
                await requestBodyRecorder?.cancel()
                await transaction?.fail(.persistenceError(error.localizedDescription))
            }
            upstreamChannel?.close(promise: nil)
            channel.close(promise: nil)
            return
        }

        if captureWritesInFlight == 0, !captureFailureHandled {
            channel.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in
                channel.close(promise: nil)
            }
        }
    }

    private func finishRequestBodyCapture(context: ChannelHandlerContext) {
        guard let transaction else {
            return
        }

        let writeTask = requestBodyWriteTask
        let recorder = requestBodyRecorder
        let channel = context.channel
        let upstreamChannel = self.upstreamChannel
        let completedAt = Date()
        Task {
            do {
                try await writeTask?.value
                let reference = try await recorder?.finalize()
                await transaction.finishRequestBody(reference, at: completedAt)
            } catch {
                await recorder?.cancel()
                await transaction.fail(.persistenceError(error.localizedDescription))
                upstreamChannel?.close(promise: nil)
                channel.close(promise: nil)
            }
        }
    }

    private func beginRequestBreakpoint(channel: Channel) {
        guard let transaction, let originalRequest = pendingRequest else {
            return
        }

        let writeTask = requestBodyWriteTask
        let recorder = requestBodyRecorder
        let gate = breakpointGate
        let loopBoundSelf = NIOLoopBound(self, eventLoop: channel.eventLoop)
        let completedAt = Date()
        breakpointTask = Task {
            do {
                try await writeTask?.value
                let reference = try await recorder?.finalize()
                var pausedRequest = originalRequest
                if let reference {
                    pausedRequest = pausedRequest.replacingBody(reference)
                }
                await transaction.finishRequestBody(reference, at: completedAt)
                await transaction.replaceRequest(pausedRequest)
                await transaction.pause(.request)
                let hit = BreakpointHit(
                    flowID: await transaction.flowID(),
                    phase: .request,
                    request: pausedRequest
                )
                let decision = await gate.pause(hit)
                let capturedRequest = pausedRequest
                channel.eventLoop.execute {
                    loopBoundSelf.value.applyRequestBreakpointDecision(
                        decision,
                        capturedRequest: capturedRequest,
                        channel: channel
                    )
                }
            } catch {
                await recorder?.cancel()
                await transaction.fail(.persistenceError(error.localizedDescription))
                channel.close(promise: nil)
            }
        }
    }

    private func applyRequestBreakpointDecision(
        _ decision: BreakpointDecision,
        capturedRequest: HTTPRequest,
        channel: Channel
    ) {
        guard channel.isActive else {
            return
        }

        switch decision {
        case .abort:
            abortBreakpoint(channel: channel)
        case .continue(let hit):
            pendingRequestBreakpoint = false
            pendingRequest = capturedRequest
            let continued = hit.request
            if continued != capturedRequest {
                let transaction = self.transaction
                Task { [transaction] in
                    await transaction?.replaceRequest(continued)
                }
                do {
                    try applyEditedRequest(continued, captured: capturedRequest, channel: channel)
                } catch {
                    sendError(
                        statusCode: 400,
                        reason: "Bad Request",
                        message: error.localizedDescription,
                        channel: channel
                    )
                    let transaction = self.transaction
                    Task { [transaction] in
                        await transaction?.fail(.protocolError(error.localizedDescription))
                    }
                    return
                }
            }

            guard let target = pendingTarget,
                let requestHead = pendingForwardedHead,
                let request = pendingRequest,
                let transaction
            else {
                abortBreakpoint(channel: channel)
                return
            }

            connectUpstream(
                target: target,
                requestHead: requestHead,
                request: request,
                clientChannel: channel,
                transaction: transaction
            )
        }
    }

    private func applyEditedRequest(
        _ request: HTTPRequest,
        captured: HTTPRequest,
        channel: Channel
    ) throws {
        pendingRequest = request
        if request.url != captured.url {
            let target = try ProxyTarget(url: request.url)
            pendingTarget = target
            var headers = HTTPConversion.sanitizedRequestHeaders(
                HTTPConversion.nioHeaders(from: request.headers)
            )
            headers.remove(name: "Host")
            headers.add(name: "Host", value: target.hostHeader)
            pendingForwardedHead = HTTPRequestHead(
                version: request.version == .http10 ? .http1_0 : .http1_1,
                method: NIOHTTP1.HTTPMethod(rawValue: request.method.rawValue),
                uri: target.originForm,
                headers: headers
            )
        } else if request.method != captured.method
            || request.headers != captured.headers
        {
            var headers = HTTPConversion.sanitizedRequestHeaders(
                HTTPConversion.nioHeaders(from: request.headers)
            )
            if let target = pendingTarget {
                headers.remove(name: "Host")
                headers.add(name: "Host", value: target.hostHeader)
            }
            let originForm = pendingForwardedHead?.uri ?? pendingTarget?.originForm ?? "/"
            pendingForwardedHead = HTTPRequestHead(
                version: request.version == .http10 ? .http1_0 : .http1_1,
                method: NIOHTTP1.HTTPMethod(rawValue: request.method.rawValue),
                uri: originForm,
                headers: headers
            )
        }

        if request.body?.id != captured.body?.id {
            pendingRequestParts = []
            pendingRequestBytes = 0
            if let data = request.body?.inlineData, !data.isEmpty {
                var buffer = channel.allocator.buffer(capacity: data.count)
                buffer.writeBytes(data)
                pendingRequestParts.append(.body(.byteBuffer(buffer)))
                pendingRequestBytes = data.count
            }
            pendingRequestParts.append(.end(nil))
        }
    }

    fileprivate func abortBreakpoint(channel: Channel) {
        didFinishLocally = true
        responseEnded = true
        pendingRequestBreakpoint = false
        breakpointTask = nil
        let transaction = self.transaction
        Task { [transaction] in
            await transaction?.cancel()
        }
        sendError(
            statusCode: 403,
            reason: "Forbidden",
            message: "Aborted at breakpoint",
            channel: channel
        )
    }

    fileprivate func markResponseEnded() {
        responseEnded = true
    }

    private func connectUpstream(
        target: ProxyTarget,
        requestHead: HTTPRequestHead,
        request: HTTPRequest,
        clientChannel: Channel,
        transaction: FlowTransaction
    ) {
        let bodyStore = self.bodyStore
        let maximumCapturedBodyBytes = self.maximumCapturedBodyBytes
        let ruleSnapshot = self.ruleSnapshot
        let breakpointGate = self.breakpointGate
        let flowSource = self.flowSource
        let loopBoundSelf = NIOLoopBound(self, eventLoop: clientChannel.eventLoop)
        let bootstrap = ClientBootstrap(group: clientChannel.eventLoop)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer {
                [
                    upstreamTLSContext, bodyStore, maximumCapturedBodyBytes, loopBoundSelf,
                    request, ruleSnapshot, breakpointGate, flowSource
                ] channel in
                let tlsFuture: EventLoopFuture<Void>
                if target.usesTLS {
                    do {
                        guard let upstreamTLSContext else {
                            throw TLSInterceptionError.missingUpstreamTLSContext
                        }
                        let tlsHandler = try NIOSSLClientHandler(
                            context: upstreamTLSContext,
                            serverHostname: target.host
                        )
                        try channel.pipeline.syncOperations.addHandler(tlsHandler)
                        tlsFuture = channel.eventLoop.makeSucceededVoidFuture()
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                } else {
                    tlsFuture = channel.eventLoop.makeSucceededVoidFuture()
                }

                return tlsFuture.flatMap {
                    channel.pipeline.addHTTPClientHandlers()
                }.flatMapThrowing {
                    try channel.pipeline.syncOperations.addHandler(
                        UpstreamResponseHandler(
                            clientChannel: clientChannel,
                            clientHandler: loopBoundSelf,
                            transaction: transaction,
                            request: request,
                            usesTLS: target.usesTLS,
                            bodyStore: bodyStore,
                            maximumCapturedBodyBytes: maximumCapturedBodyBytes,
                            ruleSnapshot: ruleSnapshot,
                            breakpointGate: breakpointGate,
                            flowSource: flowSource
                        )
                    )
                }
            }

        bootstrap.connect(host: target.host, port: target.port).whenComplete {
            [loopBoundSelf] (result: Result<Channel, Error>) in
            clientChannel.eventLoop.execute {
                let handler = loopBoundSelf.value

                switch result {
                case .success(let channel):
                    handler.upstreamChannel = channel
                    if let transaction = handler.transaction {
                        Task { [transaction] in
                            await transaction.markUpstreamConnected(at: Date())
                        }
                    }

                    channel.write(HTTPClientRequestPart.head(requestHead), promise: nil)
                    for part in handler.pendingRequestParts {
                        channel.write(part, promise: nil)
                    }
                    handler.pendingRequestParts.removeAll(keepingCapacity: false)
                    handler.pendingRequestBytes = 0

                    if handler.requestEnded {
                        channel.flush()
                    }
                case .failure(let error):
                    handler.handleUpstreamFailure(error, clientChannel: clientChannel)
                }
            }
        }
    }

    private func handleUpstreamFailure(_ error: Error, clientChannel: Channel) {
        if let transaction {
            Task {
                await transaction.fail(.upstreamUnavailable)
            }
        }

        sendError(
            statusCode: 502,
            reason: "Bad Gateway",
            message: "The upstream server could not be reached: \(error.localizedDescription)",
            channel: clientChannel
        )
    }

    private func finishWithLocalResponse(
        _ response: HTTPResponse,
        traces: [RuleTrace],
        transaction: FlowTransaction,
        channel: Channel
    ) {
        didFinishLocally = true
        responseEnded = true
        Task {
            await transaction.start(at: Date())
            await transaction.appendRuleTraces(traces)
            await transaction.serveLocalResponse(response, at: Date())
        }
        sendLocalResponse(response, channel: channel)
    }

    private func unwrapMappedLocalSpec(_ resourceID: String) throws -> MapLocalSpec {
        guard let spec = ruleSnapshot?.mappedLocal(for: resourceID) else {
            throw ProxyLensError.unsupportedOperation(
                "Mapped local resource is unavailable: \(resourceID)"
            )
        }
        return spec
    }

    fileprivate func sendLocalResponse(_ response: HTTPResponse, channel: Channel) {
        let headers = HTTPConversion.nioHeaders(from: response.headers)
        let status = HTTPResponseStatus(statusCode: response.statusCode)
        let head = HTTPResponseHead(
            version: response.version == .http10 ? .http1_0 : .http1_1,
            status: HTTPResponseStatus(
                statusCode: response.statusCode,
                reasonPhrase: response.reasonPhrase ?? status.reasonPhrase
            ),
            headers: headers
        )
        channel.write(HTTPServerResponsePart.head(head), promise: nil)
        if case .inline(let data) = response.body?.storage, !data.isEmpty {
            var body = channel.allocator.buffer(capacity: data.count)
            body.writeBytes(data)
            channel.write(HTTPServerResponsePart.body(.byteBuffer(body)), promise: nil)
        }
        channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
            channel.close(promise: nil)
        }
    }

    private func sendError(
        statusCode: Int,
        reason: String,
        message: String,
        context: ChannelHandlerContext
    ) {
        sendError(
            statusCode: statusCode, reason: reason, message: message, channel: context.channel)
    }

    private func sendError(statusCode: Int, reason: String, message: String, channel: Channel) {
        var body = channel.allocator.buffer(capacity: message.utf8.count + 2)
        body.writeString(message)
        body.writeString("\r\n")

        var headers = NIOHTTP1.HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(body.readableBytes)")
        headers.add(name: "Connection", value: "close")

        let head = HTTPResponseHead(
            version: .http1_1,
            status: HTTPResponseStatus(statusCode: statusCode, reasonPhrase: reason),
            headers: headers
        )

        channel.write(HTTPServerResponsePart.head(head), promise: nil)
        channel.write(HTTPServerResponsePart.body(.byteBuffer(body)), promise: nil)
        channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
            channel.close(promise: nil)
        }
    }
}

final class UpstreamResponseHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let clientChannel: Channel
    private let clientHandler: NIOLoopBound<HTTPProxyHandler>
    private let transaction: FlowTransaction
    private let request: HTTPRequest
    private let usesTLS: Bool
    private let bodyStore: (any BodyStore)?
    private let maximumCapturedBodyBytes: Int64
    private let ruleSnapshot: (any RuleSnapshotSource)?
    private let breakpointGate: any BreakpointGate
    private let flowSource: FlowSource
    private var responseStarted = false
    private var responseBodyRecorder: StreamingBodyRecorder?
    private var responseHeadTask: Task<Void, Never>?
    private var responseBodyWriteTask: Task<Void, Error>?
    private var captureWritesInFlight = 0
    private var captureFailureHandled = false
    private var pendingResponseBreakpoint = false
    private var pendingResponse: HTTPResponse?
    private var pendingResponseHead: HTTPResponseHead?
    private var pendingResponseBuffers: [ByteBuffer] = []
    private var pendingResponseBytes = 0
    private var pendingResponseTrailers: NIOHTTP1.HTTPHeaders?
    private var breakpointTask: Task<Void, Never>?
    private var didHandleUpstreamFailure = false

    private var isWaitingOnCompleteResponseBreakpoint: Bool {
        pendingResponseBreakpoint && breakpointTask != nil
    }

    init(
        clientChannel: Channel,
        clientHandler: NIOLoopBound<HTTPProxyHandler>,
        transaction: FlowTransaction,
        request: HTTPRequest,
        usesTLS: Bool,
        bodyStore: (any BodyStore)?,
        maximumCapturedBodyBytes: Int64,
        ruleSnapshot: (any RuleSnapshotSource)?,
        breakpointGate: any BreakpointGate,
        flowSource: FlowSource
    ) {
        self.clientChannel = clientChannel
        self.clientHandler = clientHandler
        self.transaction = transaction
        self.request = request
        self.usesTLS = usesTLS
        self.bodyStore = bodyStore
        self.maximumCapturedBodyBytes = max(0, maximumCapturedBodyBytes)
        self.ruleSnapshot = ruleSnapshot
        self.breakpointGate = breakpointGate
        self.flowSource = flowSource
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let responsePart = Self.unwrapInboundIn(data)

        switch responsePart {
        case .head(let head):
            responseStarted = true
            do {
                let coreHeaders = try HTTPConversion.coreHeaders(from: head.headers)
                var response = try HTTPResponse(
                    statusCode: Int(head.status.code),
                    reasonPhrase: head.status.reasonPhrase,
                    headers: coreHeaders,
                    version: HTTPConversion.coreVersion(from: head.version)
                )
                let responsePlan = RulePlanner.plan(
                    rules: ruleSnapshot?.currentRules() ?? RuleSet(),
                    context: RuleMatchContext(
                        request: request,
                        response: response,
                        source: flowSource
                    ),
                    phase: .responseHeaders
                )
                if responsePlan.applyNoCache {
                    response = response.replacingHeaders(
                        try NoCacheHeaders.applyingToResponse(response.headers)
                    )
                }
                if let bodyStore {
                    responseBodyRecorder = StreamingBodyRecorder(
                        bodyStore: bodyStore,
                        metadata: BodyMetadata(
                            contentType: response.headers.firstValue(for: "Content-Type"),
                            contentEncoding: response.headers.firstValue(for: "Content-Encoding")
                        ),
                        maximumByteCount: maximumCapturedBodyBytes
                    )
                }
                let transaction = self.transaction
                let receivedAt = Date()
                let traces = responsePlan.traces
                let capturedResponse = response
                responseHeadTask = Task { [transaction] in
                    await transaction.appendRuleTraces(traces)
                    await transaction.receiveResponse(capturedResponse, at: receivedAt)
                }
                var forwardedHead = head
                if responsePlan.applyNoCache {
                    forwardedHead.headers = HTTPConversion.nioHeaders(from: response.headers)
                }
                if responsePlan.shouldBreakpoint {
                    pendingResponseBreakpoint = true
                    pendingResponse = capturedResponse
                    pendingResponseHead = HTTPConversion.sanitizedResponseHead(forwardedHead)
                } else {
                    clientChannel.write(
                        HTTPServerResponsePart.head(
                            HTTPConversion.sanitizedResponseHead(forwardedHead)),
                        promise: nil
                    )
                }
            } catch {
                let transaction = self.transaction
                let message = error.localizedDescription
                Task { [transaction, message] in
                    await transaction.fail(.protocolError(message))
                }
                clientChannel.close(promise: nil)
                context.close(promise: nil)
                return
            }
        case .body(let buffer):
            recordResponseBody(buffer, context: context)
            if pendingResponseBreakpoint {
                let byteCount = buffer.readableBytes
                if pendingResponseBytes + byteCount > maximumCapturedBodyBytes {
                    captureFailureHandled = true
                    let transaction = self.transaction
                    Task {
                        await transaction.fail(
                            .protocolError("The paused response exceeded the capture limit")
                        )
                    }
                    clientChannel.close(promise: nil)
                    context.close(promise: nil)
                    return
                }
                pendingResponseBytes += byteCount
                pendingResponseBuffers.append(buffer)
            } else {
                clientChannel.write(
                    HTTPServerResponsePart.body(.byteBuffer(buffer)),
                    promise: nil
                )
            }
        case .end(let trailers):
            if pendingResponseBreakpoint {
                pendingResponseTrailers = trailers
                beginResponseBreakpoint(context: context)
                return
            }
            clientHandler.value.markResponseEnded()
            finishResponseBodyCapture(context: context)
            let forwardedTrailers = HTTPConversion.sanitizedTrailers(trailers)
            clientChannel.writeAndFlush(HTTPServerResponsePart.end(forwardedTrailers)).whenComplete
            {
                [clientChannel] _ in
                clientChannel.close(promise: nil)
            }
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if isWaitingOnCompleteResponseBreakpoint {
            context.fireChannelInactive()
            return
        }

        breakpointTask?.cancel()
        if pendingResponseBreakpoint {
            failUpstream(
                error: nil,
                context: context
            )
        }
        context.fireChannelInactive()
    }

    private func beginResponseBreakpoint(context: ChannelHandlerContext) {
        let writeTask = responseBodyWriteTask
        let headTask = responseHeadTask
        let recorder = responseBodyRecorder
        let transaction = self.transaction
        let gate = breakpointGate
        let request = self.request
        let pendingResponse = self.pendingResponse
        let loopBoundSelf = NIOLoopBound(self, eventLoop: context.eventLoop)
        let upstreamChannel = context.channel
        let clientChannel = self.clientChannel
        let clientHandler = self.clientHandler
        let completedAt = Date()
        let task = Task {
            await headTask?.value
            do {
                try await writeTask?.value
                let reference = try await recorder?.finalize()
                var pausedResponse = pendingResponse
                if let reference {
                    pausedResponse = pausedResponse?.replacingBody(reference)
                }
                if let pausedResponse {
                    await transaction.replaceResponse(pausedResponse)
                }
                await transaction.pause(.response)
                await transaction.finishResponse(reference, at: completedAt)
                let hit = BreakpointHit(
                    flowID: await transaction.flowID(),
                    phase: .response,
                    request: request,
                    response: pausedResponse ?? pendingResponse
                )
                let decision = await gate.pause(hit)
                let capturedResponse = pausedResponse
                upstreamChannel.eventLoop.execute {
                    loopBoundSelf.value.applyResponseBreakpointDecision(
                        decision,
                        capturedResponse: capturedResponse,
                        upstreamChannel: upstreamChannel
                    )
                }
            } catch {
                await recorder?.cancel()
                await transaction.fail(.persistenceError(error.localizedDescription))
                clientChannel.close(promise: nil)
                upstreamChannel.close(promise: nil)
            }
        }
        breakpointTask = task
        clientHandler.value.breakpointTask = task
    }

    private func applyResponseBreakpointDecision(
        _ decision: BreakpointDecision,
        capturedResponse: HTTPResponse?,
        upstreamChannel: Channel
    ) {
        guard clientChannel.isActive else {
            upstreamChannel.close(promise: nil)
            return
        }

        switch decision {
        case .abort:
            clientHandler.value.abortBreakpoint(channel: clientChannel)
            upstreamChannel.close(promise: nil)
        case .continue(let hit):
            let continued = hit.response ?? capturedResponse
            if let continued, continued != capturedResponse {
                let transaction = self.transaction
                Task { [transaction] in
                    await transaction.replaceResponse(continued)
                    await transaction.completePausedResponse(at: Date())
                }
                clientHandler.value.markResponseEnded()
                clientHandler.value.sendLocalResponse(continued, channel: clientChannel)
                upstreamChannel.close(promise: nil)
                return
            }

            replayBufferedResponse(upstreamChannel: upstreamChannel)
        }
    }

    private func replayBufferedResponse(upstreamChannel: Channel) {
        clientHandler.value.markResponseEnded()
        if let head = pendingResponseHead {
            clientChannel.write(HTTPServerResponsePart.head(head), promise: nil)
        }
        for buffer in pendingResponseBuffers {
            clientChannel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
        }
        let trailers = HTTPConversion.sanitizedTrailers(pendingResponseTrailers)
        clientChannel.writeAndFlush(HTTPServerResponsePart.end(trailers)).whenComplete {
            [clientChannel] _ in
            clientChannel.close(promise: nil)
        }
        let transaction = self.transaction
        Task { [transaction] in
            await transaction.completePausedResponse(at: Date())
        }
        upstreamChannel.close(promise: nil)
    }

    private func recordResponseBody(_ buffer: ByteBuffer, context: ChannelHandlerContext) {
        guard buffer.readableBytes > 0, let responseBodyRecorder else {
            return
        }

        let data = Data(buffer.readableBytesView)
        let previousTask = responseBodyWriteTask
        let writeTask = Task<Void, Error> {
            try await previousTask?.value
            try await responseBodyRecorder.append(data)
        }
        responseBodyWriteTask = writeTask
        captureWritesInFlight += 1

        let channel = context.channel
        if captureWritesInFlight == 1 {
            channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in
                channel.close(promise: nil)
            }
        }

        let loopBoundSelf = NIOLoopBound(self, eventLoop: channel.eventLoop)
        Task {
            let result = await writeTask.result
            channel.eventLoop.execute {
                loopBoundSelf.value.completeResponseBodyWrite(result, channel: channel)
            }
        }
    }

    private func completeResponseBodyWrite(
        _ result: Result<Void, Error>,
        channel: Channel
    ) {
        captureWritesInFlight = max(0, captureWritesInFlight - 1)
        if case .failure(let error) = result, !captureFailureHandled {
            captureFailureHandled = true
            let transaction = self.transaction
            let responseBodyRecorder = self.responseBodyRecorder
            Task {
                await responseBodyRecorder?.cancel()
                await transaction.fail(.persistenceError(error.localizedDescription))
            }
            clientChannel.close(promise: nil)
            channel.close(promise: nil)
            return
        }

        if captureWritesInFlight == 0, !captureFailureHandled {
            channel.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in
                channel.close(promise: nil)
            }
        }
    }

    private func finishResponseBodyCapture(context: ChannelHandlerContext) {
        let writeTask = responseBodyWriteTask
        let headTask = responseHeadTask
        let recorder = responseBodyRecorder
        let transaction = self.transaction
        let completedAt = Date()
        let upstreamChannel = context.channel
        let clientChannel = self.clientChannel
        Task {
            await headTask?.value
            do {
                try await writeTask?.value
                let reference = try await recorder?.finalize()
                await transaction.finishResponse(reference, at: completedAt)
            } catch {
                await recorder?.cancel()
                await transaction.fail(.persistenceError(error.localizedDescription))
                clientChannel.close(promise: nil)
                upstreamChannel.close(promise: nil)
            }
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        clientChannel.flush()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tlsEvent = event as? TLSUserEvent, case .handshakeCompleted = tlsEvent {
            let transaction = self.transaction
            Task { [transaction] in
                await transaction.markTLSHandshakeCompleted(at: Date())
            }
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if isWaitingOnCompleteResponseBreakpoint {
            return
        }
        failUpstream(error: error, context: context)
    }

    private func failUpstream(error: Error?, context: ChannelHandlerContext) {
        guard !didHandleUpstreamFailure else {
            return
        }
        didHandleUpstreamFailure = true
        breakpointTask?.cancel()

        let transaction = self.transaction
        let responseBodyRecorder = self.responseBodyRecorder
        let responseHeadTask = self.responseHeadTask
        let failure: FlowFailure =
            if let error {
                if usesTLS, let sslError = error as? NIOSSLError,
                    case .handshakeFailed = sslError
                {
                    .tlsHandshakeFailed
                } else if responseStarted {
                    .protocolError(error.localizedDescription)
                } else {
                    .upstreamUnavailable
                }
            } else {
                .protocolError("The upstream closed before the response completed")
            }
        Task { [transaction, responseBodyRecorder, responseHeadTask, failure] in
            await responseHeadTask?.value
            await responseBodyRecorder?.cancel()
            await transaction.fail(failure)
        }

        let clientHasResponse = responseStarted && !pendingResponseBreakpoint
        if !clientHasResponse {
            sendBadGateway(to: clientChannel)
        } else {
            clientChannel.close(promise: nil)
        }
        context.close(promise: nil)
    }

    private func sendBadGateway(to channel: Channel) {
        var body = channel.allocator.buffer(capacity: 64)
        body.writeString("The upstream response could not be read.\r\n")

        var headers = NIOHTTP1.HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(body.readableBytes)")
        headers.add(name: "Connection", value: "close")

        let head = HTTPResponseHead(
            version: .http1_1,
            status: HTTPResponseStatus(statusCode: 502, reasonPhrase: "Bad Gateway"),
            headers: headers
        )
        channel.write(HTTPServerResponsePart.head(head), promise: nil)
        channel.write(HTTPServerResponsePart.body(.byteBuffer(body)), promise: nil)
        channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
            channel.close(promise: nil)
        }
    }
}
