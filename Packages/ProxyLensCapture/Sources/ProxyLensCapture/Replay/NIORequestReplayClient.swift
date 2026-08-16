import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import ProxyLensCore

public enum RequestReplayError: Error, Equatable, LocalizedError, Sendable {
    case connectMethodUnsupported
    case incompleteResponse
    case requestBodyTooLarge(byteCount: Int64, maximumByteCount: Int64)
    case timeout
    case truncatedRequestBody
    case unsupportedHTTPVersion(ProxyLensCore.HTTPVersion)

    public var errorDescription: String? {
        switch self {
        case .connectMethodUnsupported:
            "CONNECT requests cannot be repeated"
        case .incompleteResponse:
            "The upstream closed before the replay response completed"
        case .requestBodyTooLarge(let byteCount, let maximumByteCount):
            "The \(byteCount)-byte request body exceeds the \(maximumByteCount)-byte replay limit"
        case .timeout:
            "The replay request timed out"
        case .truncatedRequestBody:
            "A request with a truncated captured body cannot be repeated safely"
        case .unsupportedHTTPVersion(let version):
            "Repeating \(version.rawValue) requests is not supported yet"
        }
    }
}

/// Repeats captured HTTP/1.x requests directly against their original upstream.
public struct NIORequestReplayClient: RequestReplayClient {
    private let bodyStore: any BodyStore
    private let maximumCapturedBodyBytes: Int64
    private let responseTimeout: TimeAmount
    private let upstreamTLSConfiguration: UpstreamTLSConfiguration

    public init(
        bodyStore: any BodyStore,
        maximumCapturedBodyBytes: Int64 = 50 * 1_024 * 1_024,
        responseTimeout: TimeAmount = .seconds(30),
        upstreamTLSConfiguration: UpstreamTLSConfiguration = UpstreamTLSConfiguration()
    ) {
        self.bodyStore = bodyStore
        self.maximumCapturedBodyBytes = max(0, maximumCapturedBodyBytes)
        self.responseTimeout = responseTimeout
        self.upstreamTLSConfiguration = upstreamTLSConfiguration
    }

    public func replay(_ request: HTTPRequest, sessionID: SessionID) async throws -> Flow {
        try validate(request)
        let target = try ProxyTarget(url: request.url)
        let duplicatedBody = try await duplicateRequestBody(request.body)
        let replayedRequest = request.replacingBody(duplicatedBody.reference)
        let startedAt = Date()
        var flow = Flow(
            sessionID: sessionID,
            source: .replay,
            request: replayedRequest,
            connection: ConnectionInfo(
                protocolKind: target.usesTLS ? .https : .http,
                upstreamHost: target.host,
                upstreamPort: UInt16(target.port),
                tlsIntercepted: false
            ),
            startedAt: startedAt
        )
        try flow.transition(to: .receivingRequest)
        flow.markRequestHeadersReceived(at: startedAt)
        flow.markRequestBodyCompleted(at: startedAt)
        try flow.transition(to: .connectingUpstream)

        let exchange: ReplayWireExchange
        do {
            exchange = try await send(
                replayedRequest,
                body: duplicatedBody.data,
                to: target
            )
        } catch {
            try? flow.transition(to: .failed(Self.flowFailure(for: error, usesTLS: target.usesTLS)))
            flow.markCompleted(at: Date())
            return flow
        }

        flow.markUpstreamConnected(at: exchange.connectedAt)
        try flow.transition(to: .receivingResponse)
        var response = exchange.response
        do {
            if exchange.receivedBodyBytes || !exchange.body.isEmpty {
                let body = try await bodyStore.put(
                    exchange.body,
                    metadata: BodyMetadata(
                        contentType: response.headers.firstValue(for: "Content-Type"),
                        contentEncoding: response.headers.firstValue(for: "Content-Encoding"),
                        isTruncated: exchange.bodyIsTruncated
                    )
                )
                response.attachBody(body)
            }
        } catch {
            try? flow.transition(to: .failed(.persistenceError(error.localizedDescription)))
            flow.markCompleted(at: Date())
            return flow
        }

        flow.attachResponse(response)
        flow.markResponseHeadersReceived(at: exchange.responseHeadersReceivedAt)
        flow.markResponseBodyCompleted(at: exchange.completedAt)
        try flow.transition(to: .completed)
        flow.markCompleted(at: exchange.completedAt)
        return flow
    }

    private func duplicateRequestBody(_ reference: BodyReference?) async throws
        -> (reference: BodyReference?, data: Data?)
    {
        guard let reference else {
            return (nil, nil)
        }
        guard !reference.isTruncated else {
            throw RequestReplayError.truncatedRequestBody
        }
        let data = try await bodyStore.read(reference)
        guard Int64(data.count) == reference.byteCount else {
            throw ProxyLensError.invalidBodySize(Int64(data.count))
        }
        let duplicatedReference = try await bodyStore.put(
            data,
            metadata: BodyMetadata(
                contentType: reference.contentType,
                contentEncoding: reference.contentEncoding,
                digest: reference.digest
            )
        )
        return (duplicatedReference, data)
    }

    private func send(
        _ request: HTTPRequest,
        body: Data?,
        to target: ProxyTarget
    ) async throws -> ReplayWireExchange {
        let tlsContext = try TLSContextFactory.upstreamContext(
            configuration: upstreamTLSConfiguration
        )
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let result = try await send(
                request,
                body: body,
                to: target,
                tlsContext: tlsContext,
                group: group
            )
            await Self.shutdown(group)
            return result
        } catch {
            await Self.shutdown(group)
            throw error
        }
    }

    private func send(
        _ request: HTTPRequest,
        body: Data?,
        to target: ProxyTarget,
        tlsContext: NIOSSLContext,
        group: MultiThreadedEventLoopGroup
    ) async throws -> ReplayWireExchange {
        let responsePromise = group.next().makePromise(of: ReplayWireResponse.self)
        let maximumCapturedBodyBytes = self.maximumCapturedBodyBytes
        let responseTimeout = self.responseTimeout
        let channel = try await ClientBootstrap(group: group)
            .connectTimeout(.seconds(10))
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                do {
                    if target.usesTLS {
                        try channel.pipeline.syncOperations.addHandler(
                            NIOSSLClientHandler(
                                context: tlsContext,
                                serverHostname: target.host
                            )
                        )
                    }
                    try channel.pipeline.syncOperations.addHTTPClientHandlers()
                    try channel.pipeline.syncOperations.addHandler(
                        IdleStateHandler(readTimeout: responseTimeout)
                    )
                    try channel.pipeline.syncOperations.addHandler(
                        ReplayResponseHandler(
                            promise: responsePromise,
                            maximumCapturedBodyBytes: maximumCapturedBodyBytes
                        )
                    )
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .connect(host: target.host, port: target.port)
            .get()
        let connectedAt = Date()

        var headers = HTTPConversion.sanitizedRequestHeaders(
            HTTPConversion.nioHeaders(from: request.headers)
        )
        headers.remove(name: "Host")
        headers.add(name: "Host", value: target.hostHeader)
        headers.remove(name: "Content-Length")
        if let body {
            headers.add(name: "Content-Length", value: "\(body.count)")
        }
        let requestHead = HTTPRequestHead(
            version: request.version == .http10 ? .http1_0 : .http1_1,
            method: NIOHTTP1.HTTPMethod(rawValue: request.method.rawValue),
            uri: target.originForm,
            headers: headers
        )
        channel.write(HTTPClientRequestPart.head(requestHead), promise: nil)
        if let body, !body.isEmpty {
            var buffer = channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            channel.write(HTTPClientRequestPart.body(.byteBuffer(buffer)), promise: nil)
        }
        channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)

        let response = try await responsePromise.futureResult.get()
        if channel.isActive {
            try? await channel.close().get()
        }
        return ReplayWireExchange(response: response, connectedAt: connectedAt)
    }

    private func validate(_ request: HTTPRequest) throws {
        guard request.method != .connect else {
            throw RequestReplayError.connectMethodUnsupported
        }
        guard request.version == .http10 || request.version == .http11 else {
            throw RequestReplayError.unsupportedHTTPVersion(request.version)
        }
        if request.body?.isTruncated == true {
            throw RequestReplayError.truncatedRequestBody
        }
        if let byteCount = request.body?.byteCount,
            byteCount > maximumCapturedBodyBytes
        {
            throw RequestReplayError.requestBodyTooLarge(
                byteCount: byteCount,
                maximumByteCount: maximumCapturedBodyBytes
            )
        }
    }

    private static func flowFailure(for error: Error, usesTLS: Bool) -> FlowFailure {
        if usesTLS, let sslError = error as? NIOSSLError, case .handshakeFailed = sslError {
            return .tlsHandshakeFailed
        }
        if let replayError = error as? RequestReplayError {
            switch replayError {
            case .timeout:
                return .timeout
            case .incompleteResponse:
                return .protocolError(replayError.localizedDescription)
            case .connectMethodUnsupported, .requestBodyTooLarge, .truncatedRequestBody,
                .unsupportedHTTPVersion:
                break
            }
        }
        return .upstreamUnavailable
    }

    private static func shutdown(_ group: MultiThreadedEventLoopGroup) async {
        await withCheckedContinuation { continuation in
            group.shutdownGracefully { _ in
                continuation.resume()
            }
        }
    }
}

private struct ReplayWireExchange: Sendable {
    let response: HTTPResponse
    let body: Data
    let bodyIsTruncated: Bool
    let receivedBodyBytes: Bool
    let responseHeadersReceivedAt: Date
    let completedAt: Date
    let connectedAt: Date

    init(response: ReplayWireResponse, connectedAt: Date) {
        self.response = response.response
        self.body = response.body
        self.bodyIsTruncated = response.bodyIsTruncated
        self.receivedBodyBytes = response.receivedBodyBytes
        self.responseHeadersReceivedAt = response.responseHeadersReceivedAt
        self.completedAt = response.completedAt
        self.connectedAt = connectedAt
    }
}

private struct ReplayWireResponse: Sendable {
    let response: HTTPResponse
    let body: Data
    let bodyIsTruncated: Bool
    let receivedBodyBytes: Bool
    let responseHeadersReceivedAt: Date
    let completedAt: Date
}

private final class ReplayResponseHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart

    private let promise: EventLoopPromise<ReplayWireResponse>
    private let maximumCapturedBodyBytes: Int64
    private var response: HTTPResponse?
    private var body = Data()
    private var bodyIsTruncated = false
    private var receivedBodyBytes = false
    private var responseHeadersReceivedAt: Date?
    private var isReadingInformationalResponse = false
    private var isFinished = false

    init(
        promise: EventLoopPromise<ReplayWireResponse>,
        maximumCapturedBodyBytes: Int64
    ) {
        self.promise = promise
        self.maximumCapturedBodyBytes = max(0, maximumCapturedBodyBytes)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        do {
            switch Self.unwrapInboundIn(data) {
            case .head(let head):
                if (100..<200).contains(head.status.code), head.status.code != 101 {
                    isReadingInformationalResponse = true
                    return
                }
                isReadingInformationalResponse = false
                response = try HTTPResponse(
                    statusCode: Int(head.status.code),
                    reasonPhrase: head.status.reasonPhrase,
                    headers: HTTPConversion.coreHeaders(from: head.headers),
                    version: HTTPConversion.coreVersion(from: head.version)
                )
                responseHeadersReceivedAt = Date()
            case .body(var buffer):
                guard !isReadingInformationalResponse else {
                    return
                }
                receivedBodyBytes = receivedBodyBytes || buffer.readableBytes > 0
                let remaining = max(0, maximumCapturedBodyBytes - Int64(body.count))
                let acceptedByteCount = Int(min(Int64(buffer.readableBytes), remaining))
                if acceptedByteCount > 0,
                    let bytes = buffer.readBytes(length: acceptedByteCount)
                {
                    body.append(contentsOf: bytes)
                }
                if buffer.readableBytes > 0 {
                    bodyIsTruncated = true
                }
            case .end:
                if isReadingInformationalResponse {
                    isReadingInformationalResponse = false
                    return
                }
                guard let response, let responseHeadersReceivedAt else {
                    throw RequestReplayError.incompleteResponse
                }
                isFinished = true
                promise.succeed(
                    ReplayWireResponse(
                        response: response,
                        body: body,
                        bodyIsTruncated: bodyIsTruncated,
                        receivedBodyBytes: receivedBodyBytes,
                        responseHeadersReceivedAt: responseHeadersReceivedAt,
                        completedAt: Date()
                    )
                )
                context.close(promise: nil)
            }
        } catch {
            finishWithError(error, context: context)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !isFinished {
            finishWithError(RequestReplayError.incompleteResponse, context: context)
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finishWithError(error, context: context)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let idleEvent = event as? IdleStateHandler.IdleStateEvent,
            case .read = idleEvent
        {
            finishWithError(RequestReplayError.timeout, context: context)
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    private func finishWithError(_ error: Error, context: ChannelHandlerContext) {
        guard !isFinished else {
            return
        }
        isFinished = true
        promise.fail(error)
        context.close(promise: nil)
    }
}
