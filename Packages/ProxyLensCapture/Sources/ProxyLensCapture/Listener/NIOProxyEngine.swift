import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import ProxyLensCore

/// A local HTTP/1.1 forwarding proxy backed by SwiftNIO.
///
/// This first capture milestone intentionally handles plain HTTP only. HTTPS
/// CONNECT and TLS interception are implemented by the following milestone.
public actor NIOProxyEngine: ProxyEngine {
    private let eventLoopThreadCount: Int
    private let eventSink: any FlowEventSink
    private let maxPendingRequestBytes: Int

    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var serverChannel: Channel?
    private var currentState: ProxyEngineState = .stopped
    private var sessionID = SessionID()

    public init(
        eventLoopThreads: Int = 1,
        eventSink: any FlowEventSink = NoOpFlowEventSink(),
        maxPendingRequestBytes: Int = 1_048_576
    ) {
        self.eventLoopThreadCount = max(1, eventLoopThreads)
        self.eventSink = eventSink
        self.maxPendingRequestBytes = max(1, maxPendingRequestBytes)
    }

    public func start(configuration: ProxyConfiguration) async throws {
        guard serverChannel == nil else {
            throw ProxyLensError.unsupportedOperation("The proxy is already running")
        }

        currentState = .starting
        sessionID = SessionID()

        let group = MultiThreadedEventLoopGroup(numberOfThreads: eventLoopThreadCount)
        eventLoopGroup = group

        do {
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 256)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { [eventSink, sessionID, maxPendingRequestBytes] channel in
                    channel.pipeline.configureHTTPServerPipeline(
                        withPipeliningAssistance: false,
                        withErrorHandling: true
                    ).flatMapThrowing {
                        try channel.pipeline.syncOperations.addHandler(
                            HTTPProxyHandler(
                                sessionID: sessionID,
                                eventSink: eventSink,
                                maxPendingRequestBytes: maxPendingRequestBytes
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
}
