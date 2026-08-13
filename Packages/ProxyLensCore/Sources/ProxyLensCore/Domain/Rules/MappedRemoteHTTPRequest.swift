import Foundation

/// The rewritten upstream destination produced by a Map Remote rule.
public struct MappedRemoteTarget: Equatable, Hashable, Sendable {
    public let url: URL
    public let host: String
    public let port: Int
    public let originForm: String
    public let usesTLS: Bool
    public let hostHeader: String

    public init(
        url: URL,
        host: String,
        port: Int,
        originForm: String,
        usesTLS: Bool,
        hostHeader: String
    ) {
        self.url = url
        self.host = host
        self.port = port
        self.originForm = originForm
        self.usesTLS = usesTLS
        self.hostHeader = hostHeader
    }
}

/// Rewrites a request destination for Map Remote. Matching stays in `RulePlanner`;
/// this type only builds the new upstream URL, origin-form path, and Host header.
public enum MappedRemoteHTTPRequest: Sendable {
    public static func make(originalURL: URL, destination: URL) throws -> MappedRemoteTarget {
        guard
            let destinationComponents = URLComponents(
                url: destination,
                resolvingAgainstBaseURL: false
            )
        else {
            throw ProxyLensError.invalidURL(destination.absoluteString)
        }

        let scheme = (destinationComponents.scheme ?? "").lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw ProxyLensError.unsupportedOperation(
                "Map Remote destination must use http or https"
            )
        }

        guard let host = destinationComponents.host, !host.isEmpty else {
            throw ProxyLensError.invalidURL(destination.absoluteString)
        }

        guard destinationComponents.user == nil,
            destinationComponents.password == nil,
            destinationComponents.fragment == nil
        else {
            throw ProxyLensError.invalidURL(destination.absoluteString)
        }

        let usesTLS = scheme == "https"
        let defaultPort = usesTLS ? 443 : 80
        let port = destinationComponents.port ?? defaultPort
        guard (1...65_535).contains(port) else {
            throw ProxyLensError.invalidURL(destination.absoluteString)
        }

        let destinationPath = destinationComponents.percentEncodedPath
        let isOriginOnly =
            (destinationPath.isEmpty || destinationPath == "/")
            && destinationComponents.percentEncodedQuery == nil

        var rewritten = URLComponents()
        rewritten.scheme = scheme
        rewritten.host = host
        if port != defaultPort {
            rewritten.port = port
        }

        if isOriginOnly {
            let original = URLComponents(url: originalURL, resolvingAgainstBaseURL: false)
            let originalPath = original?.percentEncodedPath ?? originalURL.path
            rewritten.percentEncodedPath = originalPath.isEmpty ? "/" : originalPath
            rewritten.percentEncodedQuery = original?.percentEncodedQuery
        } else {
            rewritten.percentEncodedPath = destinationPath.isEmpty ? "/" : destinationPath
            rewritten.percentEncodedQuery = destinationComponents.percentEncodedQuery
        }

        guard let url = rewritten.url else {
            throw ProxyLensError.invalidURL(destination.absoluteString)
        }

        let originPath = rewritten.percentEncodedPath.isEmpty ? "/" : rewritten.percentEncodedPath
        let originQuery = rewritten.percentEncodedQuery.map { "?\($0)" } ?? ""

        return MappedRemoteTarget(
            url: url,
            host: host,
            port: port,
            originForm: originPath + originQuery,
            usesTLS: usesTLS,
            hostHeader: hostHeader(host: host, port: port, defaultPort: defaultPort)
        )
    }

    public static func validateDestination(_ destination: URL) throws {
        _ = try make(originalURL: destination, destination: destination)
    }

    private static func hostHeader(host: String, port: Int, defaultPort: Int) -> String {
        let formattedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        if port == defaultPort {
            return formattedHost
        }
        return "\(formattedHost):\(port)"
    }
}
