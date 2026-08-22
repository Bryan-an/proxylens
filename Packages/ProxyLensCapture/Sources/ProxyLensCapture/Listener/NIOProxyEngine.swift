import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import ProxyLensCore

/// A local HTTP/1.1 and HTTPS-intercepting forwarding proxy backed by SwiftNIO.
public actor NIOProxyEngine: ProxyEngine, WebSocketFrameTransmitter {
    private let eventLoopThreadCount: Int
    private let eventSink: any FlowEventSink
    private let serverSentEventEventSink: any ServerSentEventEventSink
    private let webSocketFrameEventSink: any WebSocketFrameEventSink
    private let maxPendingRequestBytes: Int
    private let bodyStore: (any BodyStore)?
    private let maximumCapturedBodyBytes: Int64
    private let maximumWebSocketFrameBytes: Int
    private let certificateProvider: (any CertificateProvider)?
    private let upstreamTLSConfiguration: UpstreamTLSConfiguration
    private let ruleSnapshot: (any RuleSnapshotSource)?
    private let tlsInterceptionPolicy: (any TLSInterceptionPolicySource)?
    private let scriptExecutor: (any ScriptExecutor)?
    private let breakpointGate: any BreakpointGate
    private let flowSourceResolver: any FlowSourceResolver
    private let externalHTTPProxyCredentialStore: (any ExternalHTTPProxyCredentialStoring)?
    private let webSocketConnections = NIOWebSocketConnectionRegistry()

    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var serverChannel: Channel?
    private var socks5Channel: Channel?
    private var reverseProxyChannels: [UUID: Channel] = [:]
    private var upstreamHTTP2Pool: HTTP2UpstreamConnectionPool?
    private var currentState: ProxyEngineState = .stopped

    public init(
        eventLoopThreads: Int = 1,
        eventSink: any FlowEventSink = NoOpFlowEventSink(),
        serverSentEventEventSink: (any ServerSentEventEventSink)? = nil,
        webSocketFrameEventSink: (any WebSocketFrameEventSink)? = nil,
        maxPendingRequestBytes: Int = 1_048_576,
        bodyStore: (any BodyStore)? = nil,
        maximumCapturedBodyBytes: Int64 = 50 * 1_024 * 1_024,
        maximumWebSocketFrameBytes: Int = 16 * 1_024 * 1_024,
        certificateProvider: (any CertificateProvider)? = nil,
        upstreamTLSConfiguration: UpstreamTLSConfiguration = UpstreamTLSConfiguration(),
        ruleSnapshot: (any RuleSnapshotSource)? = nil,
        tlsInterceptionPolicy: (any TLSInterceptionPolicySource)? = nil,
        scriptExecutor: (any ScriptExecutor)? = nil,
        breakpointGate: any BreakpointGate = ImmediateBreakpointGate(),
        flowSourceResolver: any FlowSourceResolver = UnknownFlowSourceResolver(),
        externalHTTPProxyCredentialStore: (any ExternalHTTPProxyCredentialStoring)? = nil
    ) {
        self.eventLoopThreadCount = max(1, eventLoopThreads)
        self.eventSink = eventSink
        self.serverSentEventEventSink =
            serverSentEventEventSink ?? NoOpServerSentEventEventSink()
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
        self.tlsInterceptionPolicy = tlsInterceptionPolicy
        self.scriptExecutor = scriptExecutor
        self.breakpointGate = breakpointGate
        self.flowSourceResolver = flowSourceResolver
        self.externalHTTPProxyCredentialStore = externalHTTPProxyCredentialStore
    }

    public func start(configuration: ProxyConfiguration, sessionID: SessionID) async throws {
        guard serverChannel == nil, socks5Channel == nil, reverseProxyChannels.isEmpty else {
            throw ProxyLensError.unsupportedOperation("The proxy is already running")
        }

        currentState = .starting

        do {
            try configuration.validateListeners()
        } catch {
            currentState = .failed(error.localizedDescription)
            throw error
        }

        if configuration.interceptHTTPS, certificateProvider == nil {
            currentState = .failed(
                TLSInterceptionError.missingCertificateProvider.localizedDescription)
            throw TLSInterceptionError.missingCertificateProvider
        }

        let externalHTTPProxyRoute: ExternalHTTPProxyRoute?
        do {
            externalHTTPProxyRoute = try await makeExternalHTTPProxyRoute(
                configuration.externalHTTPProxy
            )
        } catch {
            currentState = .failed(error.localizedDescription)
            throw error
        }

        let upstreamTLSContext: NIOSSLContext
        let upstreamHTTP2TLSContext: NIOSSLContext
        do {
            upstreamTLSContext = try TLSContextFactory.upstreamContext(
                configuration: upstreamTLSConfiguration
            )
            upstreamHTTP2TLSContext = try TLSContextFactory.upstreamHTTP2Context(
                configuration: upstreamTLSConfiguration
            )
        } catch {
            currentState = .failed(error.localizedDescription)
            throw error
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: eventLoopThreadCount)
        eventLoopGroup = group
        let upstreamHTTP2Pool = HTTP2UpstreamConnectionPool(
            tlsContext: upstreamHTTP2TLSContext
        )
        self.upstreamHTTP2Pool = upstreamHTTP2Pool
        let interceptHTTPS = configuration.interceptHTTPS

        func makeBootstrap(reverseProxyRoute: ReverseProxyRoute?) -> ServerBootstrap {
            ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 256)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer {
                    [
                        eventSink,
                        serverSentEventEventSink,
                        webSocketFrameEventSink,
                        sessionID,
                        maxPendingRequestBytes,
                        bodyStore,
                        maximumCapturedBodyBytes,
                        maximumWebSocketFrameBytes,
                        webSocketConnections,
                        certificateProvider,
                        upstreamTLSContext,
                        upstreamHTTP2Pool,
                        ruleSnapshot,
                        tlsInterceptionPolicy,
                        scriptExecutor,
                        breakpointGate,
                        flowSourceResolver,
                        reverseProxyRoute,
                        externalHTTPProxyRoute
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
                    return sourceFuture.map { flowSource in
                        guard let reverseProxyRoute else { return flowSource }
                        return FlowSource.reverseProxy(
                            name: reverseProxyRoute.name,
                            clientAddress: flowSource.clientAddress,
                            application: flowSource.application
                        )
                    }.flatMapThrowing { flowSource in
                        try HTTPServerPipeline.install(
                            on: channel,
                            handler: HTTPProxyHandler(
                                sessionID: sessionID,
                                eventSink: eventSink,
                                serverSentEventEventSink: serverSentEventEventSink,
                                webSocketFrameEventSink: webSocketFrameEventSink,
                                maxPendingRequestBytes: maxPendingRequestBytes,
                                bodyStore: bodyStore,
                                maximumCapturedBodyBytes: maximumCapturedBodyBytes,
                                maximumWebSocketFrameBytes: maximumWebSocketFrameBytes,
                                webSocketConnectionRegistry: webSocketConnections,
                                interceptHTTPS: interceptHTTPS,
                                certificateProvider: certificateProvider,
                                upstreamTLSContext: upstreamTLSContext,
                                upstreamHTTP2Pool: upstreamHTTP2Pool,
                                tunnelTarget: nil,
                                reverseProxyRoute: reverseProxyRoute,
                                externalHTTPProxyRoute: externalHTTPProxyRoute,
                                ruleSnapshot: ruleSnapshot,
                                tlsInterceptionPolicy: tlsInterceptionPolicy,
                                scriptExecutor: scriptExecutor,
                                breakpointGate: breakpointGate,
                                flowSource: flowSource
                            )
                        )
                    }
                }
                .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
        }

        func makeSOCKS5Bootstrap() -> ServerBootstrap {
            ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 256)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer {
                    [
                        eventSink,
                        serverSentEventEventSink,
                        webSocketFrameEventSink,
                        sessionID,
                        maxPendingRequestBytes,
                        bodyStore,
                        maximumCapturedBodyBytes,
                        maximumWebSocketFrameBytes,
                        webSocketConnections,
                        certificateProvider,
                        upstreamTLSContext,
                        upstreamHTTP2Pool,
                        ruleSnapshot,
                        scriptExecutor,
                        breakpointGate,
                        flowSourceResolver,
                        externalHTTPProxyRoute
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
                    return sourceFuture.flatMapThrowing { resolvedSource in
                        let flowSource = FlowSource.socks5Proxy(
                            clientAddress: resolvedSource.clientAddress,
                            application: resolvedSource.application
                        )
                        try channel.pipeline.syncOperations.addHandler(
                            SOCKS5ServerHandler(
                                sessionID: sessionID,
                                eventSink: eventSink,
                                serverSentEventEventSink: serverSentEventEventSink,
                                webSocketFrameEventSink: webSocketFrameEventSink,
                                maxPendingRequestBytes: maxPendingRequestBytes,
                                bodyStore: bodyStore,
                                maximumCapturedBodyBytes: maximumCapturedBodyBytes,
                                maximumWebSocketFrameBytes: maximumWebSocketFrameBytes,
                                webSocketConnectionRegistry: webSocketConnections,
                                interceptHTTPS: interceptHTTPS,
                                certificateProvider: certificateProvider,
                                upstreamTLSContext: upstreamTLSContext,
                                upstreamHTTP2Pool: upstreamHTTP2Pool,
                                externalHTTPProxyRoute: externalHTTPProxyRoute,
                                ruleSnapshot: ruleSnapshot,
                                scriptExecutor: scriptExecutor,
                                breakpointGate: breakpointGate,
                                flowSource: flowSource
                            )
                        )
                    }
                }
                .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
        }

        do {
            let channel = try await makeBootstrap(reverseProxyRoute: nil).bind(
                host: configuration.listenEndpoint.host,
                port: Int(configuration.listenEndpoint.port)
            ).get()
            serverChannel = channel

            let forwardEndpoint = try Self.boundEndpoint(
                channel,
                fallbackHost: configuration.listenEndpoint.host
            )
            if let socks5Listener = configuration.socks5Listener,
                socks5Listener.isEnabled
            {
                let channel = try await makeSOCKS5Bootstrap().bind(
                    host: socks5Listener.listenEndpoint.host,
                    port: Int(socks5Listener.listenEndpoint.port)
                ).get()
                socks5Channel = channel
                _ = try Self.boundEndpoint(
                    channel,
                    fallbackHost: socks5Listener.listenEndpoint.host
                )
            }
            for route in configuration.reverseProxyRoutes where route.isEnabled {
                let routeChannel = try await makeBootstrap(reverseProxyRoute: route).bind(
                    host: route.listenEndpoint.host,
                    port: Int(route.listenEndpoint.port)
                ).get()
                reverseProxyChannels[route.id] = routeChannel
                _ = try Self.boundEndpoint(
                    routeChannel,
                    fallbackHost: route.listenEndpoint.host
                )
            }

            currentState = .running(forwardEndpoint)
        } catch {
            currentState = .failed(error.localizedDescription)
            for channel in reverseProxyChannels.values {
                _ = try? await channel.close().get()
            }
            reverseProxyChannels.removeAll()
            if let socks5Channel {
                _ = try? await socks5Channel.close().get()
            }
            socks5Channel = nil
            if let serverChannel {
                _ = try? await serverChannel.close().get()
            }
            serverChannel = nil
            await upstreamHTTP2Pool.closeAll()
            self.upstreamHTTP2Pool = nil
            await shutdown(group)
            eventLoopGroup = nil
            throw error
        }
    }

    public func stop() async {
        guard
            currentState != .stopped || serverChannel != nil || socks5Channel != nil
                || !reverseProxyChannels.isEmpty
        else {
            return
        }

        currentState = .stopping
        if let serverChannel {
            _ = try? await serverChannel.close().get()
            _ = try? await serverChannel.closeFuture.get()
        }
        if let socks5Channel {
            _ = try? await socks5Channel.close().get()
            _ = try? await socks5Channel.closeFuture.get()
        }
        for channel in reverseProxyChannels.values {
            _ = try? await channel.close().get()
            _ = try? await channel.closeFuture.get()
        }

        if let upstreamHTTP2Pool {
            await upstreamHTTP2Pool.closeAll()
        }

        if let eventLoopGroup {
            await shutdown(eventLoopGroup)
        }

        await webSocketConnections.removeAll()

        serverChannel = nil
        socks5Channel = nil
        reverseProxyChannels.removeAll()
        upstreamHTTP2Pool = nil
        eventLoopGroup = nil
        currentState = .stopped
    }

    public func isConnectionOpen(for flowID: FlowID) async -> Bool {
        await webSocketConnections.isConnectionOpen(for: flowID)
    }

    public func send(_ transmission: WebSocketFrameTransmission) async throws {
        try await webSocketConnections.send(transmission)
    }

    public func state() async -> ProxyEngineState {
        currentState
    }

    public func reverseProxyEndpoints() -> [UUID: NetworkEndpoint] {
        reverseProxyChannels.reduce(into: [:]) { endpoints, entry in
            endpoints[entry.key] = try? Self.boundEndpoint(
                entry.value,
                fallbackHost: entry.value.localAddress?.ipAddress ?? "127.0.0.1"
            )
        }
    }

    public func socks5Endpoint() -> NetworkEndpoint? {
        guard let socks5Channel else { return nil }
        return try? Self.boundEndpoint(
            socks5Channel,
            fallbackHost: socks5Channel.localAddress?.ipAddress ?? "127.0.0.1"
        )
    }

    private func makeExternalHTTPProxyRoute(
        _ configuration: ExternalHTTPProxyConfiguration?
    ) async throws -> ExternalHTTPProxyRoute? {
        guard let configuration, configuration.isEnabled else { return nil }
        let credentials: ExternalHTTPProxyCredentials?
        if let username = configuration.username {
            guard let externalHTTPProxyCredentialStore else {
                throw ExternalHTTPProxyRouteError.credentialsUnavailable
            }
            credentials = try await externalHTTPProxyCredentialStore.credentials(
                for: configuration.endpoint,
                username: username
            )
        } else {
            credentials = nil
        }
        return try ExternalHTTPProxyRoute(
            configuration: configuration,
            credentials: credentials
        )
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

    private static func boundEndpoint(
        _ channel: Channel,
        fallbackHost: String
    ) throws -> NetworkEndpoint {
        guard let localAddress = channel.localAddress,
            let port = localAddress.port,
            let boundPort = UInt16(exactly: port)
        else {
            throw ProxyLensError.unsupportedOperation("The proxy listener has no local address")
        }
        return NetworkEndpoint(
            host: localAddress.ipAddress ?? fallbackHost,
            port: boundPort
        )
    }
}
