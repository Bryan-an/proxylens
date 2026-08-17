import Foundation
import NIOCore
import NIOSSL
import ProxyLensCore

final class SOCKS5ServerHandler: ChannelInboundHandler, RemovableChannelHandler,
    @unchecked Sendable
{
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum ApplicationProtocol {
        case http
        case tls
        case needMore
        case unsupported
    }

    private static let maximumProtocolPrefixBytes = 16
    private static let httpMethodPrefixes = [
        "GET ", "POST ", "PUT ", "DELETE ", "PATCH ", "HEAD ", "OPTIONS ", "TRACE ",
        "CONNECT "
    ].map { Array($0.utf8) }

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
    private let upstreamTLSContext: NIOSSLContext
    private let upstreamHTTP2Pool: HTTP2UpstreamConnectionPool
    private let externalHTTPProxyRoute: ExternalHTTPProxyRoute?
    private let ruleSnapshot: (any RuleSnapshotSource)?
    private let scriptExecutor: (any ScriptExecutor)?
    private let breakpointGate: any BreakpointGate
    private let flowSource: FlowSource

    private var parser = SOCKS5HandshakeParser()
    private var target: ConnectTarget?
    private var applicationBuffers: [ByteBuffer] = []
    private var applicationPrefix: [UInt8] = []
    private var isPreparingTLS = false
    private var isClosing = false

    init(
        sessionID: SessionID,
        eventSink: any FlowEventSink,
        serverSentEventEventSink: any ServerSentEventEventSink,
        webSocketFrameEventSink: any WebSocketFrameEventSink,
        maxPendingRequestBytes: Int,
        bodyStore: (any BodyStore)?,
        maximumCapturedBodyBytes: Int64,
        maximumWebSocketFrameBytes: Int,
        webSocketConnectionRegistry: NIOWebSocketConnectionRegistry,
        interceptHTTPS: Bool,
        certificateProvider: (any CertificateProvider)?,
        upstreamTLSContext: NIOSSLContext,
        upstreamHTTP2Pool: HTTP2UpstreamConnectionPool,
        externalHTTPProxyRoute: ExternalHTTPProxyRoute?,
        ruleSnapshot: (any RuleSnapshotSource)?,
        scriptExecutor: (any ScriptExecutor)?,
        breakpointGate: any BreakpointGate,
        flowSource: FlowSource
    ) {
        self.sessionID = sessionID
        self.eventSink = eventSink
        self.serverSentEventEventSink = serverSentEventEventSink
        self.webSocketFrameEventSink = webSocketFrameEventSink
        self.maxPendingRequestBytes = maxPendingRequestBytes
        self.bodyStore = bodyStore
        self.maximumCapturedBodyBytes = maximumCapturedBodyBytes
        self.maximumWebSocketFrameBytes = maximumWebSocketFrameBytes
        self.webSocketConnectionRegistry = webSocketConnectionRegistry
        self.interceptHTTPS = interceptHTTPS
        self.certificateProvider = certificateProvider
        self.upstreamTLSContext = upstreamTLSContext
        self.upstreamHTTP2Pool = upstreamHTTP2Pool
        self.externalHTTPProxyRoute = externalHTTPProxyRoute
        self.ruleSnapshot = ruleSnapshot
        self.scriptExecutor = scriptExecutor
        self.breakpointGate = breakpointGate
        self.flowSource = flowSource
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !isClosing, !isPreparingTLS else { return }
        var inbound = Self.unwrapInboundIn(data)

        if target != nil {
            receiveApplicationBytes(inbound, context: context)
            return
        }

        let bytes = inbound.readBytes(length: inbound.readableBytes) ?? []
        for action in parser.receive(bytes) {
            switch action {
            case .write(let reply):
                var outbound = context.channel.allocator.buffer(capacity: reply.count)
                outbound.writeBytes(reply)
                context.write(Self.wrapOutboundOut(outbound), promise: nil)
            case .connect(let target, let leftover):
                self.target = target
                if !leftover.isEmpty {
                    var application = context.channel.allocator.buffer(capacity: leftover.count)
                    application.writeBytes(leftover)
                    receiveApplicationBytes(application, context: context)
                }
            case .close:
                closeAfterFlushing(context: context)
            }
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    func errorCaught(context: ChannelHandlerContext, error _: Error) {
        isClosing = true
        context.close(promise: nil)
    }

    private func receiveApplicationBytes(_ buffer: ByteBuffer, context: ChannelHandlerContext) {
        guard !isClosing, !isPreparingTLS else { return }
        applicationBuffers.append(buffer)
        if applicationPrefix.count < Self.maximumProtocolPrefixBytes {
            applicationPrefix.append(
                contentsOf: buffer.readableBytesView.prefix(
                    Self.maximumProtocolPrefixBytes - applicationPrefix.count
                )
            )
        }

        switch classifyApplicationPrefix() {
        case .http:
            installHTTPPipeline(context: context)
        case .tls:
            installTLSPipeline(context: context)
        case .needMore:
            break
        case .unsupported:
            isClosing = true
            context.close(promise: nil)
        }
    }

    private func classifyApplicationPrefix() -> ApplicationProtocol {
        if applicationPrefix.count >= 3, applicationPrefix[0] == 0x16,
            applicationPrefix[1] == 0x03, applicationPrefix[2] <= 0x04
        {
            return .tls
        }
        if applicationPrefix.first == 0x16, applicationPrefix.count < 3 {
            return .needMore
        }

        if Self.httpMethodPrefixes.contains(where: { applicationPrefix.starts(with: $0) }) {
            return .http
        }
        if applicationPrefix.count < Self.maximumProtocolPrefixBytes,
            Self.httpMethodPrefixes.contains(where: { $0.starts(with: applicationPrefix) })
        {
            return .needMore
        }
        return .unsupported
    }

    private func installHTTPPipeline(context: ChannelHandlerContext) {
        guard let target else {
            isClosing = true
            context.close(promise: nil)
            return
        }
        do {
            try HTTPServerPipeline.install(
                on: context.channel,
                handler: makeHTTPHandler(target: target, usesTLS: false)
            )
        } catch {
            isClosing = true
            context.close(promise: nil)
            return
        }
        replayApplicationBytesAfterRemoval(context: context)
    }

    private func installTLSPipeline(context: ChannelHandlerContext) {
        guard interceptHTTPS, let certificateProvider, let target else {
            isClosing = true
            context.close(promise: nil)
            return
        }
        isPreparingTLS = true
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
                    loopBoundSelf.value.finishTLSPipeline(
                        target: target,
                        serverTLSContext: serverTLSContext,
                        channel: channel
                    )
                }
            } catch {
                channel.eventLoop.execute {
                    loopBoundSelf.value.isClosing = true
                    channel.close(promise: nil)
                }
            }
        }
    }

    private func finishTLSPipeline(
        target: ConnectTarget,
        serverTLSContext: NIOSSLContext,
        channel: Channel
    ) {
        let sessionID = sessionID
        let eventSink = eventSink
        let serverSentEventEventSink = serverSentEventEventSink
        let webSocketFrameEventSink = webSocketFrameEventSink
        let maxPendingRequestBytes = maxPendingRequestBytes
        let bodyStore = bodyStore
        let maximumCapturedBodyBytes = maximumCapturedBodyBytes
        let maximumWebSocketFrameBytes = maximumWebSocketFrameBytes
        let webSocketConnectionRegistry = webSocketConnectionRegistry
        let certificateProvider = certificateProvider
        let upstreamTLSContext = upstreamTLSContext
        let upstreamHTTP2Pool = upstreamHTTP2Pool
        let externalHTTPProxyRoute = externalHTTPProxyRoute
        let ruleSnapshot = ruleSnapshot
        let scriptExecutor = scriptExecutor
        let breakpointGate = breakpointGate
        let flowSource = flowSource
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
                tunnelUsesTLS: true,
                externalHTTPProxyRoute: externalHTTPProxyRoute,
                ruleSnapshot: ruleSnapshot,
                scriptExecutor: scriptExecutor,
                breakpointGate: breakpointGate,
                flowSource: flowSource
            )
        }

        do {
            try channel.pipeline.syncOperations.addHandler(
                NIOSSLServerHandler(context: serverTLSContext),
                name: HTTPServerPipeline.tlsHandlerName
            )
        } catch {
            isClosing = true
            channel.close(promise: nil)
            return
        }

        HTTPServerPipeline.installNegotiatedHTTPS(
            on: channel,
            handlerFactory: handlerFactory
        ).flatMap {
            channel.pipeline.removeHandler(self)
        }.flatMap {
            self.replayApplicationBytes(on: channel)
            return channel.setOption(ChannelOptions.autoRead, value: true)
        }.whenFailure { _ in
            channel.close(promise: nil)
        }
    }

    private func makeHTTPHandler(target: ConnectTarget, usesTLS: Bool) -> HTTPProxyHandler {
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
            tunnelUsesTLS: usesTLS,
            externalHTTPProxyRoute: externalHTTPProxyRoute,
            ruleSnapshot: ruleSnapshot,
            scriptExecutor: scriptExecutor,
            breakpointGate: breakpointGate,
            flowSource: flowSource
        )
    }

    private func replayApplicationBytesAfterRemoval(context: ChannelHandlerContext) {
        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        let loopBoundSelf = NIOLoopBound(self, eventLoop: context.eventLoop)
        context.pipeline.removeHandler(self).whenComplete { result in
            switch result {
            case .success:
                loopBoundSelf.value.replayApplicationBytes(
                    on: loopBoundContext.value.channel
                )
            case .failure:
                loopBoundContext.value.close(promise: nil)
            }
        }
    }

    private func replayApplicationBytes(on channel: Channel) {
        let buffers = applicationBuffers
        applicationBuffers.removeAll(keepingCapacity: false)
        applicationPrefix.removeAll(keepingCapacity: false)
        for buffer in buffers {
            channel.pipeline.fireChannelRead(buffer)
        }
        channel.pipeline.fireChannelReadComplete()
    }

    private func closeAfterFlushing(context: ChannelHandlerContext) {
        guard !isClosing else { return }
        isClosing = true
        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        let empty = context.channel.allocator.buffer(capacity: 0)
        context.writeAndFlush(Self.wrapOutboundOut(empty)).whenComplete { _ in
            loopBoundContext.value.close(promise: nil)
        }
    }
}
