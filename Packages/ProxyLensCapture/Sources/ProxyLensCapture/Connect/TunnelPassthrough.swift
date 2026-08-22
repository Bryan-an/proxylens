import Foundation
import ProxyLensCore

/// Builds the `Flow` that represents a spliced CONNECT tunnel — a host excluded from TLS
/// interception, so the proxy never sees inside it. Shared by every caller that needs to
/// record such a tunnel so the construction logic exists in exactly one place.
enum TunnelPassthrough {
    static func makeFlow(
        sessionID: SessionID,
        source: FlowSource,
        target: ConnectTarget
    ) -> Flow? {
        let formattedHost = target.host.contains(":") ? "[\(target.host)]" : target.host
        guard let url = URL(string: "https://\(formattedHost):\(target.port)/") else {
            return nil
        }
        return Flow(
            sessionID: sessionID,
            source: source,
            request: HTTPRequest(
                method: .connect,
                url: url,
                rawTarget: "\(target.host):\(target.port)"
            ),
            connection: ConnectionInfo(
                protocolKind: .https,
                upstreamHost: target.host,
                upstreamPort: UInt16(target.port),
                tlsIntercepted: false
            )
        )
    }
}
