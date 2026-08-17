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
    private let serverSentEventEventSink: any ServerSentEventEventSink
    private let webSocketFrameEventSink: any WebSocketFrameEventSink
    private let maxPendingRequestBytes: Int
    private let bodyStore: (any BodyStore)?
    private let maximumCapturedBodyBytes: Int64
    private let maximumWebSocketFrameBytes: Int
    private let webSocketConnectionRegistry: NIOWebSocketConnectionRegistry
    private let interceptHTTPS: Bool
    private let certificateProvider: (any CertificateProvider)?
    private let upstreamTLSContext: NIOSSLContext?
    private let upstreamHTTP2Pool: HTTP2UpstreamConnectionPool?
    private let tunnelTarget: ConnectTarget?
    private let tunnelUsesTLS: Bool
    private let reverseProxyRoute: ReverseProxyRoute?
    private let externalHTTPProxyRoute: ExternalHTTPProxyRoute?
    private let ruleSnapshot: (any RuleSnapshotSource)?
    private let scriptExecutor: (any ScriptExecutor)?
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
    private var isEvaluatingRequestHeaderScripts = false
    fileprivate var breakpointTask: Task<Void, Never>?

    init(
        sessionID: SessionID,
        eventSink: any FlowEventSink,
        serverSentEventEventSink: any ServerSentEventEventSink = NoOpServerSentEventEventSink(),
        webSocketFrameEventSink: any WebSocketFrameEventSink = NoOpWebSocketFrameEventSink(),
        maxPendingRequestBytes: Int,
        bodyStore: (any BodyStore)? = nil,
        maximumCapturedBodyBytes: Int64 = 50 * 1_024 * 1_024,
        maximumWebSocketFrameBytes: Int = 16 * 1_024 * 1_024,
        webSocketConnectionRegistry: NIOWebSocketConnectionRegistry =
            NIOWebSocketConnectionRegistry(),
        interceptHTTPS: Bool = false,
        certificateProvider: (any CertificateProvider)? = nil,
        upstreamTLSContext: NIOSSLContext? = nil,
        upstreamHTTP2Pool: HTTP2UpstreamConnectionPool? = nil,
        tunnelTarget: ConnectTarget? = nil,
        tunnelUsesTLS: Bool = true,
        reverseProxyRoute: ReverseProxyRoute? = nil,
        externalHTTPProxyRoute: ExternalHTTPProxyRoute? = nil,
        ruleSnapshot: (any RuleSnapshotSource)? = nil,
        scriptExecutor: (any ScriptExecutor)? = nil,
        breakpointGate: any BreakpointGate = ImmediateBreakpointGate(),
        flowSource: FlowSource = .desktopProxy
    ) {
        self.sessionID = sessionID
        self.eventSink = eventSink
        self.serverSentEventEventSink = serverSentEventEventSink
        self.webSocketFrameEventSink = webSocketFrameEventSink
        self.maxPendingRequestBytes = max(1, maxPendingRequestBytes)
        self.bodyStore = bodyStore
        self.maximumCapturedBodyBytes = max(0, maximumCapturedBodyBytes)
        self.maximumWebSocketFrameBytes = min(max(1, maximumWebSocketFrameBytes), Int(UInt32.max))
        self.webSocketConnectionRegistry = webSocketConnectionRegistry
        self.interceptHTTPS = interceptHTTPS
        self.certificateProvider = certificateProvider
        self.upstreamTLSContext = upstreamTLSContext
        self.upstreamHTTP2Pool = upstreamHTTP2Pool
        self.tunnelTarget = tunnelTarget
        self.tunnelUsesTLS = tunnelUsesTLS
        self.reverseProxyRoute = reverseProxyRoute
        self.externalHTTPProxyRoute = externalHTTPProxyRoute
        self.ruleSnapshot = ruleSnapshot
        self.scriptExecutor = scriptExecutor
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

        let supportsHTTP1 =
            head.version.major == 1 && (head.version.minor == 0 || head.version.minor == 1)
        let supportsHTTP2 = head.version.major == 2 && head.version.minor == 0
        guard supportsHTTP1 || supportsHTTP2 else {
            sendError(
                statusCode: 505,
                reason: "HTTP Version Not Supported",
                message: "ProxyLens currently supports HTTP/1.0, HTTP/1.1, and HTTP/2.",
                context: context
            )
            return
        }

        if head.method == .CONNECT {
            guard reverseProxyRoute == nil else {
                sendError(
                    statusCode: 405,
                    reason: "Method Not Allowed",
                    message: "CONNECT is not supported by reverse proxy listeners.",
                    context: context
                )
                return
            }
            receiveConnectHead(head, context: context)
            return
        }

        let originalTarget: ProxyTarget
        do {
            if let reverseProxyRoute {
                originalTarget = try ProxyTarget(
                    url: reverseProxyRoute.resolvedURL(forRequestTarget: head.uri)
                )
            } else {
                originalTarget = try ProxyTarget(
                    uri: head.uri,
                    headers: head.headers,
                    tunnelTarget: tunnelTarget,
                    tunnelUsesTLS: tunnelUsesTLS
                )
            }
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
        var mappedHostHeader = reverseProxyRoute == nil ? nil : originalTarget.hostHeader
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
            tlsIntercepted: tunnelTarget != nil && tunnelUsesTLS
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
                traces: terminalRequestHeaderTraces(requestPlan),
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
                traces: terminalRequestHeaderTraces(requestPlan),
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
                traces: terminalRequestHeaderTraces(requestPlan),
                transaction: transaction,
                channel: context.channel
            )
            return
        }

        if let profile = requestPlan.throttleProfile,
            profile.dropsRequest(flowID: flow.id)
        {
            finishWithSimulatedNetworkFailure(
                traces: terminalRequestHeaderTraces(requestPlan),
                transaction: transaction,
                channel: context.channel
            )
            return
        }

        if !requestPlan.scripts.isEmpty {
            beginRequestHeaderScriptEvaluation(
                scripts: requestPlan.scripts,
                requestPlan: requestPlan,
                request: request,
                head: head,
                target: target,
                mappedHostHeader: mappedHostHeader,
                channel: context.channel,
                transaction: transaction
            )
            return
        }

        Task {
            await transaction.start(at: Date())
            await transaction.appendRuleTraces(requestPlan.traces)
        }
        continueAfterRequestHeaderScripts(
            requestPlan: requestPlan,
            capturedRequest: request,
            forwardedRequest: request,
            head: head,
            target: target,
            mappedHostHeader: mappedHostHeader,
            channel: context.channel,
            transaction: transaction
        )
    }

    private func beginRequestHeaderScriptEvaluation(
        scripts: [PlannedScript],
        requestPlan: RulePlan,
        request: HTTPRequest,
        head: HTTPRequestHead,
        target: ProxyTarget,
        mappedHostHeader: String?,
        channel: Channel,
        transaction: FlowTransaction
    ) {
        isEvaluatingRequestHeaderScripts = true
        let executor = scriptExecutor
        let isWebSocketHandshake = HTTPConversion.isWebSocketUpgradeRequest(head)
        let policy: HeaderScriptPolicy =
            isWebSocketHandshake ? .webSocketHandshake : .http
        let initialMessage = HeaderScriptRunner.requestMessage(
            request,
            webSocketHandshake: isWebSocketHandshake
        )
        let loopBoundSelf = NIOLoopBound(self, eventLoop: channel.eventLoop)
        breakpointTask = Task {
            await transaction.start(at: Date())
            await transaction.appendRuleTraces(requestPlan.traces)
            let result = await HeaderScriptRunner.run(
                scripts: scripts,
                hook: .request,
                phase: .requestHeaders,
                initialMessage: initialMessage,
                executor: executor,
                policy: policy
            )
            let forwardedRequest: HTTPRequest
            do {
                forwardedRequest = try HeaderScriptRunner.request(
                    from: result.message,
                    preserving: request,
                    policy: policy
                )
            } catch {
                await transaction.appendRuleTraces(
                    HeaderScriptRunner.failureTraces(
                        scripts: scripts,
                        phase: .requestHeaders,
                        error: error
                    )
                )
                channel.eventLoop.execute {
                    loopBoundSelf.value.continueAfterRequestHeaderScripts(
                        requestPlan: requestPlan,
                        capturedRequest: request,
                        forwardedRequest: request,
                        head: head,
                        target: target,
                        mappedHostHeader: mappedHostHeader,
                        channel: channel,
                        transaction: transaction
                    )
                }
                return
            }
            await transaction.appendRuleTraces(result.traces)
            channel.eventLoop.execute {
                loopBoundSelf.value.continueAfterRequestHeaderScripts(
                    requestPlan: requestPlan,
                    capturedRequest: request,
                    forwardedRequest: forwardedRequest,
                    head: head,
                    target: target,
                    mappedHostHeader: mappedHostHeader,
                    channel: channel,
                    transaction: transaction
                )
            }
        }
    }

    private func continueAfterRequestHeaderScripts(
        requestPlan: RulePlan,
        capturedRequest: HTTPRequest,
        forwardedRequest: HTTPRequest,
        head: HTTPRequestHead,
        target: ProxyTarget,
        mappedHostHeader: String?,
        channel: Channel,
        transaction: FlowTransaction
    ) {
        guard channel.isActive, !didFinishLocally else {
            return
        }
        isEvaluatingRequestHeaderScripts = false
        breakpointTask = nil
        let effectiveRequest =
            if requestPlan.mapRemoteURL != nil, forwardedRequest.url != capturedRequest.url {
                HTTPRequest(
                    method: forwardedRequest.method,
                    url: capturedRequest.url,
                    headers: forwardedRequest.headers,
                    body: forwardedRequest.body,
                    version: forwardedRequest.version,
                    rawTarget: capturedRequest.rawTarget,
                    graphqlOperation: forwardedRequest.graphqlOperation
                )
            } else {
                forwardedRequest
            }
        pendingRequest = effectiveRequest
        pendingTarget = target

        var forwardedHeaders: NIOHTTP1.HTTPHeaders
        let preservesWebSocketUpgrade = HTTPConversion.isWebSocketUpgradeRequest(head)
        if effectiveRequest.headers != capturedRequest.headers {
            forwardedHeaders = HTTPConversion.sanitizedRequestHeaders(
                HTTPConversion.nioHeaders(from: effectiveRequest.headers),
                preservingWebSocketUpgrade: preservesWebSocketUpgrade
            )
        } else if requestPlan.applyNoCache {
            forwardedHeaders = HTTPConversion.sanitizedRequestHeaders(
                HTTPConversion.nioHeaders(from: capturedRequest.headers),
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
            version: HTTPConversion.upstreamVersion(for: head.version),
            method: NIOHTTP1.HTTPMethod(rawValue: effectiveRequest.method.rawValue),
            uri: target.originForm,
            headers: forwardedHeaders
        )
        pendingForwardedHead = forwardedHead

        if effectiveRequest.url != capturedRequest.url {
            do {
                try applyEditedRequest(
                    effectiveRequest,
                    captured: capturedRequest,
                    channel: channel
                )
                if let editedTarget = pendingTarget {
                    Task {
                        await transaction.replaceUpstreamConnection(
                            host: editedTarget.host,
                            port: UInt16(editedTarget.port),
                            usesTLS: editedTarget.usesTLS
                        )
                    }
                }
            } catch {
                scriptedRequestFailure(error, channel: channel)
                return
            }
        }

        if requestPlan.shouldBreakpoint {
            pendingRequestBreakpoint = true
            if requestEnded {
                beginRequestBreakpoint(channel: channel)
            }
            return
        }

        if pendingRequestBodyRuleSet != nil {
            if requestEnded {
                beginRequestBodyRuleEvaluation(channel: channel)
            }
            return
        }

        guard let finalTarget = pendingTarget, let finalHead = pendingForwardedHead else {
            scriptedRequestFailure(
                ProxyLensError.unsupportedOperation("Header script produced no forwarding target"),
                channel: channel
            )
            return
        }
        if requestEnded {
            finishRequestBodyCapture(channel: channel)
        }
        connectUpstream(
            target: finalTarget,
            requestHead: finalHead,
            request: effectiveRequest,
            clientChannel: channel,
            transaction: transaction
        )
    }

    private func terminalRequestHeaderTraces(_ plan: RulePlan) -> [RuleTrace] {
        plan.traces
            + HeaderScriptRunner.skippedTraces(
                scripts: plan.scripts,
                phase: .requestHeaders,
                reason: "A terminal request-header action handled the flow before scripting"
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
        let serverSentEventEventSink = self.serverSentEventEventSink
        let webSocketFrameEventSink = self.webSocketFrameEventSink
        let maximumWebSocketFrameBytes = self.maximumWebSocketFrameBytes
        let webSocketConnectionRegistry = self.webSocketConnectionRegistry
        let certificateProvider = self.certificateProvider
        let upstreamHTTP2Pool = self.upstreamHTTP2Pool
        let externalHTTPProxyRoute = self.externalHTTPProxyRoute
        let ruleSnapshot = self.ruleSnapshot
        let scriptExecutor = self.scriptExecutor
        let breakpointGate = self.breakpointGate
        let flowSource = self.flowSource
        let handlerFactory: @Sendable () -> HTTPProxyHandler = {
            HTTPProxyHandler(
                sessionID: sessionID,
                eventSink: eventSink,
                serverSentEventEventSink: serverSentEventEventSink,
                webSocketFrameEventSink: webSocketFrameEventSink,
                maxPendingRequestBytes: maxPendingRequestBytes,
                bodyStore: bodyStore,
                maximumCapturedBodyBytes: maximumCapturedBodyBytes,
                maximumWebSocketFrameBytes: maximumWebSocketFrameBytes,
                webSocketConnectionRegistry: webSocketConnectionRegistry,
                interceptHTTPS: false,
                certificateProvider: certificateProvider,
                upstreamTLSContext: upstreamTLSContext,
                upstreamHTTP2Pool: upstreamHTTP2Pool,
                tunnelTarget: target,
                externalHTTPProxyRoute: externalHTTPProxyRoute,
                ruleSnapshot: ruleSnapshot,
                scriptExecutor: scriptExecutor,
                breakpointGate: breakpointGate,
                flowSource: flowSource
            )
        }
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
        }.flatMap {
            HTTPServerPipeline.installNegotiatedHTTPS(
                on: channel,
                handlerFactory: handlerFactory
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
        if isEvaluatingRequestHeaderScripts {
            pendingRequestParts.append(HTTPClientRequestPart.end(trailers))
            return
        }
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
        finishRequestBodyCapture(channel: context.channel)
    }

    private func finishRequestBodyCapture(channel: Channel) {
        guard let transaction else {
            return
        }

        let writeTask = requestBodyWriteTask
        let recorder = requestBodyRecorder
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
        let scriptExecutor = self.scriptExecutor
        let bufferedRequestBody = bufferedRequestBodyData()
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

                let scriptBaseRequest =
                    if let replacementBody {
                        capturedRequest.replacingBody(replacementBody)
                    } else {
                        capturedRequest
                    }
                let scriptedRequest: HTTPRequest?
                if plan.scripts.isEmpty {
                    scriptedRequest = nil
                } else {
                    do {
                        let scriptBody = replacementBody?.inlineData ?? bufferedRequestBody
                        let initialMessage = try BodyScriptRunner.requestMessage(
                            request: scriptBaseRequest,
                            bodyData: scriptBody
                        )
                        let result = await BodyScriptRunner.run(
                            scripts: plan.scripts,
                            hook: .request,
                            initialMessage: initialMessage,
                            executor: scriptExecutor
                        )
                        await transaction.appendRuleTraces(result.traces)
                        scriptedRequest = try BodyScriptRunner.request(
                            from: result.message,
                            preserving: scriptBaseRequest
                        )
                    } catch {
                        await transaction.appendRuleTraces(
                            BodyScriptRunner.failureTraces(
                                scripts: plan.scripts,
                                hook: .request,
                                error: error
                            )
                        )
                        scriptedRequest = nil
                    }
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
                    if mappedRemoteTarget != nil || replacementBody != nil
                        || scriptedRequest != nil
                    {
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
                            if let scriptedRequest {
                                try? loopBoundSelf.value.applyEditedRequest(
                                    scriptedRequest,
                                    captured: scriptBaseRequest,
                                    channel: channel
                                )
                            }
                        }
                    }
                    await transaction.pause(.request)
                    let hit = BreakpointHit(
                        flowID: await transaction.flowID(),
                        phase: .request,
                        request: scriptedRequest ?? scriptBaseRequest
                    )
                    let decision = await gate.pause(hit)
                    channel.eventLoop.execute {
                        loopBoundSelf.value.applyRequestBreakpointDecision(
                            decision,
                            capturedRequest: scriptedRequest ?? scriptBaseRequest,
                            channel: channel
                        )
                    }
                } else {
                    channel.eventLoop.execute {
                        loopBoundSelf.value.continueAfterRequestBodyRules(
                            capturedRequest: capturedRequest,
                            mappedRemoteTarget: mappedRemoteTarget,
                            replacementBody: replacementBody,
                            scriptedRequest: scriptedRequest,
                            scriptBaseRequest: scriptBaseRequest,
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
        scriptedRequest: HTTPRequest? = nil,
        scriptBaseRequest: HTTPRequest? = nil,
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
        if let scriptedRequest {
            do {
                try applyEditedRequest(
                    scriptedRequest,
                    captured: scriptBaseRequest ?? capturedRequest,
                    channel: channel
                )
            } catch {
                scriptedRequestFailure(error, channel: channel)
                return
            }
        }
        pendingRequestBodyRuleSet = nil
        breakpointTask = nil
        pendingRequest = scriptedRequest ?? capturedRequest
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
            request: scriptedRequest ?? capturedRequest,
            clientChannel: channel,
            transaction: transaction
        )
    }

    private func bufferedRequestBodyData() -> Data {
        var data = Data()
        data.reserveCapacity(pendingRequestBytes)
        for part in pendingRequestParts {
            guard case .body(let body) = part, case .byteBuffer(let buffer) = body else {
                continue
            }
            data.append(contentsOf: buffer.readableBytesView)
        }
        return data
    }

    private func scriptedRequestFailure(_ error: Error, channel: Channel) {
        sendError(
            statusCode: 500,
            reason: "Internal Server Error",
            message: error.localizedDescription,
            channel: channel
        )
        let transaction = self.transaction
        Task { [transaction] in
            await transaction?.fail(.protocolError(error.localizedDescription))
        }
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
        let connectionRequest = HTTPRequest(
            method: request.method,
            url: target.url,
            headers: request.headers,
            body: request.body,
            version: request.version,
            rawTarget: request.rawTarget,
            graphqlOperation: request.graphqlOperation
        )
        let connectionPlan = RulePlanner.plan(
            rules: ruleSnapshot?.currentRules() ?? RuleSet(),
            context: RuleMatchContext(request: connectionRequest, source: flowSource),
            phase: .connection
        )
        let routedTarget = connectionPlan.dnsSpoofAddress.map(target.connecting(to:)) ?? target

        guard !connectionPlan.traces.isEmpty else {
            connectUpstreamUsingRoute(
                target: routedTarget,
                requestHead: requestHead,
                request: request,
                clientChannel: clientChannel,
                transaction: transaction
            )
            return
        }

        let loopBoundSelf = NIOLoopBound(self, eventLoop: clientChannel.eventLoop)
        Task {
            await transaction.appendRuleTraces(connectionPlan.traces)
            clientChannel.eventLoop.execute {
                guard clientChannel.isActive else {
                    return
                }
                loopBoundSelf.value.connectUpstreamUsingRoute(
                    target: routedTarget,
                    requestHead: requestHead,
                    request: request,
                    clientChannel: clientChannel,
                    transaction: transaction
                )
            }
        }
    }

    private func connectUpstreamUsingRoute(
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
        let serverSentEventEventSink = self.serverSentEventEventSink
        let webSocketFrameEventSink = self.webSocketFrameEventSink
        let maximumWebSocketFrameBytes = self.maximumWebSocketFrameBytes
        let webSocketConnectionRegistry = self.webSocketConnectionRegistry
        let ruleSnapshot = self.ruleSnapshot
        let scriptExecutor = self.scriptExecutor
        let breakpointGate = self.breakpointGate
        let flowSource = self.flowSource
        let throttleProfile = pendingThrottleProfile
        let loopBoundSelf = NIOLoopBound(self, eventLoop: clientChannel.eventLoop)
        let responseHandler = UpstreamResponseHandler(
            clientChannel: clientChannel,
            clientHandler: loopBoundSelf,
            transaction: transaction,
            request: request,
            usesTLS: target.usesTLS,
            bodyStore: bodyStore,
            maximumCapturedBodyBytes: maximumCapturedBodyBytes,
            serverSentEventEventSink: serverSentEventEventSink,
            webSocketFrameEventSink: webSocketFrameEventSink,
            maximumWebSocketFrameBytes: maximumWebSocketFrameBytes,
            webSocketConnectionRegistry: webSocketConnectionRegistry,
            ruleSnapshot: ruleSnapshot,
            scriptExecutor: scriptExecutor,
            breakpointGate: breakpointGate,
            flowSource: flowSource,
            throttleProfile: throttleProfile
        )
        let usesExternalHTTPProxy = externalHTTPProxyRoute?.shouldProxy(target) == true

        if target.usesTLS,
            let upstreamHTTP2Pool,
            !usesExternalHTTPProxy,
            !HTTPConversion.isWebSocketUpgradeRequest(requestHead)
        {
            upstreamHTTP2Pool.openRequestChannel(
                target: target,
                on: clientChannel.eventLoop,
                responseHandler: responseHandler
            ).whenComplete { [loopBoundSelf] result in
                clientChannel.eventLoop.execute {
                    let handler = loopBoundSelf.value
                    switch result {
                    case .success(.stream(let channel, let connectionReused)):
                        var http2Head = requestHead
                        http2Head.version = NIOHTTP1.HTTPVersion(major: 2, minor: 0)
                        handler.beginForwardingRequest(
                            head: http2Head,
                            to: channel,
                            clientChannel: clientChannel,
                            upstreamHTTPVersion: .http2,
                            isConnectionReused: connectionReused
                        )
                    case .success(.http1Required):
                        handler.connectUpstreamHTTP1(
                            target: target,
                            requestHead: requestHead,
                            responseHandler: responseHandler,
                            clientChannel: clientChannel
                        )
                    case .failure(let error):
                        handler.handleUpstreamFailure(error, clientChannel: clientChannel)
                    }
                }
            }
            return
        }

        connectUpstreamHTTP1(
            target: target,
            requestHead: requestHead,
            responseHandler: responseHandler,
            clientChannel: clientChannel
        )
    }

    private func connectUpstreamHTTP1(
        target: ProxyTarget,
        requestHead: HTTPRequestHead,
        responseHandler: UpstreamResponseHandler,
        clientChannel: Channel
    ) {
        let upstreamTLSContext = self.upstreamTLSContext
        let externalHTTPProxyRoute = self.externalHTTPProxyRoute.flatMap {
            $0.shouldProxy(target) ? $0 : nil
        }
        let usesExternalConnectTunnel = externalHTTPProxyRoute != nil && target.usesTLS
        let forwardedHead: HTTPRequestHead
        do {
            if let externalHTTPProxyRoute, !target.usesTLS {
                forwardedHead = try externalHTTPProxyRoute.requestHead(
                    forwarding: requestHead,
                    to: target
                )
            } else {
                forwardedHead = requestHead
            }
        } catch {
            handleUpstreamFailure(error, clientChannel: clientChannel)
            return
        }
        let loopBoundSelf = NIOLoopBound(self, eventLoop: clientChannel.eventLoop)
        let bootstrap = ClientBootstrap(group: clientChannel.eventLoop)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer {
                [upstreamTLSContext, responseHandler] channel in
                let tlsFuture: EventLoopFuture<Void>
                if target.usesTLS, !usesExternalConnectTunnel {
                    do {
                        guard let upstreamTLSContext else {
                            throw TLSInterceptionError.missingUpstreamTLSContext
                        }
                        let tlsHandler = try NIOSSLClientHandler(
                            context: upstreamTLSContext,
                            serverHostname: target.tlsServerName
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
                    guard !usesExternalConnectTunnel else { return }
                    try HTTPClientPipeline.install(
                        on: channel,
                        responseHandler: responseHandler
                    )
                }
            }

        let connectionEndpoint = externalHTTPProxyRoute?.endpoint
        let connectionHost = connectionEndpoint?.host ?? target.connectionHost
        let connectionPort = Int(connectionEndpoint?.port ?? UInt16(target.port))
        bootstrap.connect(host: connectionHost, port: connectionPort).whenComplete {
            [loopBoundSelf] (result: Result<Channel, Error>) in
            clientChannel.eventLoop.execute {
                let handler = loopBoundSelf.value

                switch result {
                case .success(let channel):
                    if let externalHTTPProxyRoute, target.usesTLS {
                        handler.establishExternalHTTPProxyTunnel(
                            route: externalHTTPProxyRoute,
                            target: target,
                            channel: channel,
                            responseHandler: responseHandler,
                            clientChannel: clientChannel,
                            requestHead: forwardedHead
                        )
                    } else {
                        handler.beginForwardingRequest(
                            head: forwardedHead,
                            to: channel,
                            clientChannel: clientChannel,
                            upstreamHTTPVersion: .http11,
                            isConnectionReused: false
                        )
                    }
                case .failure(let error):
                    handler.handleUpstreamFailure(error, clientChannel: clientChannel)
                }
            }
        }
    }

    private func establishExternalHTTPProxyTunnel(
        route: ExternalHTTPProxyRoute,
        target: ProxyTarget,
        channel: Channel,
        responseHandler: UpstreamResponseHandler,
        clientChannel: Channel,
        requestHead: HTTPRequestHead
    ) {
        guard let upstreamTLSContext else {
            handleUpstreamFailure(
                TLSInterceptionError.missingUpstreamTLSContext,
                clientChannel: clientChannel
            )
            channel.close(promise: nil)
            return
        }

        let readyPromise = channel.eventLoop.makePromise(of: Channel.self)
        let request = route.connectRequestBytes(
            to: target,
            allocator: channel.allocator
        )
        let connectHandler = HTTPUpstreamProxyConnectHandler(
            request: request,
            readyPromise: readyPromise
        ) { channel in
            channel.eventLoop.makeCompletedFuture(
                Result<Void, Error> {
                    let tlsHandler = try NIOSSLClientHandler(
                        context: upstreamTLSContext,
                        serverHostname: target.tlsServerName
                    )
                    try channel.pipeline.syncOperations.addHandler(
                        tlsHandler,
                        name: "proxylens.external-proxy.origin-tls"
                    )
                    try HTTPClientPipeline.install(
                        on: channel,
                        responseHandler: responseHandler
                    )
                }
            )
        }
        channel.pipeline.addHandler(connectHandler).flatMap {
            readyPromise.futureResult
        }.whenComplete {
            [loopBoundSelf = NIOLoopBound(self, eventLoop: clientChannel.eventLoop)]
            result in
            clientChannel.eventLoop.execute {
                let handler = loopBoundSelf.value
                switch result {
                case .success(let tunnelChannel):
                    handler.beginForwardingRequest(
                        head: requestHead,
                        to: tunnelChannel,
                        clientChannel: clientChannel,
                        upstreamHTTPVersion: .http11,
                        isConnectionReused: false
                    )
                case .failure(let error):
                    handler.handleUpstreamFailure(error, clientChannel: clientChannel)
                }
            }
        }
    }

    private func beginForwardingRequest(
        head: HTTPRequestHead,
        to channel: Channel,
        clientChannel: Channel,
        upstreamHTTPVersion: ProxyLensCore.HTTPVersion,
        isConnectionReused: Bool
    ) {
        upstreamChannel = channel
        isWaitingForThrottleLatency = false
        updateClientAutoRead(clientChannel)
        if let transaction {
            Task { [transaction] in
                await transaction.markUpstreamConnected(
                    at: Date(),
                    upstreamHTTPVersion: upstreamHTTPVersion,
                    isConnectionReused: isConnectionReused
                )
            }
        }

        channel.write(HTTPClientRequestPart.head(head), promise: nil)
        var forwardedEnd = false
        for part in pendingRequestParts {
            switch part {
            case .body(let body):
                if case .byteBuffer(let buffer) = body {
                    forwardRequestBody(
                        buffer,
                        to: channel,
                        clientChannel: clientChannel
                    )
                } else {
                    channel.write(part, promise: nil)
                }
            case .end:
                forwardedEnd = true
                forwardRequestEnd(part, to: channel)
            case .head:
                channel.write(part, promise: nil)
            }
        }
        pendingRequestParts.removeAll(keepingCapacity: false)
        pendingRequestBytes = 0

        if requestEnded, !forwardedEnd {
            channel.flush()
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
            version: HTTPConversion.nioVersion(from: response.version),
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
    private let serverSentEventEventSink: any ServerSentEventEventSink
    private let webSocketFrameEventSink: any WebSocketFrameEventSink
    private let maximumWebSocketFrameBytes: Int
    private let webSocketConnectionRegistry: NIOWebSocketConnectionRegistry
    private let ruleSnapshot: (any RuleSnapshotSource)?
    private let scriptExecutor: (any ScriptExecutor)?
    private let breakpointGate: any BreakpointGate
    private let flowSource: FlowSource
    private let throttleProfile: ThrottleProfile?
    private var responseStarted = false
    private var responseBodyRecorder: StreamingBodyRecorder?
    private var responseHeadTask: Task<Void, Never>?
    private var responseBodyWriteTask: Task<Void, Error>?
    private var serverSentEventDecoder: ServerSentEventStreamDecoder?
    private var serverSentEventParser: ServerSentEventStreamParser?
    private var serverSentEventRecorder: ServerSentEventRecorder?
    private var serverSentEventWriteTask: Task<Void, Never>?
    private var serverSentEventSequenceNumber: Int64 = 0
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
    private var pendingResponseScripts: [PlannedScript] = []
    private var isEvaluatingResponseHeaderScripts = false
    private var upstreamBecameInactiveDuringHeaderScripts = false
    private var didReceiveResponseEnd = false
    private var queuedResponseParts: [HTTPClientResponsePart] = []
    private var queuedResponseBytes = 0
    private var breakpointTask: Task<Void, Never>?
    private var didHandleUpstreamFailure = false
    private var isWebSocketUpgrade = false

    private var isWaitingOnCompleteBufferedResponse: Bool {
        (pendingResponseBreakpoint || !pendingResponseScripts.isEmpty) && breakpointTask != nil
    }

    init(
        clientChannel: Channel,
        clientHandler: NIOLoopBound<HTTPProxyHandler>,
        transaction: FlowTransaction,
        request: HTTPRequest,
        usesTLS: Bool,
        bodyStore: (any BodyStore)?,
        maximumCapturedBodyBytes: Int64,
        serverSentEventEventSink: any ServerSentEventEventSink,
        webSocketFrameEventSink: any WebSocketFrameEventSink,
        maximumWebSocketFrameBytes: Int,
        webSocketConnectionRegistry: NIOWebSocketConnectionRegistry,
        ruleSnapshot: (any RuleSnapshotSource)?,
        scriptExecutor: (any ScriptExecutor)?,
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
        self.serverSentEventEventSink = serverSentEventEventSink
        self.webSocketFrameEventSink = webSocketFrameEventSink
        self.maximumWebSocketFrameBytes = min(max(1, maximumWebSocketFrameBytes), Int(UInt32.max))
        self.webSocketConnectionRegistry = webSocketConnectionRegistry
        self.ruleSnapshot = ruleSnapshot
        self.scriptExecutor = scriptExecutor
        self.breakpointGate = breakpointGate
        self.flowSource = flowSource
        self.throttleProfile = throttleProfile
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let responsePart = Self.unwrapInboundIn(data)

        if isEvaluatingResponseHeaderScripts {
            if case .body(let buffer) = responsePart {
                queuedResponseBytes += buffer.readableBytes
                guard queuedResponseBytes <= ScriptExecutionLimits.maximumInputByteCount else {
                    failUpstream(
                        error: ProxyLensError.unsupportedOperation(
                            "The response exceeded the header-script gate buffer limit"
                        ),
                        context: context
                    )
                    return
                }
            }
            queuedResponseParts.append(responsePart)
            return
        }

        processResponsePart(responsePart, context: context)
    }

    private func processResponsePart(
        _ responsePart: HTTPClientResponsePart,
        context: ChannelHandlerContext
    ) {
        switch responsePart {
        case .head(let head):
            responseStarted = true
            do {
                let coreHeaders = try HTTPConversion.coreHeaders(from: head.headers)
                let upstreamVersion = try HTTPConversion.coreVersion(from: head.version)
                let downstreamVersion: ProxyLensCore.HTTPVersion =
                    if request.version == .http2 || upstreamVersion == .http2 {
                        request.version
                    } else {
                        upstreamVersion
                    }
                var response = try HTTPResponse(
                    statusCode: Int(head.status.code),
                    reasonPhrase: head.status.reasonPhrase,
                    headers: coreHeaders,
                    version: downstreamVersion
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
                    if Self.isEventStream(response) {
                        let maximumEventDataBytes = min(
                            maximumCapturedBodyBytes,
                            Self.maximumServerSentEventDataBytes
                        )
                        let contentEncoding = response.headers
                            .values(for: "Content-Encoding")
                            .joined(separator: ",")
                        let maximumDecodedByteCount = Int(
                            min(maximumCapturedBodyBytes, Int64(Int.max))
                        )
                        if let decoder = try? ServerSentEventStreamDecoder(
                            contentEncoding: contentEncoding,
                            maximumDecodedByteCount: maximumDecodedByteCount
                        ) {
                            serverSentEventDecoder = decoder
                            serverSentEventParser = ServerSentEventStreamParser(
                                maximumEventDataBytes: Int(maximumEventDataBytes)
                            )
                            serverSentEventRecorder = ServerSentEventRecorder(
                                bodyStore: bodyStore,
                                maximumCapturedDataBytes: maximumEventDataBytes,
                                eventSink: serverSentEventEventSink
                            )
                        }
                    }
                }
                let transaction = self.transaction
                let receivedAt = Date()
                var traces = responsePlan.traces + responseBodyPlan.traces
                if !responseBodyPlan.scripts.isEmpty {
                    if responsePlan.shouldBreakpoint {
                        traces.append(
                            contentsOf: BodyScriptRunner.failureTraces(
                                scripts: responseBodyPlan.scripts,
                                hook: .response,
                                error: ProxyLensError.unsupportedOperation(
                                    "Response body scripts cannot run with a response breakpoint yet"
                                )
                            )
                        )
                    } else if isWebSocketUpgrade || Self.isEventStream(response) {
                        traces.append(
                            contentsOf: BodyScriptRunner.failureTraces(
                                scripts: responseBodyPlan.scripts,
                                hook: .response,
                                error: ProxyLensError.unsupportedOperation(
                                    "Streaming responses cannot run body scripts"
                                )
                            )
                        )
                    } else {
                        pendingResponseScripts = responseBodyPlan.scripts
                    }
                }
                let capturedResponse = response
                responseHeadTask = Task { [transaction] in
                    await transaction.appendRuleTraces(traces)
                    await transaction.receiveResponse(capturedResponse, at: receivedAt)
                }
                var forwardedHead = head
                forwardedHead.version = HTTPConversion.nioVersion(from: downstreamVersion)
                if responsePlan.applyNoCache {
                    forwardedHead.headers = HTTPConversion.nioHeaders(from: response.headers)
                }
                if let pendingResponseReplacement {
                    forwardedHead = Self.replacingBody(
                        in: forwardedHead,
                        with: pendingResponseReplacement
                    )
                }
                if !responsePlan.scripts.isEmpty {
                    beginResponseHeaderScriptEvaluation(
                        scripts: responsePlan.scripts,
                        responsePlan: responsePlan,
                        forwardedResponse: response,
                        forwardedHead: forwardedHead,
                        context: context
                    )
                } else {
                    dispatchResponseHead(
                        responsePlan: responsePlan,
                        forwardedResponse: response,
                        forwardedHead: forwardedHead
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
            recordServerSentEvents(buffer)
            if pendingResponseBreakpoint || !pendingResponseScripts.isEmpty {
                let byteCount = buffer.readableBytes
                let maximumBufferedBytes =
                    pendingResponseBreakpoint
                    ? maximumCapturedBodyBytes
                    : min(
                        maximumCapturedBodyBytes,
                        Int64(ScriptExecutionLimits.maximumBodyByteCount)
                    )
                if Int64(pendingResponseBytes + byteCount) > maximumBufferedBytes {
                    if !pendingResponseBreakpoint {
                        failOpenResponseScriptsForOversizedBody(
                            currentBuffer: buffer,
                            context: context
                        )
                        return
                    }
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
            didReceiveResponseEnd = true
            if isWebSocketUpgrade {
                beginWebSocketBridge(trailers: trailers, context: context)
                return
            }
            if pendingResponseBreakpoint {
                pendingResponseTrailers = trailers
                beginResponseBreakpoint(context: context)
                return
            }
            if !pendingResponseScripts.isEmpty {
                pendingResponseTrailers = trailers
                beginResponseBodyScriptEvaluation(context: context)
                return
            }
            clientHandler.value.markResponseEnded()
            finishServerSentEventCapture(receivedAt: Date())
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

    private func beginResponseHeaderScriptEvaluation(
        scripts: [PlannedScript],
        responsePlan: RulePlan,
        forwardedResponse: HTTPResponse,
        forwardedHead: HTTPResponseHead,
        context: ChannelHandlerContext
    ) {
        isEvaluatingResponseHeaderScripts = true
        updateUpstreamAutoRead(context.channel)
        let executor = scriptExecutor
        let initialMessage = HeaderScriptRunner.responseMessage(forwardedResponse)
        let policy: HeaderScriptPolicy =
            isWebSocketUpgrade ? .webSocketHandshake : .http
        let transaction = self.transaction
        let headTask = responseHeadTask
        let upstreamChannel = context.channel
        let loopBoundSelf = NIOLoopBound(self, eventLoop: context.eventLoop)
        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        breakpointTask = Task {
            await headTask?.value
            let result = await HeaderScriptRunner.run(
                scripts: scripts,
                hook: .response,
                phase: .responseHeaders,
                initialMessage: initialMessage,
                executor: executor,
                policy: policy
            )
            let scriptedResponse: HTTPResponse
            do {
                scriptedResponse = try HeaderScriptRunner.response(
                    from: result.message,
                    preserving: forwardedResponse
                )
                await transaction.appendRuleTraces(result.traces)
            } catch {
                scriptedResponse = forwardedResponse
                await transaction.appendRuleTraces(
                    HeaderScriptRunner.failureTraces(
                        scripts: scripts,
                        phase: .responseHeaders,
                        error: error
                    )
                )
            }
            upstreamChannel.eventLoop.execute {
                loopBoundSelf.value.continueAfterResponseHeaderScripts(
                    responsePlan: responsePlan,
                    forwardedResponse: scriptedResponse,
                    forwardedHead: forwardedHead,
                    context: loopBoundContext.value
                )
            }
        }
    }

    private func continueAfterResponseHeaderScripts(
        responsePlan: RulePlan,
        forwardedResponse: HTTPResponse,
        forwardedHead: HTTPResponseHead,
        context: ChannelHandlerContext
    ) {
        let upstreamChannel = context.channel
        guard clientChannel.isActive else {
            isEvaluatingResponseHeaderScripts = false
            upstreamChannel.close(promise: nil)
            return
        }
        var scriptedHead = forwardedHead
        scriptedHead.status = HTTPResponseStatus(statusCode: forwardedResponse.statusCode)
        scriptedHead.headers = HTTPConversion.nioHeaders(from: forwardedResponse.headers)
        if let pendingResponseReplacement {
            scriptedHead = Self.replacingBody(
                in: scriptedHead,
                with: pendingResponseReplacement
            )
        }
        isWebSocketUpgrade = Self.isWebSocketUpgrade(
            request: request,
            responseHead: scriptedHead
        )
        isEvaluatingResponseHeaderScripts = false
        breakpointTask = nil
        dispatchResponseHead(
            responsePlan: responsePlan,
            forwardedResponse: forwardedResponse,
            forwardedHead: scriptedHead
        )

        let queuedParts = queuedResponseParts
        queuedResponseParts = []
        queuedResponseBytes = 0
        for part in queuedParts {
            processResponsePart(part, context: context)
        }
        if upstreamBecameInactiveDuringHeaderScripts, !didReceiveResponseEnd {
            failUpstream(error: nil, context: context)
        } else if upstreamChannel.isActive {
            updateUpstreamAutoRead(upstreamChannel)
        }
    }

    private func dispatchResponseHead(
        responsePlan: RulePlan,
        forwardedResponse: HTTPResponse,
        forwardedHead: HTTPResponseHead
    ) {
        if responsePlan.shouldBreakpoint, !isWebSocketUpgrade {
            pendingResponseBreakpoint = true
            pendingResponse = forwardedResponse
            pendingResponseHead = HTTPConversion.sanitizedResponseHead(
                forwardedHead,
                preservingWebSocketUpgrade: isWebSocketUpgrade
            )
        } else if !pendingResponseScripts.isEmpty {
            pendingResponse = forwardedResponse
            pendingResponseHead = HTTPConversion.sanitizedResponseHead(
                forwardedHead,
                preservingWebSocketUpgrade: false
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
        let flowFuture = context.eventLoop.makeFutureWithTask {
            await headTask?.value
            return await transaction.snapshot()
        }
        let upstreamChannel = context.channel
        let bodyStore = self.bodyStore
        let maximumCapturedFrameBytes = min(
            maximumCapturedBodyBytes,
            Int64(maximumWebSocketFrameBytes)
        )
        let maximumFrameBytes = maximumWebSocketFrameBytes
        let frameEventSink = webSocketFrameEventSink
        let webSocketConnectionRegistry = self.webSocketConnectionRegistry
        let ruleSnapshot = self.ruleSnapshot
        let breakpointGate = self.breakpointGate
        clientChannel.writeAndFlush(HTTPServerResponsePart.end(nil)).flatMap {
            flowFuture
        }.flatMap { flow in
            WebSocketBridge.install(
                clientChannel: self.clientChannel,
                upstreamChannel: upstreamChannel,
                transaction: transaction,
                flowID: flow.id,
                usesTLS: self.usesTLS,
                bodyStore: bodyStore,
                maximumCapturedFrameBytes: maximumCapturedFrameBytes,
                maximumFrameBytes: maximumFrameBytes,
                eventSink: frameEventSink,
                connectionRegistry: webSocketConnectionRegistry,
                ruleSnapshot: ruleSnapshot,
                ruleContext: RuleMatchContext(flow: flow),
                breakpointGate: breakpointGate
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
        if isEvaluatingResponseHeaderScripts {
            upstreamBecameInactiveDuringHeaderScripts = true
            context.fireChannelInactive()
            return
        }
        if isWaitingOnCompleteBufferedResponse {
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

    private func beginResponseBodyScriptEvaluation(context: ChannelHandlerContext) {
        guard let capturedResponse = pendingResponse, !pendingResponseScripts.isEmpty else {
            return
        }
        let scripts = pendingResponseScripts
        let writeTask = responseBodyWriteTask
        let headTask = responseHeadTask
        let recorder = responseBodyRecorder
        let transaction = self.transaction
        let scriptExecutor = self.scriptExecutor
        let bufferedBody = bufferedResponseBodyData()
        let replacementBody = pendingResponseReplacement
        let completedAt = Date()
        let upstreamChannel = context.channel
        let loopBoundSelf = NIOLoopBound(self, eventLoop: context.eventLoop)
        let clientChannel = self.clientChannel

        let task = Task {
            await headTask?.value
            do {
                try await writeTask?.value
                let reference = try await recorder?.finalize()
                let scriptBaseResponse =
                    if let replacementBody {
                        capturedResponse.replacingBody(replacementBody)
                    } else {
                        capturedResponse
                    }
                let bodyData = replacementBody?.inlineData ?? bufferedBody
                let forwardedResponse: HTTPResponse
                do {
                    let initialMessage = try BodyScriptRunner.responseMessage(
                        response: scriptBaseResponse,
                        bodyData: bodyData
                    )
                    let result = await BodyScriptRunner.run(
                        scripts: scripts,
                        hook: .response,
                        initialMessage: initialMessage,
                        executor: scriptExecutor
                    )
                    await transaction.appendRuleTraces(result.traces)
                    forwardedResponse = try BodyScriptRunner.response(
                        from: result.message,
                        preserving: scriptBaseResponse
                    )
                } catch {
                    await transaction.appendRuleTraces(
                        BodyScriptRunner.failureTraces(
                            scripts: scripts,
                            hook: .response,
                            error: error
                        )
                    )
                    forwardedResponse = scriptBaseResponse
                }
                await transaction.finishResponse(reference, at: completedAt)
                upstreamChannel.eventLoop.execute {
                    loopBoundSelf.value.replayScriptedResponse(
                        forwardedResponse,
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

    private func replayScriptedResponse(
        _ response: HTTPResponse,
        upstreamChannel: Channel
    ) {
        guard clientChannel.isActive else {
            upstreamChannel.close(promise: nil)
            return
        }
        clientHandler.value.markResponseEnded()
        let body = response.body?.inlineData ?? Data()
        let bodyReference = BodyReference(
            inline: body,
            metadata: BodyMetadata(
                contentType: response.headers.firstValue(for: "Content-Type"),
                contentEncoding: response.headers.firstValue(for: "Content-Encoding")
            )
        )
        var head = HTTPResponseHead(
            version: HTTPConversion.nioVersion(from: response.version),
            status: HTTPResponseStatus(statusCode: response.statusCode),
            headers: HTTPConversion.nioHeaders(from: response.headers)
        )
        head = Self.replacingBody(in: head, with: bodyReference)
        clientChannel.write(
            HTTPServerResponsePart.head(
                HTTPConversion.sanitizedResponseHead(
                    head,
                    preservingWebSocketUpgrade: false
                )
            ),
            promise: nil
        )
        writeReplacementBody(bodyReference, upstreamChannel: upstreamChannel)
        finishForwardedResponse(trailers: nil, upstreamChannel: upstreamChannel)
        pendingResponseScripts = []
        breakpointTask = nil
        upstreamChannel.close(promise: nil)
    }

    private func bufferedResponseBodyData() -> Data {
        var data = Data()
        data.reserveCapacity(pendingResponseBytes)
        for buffer in pendingResponseBuffers {
            data.append(contentsOf: buffer.readableBytesView)
        }
        return data
    }

    private func failOpenResponseScriptsForOversizedBody(
        currentBuffer: ByteBuffer,
        context: ChannelHandlerContext
    ) {
        let traces = BodyScriptRunner.failureTraces(
            scripts: pendingResponseScripts,
            hook: .response,
            error: ScriptExecutionError.bodyTooLarge(
                maximumByteCount: ScriptExecutionLimits.maximumBodyByteCount
            )
        )
        let transaction = self.transaction
        let precedingHeadTask = responseHeadTask
        responseHeadTask = Task { [transaction, precedingHeadTask] in
            await precedingHeadTask?.value
            await transaction.appendRuleTraces(traces)
        }
        pendingResponseScripts = []
        if let head = pendingResponseHead {
            clientChannel.write(HTTPServerResponsePart.head(head), promise: nil)
        }
        for buffer in pendingResponseBuffers {
            forwardResponseBody(buffer, upstreamChannel: context.channel)
        }
        forwardResponseBody(currentBuffer, upstreamChannel: context.channel)
        pendingResponseBuffers = []
        pendingResponseBytes = 0
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

    private static func isEventStream(_ response: HTTPResponse) -> Bool {
        let mediaType =
            response.headers.firstValue(for: "Content-Type")?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return mediaType?.caseInsensitiveCompare("text/event-stream") == .orderedSame
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

    private func recordServerSentEvents(_ buffer: ByteBuffer) {
        guard
            buffer.readableBytes > 0,
            let decoder = serverSentEventDecoder,
            var parser = serverSentEventParser
        else {
            return
        }
        do {
            let decoded = try decoder.append(Data(buffer.readableBytesView))
            let events = parser.append(decoded, receivedAt: Date())
            serverSentEventParser = parser
            enqueueServerSentEvents(events)
        } catch {
            stopServerSentEventCapture()
        }
    }

    private func finishServerSentEventCapture(receivedAt: Date) {
        guard let decoder = serverSentEventDecoder, var parser = serverSentEventParser else {
            return
        }
        do {
            let decoded = try decoder.finish()
            var events = parser.append(decoded, receivedAt: receivedAt)
            events.append(contentsOf: parser.finish(receivedAt: receivedAt))
            enqueueServerSentEvents(events)
            stopServerSentEventCapture()
        } catch {
            stopServerSentEventCapture()
        }
    }

    private func stopServerSentEventCapture() {
        serverSentEventDecoder = nil
        serverSentEventParser = nil
        serverSentEventRecorder = nil
    }

    private func enqueueServerSentEvents(_ events: [ParsedServerSentEvent]) {
        guard !events.isEmpty, let recorder = serverSentEventRecorder else {
            return
        }

        let firstSequenceNumber = serverSentEventSequenceNumber + 1
        serverSentEventSequenceNumber += Int64(events.count)
        let previousTask = serverSentEventWriteTask
        let transaction = self.transaction
        serverSentEventWriteTask = Task {
            await previousTask?.value
            let flowID = await transaction.flowID()
            for (offset, event) in events.enumerated() {
                try? await recorder.record(
                    event,
                    flowID: flowID,
                    sequenceNumber: firstSequenceNumber + Int64(offset)
                )
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
            && !isEvaluatingResponseHeaderScripts
        channel.setOption(ChannelOptions.autoRead, value: shouldRead).whenFailure { _ in
            channel.close(promise: nil)
        }
    }

    private static let throttleQueueHighWatermark = 256 * 1_024
    private static let throttleQueueLowWatermark = 128 * 1_024
    private static let maximumServerSentEventDataBytes: Int64 = 1_024 * 1_024

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
        if isWaitingOnCompleteBufferedResponse {
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
