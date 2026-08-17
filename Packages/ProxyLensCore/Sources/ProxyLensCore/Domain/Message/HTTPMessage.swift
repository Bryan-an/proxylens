import Foundation

public struct HTTPMethod: RawRepresentable, Codable, Equatable, Hashable, Sendable,
    ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue.uppercased()
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public static let get: HTTPMethod = "GET"
    public static let post: HTTPMethod = "POST"
    public static let put: HTTPMethod = "PUT"
    public static let patch: HTTPMethod = "PATCH"
    public static let delete: HTTPMethod = "DELETE"
    public static let head: HTTPMethod = "HEAD"
    public static let options: HTTPMethod = "OPTIONS"
    public static let connect: HTTPMethod = "CONNECT"
}

public enum HTTPVersion: String, Codable, Equatable, Hashable, Sendable {
    case http10 = "HTTP/1.0"
    case http11 = "HTTP/1.1"
    case http2 = "HTTP/2"
    case http3 = "HTTP/3"
}

public struct HTTPRequest: Codable, Equatable, Hashable, Sendable {
    public let method: HTTPMethod
    public let url: URL
    public let headers: HTTPHeaders
    public private(set) var body: BodyReference?
    public let version: HTTPVersion
    public let rawTarget: String?
    public private(set) var graphqlOperation: GraphQLOperationMetadata?

    public init(
        method: HTTPMethod,
        url: URL,
        headers: HTTPHeaders = HTTPHeaders(),
        body: BodyReference? = nil,
        version: HTTPVersion = .http11,
        rawTarget: String? = nil,
        graphqlOperation: GraphQLOperationMetadata? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.version = version
        self.rawTarget = rawTarget
        self.graphqlOperation = graphqlOperation ?? Self.inferGraphQLOperation(from: body)
    }

    public mutating func attachBody(_ body: BodyReference) {
        self.body = body
        graphqlOperation = Self.inferGraphQLOperation(from: body)
    }

    public mutating func attachBody(
        _ body: BodyReference,
        graphqlOperation: GraphQLOperationMetadata?
    ) {
        self.body = body
        self.graphqlOperation = graphqlOperation
    }

    public func replacingHeaders(_ headers: HTTPHeaders) -> HTTPRequest {
        HTTPRequest(
            method: method,
            url: url,
            headers: headers,
            body: body,
            version: version,
            rawTarget: rawTarget,
            graphqlOperation: graphqlOperation
        )
    }

    public func replacingBody(_ body: BodyReference?) -> HTTPRequest {
        HTTPRequest(
            method: method,
            url: url,
            headers: headers,
            body: body,
            version: version,
            rawTarget: rawTarget
        )
    }

    public func replacingBody(
        _ body: BodyReference?,
        graphqlOperation: GraphQLOperationMetadata?
    ) -> HTTPRequest {
        HTTPRequest(
            method: method,
            url: url,
            headers: headers,
            body: body,
            version: version,
            rawTarget: rawTarget,
            graphqlOperation: graphqlOperation
        )
    }

    private static func inferGraphQLOperation(
        from body: BodyReference?
    ) -> GraphQLOperationMetadata? {
        guard let body, let data = body.inlineData else {
            return nil
        }
        return GraphQLBodyView.operationMetadata(
            data: data,
            contentType: body.contentType,
            contentEncoding: body.contentEncoding,
            isTruncated: body.isTruncated
        )
    }
}

public struct HTTPResponse: Codable, Equatable, Hashable, Sendable {
    public let statusCode: Int
    public let reasonPhrase: String?
    public let headers: HTTPHeaders
    public private(set) var body: BodyReference?
    public let version: HTTPVersion

    public init(
        statusCode: Int,
        reasonPhrase: String? = nil,
        headers: HTTPHeaders = HTTPHeaders(),
        body: BodyReference? = nil,
        version: HTTPVersion = .http11
    ) throws {
        guard (100...999).contains(statusCode) else {
            throw ProxyLensError.invalidStatusCode(statusCode)
        }

        self.statusCode = statusCode
        self.reasonPhrase = reasonPhrase
        self.headers = headers
        self.body = body
        self.version = version
    }

    public mutating func attachBody(_ body: BodyReference) {
        self.body = body
    }

    public func replacingHeaders(_ headers: HTTPHeaders) -> HTTPResponse {
        do {
            return try HTTPResponse(
                statusCode: statusCode,
                reasonPhrase: reasonPhrase,
                headers: headers,
                body: body,
                version: version
            )
        } catch {
            preconditionFailure("Replacing headers must preserve a valid HTTP status code")
        }
    }

    public func replacingBody(_ body: BodyReference?) -> HTTPResponse {
        do {
            return try HTTPResponse(
                statusCode: statusCode,
                reasonPhrase: reasonPhrase,
                headers: headers,
                body: body,
                version: version
            )
        } catch {
            preconditionFailure("Replacing the body must preserve a valid HTTP status code")
        }
    }
}
