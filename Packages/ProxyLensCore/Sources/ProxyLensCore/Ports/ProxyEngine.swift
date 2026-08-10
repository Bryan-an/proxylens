import Foundation

public struct NetworkEndpoint: Codable, Equatable, Hashable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

public struct ProxyConfiguration: Codable, Equatable, Hashable, Sendable {
    public let listenEndpoint: NetworkEndpoint
    public let interceptHTTPS: Bool

    public init(listenEndpoint: NetworkEndpoint, interceptHTTPS: Bool = true) {
        self.listenEndpoint = listenEndpoint
        self.interceptHTTPS = interceptHTTPS
    }
}

public enum ProxyEngineState: Codable, Equatable, Hashable, Sendable {
    case stopped
    case starting
    case running(NetworkEndpoint)
    case stopping
    case failed(String)
}

public protocol ProxyEngine: Sendable {
    func start(configuration: ProxyConfiguration, sessionID: SessionID) async throws
    func stop() async
    func state() async -> ProxyEngineState
}
