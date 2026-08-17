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
    private let webSocketFrameEventSink: any WebSocketFrameEventSink
    private let maxPendingRequestBytes: Int
    private let bodyStore: (any BodyStore)?
    private let maximumCapturedBodyBytes: Int64
    private let maximumWebSocketFrameBytes: Int
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
    private var pendingThrottleProfile: ThrottleProfile?
    private var uploadPacer = BandwidthPacer()
    private var scheduledUploadBytes = 0
    private var isUploadThrottleReadPaused = false
    private var isWaitingForThrottleLatency = false
    private var pendingRequestBreakpoint = false
    private var pendingRequestBodyRuleSet: RuleSet?
    fileprivate var breakpointTask: Task<Void, Never>?

    init(
        sessionID: SessionID,
        eventSink: any FlowEventSink,
        webSocketFrameEventSink: any WebSocketFrameEventSink = NoOpWebSocketFrameEventSink(),
        maxPendingRequestBytes: Int,
        bodyStore: (any BodyStore)? = nil,
        maximumCapturedBodyBytes: Int64 = 50 * 1_024 * 1_024,
        maximumWebSocketFrameBytes: Int = 16 * 1_024 * 1_024,
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
        self.webSocketFrameEventSink = webSocketFrameEventSink
        self.maxPendingRequestBytes = max(1, maxPendingRequestBytes)
        self.bodyStore = bodyStore
        self.maximumCapturedBodyBytes = max(0, maximumCapturedBodyBytes)
        self.maximumWebSocketFrameBytes = min(max(1, maximumWebSocketFrameBytes), Int(UInt32.max))
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
        let ruleSet = ruleSnapshot?.currentRules() ?? RuleSet()
        let requestPlan = RulePlanner.plan(
            rules: ruleSet,
            context: RuleMatchContext(request: request, source: flowSource),
            phase: .requestHeaders
        )
        if ruleSet.hasEnabledRules(for: .requestBody) {
            pendingRequestBodyRuleSet = ruleSet
        }
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
                maximumByteCount: maximumCapturedBodyBytes,
                discoversGraphQLOperation: true
            )
        }

        self.requestHead = head
        self.transaction = transaction
        self.pendingTarget = target
        self.pendingRequest = request
        self.pendingThrottleProfile = requestPlan.throttleProfile
        uploadPacer.reset()
        scheduledUploadBytes = 0
        isUploadThrottleReadPaused = false

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

        if let destination = requestPlan.redirectURL {
            let redirectedResponse: HTTPResponse
            do {
                var response = try RedirectedHTTPResponse.make(
                    destination: destination,
                    version: coreVersion
                )
                if requestPlan.applyNoCache {
                    response = response.replacingHeaders(
                        try NoCacheHeaders.applyingToResponse(response.headers)
                    )
                }
                redirectedResponse = response
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
                redirectedResponse,
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

        if let profile = requestPlan.throttleProfile,
            profile.dropsRequest(flowID: flow.id)
        {
            finishWithSimulatedNetworkFailure(
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
        let preservesWebSocketUpgrade = HTTPConversion.isWebSocketUpgradeRequest(head)
        if requestPlan.applyNoCache {
            forwardedHeaders = HTTPConversion.sanitizedRequestHeaders(
                HTTPConversion.nioHeaders(from: request.headers),
                preservingWebSocketUpgrade: preservesWebSocketUpgrade
            )
        } else {
            forwardedHeaders = HTTPConversion.sanitizedRequestHeaders(
                head.headers,
                preservingWebSocketUpgrade: preservesWebSocketUpgrade
            )
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

        if pendingRequestBodyRuleSet != nil {
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
        let sessionID = self.sessionID
        let eventSink = self.eventSink
        let maxPendingRequestBytes = self.maxPendingRequestBytes
        let bodyStore = self.bodyStore
        let maximumCapturedBodyBytes = self.maximumCapturedBodyBytes
        let webSocketFrameEventSink = self.webSocketFrameEventSink
        let maximumWebSocketFrameBytes = self.maximumWebSocketFrameBytes
        let certificateProvider = self.certificateProvider
        let ruleSnapshot = self.ruleSnapshot
        let breakpointGate = self.breakpointGate
        let flowSource = self.flowSource
        HTTPServerPipeline.removePlaintextHTTPHandlers(from: channel).flatMap {
            var response = channel.allocator.buffer(capacity: 39)
            response.writeString("HTTP/1.1 200 Connection Established\r\n\r\n")
            return channel.writeAndFlush(response)
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
                    webSocketFrameEventSink: webSocketFrameEventSink,
                    maxPendingRequestBytes: maxPendingRequestBytes,
                    bodyStore: bodyStore,
                    maximumCapturedBodyBytes: maximumCapturedBodyBytes,
                    maximumWebSocketFrameBytes: maximumWebSocketFrameBytes,
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
            forwardRequestBody(
                buffer,
                to: upstreamChannel,
                clientChannel: context.channel
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
        if pendingRequestBodyRuleSet != nil {
            pendingRequestParts.append(HTTPClientRequestPart.end(trailers))
            beginRequestBodyRuleEvaluation(channel: context.channel)
            return
        }

        finishRequestBodyCapture(context: context)

        let endPart = HTTPClientRequestPart.end(trailers)
        if let upstreamChannel {
            forwardRequestEnd(
                endPart,
                to: upstreamChannel
            )
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
        updateClientAutoRead(channel)

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

        updateClientAutoRead(channel)
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
                let graphqlOperation: GraphQLOperationMetadata? =
                    if let recorder, let reference {
                        await recorder.graphqlOperation(for: reference)
                    } else {
                        nil
                    }
                await transaction.finishRequestBody(
                    reference,
                    graphqlOperation: graphqlOperation,
                    at: completedAt
                )
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
                let graphqlOperation: GraphQLOperationMetadata? =
                    if let recorder, let reference {
                        await recorder.graphqlOperation(for: reference)
                    } else {
                        nil
                    }
                var pausedRequest = originalRequest
                if let reference {
                    pausedRequest = pausedRequest.replacingBody(
                        reference,
                        graphqlOperation: graphqlOperation
                    )
                }
                await transaction.finishRequestBody(
                    reference,
                    graphqlOperation: graphqlOperation,
                    at: completedAt
                )
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

    private func beginRequestBodyRuleEvaluation(channel: Channel) {
        guard let transaction, let originalRequest = pendingRequest,
            let rules = pendingRequestBodyRuleSet
        else {
            return
        }

        let writeTask = requestBodyWriteTask
        let recorder = requestBodyRecorder
        let gate = breakpointGate
        let source = flowSource
        let ruleResources = ruleSnapshot
        let loopBoundSelf = NIOLoopBound(self, eventLoop: channel.eventLoop)
        let completedAt = Date()
        breakpointTask = Task {
            do {
                try await writeTask?.value
                let reference = try await recorder?.finalize()
                let graphqlOperation: GraphQLOperationMetadata? =
                    if let recorder, let reference {
                        await recorder.graphqlOperation(for: reference)
                    } else {
                        nil
                    }
                let capturedRequest =
                    if let reference {
                        originalRequest.replacingBody(
                            reference,
                            graphqlOperation: graphqlOperation
                        )
                    } else {
                        originalRequest
                    }
                await transaction.finishRequestBody(
                    reference,
                    graphqlOperation: graphqlOperation,
                    at: completedAt
                )
                let plan = RulePlanner.plan(
                    rules: rules,
                    context: RuleMatchContext(request: capturedRequest, source: source),
                    phase: .requestBody
                )
                await transaction.appendRuleTraces(plan.traces)

                let mappedRemoteTarget: MappedRemoteTarget?
                if let destination = plan.mapRemoteURL {
                    let mapped = try MappedRemoteHTTPRequest.make(
                        originalURL: capturedRequest.url,
                        destination: destination
                    )
                    await transaction.replaceUpstreamConnection(
                        host: mapped.host,
                        port: UInt16(mapped.port),
                        usesTLS: mapped.usesTLS
                    )
                    mappedRemoteTarget = mapped
                } else {
                    mappedRemoteTarget = nil
                }

                let replacementBody: BodyReference?
                if let body = plan.replacementBody {
                    guard body.inlineData != nil, !body.isTruncated else {
                        throw ProxyLensError.unsupportedOperation(
                            "Request-body replacement requires complete inline bytes"
                        )
                    }
                    replacementBody = body
                } else {
                    replacementBody = nil
                }

                if plan.shouldBlock {
                    let response = try BlockedHTTPResponse.make(
                        reason: plan.blockReason,
                        version: capturedRequest.version
                    )
                    channel.eventLoop.execute {
                        loopBoundSelf.value.finishRequestBodyWithLocalResponse(
                            response,
                            capturedRequest: capturedRequest,
                            channel: channel
                        )
                    }
                } else if let resourceID = plan.mapLocalResourceID {
                    guard let spec = ruleResources?.mappedLocal(for: resourceID) else {
                        throw ProxyLensError.unsupportedOperation(
                            "Mapped local resource is unavailable: \(resourceID)"
                        )
                    }
                    let response = try MappedLocalHTTPResponse.make(
                        spec: spec,
                        version: capturedRequest.version
                    )
                    channel.eventLoop.execute {
                        loopBoundSelf.value.finishRequestBodyWithLocalResponse(
                            response,
                            capturedRequest: capturedRequest,
                            channel: channel
                        )
                    }
                } else if plan.shouldBreakpoint {
                    if mappedRemoteTarget != nil || replacementBody != nil {
                        channel.eventLoop.execute {
                            if let mappedRemoteTarget {
                                loopBoundSelf.value.applyRequestBodyMapRemote(
                                    mappedRemoteTarget,
                                    channel: channel
                                )
                            }
                            if let replacementBody {
                                loopBoundSelf.value.applyRequestBodyReplacement(
                                    replacementBody,
                                    channel: channel
                                )
                            }
                        }
                    }
                    await transaction.pause(.request)
                    let hit = BreakpointHit(
                        flowID: await transaction.flowID(),
                        phase: .request,
                        request: capturedRequest
                    )
                    let decision = await gate.pause(hit)
                    channel.eventLoop.execute {
                        loopBoundSelf.value.applyRequestBreakpointDecision(
                            decision,
                            capturedRequest: capturedRequest,
                            channel: channel
                        )
                    }
                } else {
                    channel.eventLoop.execute {
                        loopBoundSelf.value.continueAfterRequestBodyRules(
                            capturedRequest: capturedRequest,
                            mappedRemoteTarget: mappedRemoteTarget,
                            replacementBody: replacementBody,
                            channel: channel
                        )
                    }
                }
            } catch {
                await recorder?.cancel()
                await transaction.fail(.persistenceError(error.localizedDescription))
                channel.close(promise: nil)
            }
        }
    }

    private func finishRequestBodyWithLocalResponse(
        _ response: HTTPResponse,
        capturedRequest: HTTPRequest,
        channel: Channel
    ) {
        guard channel.isActive, let transaction else {
            return
        }
        pendingRequestBodyRuleSet = nil
        breakpointTask = nil
        pendingRequest = capturedRequest
        finishWithLocalResponse(
            response,
            traces: [],
            transaction: transaction,
            channel: channel
        )
    }

    private func continueAfterRequestBodyRules(
        capturedRequest: HTTPRequest,
        mappedRemoteTarget: MappedRemoteTarget? = nil,
        replacementBody: BodyReference? = nil,
        channel: Channel
    ) {
        guard channel.isActive else {
            return
        }
        if let mappedRemoteTarget {
            applyRequestBodyMapRemote(mappedRemoteTarget, channel: channel)
        }
        if let replacementBody {
            applyRequestBodyReplacement(replacementBody, channel: channel)
        }
        pendingRequestBodyRuleSet = nil
        breakpointTask = nil
        pendingRequest = capturedRequest
        guard let target = pendingTarget,
            let requestHead = pendingForwardedHead,
            let transaction
        else {
            abortBreakpoint(channel: channel)
            return
        }
        connectUpstream(
            target: target,
            requestHead: requestHead,
            request: capturedRequest,
            clientChannel: channel,
            transaction: transaction
        )
    }

    private func applyRequestBodyMapRemote(
        _ mapped: MappedRemoteTarget,
        channel: Channel
    ) {
        guard channel.isActive, let forwardedHead = pendingForwardedHead else {
            return
        }

        let target = ProxyTarget(mapped)
        var headers = forwardedHead.headers
        headers.remove(name: "Host")
        headers.add(name: "Host", value: mapped.hostHeader)
        pendingTarget = target
        pendingForwardedHead = HTTPRequestHead(
            version: forwardedHead.version,
            method: forwardedHead.method,
            uri: mapped.originForm,
            headers: headers
        )
    }

    private func applyRequestBodyReplacement(
        _ replacement: BodyReference,
        channel: Channel
    ) {
        guard channel.isActive, let data = replacement.inlineData,
            let forwardedHead = pendingForwardedHead
        else {
            return
        }

        var endPart = HTTPClientRequestPart.end(nil)
        for part in pendingRequestParts {
            if case .end(let trailers) = part {
                endPart = .end(trailers)
            }
        }

        pendingRequestParts.removeAll(keepingCapacity: true)
        pendingRequestBytes = data.count
        if !data.isEmpty {
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            pendingRequestParts.append(.body(.byteBuffer(buffer)))
        }
        pendingRequestParts.append(endPart)

        var headers = forwardedHead.headers
        headers.remove(name: "Content-Length")
        headers.remove(name: "Transfer-Encoding")
        headers.remove(name: "Content-Encoding")
        headers.add(name: "Content-Length", value: "\(data.count)")
        if let contentType = replacement.contentType {
            headers.remove(name: "Content-Type")
            headers.add(name: "Content-Type", value: contentType)
        }
        if let contentEncoding = replacement.contentEncoding {
            headers.add(name: "Content-Encoding", value: contentEncoding)
        }
        pendingForwardedHead = HTTPRequestHead(
            version: forwardedHead.version,
            method: forwardedHead.method,
            uri: forwardedHead.uri,
            headers: headers
        )
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
            pendingRequestBodyRuleSet = nil
            breakpointTask = nil
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
            let editedHeaders = HTTPConversion.nioHeaders(from: request.headers)
            var headers = HTTPConversion.sanitizedRequestHeaders(
                editedHeaders,
                preservingWebSocketUpgrade: HTTPConversion.isWebSocketUpgradeHeaders(
                    editedHeaders
                )
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
            let editedHeaders = HTTPConversion.nioHeaders(from: request.headers)
            var headers = HTTPConversion.sanitizedRequestHeaders(
                editedHeaders,
                preservingWebSocketUpgrade: HTTPConversion.isWebSocketUpgradeHeaders(
                    editedHeaders
                )
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
        let profile = pendingThrottleProfile
        guard let latency = profile?.latency,
            latency.isFinite,
            latency > 0
        else {
            connectUpstreamNow(
                target: target,
                requestHead: requestHead,
                request: request,
                clientChannel: clientChannel,
                transaction: transaction
            )
            return
        }

        let boundedLatency = min(latency, 60)
        let nanoseconds = Int64((boundedLatency * 1_000_000_000).rounded())
        isWaitingForThrottleLatency = true
        updateClientAutoRead(clientChannel)
        let loopBoundSelf = NIOLoopBound(self, eventLoop: clientChannel.eventLoop)
        clientChannel.eventLoop.scheduleTask(in: .nanoseconds(nanoseconds)) {
            guard clientChannel.isActive else {
                return
            }
            loopBoundSelf.value.connectUpstreamNow(
                target: target,
                requestHead: requestHead,
                request: request,
                clientChannel: clientChannel,
                transaction: transaction
            )
        }
    }

    private func connectUpstreamNow(
        target: ProxyTarget,
        requestHead: HTTPRequestHead,
        request: HTTPRequest,
        clientChannel: Channel,
        transaction: FlowTransaction
    ) {
        let bodyStore = self.bodyStore
        let maximumCapturedBodyBytes = self.maximumCapturedBodyBytes
        let webSocketFrameEventSink = self.webSocketFrameEventSink
        let maximumWebSocketFrameBytes = self.maximumWebSocketFrameBytes
        let ruleSnapshot = self.ruleSnapshot
        let breakpointGate = self.breakpointGate
        let flowSource = self.flowSource
        let throttleProfile = pendingThrottleProfile
        let loopBoundSelf = NIOLoopBound(self, eventLoop: clientChannel.eventLoop)
        let bootstrap = ClientBootstrap(group: clientChannel.eventLoop)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer {
                [
                    upstreamTLSContext, bodyStore, maximumCapturedBodyBytes,
                    webSocketFrameEventSink, maximumWebSocketFrameBytes, loopBoundSelf,
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

                return tlsFuture.flatMapThrowing {
                    try HTTPClientPipeline.install(
                        on: channel,
                        responseHandler: UpstreamResponseHandler(
                            clientChannel: clientChannel,
                            clientHandler: loopBoundSelf,
                            transaction: transaction,
                            request: request,
                            usesTLS: target.usesTLS,
                            bodyStore: bodyStore,
                            maximumCapturedBodyBytes: maximumCapturedBodyBytes,
                            webSocketFrameEventSink: webSocketFrameEventSink,
                            maximumWebSocketFrameBytes: maximumWebSocketFrameBytes,
                            ruleSnapshot: ruleSnapshot,
                            breakpointGate: breakpointGate,
                            flowSource: flowSource,
                            throttleProfile: throttleProfile
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
                    handler.isWaitingForThrottleLatency = false
                    handler.updateClientAutoRead(clientChannel)
                    if let transaction = handler.transaction {
                        Task { [transaction] in
                            await transaction.markUpstreamConnected(at: Date())
                        }
                    }

                    channel.write(HTTPClientRequestPart.head(requestHead), promise: nil)
                    var forwardedEnd = false
                    for part in handler.pendingRequestParts {
                        switch part {
                        case .body(let body):
                            if case .byteBuffer(let buffer) = body {
                                handler.forwardRequestBody(
                                    buffer,
                                    to: channel,
                                    clientChannel: clientChannel
                                )
                            } else {
                                channel.write(part, promise: nil)
                            }
                        case .end:
                            forwardedEnd = true
                            handler.forwardRequestEnd(part, to: channel)
                        case .head:
                            channel.write(part, promise: nil)
                        }
                    }
                    handler.pendingRequestParts.removeAll(keepingCapacity: false)
                    handler.pendingRequestBytes = 0

                    if handler.requestEnded, !forwardedEnd {
                        channel.flush()
                    }
                case .failure(let error):
                    handler.handleUpstreamFailure(error, clientChannel: clientChannel)
                }
            }
        }
    }

    private func forwardRequestBody(
        _ buffer: ByteBuffer,
        to upstreamChannel: Channel,
        clientChannel: Channel
    ) {
        guard let rate = pendingThrottleProfile?.uploadBytesPerSecond, rate > 0,
            buffer.readableBytes > 0
        else {
            upstreamChannel.write(
                HTTPClientRequestPart.body(.byteBuffer(buffer)),
                promise: nil
            )
            return
        }

        let byteCount = buffer.readableBytes
        let deadline = uploadPacer.deadline(
            forByteCount: byteCount,
            bytesPerSecond: rate,
            now: upstreamChannel.eventLoop.now
        )
        scheduledUploadBytes += byteCount
        if scheduledUploadBytes >= Self.throttleQueueHighWatermark {
            isUploadThrottleReadPaused = true
            updateClientAutoRead(clientChannel)
        }

        let loopBoundSelf = NIOLoopBound(self, eventLoop: upstreamChannel.eventLoop)
        upstreamChannel.eventLoop.scheduleTask(deadline: deadline) {
            upstreamChannel.write(
                HTTPClientRequestPart.body(.byteBuffer(buffer)),
                promise: nil
            )
            loopBoundSelf.value.completeScheduledUpload(
                byteCount: byteCount,
                clientChannel: clientChannel
            )
        }
    }

    private func forwardRequestEnd(
        _ endPart: HTTPClientRequestPart,
        to upstreamChannel: Channel
    ) {
        guard pendingThrottleProfile?.uploadBytesPerSecond != nil,
            let deadline = uploadPacer.completionDeadline
        else {
            upstreamChannel.writeAndFlush(endPart, promise: nil)
            return
        }

        upstreamChannel.eventLoop.scheduleTask(deadline: deadline) {
            upstreamChannel.writeAndFlush(endPart, promise: nil)
        }
    }

    private func completeScheduledUpload(byteCount: Int, clientChannel: Channel) {
        scheduledUploadBytes = max(0, scheduledUploadBytes - byteCount)
        if scheduledUploadBytes <= Self.throttleQueueLowWatermark {
            isUploadThrottleReadPaused = false
            updateClientAutoRead(clientChannel)
        }
    }

    private func updateClientAutoRead(_ channel: Channel) {
        let shouldRead =
            captureWritesInFlight == 0
            && !captureFailureHandled
            && !isWaitingForThrottleLatency
            && !isUploadThrottleReadPaused
        channel.setOption(ChannelOptions.autoRead, value: shouldRead).whenFailure { _ in
            channel.close(promise: nil)
        }
    }

    private static let throttleQueueHighWatermark = 256 * 1_024
    private static let throttleQueueLowWatermark = 128 * 1_024

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

    private func finishWithSimulatedNetworkFailure(
        traces: [RuleTrace],
        transaction: FlowTransaction,
        channel: Channel
    ) {
        didFinishLocally = true
        let requestBodyRecorder = self.requestBodyRecorder
        Task {
            await requestBodyRecorder?.cancel()
            await transaction.start(at: Date())
            await transaction.appendRuleTraces(traces)
            await transaction.fail(.simulatedNetworkFailure)
            channel.close(promise: nil)
        }
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

private struct BandwidthPacer {
    private(set) var completionDeadline: NIODeadline?

    mutating func reset() {
        completionDeadline = nil
    }

    mutating func deadline(
        forByteCount byteCount: Int,
        bytesPerSecond: Int64,
        now: NIODeadline
    ) -> NIODeadline {
        guard byteCount > 0, bytesPerSecond > 0 else {
            return completionDeadline ?? now
        }

        let base = max(completionDeadline ?? now, now)
        let transferNanoseconds = Int64(
            ceil(Double(byteCount) / Double(bytesPerSecond) * 1_000_000_000)
        )
        let deadline = base + .nanoseconds(max(1, transferNanoseconds))
        completionDeadline = deadline
        return deadline
    }
}

final class UpstreamResponseHandler:
    ChannelInboundHandler,
    RemovableChannelHandler,
    @unchecked Sendable
{
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let clientChannel: Channel
    private let clientHandler: NIOLoopBound<HTTPProxyHandler>
    private let transaction: FlowTransaction
    private let request: HTTPRequest
    private let usesTLS: Bool
    private let bodyStore: (any BodyStore)?
    private let maximumCapturedBodyBytes: Int64
    private let webSocketFrameEventSink: any WebSocketFrameEventSink
    private let maximumWebSocketFrameBytes: Int
    private let ruleSnapshot: (any RuleSnapshotSource)?
    private let breakpointGate: any BreakpointGate
    private let flowSource: FlowSource
    private let throttleProfile: ThrottleProfile?
    private var responseStarted = false
    private var responseBodyRecorder: StreamingBodyRecorder?
    private var responseHeadTask: Task<Void, Never>?
    private var responseBodyWriteTask: Task<Void, Error>?
    private var captureWritesInFlight = 0
    private var captureFailureHandled = false
    private var downloadPacer = BandwidthPacer()
    private var scheduledDownloadBytes = 0
    private var isDownloadThrottleReadPaused = false
    private var pendingResponseBreakpoint = false
    private var pendingResponse: HTTPResponse?
    private var pendingResponseHead: HTTPResponseHead?
    private var pendingResponseBuffers: [ByteBuffer] = []
    private var pendingResponseBytes = 0
    private var pendingResponseTrailers: NIOHTTP1.HTTPHeaders?
    private var pendingResponseReplacement: BodyReference?
    private var breakpointTask: Task<Void, Never>?
    private var didHandleUpstreamFailure = false
    private var isWebSocketUpgrade = false

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
        webSocketFrameEventSink: any WebSocketFrameEventSink,
        maximumWebSocketFrameBytes: Int,
        ruleSnapshot: (any RuleSnapshotSource)?,
        breakpointGate: any BreakpointGate,
        flowSource: FlowSource,
        throttleProfile: ThrottleProfile?
    ) {
        self.clientChannel = clientChannel
        self.clientHandler = clientHandler
        self.transaction = transaction
        self.request = request
        self.usesTLS = usesTLS
        self.bodyStore = bodyStore
        self.maximumCapturedBodyBytes = max(0, maximumCapturedBodyBytes)
        self.webSocketFrameEventSink = webSocketFrameEventSink
        self.maximumWebSocketFrameBytes = min(max(1, maximumWebSocketFrameBytes), Int(UInt32.max))
        self.ruleSnapshot = ruleSnapshot
        self.breakpointGate = breakpointGate
        self.flowSource = flowSource
        self.throttleProfile = throttleProfile
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
                let rules = ruleSnapshot?.currentRules() ?? RuleSet()
                let responsePlan = RulePlanner.plan(
                    rules: rules,
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
                let responseBodyPlan =
                    if Self.responseMayCarryBody(request: request, response: response) {
                        RulePlanner.plan(
                            rules: rules,
                            context: RuleMatchContext(
                                request: request,
                                response: response,
                                source: flowSource
                            ),
                            phase: .responseBody
                        )
                    } else {
                        RulePlan(phase: .responseBody)
                    }
                isWebSocketUpgrade = Self.isWebSocketUpgrade(
                    request: request,
                    responseHead: head
                )
                if let replacement = responseBodyPlan.replacementBody {
                    guard replacement.inlineData != nil, !replacement.isTruncated else {
                        throw ProxyLensError.unsupportedOperation(
                            "Response-body replacement requires complete inline bytes"
                        )
                    }
                    pendingResponseReplacement = replacement
                }
                if let bodyStore,
                    Self.responseMayCarryBody(request: request, response: response)
                {
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
                let traces = responsePlan.traces + responseBodyPlan.traces
                let capturedResponse = response
                responseHeadTask = Task { [transaction] in
                    await transaction.appendRuleTraces(traces)
                    await transaction.receiveResponse(capturedResponse, at: receivedAt)
                }
                var forwardedHead = head
                if responsePlan.applyNoCache {
                    forwardedHead.headers = HTTPConversion.nioHeaders(from: response.headers)
                }
                if let pendingResponseReplacement {
                    forwardedHead = Self.replacingBody(
                        in: forwardedHead,
                        with: pendingResponseReplacement
                    )
                }
                if responsePlan.shouldBreakpoint, !isWebSocketUpgrade {
                    pendingResponseBreakpoint = true
                    pendingResponse = capturedResponse
                    pendingResponseHead = HTTPConversion.sanitizedResponseHead(
                        forwardedHead,
                        preservingWebSocketUpgrade: isWebSocketUpgrade
                    )
                } else {
                    clientChannel.write(
                        HTTPServerResponsePart.head(
                            HTTPConversion.sanitizedResponseHead(
                                forwardedHead,
                                preservingWebSocketUpgrade: isWebSocketUpgrade
                            )),
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
            } else if pendingResponseReplacement == nil {
                forwardResponseBody(buffer, upstreamChannel: context.channel)
            }
        case .end(let trailers):
            if isWebSocketUpgrade {
                beginWebSocketBridge(trailers: trailers, context: context)
                return
            }
            if pendingResponseBreakpoint {
                pendingResponseTrailers = trailers
                beginResponseBreakpoint(context: context)
                return
            }
            clientHandler.value.markResponseEnded()
            finishResponseBodyCapture(context: context)
            if let replacement = pendingResponseReplacement {
                writeReplacementBody(replacement, upstreamChannel: context.channel)
            }
            let forwardedTrailers =
                pendingResponseReplacement == nil
                ? HTTPConversion.sanitizedTrailers(trailers)
                : nil
            finishForwardedResponse(
                trailers: forwardedTrailers,
                upstreamChannel: context.channel
            )
            context.close(promise: nil)
        }
    }

    private func beginWebSocketBridge(
        trailers: NIOHTTP1.HTTPHeaders?,
        context: ChannelHandlerContext
    ) {
        guard trailers == nil else {
            failUpstream(
                error: ProxyLensError.unsupportedOperation(
                    "WebSocket upgrade responses cannot contain trailers"
                ),
                context: context
            )
            return
        }

        clientHandler.value.markResponseEnded()
        let transaction = self.transaction
        let headTask = responseHeadTask
        let flowIDFuture = context.eventLoop.makeFutureWithTask {
            await headTask?.value
            await transaction.beginWebSocket(secure: self.usesTLS, at: Date())
            return await transaction.flowID()
        }
        let upstreamChannel = context.channel
        let bodyStore = self.bodyStore
        let maximumCapturedFrameBytes = min(
            maximumCapturedBodyBytes,
            Int64(maximumWebSocketFrameBytes)
        )
        let maximumFrameBytes = maximumWebSocketFrameBytes
        let frameEventSink = webSocketFrameEventSink
        clientChannel.writeAndFlush(HTTPServerResponsePart.end(nil)).flatMap {
            flowIDFuture
        }.flatMap { flowID in
            WebSocketBridge.install(
                clientChannel: self.clientChannel,
                upstreamChannel: upstreamChannel,
                transaction: transaction,
                flowID: flowID,
                bodyStore: bodyStore,
                maximumCapturedFrameBytes: maximumCapturedFrameBytes,
                maximumFrameBytes: maximumFrameBytes,
                eventSink: frameEventSink
            )
        }.whenFailure { error in
            Task { [transaction] in
                await transaction.fail(.protocolError(error.localizedDescription))
            }
            self.clientChannel.close(promise: nil)
            upstreamChannel.close(promise: nil)
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
        if let replacement = pendingResponseReplacement {
            writeReplacementBody(replacement, upstreamChannel: upstreamChannel)
        } else {
            for buffer in pendingResponseBuffers {
                forwardResponseBody(buffer, upstreamChannel: upstreamChannel)
            }
        }
        let trailers =
            pendingResponseReplacement == nil
            ? HTTPConversion.sanitizedTrailers(pendingResponseTrailers)
            : nil
        finishForwardedResponse(trailers: trailers, upstreamChannel: upstreamChannel)
        let transaction = self.transaction
        Task { [transaction] in
            await transaction.completePausedResponse(at: Date())
        }
        upstreamChannel.close(promise: nil)
    }

    private func writeReplacementBody(
        _ replacement: BodyReference,
        upstreamChannel: Channel
    ) {
        guard let data = replacement.inlineData, !data.isEmpty else {
            return
        }
        var buffer = clientChannel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        forwardResponseBody(buffer, upstreamChannel: upstreamChannel)
    }

    private func forwardResponseBody(_ buffer: ByteBuffer, upstreamChannel: Channel) {
        guard let rate = throttleProfile?.downloadBytesPerSecond, rate > 0,
            buffer.readableBytes > 0
        else {
            clientChannel.write(
                HTTPServerResponsePart.body(.byteBuffer(buffer)),
                promise: nil
            )
            return
        }

        let byteCount = buffer.readableBytes
        let deadline = downloadPacer.deadline(
            forByteCount: byteCount,
            bytesPerSecond: rate,
            now: clientChannel.eventLoop.now
        )
        scheduledDownloadBytes += byteCount
        if scheduledDownloadBytes >= Self.throttleQueueHighWatermark {
            isDownloadThrottleReadPaused = true
            updateUpstreamAutoRead(upstreamChannel)
        }

        let clientChannel = self.clientChannel
        let loopBoundSelf = NIOLoopBound(self, eventLoop: clientChannel.eventLoop)
        clientChannel.eventLoop.scheduleTask(deadline: deadline) {
            clientChannel.write(
                HTTPServerResponsePart.body(.byteBuffer(buffer)),
                promise: nil
            )
            loopBoundSelf.value.completeScheduledDownload(
                byteCount: byteCount,
                upstreamChannel: upstreamChannel
            )
        }
    }

    private func finishForwardedResponse(
        trailers: NIOHTTP1.HTTPHeaders?,
        upstreamChannel: Channel
    ) {
        if throttleProfile?.downloadBytesPerSecond != nil,
            let deadline = downloadPacer.completionDeadline
        {
            let loopBoundSelf = NIOLoopBound(self, eventLoop: clientChannel.eventLoop)
            clientChannel.eventLoop.scheduleTask(deadline: deadline) {
                loopBoundSelf.value.writeResponseEnd(trailers)
            }
        } else {
            writeResponseEnd(trailers)
        }
    }

    private func writeResponseEnd(_ trailers: NIOHTTP1.HTTPHeaders?) {
        clientChannel.writeAndFlush(HTTPServerResponsePart.end(trailers)).whenComplete {
            [clientChannel] _ in
            clientChannel.close(promise: nil)
        }
    }

    private func completeScheduledDownload(byteCount: Int, upstreamChannel: Channel) {
        scheduledDownloadBytes = max(0, scheduledDownloadBytes - byteCount)
        if scheduledDownloadBytes <= Self.throttleQueueLowWatermark {
            isDownloadThrottleReadPaused = false
            updateUpstreamAutoRead(upstreamChannel)
        }
    }

    private static func replacingBody(
        in head: HTTPResponseHead,
        with replacement: BodyReference
    ) -> HTTPResponseHead {
        var headers = head.headers
        headers.remove(name: "Content-Length")
        headers.remove(name: "Transfer-Encoding")
        headers.remove(name: "Trailer")
        headers.remove(name: "Content-Encoding")
        headers.remove(name: "Content-Range")
        headers.remove(name: "Content-MD5")
        headers.remove(name: "Digest")
        headers.remove(name: "ETag")
        headers.add(name: "Content-Length", value: "\(replacement.inlineData?.count ?? 0)")
        if let contentType = replacement.contentType {
            headers.remove(name: "Content-Type")
            headers.add(name: "Content-Type", value: contentType)
        }
        if let contentEncoding = replacement.contentEncoding {
            headers.add(name: "Content-Encoding", value: contentEncoding)
        }
        return HTTPResponseHead(
            version: head.version,
            status: head.status,
            headers: headers
        )
    }

    private static func responseMayCarryBody(
        request: HTTPRequest,
        response: HTTPResponse
    ) -> Bool {
        request.method != .head
            && !(100..<200).contains(response.statusCode)
            && response.statusCode != 204
            && response.statusCode != 304
    }

    private static func isWebSocketUpgrade(
        request: HTTPRequest,
        responseHead: HTTPResponseHead
    ) -> Bool {
        responseHead.status == .switchingProtocols
            && headerContainsToken(request.headers.values(for: "Connection"), token: "upgrade")
            && headerContainsToken(request.headers.values(for: "Upgrade"), token: "websocket")
            && headerContainsToken(
                responseHead.headers[canonicalForm: "Connection"], token: "upgrade")
            && headerContainsToken(
                responseHead.headers[canonicalForm: "Upgrade"], token: "websocket")
    }

    private static func headerContainsToken<Values: Sequence>(
        _ values: Values,
        token: String
    ) -> Bool where Values.Element: StringProtocol {
        values.contains { value in
            value.split(separator: ",").contains {
                String($0).trimmingCharacters(in: .whitespaces)
                    .caseInsensitiveCompare(token) == .orderedSame
            }
        }
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
        updateUpstreamAutoRead(channel)

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

        updateUpstreamAutoRead(channel)
    }

    private func updateUpstreamAutoRead(_ channel: Channel) {
        let shouldRead =
            captureWritesInFlight == 0
            && !captureFailureHandled
            && !isDownloadThrottleReadPaused
        channel.setOption(ChannelOptions.autoRead, value: shouldRead).whenFailure { _ in
            channel.close(promise: nil)
        }
    }

    private static let throttleQueueHighWatermark = 256 * 1_024
    private static let throttleQueueLowWatermark = 128 * 1_024

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
