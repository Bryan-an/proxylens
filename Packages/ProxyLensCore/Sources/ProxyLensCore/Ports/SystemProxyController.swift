import Foundation

public struct SystemProxyConfiguration: Codable, Equatable, Hashable, Sendable {
    public let httpEndpoint: NetworkEndpoint?
    public let httpsEndpoint: NetworkEndpoint?
    public let bypassDomains: [String]

    public init(
        httpEndpoint: NetworkEndpoint? = nil,
        httpsEndpoint: NetworkEndpoint? = nil,
        bypassDomains: [String] = []
    ) {
        self.httpEndpoint = httpEndpoint
        self.httpsEndpoint = httpsEndpoint
        self.bypassDomains = bypassDomains
    }
}

public protocol SystemProxyController: Sendable {
    func currentConfiguration() async throws -> SystemProxyConfiguration
    func apply(_ configuration: SystemProxyConfiguration) async throws
    func restore(_ configuration: SystemProxyConfiguration) async throws
}
