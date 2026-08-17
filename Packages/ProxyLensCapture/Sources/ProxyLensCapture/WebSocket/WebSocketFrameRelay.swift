import NIOWebSocket
import ProxyLensCore

enum WebSocketFrameRelay {
    static func forwardedFrame(
        _ frame: WebSocketFrame,
        direction: WebSocketFrameDirection
    ) -> WebSocketFrame {
        WebSocketFrame(
            fin: frame.fin,
            rsv1: frame.rsv1,
            rsv2: frame.rsv2,
            rsv3: frame.rsv3,
            opcode: frame.opcode,
            maskKey: direction == .clientToServer ? .random() : nil,
            data: frame.unmaskedData,
            extensionData: frame.unmaskedExtensionData
        )
    }

    static func capturedOpcode(_ opcode: WebSocketOpcode) -> WebSocketFrameOpcode {
        switch opcode {
        case .continuation: .continuation
        case .text: .text
        case .binary: .binary
        case .connectionClose: .close
        case .ping: .ping
        case .pong: .pong
        default: .unknown(UInt8(webSocketOpcode: opcode))
        }
    }

    static func reservedBits(_ frame: WebSocketFrame) -> WebSocketReservedBits {
        var bits: WebSocketReservedBits = []
        if frame.rsv1 { bits.insert(.rsv1) }
        if frame.rsv2 { bits.insert(.rsv2) }
        if frame.rsv3 { bits.insert(.rsv3) }
        return bits
    }
}
