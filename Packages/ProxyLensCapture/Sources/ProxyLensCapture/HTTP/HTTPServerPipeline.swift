import NIOCore
import NIOHTTP1

enum HTTPServerPipeline {
    static let responseEncoderName = "proxylens.http.response-encoder"
    static let requestDecoderName = "proxylens.http.request-decoder"
    static let responseValidatorName = "proxylens.http.response-validator"
    static let protocolErrorHandlerName = "proxylens.http.protocol-error-handler"
    static let proxyHandlerName = "proxylens.http.proxy-handler"
    static let tlsHandlerName = "proxylens.tls.server-handler"

    static func install(on channel: Channel, handler: HTTPProxyHandler) throws {
        let operations = channel.pipeline.syncOperations
        try operations.addHandler(
            HTTPResponseEncoder(),
            name: responseEncoderName
        )
        try operations.addHandler(
            ByteToMessageHandler(
                HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)
            ),
            name: requestDecoderName
        )
        try operations.addHandler(
            NIOHTTPResponseHeadersValidator(),
            name: responseValidatorName
        )
        try operations.addHandler(
            HTTPServerProtocolErrorHandler(),
            name: protocolErrorHandlerName
        )
        try operations.addHandler(handler, name: proxyHandlerName)
    }

    static func removePlaintextHTTPHandlers(from channel: Channel) -> EventLoopFuture<Void> {
        do {
            let operations = channel.pipeline.syncOperations
            let proxyHandler = try operations.context(name: proxyHandlerName)
            let protocolErrorHandler = try operations.context(name: protocolErrorHandlerName)
            let responseHeadersValidator = try operations.context(name: responseValidatorName)
            let requestDecoder = try operations.context(name: requestDecoderName)
            let responseEncoder = try operations.context(name: responseEncoderName)
            let loopBoundOperations = NIOLoopBound(operations, eventLoop: channel.eventLoop)
            let loopBoundProtocolErrorHandler = NIOLoopBound(
                protocolErrorHandler,
                eventLoop: channel.eventLoop
            )
            let loopBoundResponseHeadersValidator = NIOLoopBound(
                responseHeadersValidator,
                eventLoop: channel.eventLoop
            )
            let loopBoundRequestDecoder = NIOLoopBound(
                requestDecoder,
                eventLoop: channel.eventLoop
            )
            let loopBoundResponseEncoder = NIOLoopBound(
                responseEncoder,
                eventLoop: channel.eventLoop
            )

            return operations.removeHandler(context: proxyHandler)
                .flatMap {
                    loopBoundOperations.value.removeHandler(
                        context: loopBoundProtocolErrorHandler.value
                    )
                }
                .flatMap {
                    loopBoundOperations.value.removeHandler(
                        context: loopBoundResponseHeadersValidator.value
                    )
                }
                .flatMap {
                    loopBoundOperations.value.removeHandler(
                        context: loopBoundRequestDecoder.value
                    )
                }
                .flatMap {
                    loopBoundOperations.value.removeHandler(
                        context: loopBoundResponseEncoder.value
                    )
                }
        } catch {
            return channel.eventLoop.makeFailedFuture(error)
        }
    }
}
