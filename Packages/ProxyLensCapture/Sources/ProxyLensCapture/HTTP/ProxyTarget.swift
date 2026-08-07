import Foundation
import NIOHTTP1

struct ProxyTarget: Sendable {
    let url: URL
    let host: String
    let port: Int
    let originForm: String

    init(uri: String, headers: NIOHTTP1.HTTPHeaders) throws {
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

        self.url = parsedURL
        self.host = host
        self.port = port
        self.originForm = originForm.isEmpty ? "/" : originForm
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
