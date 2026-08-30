import Foundation

public protocol FlowSourceResolver: Sendable {
    func resolveSource(
        clientEndpoint: NetworkEndpoint,
        proxyEndpoint: NetworkEndpoint
    ) async -> FlowSource
}

public struct UnknownFlowSourceResolver: FlowSourceResolver {
    public init() {}

    public func resolveSource(
        clientEndpoint: NetworkEndpoint,
        proxyEndpoint _: NetworkEndpoint
    ) async -> FlowSource {
        guard NetworkAddress.isLoopback(clientEndpoint.host) else {
            return FlowSource.remoteDevice(
                address: clientEndpoint.host,
                port: clientEndpoint.port
            )
        }
        return FlowSource(
            kind: .desktopProxy,
            label: "Desktop proxy",
            clientAddress: Self.address(clientEndpoint)
        )
    }

    private static func address(_ endpoint: NetworkEndpoint) -> String {
        let host = endpoint.host.contains(":") ? "[\(endpoint.host)]" : endpoint.host
        return "\(host):\(endpoint.port)"
    }
}
