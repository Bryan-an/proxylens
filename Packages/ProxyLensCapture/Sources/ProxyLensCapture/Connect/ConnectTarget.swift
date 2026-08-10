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

        let port = components.port ?? 443
        guard (1...65_535).contains(port) else {
            throw ConnectTargetError.invalidPort(port)
        }

        self.host = host
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
