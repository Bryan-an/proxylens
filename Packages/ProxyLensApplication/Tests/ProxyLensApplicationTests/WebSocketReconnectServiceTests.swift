import Foundation
import ProxyLensCore
import XCTest

@testable import ProxyLensApplication

final class WebSocketReconnectServiceTests: XCTestCase {
    func testReconnectBuildsAWebSocketGETAndPassesOneBoundedInitialMessage() async throws {
        let sessionID = SessionID()
        let result = Self.liveFlow(sessionID: sessionID)
        let client = RecordingWebSocketConnectionClient(result: result)
        var headers = HTTPHeaders()
        try headers.append(name: "Authorization", value: "Bearer local-secret")
        try headers.append(name: "Sec-WebSocket-Protocol", value: "graphql-transport-ws")
        let service = WebSocketComposeService(
            transmitters: [client],
            connectionClient: client,
            maximumPayloadBytes: 64,
            maximumReconnectHeaderBytes: 1_024
        )

        let connected = try await service.reconnect(
            WebSocketReconnectRequest(
                url: try XCTUnwrap(URL(string: "wss://socket.example.com/events?channel=1")),
                headers: headers,
                replayPayload: WebSocketReplayPayload(
                    encoding: .text,
                    payload: #"{"type":"ping"}"#
                )
            ),
            sessionID: sessionID
        )

        XCTAssertEqual(connected, result)
        let attempts = await client.connectionAttempts()
        XCTAssertEqual(attempts.count, 1)
        XCTAssertEqual(attempts[0].request.method, .get)
        XCTAssertEqual(attempts[0].request.version, .http11)
        XCTAssertEqual(
            attempts[0].request.url.absoluteString,
            "wss://socket.example.com/events?channel=1"
        )
        XCTAssertEqual(attempts[0].request.headers, headers)
        XCTAssertNil(attempts[0].request.body)
        XCTAssertEqual(attempts[0].sessionID, sessionID)
        XCTAssertEqual(
            attempts[0].initialMessage,
            WebSocketClientMessage(
                opcode: .text,
                payload: Data(#"{"type":"ping"}"#.utf8)
            )
        )
    }

    func testReconnectCanOpenWithoutSendingAndDecodesBinaryReplay() async throws {
        let result = Self.liveFlow()
        let client = RecordingWebSocketConnectionClient(result: result)
        let service = WebSocketComposeService(
            transmitters: [client],
            connectionClient: client,
            maximumPayloadBytes: 8
        )

        _ = try await service.reconnect(
            WebSocketReconnectRequest(
                url: try XCTUnwrap(URL(string: "ws://127.0.0.1:9090/socket"))
            ),
            sessionID: result.sessionID
        )
        _ = try await service.reconnect(
            WebSocketReconnectRequest(
                url: try XCTUnwrap(URL(string: "ws://127.0.0.1:9090/socket")),
                replayPayload: WebSocketReplayPayload(
                    encoding: .base64,
                    payload: Data([0x00, 0x7F, 0xFF]).base64EncodedString()
                )
            ),
            sessionID: result.sessionID
        )

        let attempts = await client.connectionAttempts()
        XCTAssertNil(attempts[0].initialMessage)
        XCTAssertEqual(
            attempts[1].initialMessage,
            WebSocketClientMessage(opcode: .binary, payload: Data([0x00, 0x7F, 0xFF]))
        )
    }

    func testReconnectRejectsUnsafeURLsHeadersAndPayloadsBeforeOpening() async throws {
        let result = Self.liveFlow()
        let client = RecordingWebSocketConnectionClient(result: result)
        let service = WebSocketComposeService(
            transmitters: [client],
            connectionClient: client,
            maximumPayloadBytes: 4,
            maximumReconnectHeaderBytes: 16
        )

        for value in [
            "https://example.com/socket",
            "ws://user:password@example.com/socket",
            "wss://example.com/socket#fragment"
        ] {
            do {
                _ = try await service.reconnect(
                    WebSocketReconnectRequest(url: try XCTUnwrap(URL(string: value))),
                    sessionID: result.sessionID
                )
                XCTFail("Expected \(value) to be rejected")
            } catch is WebSocketReconnectError {
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        var largeHeaders = HTTPHeaders()
        try largeHeaders.append(name: "X-Long", value: String(repeating: "a", count: 20))
        do {
            _ = try await service.reconnect(
                WebSocketReconnectRequest(
                    url: try XCTUnwrap(URL(string: "ws://example.com/socket")),
                    headers: largeHeaders
                ),
                sessionID: result.sessionID
            )
            XCTFail("Expected oversized headers to be rejected")
        } catch let error as WebSocketReconnectError {
            XCTAssertEqual(error, .headersTooLarge(maximumBytes: 16))
        }

        for payload in [
            WebSocketReplayPayload(encoding: .base64, payload: "not base64"),
            WebSocketReplayPayload(encoding: .text, payload: "12345")
        ] {
            do {
                _ = try await service.reconnect(
                    WebSocketReconnectRequest(
                        url: try XCTUnwrap(URL(string: "ws://example.com/socket")),
                        replayPayload: payload
                    ),
                    sessionID: result.sessionID
                )
                XCTFail("Expected invalid replay payload to be rejected")
            } catch is WebSocketComposeError {
            }
        }

        let attempts = await client.connectionAttempts()
        XCTAssertTrue(attempts.isEmpty)
    }

    func testComposeRoutesToTheOpenTransportAndDisconnectUsesTheFreshClient() async throws {
        let interceptedFlowID = FlowID()
        let replayFlow = Self.liveFlow()
        let intercepted = RecordingWebSocketFrameTransmitter(openFlowIDs: [interceptedFlowID])
        let client = RecordingWebSocketConnectionClient(result: replayFlow)
        let service = WebSocketComposeService(
            transmitters: [intercepted, client],
            connectionClient: client
        )

        try await service.send(
            WebSocketComposeRequest(
                flowID: interceptedFlowID,
                direction: .serverToClient,
                payloadEncoding: .text,
                payload: "intercepted"
            )
        )
        try await service.send(
            WebSocketComposeRequest(
                flowID: replayFlow.id,
                direction: .clientToServer,
                payloadEncoding: .text,
                payload: "fresh"
            )
        )
        await service.disconnect(flowID: replayFlow.id)

        let interceptedPayloads = await intercepted.transmissions().map(\.payload)
        let clientPayloads = await client.transmissions().map(\.payload)
        let disconnectedFlowIDs = await client.disconnectedFlowIDs()
        XCTAssertEqual(interceptedPayloads, [Data("intercepted".utf8)])
        XCTAssertEqual(clientPayloads, [Data("fresh".utf8)])
        XCTAssertEqual(disconnectedFlowIDs, [replayFlow.id])
    }

    private static func liveFlow(sessionID: SessionID = SessionID()) -> Flow {
        Flow(
            sessionID: sessionID,
            source: .replay,
            request: HTTPRequest(
                method: .get,
                url: URL(string: "ws://127.0.0.1/socket")!
            ),
            connection: ConnectionInfo(
                protocolKind: .webSocket,
                upstreamHost: "127.0.0.1",
                upstreamPort: 80
            )
        )
    }
}

private actor RecordingWebSocketConnectionClient: WebSocketConnectionClient {
    struct Attempt: Sendable {
        let request: HTTPRequest
        let initialMessage: WebSocketClientMessage?
        let sessionID: SessionID
    }

    private let result: Flow
    private var attempts: [Attempt] = []
    private var sent: [WebSocketFrameTransmission] = []
    private var disconnected: [FlowID] = []

    init(result: Flow) {
        self.result = result
    }

    func connect(
        _ request: HTTPRequest,
        initialMessage: WebSocketClientMessage?,
        sessionID: SessionID
    ) -> Flow {
        attempts.append(
            Attempt(request: request, initialMessage: initialMessage, sessionID: sessionID)
        )
        return result
    }

    func disconnect(flowID: FlowID) {
        disconnected.append(flowID)
    }

    func isConnectionOpen(for flowID: FlowID) -> Bool {
        flowID == result.id
    }

    func send(_ transmission: WebSocketFrameTransmission) {
        sent.append(transmission)
    }

    func connectionAttempts() -> [Attempt] {
        attempts
    }

    func transmissions() -> [WebSocketFrameTransmission] {
        sent
    }

    func disconnectedFlowIDs() -> [FlowID] {
        disconnected
    }
}

private actor RecordingWebSocketFrameTransmitter: WebSocketFrameTransmitter {
    private let openFlowIDs: Set<FlowID>
    private var sent: [WebSocketFrameTransmission] = []

    init(openFlowIDs: Set<FlowID>) {
        self.openFlowIDs = openFlowIDs
    }

    func isConnectionOpen(for flowID: FlowID) -> Bool {
        openFlowIDs.contains(flowID)
    }

    func send(_ transmission: WebSocketFrameTransmission) {
        sent.append(transmission)
    }

    func transmissions() -> [WebSocketFrameTransmission] {
        sent
    }
}
