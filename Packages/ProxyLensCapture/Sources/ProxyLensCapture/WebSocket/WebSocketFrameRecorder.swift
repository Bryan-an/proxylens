import Foundation
import NIOWebSocket
import ProxyLensCore

struct WebSocketFrameRecorder: Sendable {
    private let bodyStore: any BodyStore
    private let maximumCapturedFrameBytes: Int64
    private let eventSink: any WebSocketFrameEventSink

    init(
        bodyStore: any BodyStore,
        maximumCapturedFrameBytes: Int64,
        eventSink: any WebSocketFrameEventSink
    ) {
        self.bodyStore = bodyStore
        self.maximumCapturedFrameBytes = max(0, maximumCapturedFrameBytes)
        self.eventSink = eventSink
    }

    func record(
        _ frame: WebSocketFrame,
        flowID: FlowID,
        sequenceNumber: Int64,
        direction: WebSocketFrameDirection,
        receivedAt: Date = Date()
    ) async throws {
        let writer = try await bodyStore.beginWrite(
            metadata: BodyMetadata(contentType: Self.contentType(for: frame.opcode)),
            maximumByteCount: maximumCapturedFrameBytes
        )
        do {
            try await writer.append(Data(frame.unmaskedData.readableBytesView))
            let payload = try await writer.finalize()
            await eventSink.publish(
                CapturedWebSocketFrame(
                    flowID: flowID,
                    sequenceNumber: sequenceNumber,
                    direction: direction,
                    opcode: WebSocketFrameRelay.capturedOpcode(frame.opcode),
                    isFinal: frame.fin,
                    reservedBits: WebSocketFrameRelay.reservedBits(frame),
                    wasMasked: frame.maskKey != nil,
                    payload: payload,
                    receivedAt: receivedAt
                )
            )
        } catch {
            await writer.cancel()
            throw error
        }
    }

    private static func contentType(for opcode: WebSocketOpcode) -> String {
        switch opcode {
        case .text: "text/plain; charset=utf-8"
        default: "application/octet-stream"
        }
    }
}

struct NoOpWebSocketFrameEventSink: WebSocketFrameEventSink {
    func publish(_: CapturedWebSocketFrame) async {}
}
