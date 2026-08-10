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
    private let maxPendingRequestBytes: Int
    private let certificateProvider: (any CertificateProvider)?
    private let upstreamTLSConfiguration: UpstreamTLSConfiguration

    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var serverChannel: Channel?
    private var currentState: ProxyEngineState = .stopped
    private var sessionID = SessionID()

    public init(
        eventLoopThreads: Int = 1,
        eventSink: any FlowEventSink = NoOpFlowEventSink(),
        maxPendingRequestBytes: Int = 1_048_576,
        certificateProvider: (any CertificateProvider)? = nil,
        upstreamTLSConfiguration: UpstreamTLSConfiguration = UpstreamTLSConfiguration()
    ) {
        self.eventLoopThreadCount = max(1, eventLoopThreads)
        self.eventSink = eventSink
        self.maxPendingRequestBytes = max(1, maxPendingRequestBytes)
        self.certificateProvider = certificateProvider
        self.upstreamTLSConfiguration = upstreamTLSConfiguration
    }

    public func start(configuration: ProxyConfiguration) async throws {
        guard serverChannel == nil else {
            throw ProxyLensError.unsupportedOperation("The proxy is already running")
        }

        currentState = .starting
        sessionID = SessionID()

        if configuration.interceptHTTPS, certificateProvider == nil {
            currentState = .failed(
                TLSInterceptionError.missingCertificateProvider.localizedDescription)
            throw TLSInterceptionError.missingCertificateProvider
        }

        let upstreamTLSContext: NIOSSLContext?
        do {
            upstreamTLSContext =
                configuration.interceptHTTPS
                ? try TLSContextFactory.upstreamContext(configuration: upstreamTLSConfiguration)
                : nil
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
                        sessionID,
                        maxPendingRequestBytes,
                        certificateProvider,
                        upstreamTLSContext,
                    ] channel in
                    channel.eventLoop.makeCompletedFuture(
                        Result {
                            try HTTPServerPipeline.install(
                                on: channel,
                                handler: HTTPProxyHandler(
                                    sessionID: sessionID,
                                    eventSink: eventSink,
                                    maxPendingRequestBytes: maxPendingRequestBytes,
                                    interceptHTTPS: interceptHTTPS,
                                    certificateProvider: certificateProvider,
                                    upstreamTLSContext: upstreamTLSContext
                                )
                            )
                        }
                    )
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
}
