import NIOCore
import NIOHTTP1

enum HTTPClientPipeline {
    static let requestEncoderName = "proxylens.upstream.request-encoder"
    static let responseDecoderName = "proxylens.upstream.response-decoder"
    static let requestValidatorName = "proxylens.upstream.request-validator"
    static let responseHandlerName = "proxylens.upstream.response-handler"

    static func install(
        on channel: Channel,
        responseHandler: UpstreamResponseHandler
    ) throws {
        let operations = channel.pipeline.syncOperations
        try operations.addHandler(HTTPRequestEncoder(), name: requestEncoderName)
        try operations.addHandler(
            ByteToMessageHandler(
                HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes)
            ),
            name: responseDecoderName
        )
        try operations.addHandler(
            NIOHTTPRequestHeadersValidator(),
            name: requestValidatorName
        )
        try operations.addHandler(responseHandler, name: responseHandlerName)
    }
}
