import Foundation
import NIOHTTP1
import ProxyLensCore

struct ProxyTarget: Sendable {
    let url: URL
    let host: String
    let port: Int
    let originForm: String
    let usesTLS: Bool

    init(
        uri: String,
        headers: NIOHTTP1.HTTPHeaders,
        tunnelTarget: ConnectTarget? = nil
    ) throws {
        if let tunnelTarget {
            try self.init(tunneledURI: uri, target: tunnelTarget)
            return
        }

        let parsedURL: URL
        let originForm: String

        if let absoluteURL = URL(string: uri), let scheme = absoluteURL.scheme {
            guard scheme.caseInsensitiveCompare("http") == .orderedSame else {
                throw ProxyTargetError.unsupportedScheme(scheme)
            }

            parsedURL = absoluteURL
            originForm = Self.originForm(for: absoluteURL)
        } else {
            guard uri == "*" || uri.hasPrefix("/") else {
                throw ProxyTargetError.invalidURI(uri)
            }

            guard let host = headers.first(name: "host"), !host.isEmpty,
                let absoluteURL = URL(string: "http://\(host)\(uri == "*" ? "/" : uri)")
            else {
                throw ProxyTargetError.missingHost
            }

            parsedURL = absoluteURL
            originForm = uri
        }

        guard let host = parsedURL.host, !host.isEmpty else {
            throw ProxyTargetError.missingHost
        }

        guard parsedURL.user == nil, parsedURL.password == nil, parsedURL.fragment == nil else {
            throw ProxyTargetError.invalidURI(uri)
        }

        let port = parsedURL.port ?? 80
        guard (1...65_535).contains(port) else {
            throw ProxyTargetError.invalidPort(port)
        }

        self.init(
            url: parsedURL,
            host: host,
            port: port,
            originForm: originForm.isEmpty ? "/" : originForm,
            usesTLS: false
        )
    }

    init(_ mapped: MappedRemoteTarget) {
        self.init(
            url: mapped.url,
            host: mapped.host,
            port: mapped.port,
            originForm: mapped.originForm,
            usesTLS: mapped.usesTLS
        )
    }

    private init(tunneledURI uri: String, target: ConnectTarget) throws {
        guard uri == "*" || uri.hasPrefix("/"),
            let relativeComponents = URLComponents(string: uri == "*" ? "/" : uri),
            relativeComponents.scheme == nil,
            relativeComponents.host == nil,
            relativeComponents.user == nil,
            relativeComponents.password == nil,
            relativeComponents.fragment == nil
        else {
            throw ProxyTargetError.invalidURI(uri)
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = target.host
        if target.port != 443 {
            components.port = target.port
        }
        components.percentEncodedPath =
            relativeComponents.percentEncodedPath.isEmpty
            ? "/"
            : relativeComponents.percentEncodedPath
        components.percentEncodedQuery = relativeComponents.percentEncodedQuery

        guard let url = components.url else {
            throw ProxyTargetError.invalidURI(uri)
        }

        self.init(
            url: url,
            host: target.host,
            port: target.port,
            originForm: uri == "*" ? "*" : uri,
            usesTLS: true
        )
    }

    private init(
        url: URL,
        host: String,
        port: Int,
        originForm: String,
        usesTLS: Bool
    ) {
        self.url = url
        self.host = host
        self.port = port
        self.originForm = originForm
        self.usesTLS = usesTLS
    }

    private static func originForm(for url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let encodedPath = components?.percentEncodedPath ?? url.path
        let path = encodedPath.isEmpty ? "/" : encodedPath
        let query = components?.percentEncodedQuery.map { "?\($0)" } ?? ""
        return path + query
    }
}

enum ProxyTargetError: Error, Equatable, LocalizedError, Sendable {
    case invalidURI(String)
    case invalidPort(Int)
    case missingHost
    case unsupportedScheme(String)

    var errorDescription: String? {
        switch self {
        case .invalidURI(let uri):
            "Invalid HTTP request target: \(uri)"
        case .invalidPort(let port):
            "Invalid upstream port: \(port)"
        case .missingHost:
            "The request does not contain an upstream host"
        case .unsupportedScheme(let scheme):
            "Unsupported request scheme: \(scheme)"
        }
    }
}
