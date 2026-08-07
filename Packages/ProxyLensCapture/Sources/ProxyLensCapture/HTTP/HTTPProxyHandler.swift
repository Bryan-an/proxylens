import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import ProxyLensCore

final class HTTPProxyHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let sessionID: SessionID
    private let eventSink: any FlowEventSink
    private let maxPendingRequestBytes: Int

    private var requestHead: HTTPRequestHead?
    private var upstreamChannel: Channel?
    private var pendingRequestParts: [HTTPClientRequestPart] = []
    private var pendingRequestBytes = 0
    private var requestEnded = false
    private var responseStarted = false
    private var transaction: FlowTransaction?

    init(
        sessionID: SessionID,
        eventSink: any FlowEventSink,
        maxPendingRequestBytes: Int
    ) {
        self.sessionID = sessionID
        self.eventSink = eventSink
        self.maxPendingRequestBytes = max(1, maxPendingRequestBytes)
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
        Task {
            await transaction.fail(.clientDisconnected)
            upstreamChannel?.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        let upstreamChannel = self.upstreamChannel
        if let transaction {
            Task {
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

        guard head.method != .CONNECT else {
            sendError(
                statusCode: 501,
                reason: "Not Implemented",
                message: "CONNECT is implemented in the TLS interception milestone.",
                context: context
            )
            return
        }

        let target: ProxyTarget
        do {
            target = try ProxyTarget(uri: head.uri, headers: head.headers)
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

        let request = HTTPRequest(
            method: ProxyLensCore.HTTPMethod(rawValue: head.method.rawValue),
            url: target.url,
            headers: coreHeaders,
            version: coreVersion,
            rawTarget: head.uri
        )
        let connection = ConnectionInfo(
            protocolKind: .http,
            upstreamHost: target.host,
            upstreamPort: UInt16(target.port)
        )
        let flow = Flow(sessionID: sessionID, request: request, connection: connection)
        let transaction = FlowTransaction(flow: flow, eventSink: eventSink)

        self.requestHead = head
        self.transaction = transaction
        Task {
            await transaction.start(at: Date())
        }

        let forwardedHeaders = HTTPConversion.sanitizedRequestHeaders(head.headers)
        let forwardedHead = HTTPRequestHead(
            version: head.version,
            method: head.method,
            uri: target.originForm,
            headers: forwardedHeaders
        )

        connectUpstream(
            target: target,
            requestHead: forwardedHead,
            clientChannel: context.channel,
            transaction: transaction
        )
    }

    private func receiveRequestBody(_ buffer: inout ByteBuffer, context: ChannelHandlerContext) {
        let byteCount = buffer.readableBytes

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
        requestEnded = true
        if let transaction {
            Task {
                await transaction.markRequestBodyCompleted(at: Date())
            }
        }

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

    private func connectUpstream(
        target: ProxyTarget,
        requestHead: HTTPRequestHead,
        clientChannel: Channel,
        transaction: FlowTransaction
    ) {
        let bootstrap = ClientBootstrap(group: clientChannel.eventLoop)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHTTPClientHandlers().flatMapThrowing {
                    try channel.pipeline.syncOperations.addHandler(
                        UpstreamResponseHandler(
                            clientChannel: clientChannel,
                            transaction: transaction
                        )
                    )
                }
            }

        let loopBoundSelf = NIOLoopBound(self, eventLoop: clientChannel.eventLoop)
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
    private let transaction: FlowTransaction
    private var responseStarted = false

    init(clientChannel: Channel, transaction: FlowTransaction) {
        self.clientChannel = clientChannel
        self.transaction = transaction
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let responsePart = Self.unwrapInboundIn(data)

        switch responsePart {
        case .head(let head):
            responseStarted = true
            let forwardedHead = HTTPConversion.sanitizedResponseHead(head)
            do {
                let response = try HTTPResponse(
                    statusCode: Int(head.status.code),
                    reasonPhrase: head.status.reasonPhrase,
                    headers: HTTPConversion.coreHeaders(from: head.headers),
                    version: HTTPConversion.coreVersion(from: head.version)
                )
                let transaction = self.transaction
                Task { [transaction] in
                    await transaction.receiveResponse(response, at: Date())
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

            clientChannel.write(HTTPServerResponsePart.head(forwardedHead), promise: nil)
        case .body(let buffer):
            clientChannel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
        case .end(let trailers):
            let forwardedTrailers = HTTPConversion.sanitizedTrailers(trailers)
            clientChannel.writeAndFlush(HTTPServerResponsePart.end(forwardedTrailers)).whenComplete
            {
                [clientChannel, transaction] _ in
                Task {
                    await transaction.finishResponse(at: Date())
                }
                clientChannel.close(promise: nil)
            }
            context.close(promise: nil)
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        clientChannel.flush()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        let transaction = self.transaction
        let failure: FlowFailure =
            responseStarted
            ? .protocolError(error.localizedDescription)
            : .upstreamUnavailable
        Task { [transaction, failure] in
            await transaction.fail(failure)
        }

        if !responseStarted {
            var body = clientChannel.allocator.buffer(capacity: 64)
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
            clientChannel.write(HTTPServerResponsePart.head(head), promise: nil)
            clientChannel.write(HTTPServerResponsePart.body(.byteBuffer(body)), promise: nil)
            clientChannel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
        }

        clientChannel.close(promise: nil)
        context.close(promise: nil)
    }
}
