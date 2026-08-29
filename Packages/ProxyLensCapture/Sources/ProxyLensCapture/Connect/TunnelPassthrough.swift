import Foundation
import NIOCore
import ProxyLensCore

/// Builds the `Flow` that represents a spliced CONNECT tunnel — a host excluded from TLS
/// interception, so the proxy never sees inside it — and wires the byte-level splice both
/// listeners need once the upstream dial succeeds. Shared by every caller so the
/// construction and wiring logic each exist in exactly one place.
enum TunnelPassthrough {
    static let tunnelRelayHandlerName = "proxylens.tunnel.relay"

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

    /// Wires two already-connected channels into a spliced raw-byte tunnel: installs a
    /// `TunnelRelayHandler` on each side, connects them as peers, and re-enables `autoRead`
    /// on both only once both relays exist — never parsing, decoding, or retaining the
    /// tunnel's payload bytes beyond the one-shot `extraUpstreamBytes` replay below.
    ///
    /// `prelude` runs first, before either relay is installed: the caller's chance to do
    /// protocol-specific work on `clientChannel` while it is still known nothing exists yet
    /// that would race the relay (HTTP CONNECT removes its plaintext HTTP handlers and writes
    /// `200 Connection Established`; SOCKS5 removes itself from the pipeline — there is
    /// nothing left to write, since the SOCKS success reply already went out before
    /// classification). `extraUpstreamBytes` are written and flushed to `upstreamChannel`
    /// once both relays are wired but before `autoRead` returns — SOCKS5-only, for the
    /// ClientHello bytes it already consumed while classifying the connection, which must be
    /// replayed to the origin rather than lost.
    ///
    /// This function's own success-case `markUpstreamConnected` Task, the `clientRelay`
    /// `onClose` Task the caller wires up, and the caller's own `transaction.start` Task all
    /// target the same `transaction` from independent, unstructured `Task {}`s with no
    /// ordering guarantee relative to one another. Every interleaving still ends the flow
    /// correctly: `FlowTransaction.start` only acts while the flow is still `.created`,
    /// `.created → .failed` is a permitted transition (so a `fail` landing before `start`
    /// still terminates the flow), and `finishResponse` defers completion until the request
    /// side has also finished — so whichever of these lands first, the flow still reaches
    /// exactly one terminal event.
    @discardableResult
    static func splice(
        clientChannel: Channel,
        upstreamChannel: Channel,
        clientRelay: TunnelRelayHandler,
        transaction: FlowTransaction?,
        extraUpstreamBytes: [ByteBuffer] = [],
        prelude: @escaping @Sendable () -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Void> {
        let upstreamRelay = TunnelRelayHandler()
        let loopBoundClientRelay = NIOLoopBound(clientRelay, eventLoop: clientChannel.eventLoop)
        let loopBoundUpstreamRelay = NIOLoopBound(
            upstreamRelay, eventLoop: clientChannel.eventLoop)

        return prelude().flatMapThrowing {
            let clientRelay = loopBoundClientRelay.value
            let upstreamRelay = loopBoundUpstreamRelay.value
            try clientChannel.pipeline.syncOperations.addHandler(
                clientRelay,
                name: tunnelRelayHandlerName
            )
            try upstreamChannel.pipeline.syncOperations.addHandler(
                upstreamRelay,
                name: tunnelRelayHandlerName
            )
            clientRelay.connectPeer(upstreamChannel)
            upstreamRelay.connectPeer(clientChannel)
            guard !extraUpstreamBytes.isEmpty else { return }
            for buffer in extraUpstreamBytes {
                upstreamChannel.write(buffer, promise: nil)
            }
            upstreamChannel.flush()
        }.flatMap {
            // Both sides were held at autoRead false until the relay handlers above were
            // installed — re-enable both here, not just the client, or the upstream side
            // never reads what the origin already has buffered.
            clientChannel.setOption(ChannelOptions.autoRead, value: true)
        }.flatMap {
            upstreamChannel.setOption(ChannelOptions.autoRead, value: true)
        }.map {
            if let transaction {
                Task { await transaction.markUpstreamConnected(at: Date()) }
            }
        }.flatMapError { error in
            if let transaction {
                Task { await transaction.fail(.upstreamUnavailable) }
            }
            upstreamChannel.close(promise: nil)
            clientChannel.close(promise: nil)
            return clientChannel.eventLoop.makeFailedFuture(error)
        }
    }
}
