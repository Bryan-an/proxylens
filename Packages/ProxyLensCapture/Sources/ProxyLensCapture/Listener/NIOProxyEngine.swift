import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import ProxyLensCore

/// A local HTTP/1.1 and HTTPS-intercepting forwarding proxy backed by SwiftNIO.
public actor NIOProxyEngine: ProxyEngine {
    private let eventLoopThreadCount: Int
    private let eventSink: any FlowEventSink
    private let webSocketFrameEventSink: any WebSocketFrameEventSink
    private let maxPendingRequestBytes: Int
    private let bodyStore: (any BodyStore)?
    private let maximumCapturedBodyBytes: Int64
    private let maximumWebSocketFrameBytes: Int
    private let certificateProvider: (any CertificateProvider)?
    private let upstreamTLSConfiguration: UpstreamTLSConfiguration
    private let ruleSnapshot: (any RuleSnapshotSource)?
    private let breakpointGate: any BreakpointGate
    private let flowSourceResolver: any FlowSourceResolver

    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var serverChannel: Channel?
    private var currentState: ProxyEngineState = .stopped

    public init(
        eventLoopThreads: Int = 1,
        eventSink: any FlowEventSink = NoOpFlowEventSink(),
        webSocketFrameEventSink: (any WebSocketFrameEventSink)? = nil,
        maxPendingRequestBytes: Int = 1_048_576,
        bodyStore: (any BodyStore)? = nil,
        maximumCapturedBodyBytes: Int64 = 50 * 1_024 * 1_024,
        maximumWebSocketFrameBytes: Int = 16 * 1_024 * 1_024,
        certificateProvider: (any CertificateProvider)? = nil,
        upstreamTLSConfiguration: UpstreamTLSConfiguration = UpstreamTLSConfiguration(),
        ruleSnapshot: (any RuleSnapshotSource)? = nil,
        breakpointGate: any BreakpointGate = ImmediateBreakpointGate(),
        flowSourceResolver: any FlowSourceResolver = UnknownFlowSourceResolver()
    ) {
        self.eventLoopThreadCount = max(1, eventLoopThreads)
        self.eventSink = eventSink
        self.webSocketFrameEventSink = webSocketFrameEventSink ?? NoOpWebSocketFrameEventSink()
        self.maxPendingRequestBytes = max(1, maxPendingRequestBytes)
        self.bodyStore = bodyStore
        self.maximumCapturedBodyBytes = max(0, maximumCapturedBodyBytes)
        self.maximumWebSocketFrameBytes = min(
            max(1, maximumWebSocketFrameBytes),
            Int(UInt32.max)
        )
        self.certificateProvider = certificateProvider
        self.upstreamTLSConfiguration = upstreamTLSConfiguration
        self.ruleSnapshot = ruleSnapshot
        self.breakpointGate = breakpointGate
        self.flowSourceResolver = flowSourceResolver
    }

    public func start(configuration: ProxyConfiguration, sessionID: SessionID) async throws {
        guard serverChannel == nil else {
            throw ProxyLensError.unsupportedOperation("The proxy is already running")
        }

        currentState = .starting

        if configuration.interceptHTTPS, certificateProvider == nil {
            currentState = .failed(
                TLSInterceptionError.missingCertificateProvider.localizedDescription)
            throw TLSInterceptionError.missingCertificateProvider
        }

        let upstreamTLSContext: NIOSSLContext
        do {
            upstreamTLSContext = try TLSContextFactory.upstreamContext(
                configuration: upstreamTLSConfiguration
            )
        } catch {
            currentState = .failed(error.localizedDescription)
            throw error
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: eventLoopThreadCount)
        eventLoopGroup = group
        let interceptHTTPS = configuration.interceptHTTPS

        do {
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 256)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer {
                    [
                        eventSink,
                        webSocketFrameEventSink,
                        sessionID,
                        maxPendingRequestBytes,
                        bodyStore,
                        maximumCapturedBodyBytes,
                        maximumWebSocketFrameBytes,
                        certificateProvider,
                        upstreamTLSContext,
                        ruleSnapshot,
                        breakpointGate,
                        flowSourceResolver
                    ] channel in
                    let sourceFuture: EventLoopFuture<FlowSource>
                    if let clientEndpoint = Self.endpoint(channel.remoteAddress),
                        let proxyEndpoint = Self.endpoint(channel.localAddress)
                    {
                        sourceFuture = channel.eventLoop.makeFutureWithTask {
                            await flowSourceResolver.resolveSource(
                                clientEndpoint: clientEndpoint,
                                proxyEndpoint: proxyEndpoint
                            )
                        }
                    } else {
                        sourceFuture = channel.eventLoop.makeSucceededFuture(.desktopProxy)
                    }
                    return sourceFuture.flatMapThrowing { flowSource in
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
                                interceptHTTPS: interceptHTTPS,
                                certificateProvider: certificateProvider,
                                upstreamTLSContext: upstreamTLSContext,
                                tunnelTarget: nil,
                                ruleSnapshot: ruleSnapshot,
                                breakpointGate: breakpointGate,
                                flowSource: flowSource
                            )
                        )
                    }
                }
                .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)

            let channel = try await bootstrap.bind(
                host: configuration.listenEndpoint.host,
                port: Int(configuration.listenEndpoint.port)
            ).get()

            guard let localAddress = channel.localAddress,
                let port = localAddress.port,
                let boundPort = UInt16(exactly: port)
            else {
                try? await channel.close().get()
                await shutdown(group)
                eventLoopGroup = nil
                throw ProxyLensError.unsupportedOperation("The proxy listener has no local address")
            }

            serverChannel = channel
            currentState = .running(
                NetworkEndpoint(
                    host: localAddress.ipAddress ?? configuration.listenEndpoint.host,
                    port: boundPort
                )
            )
        } catch {
            currentState = .failed(error.localizedDescription)
            await shutdown(group)
            eventLoopGroup = nil
            throw error
        }
    }

    public func stop() async {
        guard currentState != .stopped || serverChannel != nil else {
            return
        }

        currentState = .stopping
        if let serverChannel {
            _ = try? await serverChannel.close().get()
            _ = try? await serverChannel.closeFuture.get()
        }

        if let eventLoopGroup {
            await shutdown(eventLoopGroup)
        }

        serverChannel = nil
        eventLoopGroup = nil
        currentState = .stopped
    }

    public func state() async -> ProxyEngineState {
        currentState
    }

    private func shutdown(_ group: MultiThreadedEventLoopGroup) async {
        await withCheckedContinuation { continuation in
            group.shutdownGracefully { _ in
                continuation.resume()
            }
        }
    }

    private static func endpoint(_ address: SocketAddress?) -> NetworkEndpoint? {
        guard let address, let port = address.port, let endpointPort = UInt16(exactly: port) else {
            return nil
        }
        return NetworkEndpoint(host: address.ipAddress ?? "localhost", port: endpointPort)
    }
}
