import Foundation
import NIOHTTP1
import ProxyLensCore

struct ProxyConnectionIdentity: Equatable, Hashable, Sendable {
    let logicalHost: String
    let connectionHost: String
    let port: Int
    let usesTLS: Bool
}

struct ProxyTarget: Sendable {
    let url: URL
    let host: String
    let connectionHost: String
    let port: Int
    let originForm: String
    let usesTLS: Bool

    var hostHeader: String {
        let formattedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let defaultPort = usesTLS ? 443 : 80
        if port == defaultPort {
            return formattedHost
        }
        return "\(formattedHost):\(port)"
    }

    var connectionIdentity: ProxyConnectionIdentity {
        ProxyConnectionIdentity(
            logicalHost: host.lowercased(),
            connectionHost: connectionHost.lowercased(),
            port: port,
            usesTLS: usesTLS
        )
    }

    func connecting(to address: String) -> ProxyTarget {
        ProxyTarget(
            url: url,
            host: host,
            connectionHost: address,
            port: port,
            originForm: originForm,
            usesTLS: usesTLS
        )
    }

    init(
        uri: String,
        headers: NIOHTTP1.HTTPHeaders,
        tunnelTarget: ConnectTarget? = nil,
        tunnelUsesTLS: Bool = true
    ) throws {
        if let tunnelTarget {
            try self.init(tunneledURI: uri, target: tunnelTarget, usesTLS: tunnelUsesTLS)
            return
        }

        let parsedURL: URL
        let originForm: String

        if let absoluteURL = URL(string: uri), let scheme = absoluteURL.scheme {
            let normalizedScheme = scheme.lowercased()
            guard ["http", "https", "ws", "wss"].contains(normalizedScheme) else {
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

        let usesTLS =
            parsedURL.scheme?.lowercased() == "https"
            || parsedURL.scheme?.lowercased() == "wss"
        let port = parsedURL.port ?? (usesTLS ? 443 : 80)
        guard (1...65_535).contains(port) else {
            throw ProxyTargetError.invalidPort(port)
        }

        self.init(
            url: parsedURL,
            host: host,
            port: port,
            originForm: originForm.isEmpty ? "/" : originForm,
            usesTLS: usesTLS
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

    init(url: URL) throws {
        guard let scheme = url.scheme?.lowercased(),
            ["http", "https", "ws", "wss"].contains(scheme)
        else {
            throw ProxyTargetError.unsupportedScheme(url.scheme ?? "")
        }
        guard let host = url.host, !host.isEmpty else {
            throw ProxyTargetError.missingHost
        }
        guard url.user == nil, url.password == nil, url.fragment == nil else {
            throw ProxyTargetError.invalidURI(url.absoluteString)
        }

        let usesTLS = scheme == "https" || scheme == "wss"
        let port = url.port ?? (usesTLS ? 443 : 80)
        guard (1...65_535).contains(port) else {
            throw ProxyTargetError.invalidPort(port)
        }

        self.init(
            url: url,
            host: host,
            port: port,
            originForm: Self.originForm(for: url),
            usesTLS: usesTLS
        )
    }

    private init(tunneledURI uri: String, target: ConnectTarget, usesTLS: Bool) throws {
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
        components.scheme = usesTLS ? "https" : "http"
        // `URLComponents` yields a nil URL for an unbracketed IPv6 literal host.
        components.host = target.host.contains(":") ? "[\(target.host)]" : target.host
        if target.port != (usesTLS ? 443 : 80) {
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
            usesTLS: usesTLS
        )
    }

    private init(
        url: URL,
        host: String,
        connectionHost: String? = nil,
        port: Int,
        originForm: String,
        usesTLS: Bool
    ) {
        self.url = url
        self.host = host
        self.connectionHost = connectionHost ?? host
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
