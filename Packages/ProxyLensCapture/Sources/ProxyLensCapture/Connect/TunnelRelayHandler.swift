import NIOCore

/// Byte-level half of a spliced tunnel. One instance sits on each channel and forwards
/// raw bytes to the peer channel; nothing is parsed, decoded, or retained beyond the
/// pre-splice buffer.
final class TunnelRelayHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private var peer: Channel?
    private var bufferedReads: [ByteBuffer] = []
    private var didClose = false
    private let onClose: (@Sendable () -> Void)?

    init(onClose: (@Sendable () -> Void)? = nil) {
        self.onClose = onClose
    }

    /// Call on this handler's own event loop once the other side of the tunnel exists.
    func connectPeer(_ channel: Channel) {
        peer = channel
        let buffered = bufferedReads
        bufferedReads.removeAll(keepingCapacity: false)
        for buffer in buffered {
            channel.write(buffer, promise: nil)
        }
        if !buffered.isEmpty {
            channel.flush()
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = Self.unwrapInboundIn(data)
        guard let peer else {
            bufferedReads.append(buffer)
            return
        }
        peer.writeAndFlush(buffer, promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        // When this side's outbound buffer fills, stop the peer from reading more
        // until it drains; resume (and prime a read) once writable again.
        let isWritable = context.channel.isWritable
        peer?.setOption(ChannelOptions.autoRead, value: isWritable).whenSuccess { [peer] in
            if isWritable {
                peer?.read()
            }
        }
        context.fireChannelWritabilityChanged()
    }

    func channelInactive(context: ChannelHandlerContext) {
        closeTunnel()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        closeTunnel()
        context.close(promise: nil)
    }

    private func closeTunnel() {
        guard !didClose else { return }
        didClose = true
        peer?.close(promise: nil)
        onClose?()
    }
}
