import Foundation
import NIOCore

enum HTTPUpstreamProxyConnectError: Error, Equatable, LocalizedError, Sendable {
    case responseHeadersTooLarge
    case malformedResponse
    case rejected(statusCode: Int)
    case unexpectedResponseBody
    case connectionClosed

    var errorDescription: String? {
        switch self {
        case .responseHeadersTooLarge:
            "The external proxy CONNECT response headers exceeded 32 KiB."
        case .malformedResponse:
            "The external proxy returned a malformed CONNECT response."
        case .rejected(let statusCode):
            "The external proxy rejected CONNECT with HTTP status \(statusCode)."
        case .unexpectedResponseBody:
            "The external proxy returned an unexpected CONNECT response body."
        case .connectionClosed:
            "The external proxy closed the CONNECT handshake."
        }
    }
}

final class HTTPUpstreamProxyConnectHandler: ChannelInboundHandler, RemovableChannelHandler,
    @unchecked Sendable
{
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private static let maximumResponseHeaderBytes = 32 * 1_024
    private static let headerTerminator = Array("\r\n\r\n".utf8)

    private let request: ByteBuffer
    private let readyPromise: EventLoopPromise<Channel>
    private let configureTunnel: @Sendable (Channel) -> EventLoopFuture<Void>
    private var responseBytes: [UInt8] = []
    private var didStart = false
    private var didComplete = false

    init(
        request: ByteBuffer,
        readyPromise: EventLoopPromise<Channel>,
        configureTunnel: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) {
        self.request = request
        self.readyPromise = readyPromise
        self.configureTunnel = configureTunnel
    }

    func handlerAdded(context: ChannelHandlerContext) {
        startIfPossible(context: context)
    }

    func channelActive(context: ChannelHandlerContext) {
        startIfPossible(context: context)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = Self.unwrapInboundIn(data)
        responseBytes.append(contentsOf: buffer.readableBytesView)
        buffer.moveReaderIndex(forwardBy: buffer.readableBytes)

        guard responseBytes.count <= Self.maximumResponseHeaderBytes else {
            fail(HTTPUpstreamProxyConnectError.responseHeadersTooLarge, context: context)
            return
        }
        guard let terminatorIndex = responseBytes.firstRange(of: Self.headerTerminator)?.lowerBound
        else {
            return
        }
        let responseEnd = terminatorIndex + Self.headerTerminator.count
        guard responseEnd == responseBytes.count else {
            fail(HTTPUpstreamProxyConnectError.unexpectedResponseBody, context: context)
            return
        }
        guard let headerText = String(bytes: responseBytes[..<responseEnd], encoding: .utf8),
            let statusCode = Self.statusCode(from: headerText)
        else {
            fail(HTTPUpstreamProxyConnectError.malformedResponse, context: context)
            return
        }
        guard (200...299).contains(statusCode) else {
            fail(HTTPUpstreamProxyConnectError.rejected(statusCode: statusCode), context: context)
            return
        }
        guard Self.hasNoResponseBody(headerText) else {
            fail(HTTPUpstreamProxyConnectError.unexpectedResponseBody, context: context)
            return
        }

        didComplete = true
        let channel = context.channel
        channel.pipeline.removeHandler(self).flatMap {
            self.configureTunnel(channel)
        }.whenComplete { result in
            switch result {
            case .success:
                self.readyPromise.succeed(channel)
            case .failure(let error):
                self.readyPromise.fail(error)
                channel.close(promise: nil)
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error, context: context)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !didComplete {
            fail(HTTPUpstreamProxyConnectError.connectionClosed, context: context)
        }
        context.fireChannelInactive()
    }

    private func startIfPossible(context: ChannelHandlerContext) {
        guard context.channel.isActive, !didStart, !didComplete else { return }
        didStart = true
        context.writeAndFlush(Self.wrapOutboundOut(request), promise: nil)
    }

    private func fail(_ error: Error, context: ChannelHandlerContext) {
        guard !didComplete else { return }
        didComplete = true
        readyPromise.fail(error)
        context.close(promise: nil)
    }

    private static func statusCode(from response: String) -> Int? {
        guard let statusLine = response.components(separatedBy: "\r\n").first else {
            return nil
        }
        let parts = statusLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2,
            parts[0].hasPrefix("HTTP/1."),
            parts[1].count == 3,
            let statusCode = Int(parts[1])
        else {
            return nil
        }
        return statusCode
    }

    private static func hasNoResponseBody(_ response: String) -> Bool {
        let headerLines = response.components(separatedBy: "\r\n").dropFirst()
        for line in headerLines {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
            if name == "transfer-encoding", !value.isEmpty {
                return false
            }
            if name == "content-length", value != "0" {
                return false
            }
        }
        return true
    }
}

extension Array where Element: Equatable {
    fileprivate func firstRange(of pattern: [Element]) -> Range<Int>? {
        guard !pattern.isEmpty, count >= pattern.count else { return nil }
        for index in 0...(count - pattern.count) where self[index...].starts(with: pattern) {
            return index..<(index + pattern.count)
        }
        return nil
    }
}
