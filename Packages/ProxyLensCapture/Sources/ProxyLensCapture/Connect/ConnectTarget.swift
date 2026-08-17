import Foundation

struct ConnectTarget: Equatable, Hashable, Sendable {
    let host: String
    let port: Int

    init(authority: String) throws {
        guard !authority.isEmpty,
            let components = URLComponents(string: "https://\(authority)"),
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.path.isEmpty,
            let host = components.host,
            !host.isEmpty
        else {
            throw ConnectTargetError.invalidAuthority(authority)
        }

        try self.init(host: host, port: components.port ?? 443)
    }

    init(host: String, port: Int) throws {
        var normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        // `URLComponents.host` reports IPv6 literals bracketed, while `URL.host`, SOCKS5 address
        // bytes, and the stored form are unbracketed. Normalize to the unbracketed spelling here so
        // every caller agrees, and rebracket only where a URL or wire authority is built.
        if normalizedHost.hasPrefix("["), normalizedHost.hasSuffix("]") {
            let literal = String(normalizedHost.dropFirst().dropLast())
            guard literal.contains(":") else {
                throw ConnectTargetError.invalidAuthority(host)
            }
            normalizedHost = literal
        }
        guard !normalizedHost.isEmpty,
            !normalizedHost.contains("["),
            !normalizedHost.contains("]"),
            normalizedHost.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            }),
            !normalizedHost.contains(where: \Character.isWhitespace)
        else {
            throw ConnectTargetError.invalidAuthority(host)
        }
        guard (1...65_535).contains(port) else {
            throw ConnectTargetError.invalidPort(port)
        }

        let authorityHost = normalizedHost.contains(":") ? "[\(normalizedHost)]" : normalizedHost
        guard let components = URLComponents(string: "https://\(authorityHost):\(port)"),
            components.host != nil,
            components.url != nil
        else {
            throw ConnectTargetError.invalidAuthority(host)
        }

        self.host = normalizedHost
        self.port = port
    }
}

enum ConnectTargetError: Error, Equatable, LocalizedError, Sendable {
    case invalidAuthority(String)
    case invalidPort(Int)

    var errorDescription: String? {
        switch self {
        case .invalidAuthority(let authority):
            "Invalid CONNECT authority: \(authority)"
        case .invalidPort(let port):
            "Invalid CONNECT port: \(port)"
        }
    }
}
