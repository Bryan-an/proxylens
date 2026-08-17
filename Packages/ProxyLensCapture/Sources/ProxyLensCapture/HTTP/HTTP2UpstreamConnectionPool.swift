import Foundation
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOPosix
import NIOSSL

enum HTTP2UpstreamRequestChannel: @unchecked Sendable {
    case stream(Channel, connectionReused: Bool)
    case http1Required
}

final class HTTP2UpstreamConnectionPool: @unchecked Sendable {
    private struct Key: Hashable {
        let destination: ProxyConnectionIdentity
        let eventLoop: ObjectIdentifier
    }

    fileprivate final class Connection: @unchecked Sendable {
        let parentChannel: Channel
        let multiplexer: NIOHTTP2Handler.StreamMultiplexer

        init(parentChannel: Channel, multiplexer: NIOHTTP2Handler.StreamMultiplexer) {
            self.parentChannel = parentChannel
            self.multiplexer = multiplexer
        }
    }

    fileprivate enum NegotiatedProtocol: @unchecked Sendable {
        case http2(Connection)
        case http1
    }

    private enum Entry: @unchecked Sendable {
        case connecting(UUID, EventLoopFuture<NegotiatedProtocol>)
        case http2(Connection)
        case http1
    }

    private struct Acquisition: @unchecked Sendable {
        let negotiatedProtocol: NegotiatedProtocol
        let connectionReused: Bool
    }

    fileprivate final class NegotiationResolver: @unchecked Sendable {
        let futureResult: EventLoopFuture<NegotiatedProtocol>

        private let lock = NSLock()
        private let promise: EventLoopPromise<NegotiatedProtocol>
        private var isCompleted = false

        init(eventLoop: EventLoop) {
            promise = eventLoop.makePromise(of: NegotiatedProtocol.self)
            futureResult = promise.futureResult
        }

        func succeed(_ value: NegotiatedProtocol) {
            guard markCompleted() else {
                return
            }
            promise.succeed(value)
        }

        func fail(_ error: Error) {
            guard markCompleted() else {
                return
            }
            promise.fail(error)
        }

        private func markCompleted() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !isCompleted else {
                return false
            }
            isCompleted = true
            return true
        }
    }

    private let tlsContext: NIOSSLContext
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var channels: [ObjectIdentifier: Channel] = [:]
    private var isClosed = false

    init(tlsContext: NIOSSLContext) {
        self.tlsContext = tlsContext
    }

    func openRequestChannel(
        target: ProxyTarget,
        on eventLoop: EventLoop,
        responseHandler: UpstreamResponseHandler
    ) -> EventLoopFuture<HTTP2UpstreamRequestChannel> {
        if !eventLoop.inEventLoop {
            return eventLoop.flatSubmit {
                self.openRequestChannel(
                    target: target,
                    on: eventLoop,
                    responseHandler: responseHandler
                )
            }
        }

        return negotiation(for: target, on: eventLoop).flatMap { acquisition in
            switch acquisition.negotiatedProtocol {
            case .http1:
                return eventLoop.makeSucceededFuture(.http1Required)
            case .http2(let connection):
                return self.openStream(
                    on: connection,
                    target: target,
                    responseHandler: responseHandler
                ).map {
                    HTTP2UpstreamRequestChannel.stream(
                        $0,
                        connectionReused: acquisition.connectionReused
                    )
                }
            }
        }
    }

    func closeAll() async {
        let openChannels = takeChannelsForShutdown()

        for channel in openChannels where channel.isActive {
            _ = try? await channel.close().get()
        }
    }

    private func takeChannelsForShutdown() -> [Channel] {
        lock.lock()
        defer { lock.unlock() }
        isClosed = true
        entries.removeAll(keepingCapacity: false)
        let openChannels = Array(channels.values)
        channels.removeAll(keepingCapacity: false)
        return openChannels
    }

    private func negotiation(
        for target: ProxyTarget,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<Acquisition> {
        let key = Key(
            destination: target.connectionIdentity,
            eventLoop: ObjectIdentifier(eventLoop)
        )
        var pendingConnection: (token: UUID, resolver: NegotiationResolver)?
        let result: EventLoopFuture<Acquisition>

        lock.lock()
        if isClosed {
            result = eventLoop.makeFailedFuture(HTTP2UpstreamPoolError.closed)
        } else if let entry = entries[key] {
            switch entry {
            case .connecting(_, let future):
                result = future.map {
                    Acquisition(negotiatedProtocol: $0, connectionReused: true)
                }
            case .http1:
                result = eventLoop.makeSucceededFuture(
                    Acquisition(negotiatedProtocol: .http1, connectionReused: false)
                )
            case .http2(let connection) where connection.parentChannel.isActive:
                result = eventLoop.makeSucceededFuture(
                    Acquisition(negotiatedProtocol: .http2(connection), connectionReused: true)
                )
            case .http2:
                let token = UUID()
                let resolver = NegotiationResolver(eventLoop: eventLoop)
                entries[key] = .connecting(token, resolver.futureResult)
                result = resolver.futureResult.map {
                    Acquisition(negotiatedProtocol: $0, connectionReused: false)
                }
                pendingConnection = (token, resolver)
            }
        } else {
            let token = UUID()
            let resolver = NegotiationResolver(eventLoop: eventLoop)
            entries[key] = .connecting(token, resolver.futureResult)
            result = resolver.futureResult.map {
                Acquisition(negotiatedProtocol: $0, connectionReused: false)
            }
            pendingConnection = (token, resolver)
        }
        lock.unlock()

        if let pendingConnection {
            establishConnection(
                target: target,
                key: key,
                token: pendingConnection.token,
                eventLoop: eventLoop,
                resolver: pendingConnection.resolver
            )
        }
        return result
    }

    private func establishConnection(
        target: ProxyTarget,
        key: Key,
        token: UUID,
        eventLoop: EventLoop,
        resolver: NegotiationResolver
    ) {
        let bootstrap = ClientBootstrap(group: eventLoop)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { [tlsContext] channel in
                do {
                    let tlsHandler = try NIOSSLClientHandler(
                        context: tlsContext,
                        serverHostname: target.tlsServerName
                    )
                    try channel.pipeline.syncOperations.addHandler(tlsHandler)
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }

                return channel.configureHTTP2SecureUpgrade(
                    h2ChannelConfigurator: { channel in
                        var connectionConfiguration =
                            NIOHTTP2Handler.ConnectionConfiguration()
                        connectionConfiguration.initialSettings.append(
                            HTTP2Setting(parameter: .enablePush, value: 0)
                        )
                        return channel.configureHTTP2Pipeline(
                            mode: .client,
                            connectionConfiguration: connectionConfiguration,
                            streamConfiguration: NIOHTTP2Handler.StreamConfiguration()
                        ) { streamChannel in
                            streamChannel.close()
                        }.map { multiplexer in
                            let connection = Connection(
                                parentChannel: channel,
                                multiplexer: multiplexer
                            )
                            if self.recordHTTP2(connection, for: key, token: token) {
                                resolver.succeed(.http2(connection))
                            } else {
                                resolver.fail(HTTP2UpstreamPoolError.closed)
                                channel.close(promise: nil)
                            }
                        }
                    },
                    http1ChannelConfigurator: { channel in
                        if self.recordHTTP1(for: key, token: token) {
                            resolver.succeed(.http1)
                        } else {
                            resolver.fail(HTTP2UpstreamPoolError.closed)
                        }
                        return channel.close()
                    }
                ).flatMap {
                    channel.pipeline.addHandler(
                        HTTP2UpstreamNegotiationErrorHandler(resolver: resolver)
                    )
                }
            }

        bootstrap.connect(host: target.connectionHost, port: target.port).whenComplete { result in
            switch result {
            case .success(let channel):
                self.register(channel, for: key, token: token, resolver: resolver)
            case .failure(let error):
                self.removeConnectingEntry(for: key, token: token)
                resolver.fail(error)
            }
        }
    }

    private func openStream(
        on connection: Connection,
        target: ProxyTarget,
        responseHandler: UpstreamResponseHandler
    ) -> EventLoopFuture<Channel> {
        connection.multiplexer.createStreamChannel { streamChannel in
            streamChannel.eventLoop.makeCompletedFuture {
                let operations = streamChannel.pipeline.syncOperations
                try operations.addHandler(
                    HTTP2FramePayloadToHTTP1ClientCodec(
                        httpProtocol: target.usesTLS ? .https : .http
                    )
                )
                try operations.addHandler(
                    responseHandler,
                    name: HTTPClientPipeline.responseHandlerName
                )
            }
        }
    }

    private func recordHTTP2(_ connection: Connection, for key: Key, token: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed,
            case .connecting(let currentToken, _) = entries[key],
            currentToken == token
        else {
            return false
        }
        entries[key] = .http2(connection)
        return true
    }

    private func recordHTTP1(for key: Key, token: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed,
            case .connecting(let currentToken, _) = entries[key],
            currentToken == token
        else {
            return false
        }
        entries[key] = .http1
        return true
    }

    private func register(
        _ channel: Channel,
        for key: Key,
        token: UUID,
        resolver: NegotiationResolver
    ) {
        let identifier = ObjectIdentifier(channel)
        var shouldClose = false
        lock.lock()
        if isClosed {
            shouldClose = true
        } else {
            channels[identifier] = channel
        }
        lock.unlock()

        if shouldClose {
            resolver.fail(HTTP2UpstreamPoolError.closed)
            channel.close(promise: nil)
            return
        }

        channel.closeFuture.whenComplete { _ in
            self.channelClosed(
                identifier: identifier,
                key: key,
                token: token,
                resolver: resolver
            )
        }
    }

    private func channelClosed(
        identifier: ObjectIdentifier,
        key: Key,
        token: UUID,
        resolver: NegotiationResolver
    ) {
        var failedDuringNegotiation = false
        lock.lock()
        channels.removeValue(forKey: identifier)
        if let entry = entries[key] {
            switch entry {
            case .connecting(let currentToken, _) where currentToken == token:
                entries.removeValue(forKey: key)
                failedDuringNegotiation = true
            case .http2(let connection)
            where ObjectIdentifier(connection.parentChannel) == identifier:
                entries.removeValue(forKey: key)
            default:
                break
            }
        }
        lock.unlock()

        if failedDuringNegotiation {
            resolver.fail(ChannelError.eof)
        }
    }

    private func removeConnectingEntry(for key: Key, token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard case .connecting(let currentToken, _) = entries[key], currentToken == token else {
            return
        }
        entries.removeValue(forKey: key)
    }
}

private enum HTTP2UpstreamPoolError: Error {
    case closed
}

private final class HTTP2UpstreamNegotiationErrorHandler:
    ChannelInboundHandler,
    @unchecked Sendable
{
    typealias InboundIn = Any

    private let resolver: HTTP2UpstreamConnectionPool.NegotiationResolver

    init(resolver: HTTP2UpstreamConnectionPool.NegotiationResolver) {
        self.resolver = resolver
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        resolver.fail(error)
        context.close(promise: nil)
    }
}
