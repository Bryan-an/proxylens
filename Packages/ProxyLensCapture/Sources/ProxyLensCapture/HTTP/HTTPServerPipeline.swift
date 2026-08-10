import NIOCore
import NIOHTTP1

enum HTTPServerPipeline {
    static let proxyHandlerName = "proxylens.http.proxy-handler"
    static let tlsHandlerName = "proxylens.tls.server-handler"

    static func install(on channel: Channel, handler: HTTPProxyHandler) throws {
        let operations = channel.pipeline.syncOperations
        try operations.configureHTTPServerPipeline(
            withPipeliningAssistance: false,
            withErrorHandling: true,
            withOutboundHeaderValidation: true
        )
        try operations.addHandler(handler, name: proxyHandlerName)
    }

    static func removePlaintextHTTPHandlers(from channel: Channel) -> EventLoopFuture<Void> {
        do {
            let operations = channel.pipeline.syncOperations
            let proxyHandler = try operations.context(name: proxyHandlerName)
            let protocolErrorHandler = try operations.context(
                handlerType: HTTPServerProtocolErrorHandler.self
            )
            let responseHeadersValidator = try operations.context(
                handlerType: NIOHTTPResponseHeadersValidator.self
            )
            let requestDecoder = try operations.context(
                handlerType: ByteToMessageHandler<HTTPRequestDecoder>.self
            )
            let responseEncoder = try operations.context(handlerType: HTTPResponseEncoder.self)
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
