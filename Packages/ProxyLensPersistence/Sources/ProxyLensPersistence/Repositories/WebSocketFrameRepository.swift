import Foundation
import GRDB
import ProxyLensCore

struct WebSocketFrameRepository: Sendable {
    static func save(_ frame: CapturedWebSocketFrame, in database: Database) throws {
        try database.execute(
            sql: """
                INSERT INTO websocket_frames (
                    id, flow_id, sequence_number, direction, opcode, received_at,
                    payload_byte_count, snapshot, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    flow_id = excluded.flow_id,
                    sequence_number = excluded.sequence_number,
                    direction = excluded.direction,
                    opcode = excluded.opcode,
                    received_at = excluded.received_at,
                    payload_byte_count = excluded.payload_byte_count,
                    snapshot = excluded.snapshot,
                    updated_at = excluded.updated_at
                """,
            arguments: [
                frame.id.uuidString,
                frame.flowID.description,
                frame.sequenceNumber,
                frame.direction.rawValue,
                persistedOpcode(frame.opcode),
                frame.receivedAt.timeIntervalSince1970,
                frame.payloadByteCount,
                try PersistenceCoding.encode(frame),
                Date().timeIntervalSince1970
            ]
        )
    }

    static func fetchAll(for flowID: FlowID, from database: Database) throws
        -> [CapturedWebSocketFrame]
    {
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT snapshot FROM websocket_frames
                WHERE flow_id = ? ORDER BY sequence_number ASC
                """,
            arguments: [flowID.description]
        )
        return try rows.map { row in
            let snapshot: Data = row["snapshot"]
            return try PersistenceCoding.decode(CapturedWebSocketFrame.self, from: snapshot)
        }
    }

    static func deleteAll(for flowID: FlowID, from database: Database) throws {
        try database.execute(
            sql: "DELETE FROM websocket_frames WHERE flow_id = ?",
            arguments: [flowID.description]
        )
    }

    private static func persistedOpcode(_ opcode: WebSocketFrameOpcode) -> String {
        switch opcode {
        case .continuation: "continuation"
        case .text: "text"
        case .binary: "binary"
        case .close: "close"
        case .ping: "ping"
        case .pong: "pong"
        case .unknown(let value): "unknown_\(value)"
        }
    }
}
