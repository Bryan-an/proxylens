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
    /// Restores a proxy configuration left active by an interrupted capture.
    func recoverInterruptedConfiguration() async throws

    /// Durably snapshots the current proxy configuration before it is changed.
    func prepareForProxyActivation() async throws

    /// Applies ProxyLens endpoints after a restorable snapshot has been saved.
    func apply(_ configuration: SystemProxyConfiguration) async throws

    /// Restores the durable snapshot and removes it after a successful restore.
    func restorePreviousConfiguration() async throws
}
