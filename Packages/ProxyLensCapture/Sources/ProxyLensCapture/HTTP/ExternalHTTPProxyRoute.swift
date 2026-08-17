import Foundation
import NIOCore
import NIOHTTP1
import ProxyLensCore

enum ExternalHTTPProxyRouteError: Error, Equatable, LocalizedError, Sendable {
    case credentialsUnavailable
    case credentialsDoNotMatchConfiguration
    case invalidAbsoluteRequestTarget

    var errorDescription: String? {
        switch self {
        case .credentialsUnavailable:
            "External proxy credentials are unavailable."
        case .credentialsDoNotMatchConfiguration:
            "External proxy credentials do not match the saved configuration."
        case .invalidAbsoluteRequestTarget:
            "The external proxy request target could not be constructed."
        }
    }
}

struct ExternalHTTPProxyRoute: Sendable {
    let configuration: ExternalHTTPProxyConfiguration
    private let authorizationValue: String?

    init(
        configuration: ExternalHTTPProxyConfiguration,
        credentials: ExternalHTTPProxyCredentials?
    ) throws {
        if let username = configuration.username {
            guard let credentials else {
                throw ExternalHTTPProxyRouteError.credentialsUnavailable
            }
            guard credentials.username == username else {
                throw ExternalHTTPProxyRouteError.credentialsDoNotMatchConfiguration
            }
            let token = Data("\(credentials.username):\(credentials.password)".utf8)
                .base64EncodedString()
            authorizationValue = "Basic \(token)"
        } else {
            authorizationValue = nil
        }
        self.configuration = configuration
    }

    var endpoint: NetworkEndpoint { configuration.endpoint }

    func shouldProxy(_ target: ProxyTarget) -> Bool {
        configuration.shouldProxy(host: target.host)
    }

    func requestHead(
        forwarding head: HTTPRequestHead,
        to target: ProxyTarget
    ) throws -> HTTPRequestHead {
        var headers = head.headers
        headers.remove(name: "Proxy-Authorization")
        if let authorizationValue {
            headers.add(name: "Proxy-Authorization", value: authorizationValue)
        }
        return HTTPRequestHead(
            version: .http1_1,
            method: head.method,
            uri: try absoluteRequestTarget(for: target),
            headers: headers
        )
    }

    func connectRequestBytes(
        to target: ProxyTarget,
        allocator: ByteBufferAllocator
    ) -> ByteBuffer {
        let authority = connectAuthority(for: target)
        var request = "CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\n"
        request += "Proxy-Connection: keep-alive\r\n"
        if let authorizationValue {
            request += "Proxy-Authorization: \(authorizationValue)\r\n"
        }
        request += "\r\n"

        var buffer = allocator.buffer(capacity: request.utf8.count)
        buffer.writeString(request)
        return buffer
    }

    private func absoluteRequestTarget(for target: ProxyTarget) throws -> String {
        guard target.originForm == "*" || target.originForm.hasPrefix("/") else {
            throw ExternalHTTPProxyRouteError.invalidAbsoluteRequestTarget
        }
        let scheme = target.url.scheme?.lowercased() ?? "http"
        let authority = connectionAuthority(for: target)
        let path = target.originForm == "*" ? "/" : target.originForm
        return "\(scheme)://\(authority)\(path)"
    }

    /// Absolute-form request targets omit a default port, matching ordinary origin URLs.
    private func connectionAuthority(for target: ProxyTarget) -> String {
        let formattedHost = bracketedConnectionHost(for: target)
        let defaultPort = target.usesTLS ? 443 : 80
        return target.port == defaultPort ? formattedHost : "\(formattedHost):\(target.port)"
    }

    /// RFC 9110 requires the authority form of a `CONNECT` target to carry an explicit port, so the
    /// default port is never elided here.
    private func connectAuthority(for target: ProxyTarget) -> String {
        "\(bracketedConnectionHost(for: target)):\(target.port)"
    }

    private func bracketedConnectionHost(for target: ProxyTarget) -> String {
        target.connectionHost.contains(":") && !target.connectionHost.hasPrefix("[")
            ? "[\(target.connectionHost)]"
            : target.connectionHost
    }
}
