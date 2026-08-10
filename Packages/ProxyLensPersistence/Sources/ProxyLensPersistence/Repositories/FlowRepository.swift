import Foundation
import GRDB
import ProxyLensCore

struct FlowRepository: Sendable {
    static func save(_ flow: Flow, in database: Database) throws {
        let summary = flow.summary
        let snapshot = try PersistenceCoding.encode(flow)
        let arguments: StatementArguments = [
            flow.id.description,
            flow.sessionID.description,
            flow.createdAt.timeIntervalSince1970,
            flow.source.kind.rawValue,
            flow.source.label,
            flow.source.clientAddress,
            flow.request.method.rawValue,
            flow.request.url.absoluteString,
            flow.response?.statusCode,
            persistedState(flow.state),
            summary.requestByteCount,
            summary.responseByteCount,
            summary.totalDuration,
            snapshot,
            Date().timeIntervalSince1970
        ]

        try database.execute(
            sql: """
                INSERT INTO flows (
                    id, session_id, created_at, source_kind, source_label, client_address,
                    method, url, status_code, state, request_byte_count, response_byte_count,
                    total_duration, snapshot, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    session_id = excluded.session_id,
                    created_at = excluded.created_at,
                    source_kind = excluded.source_kind,
                    source_label = excluded.source_label,
                    client_address = excluded.client_address,
                    method = excluded.method,
                    url = excluded.url,
                    status_code = excluded.status_code,
                    state = excluded.state,
                    request_byte_count = excluded.request_byte_count,
                    response_byte_count = excluded.response_byte_count,
                    total_duration = excluded.total_duration,
                    snapshot = excluded.snapshot,
                    updated_at = excluded.updated_at
                """,
            arguments: arguments
        )
    }

    static func fetch(_ flowID: FlowID, from database: Database) throws -> Flow? {
        guard
            let snapshot = try Data.fetchOne(
                database,
                sql: "SELECT snapshot FROM flows WHERE id = ?",
                arguments: [flowID.description]
            )
        else {
            return nil
        }

        return try PersistenceCoding.decode(Flow.self, from: snapshot)
    }

    static func fetchAll(in sessionID: SessionID, from database: Database) throws -> [Flow] {
        let rows = try Row.fetchAll(
            database,
            sql: "SELECT snapshot FROM flows WHERE session_id = ? ORDER BY created_at DESC",
            arguments: [sessionID.description]
        )
        return try decodeFlows(rows)
    }

    static func fetchNonTerminal(in sessionID: SessionID, from database: Database) throws -> [Flow]
    {
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT snapshot FROM flows
                WHERE session_id = ? AND state NOT IN ('completed', 'cancelled', 'failed')
                ORDER BY created_at
                """,
            arguments: [sessionID.description]
        )
        return try decodeFlows(rows)
    }

    static func exists(_ flowID: FlowID, in database: Database) throws -> Bool {
        try Bool.fetchOne(
            database,
            sql: "SELECT EXISTS(SELECT 1 FROM flows WHERE id = ?)",
            arguments: [flowID.description]
        ) ?? false
    }

    static func delete(_ flowID: FlowID, from database: Database) throws {
        try database.execute(
            sql: "DELETE FROM flows WHERE id = ?",
            arguments: [flowID.description]
        )
    }

    private static func decodeFlows(_ rows: [Row]) throws -> [Flow] {
        try rows.map { row in
            let snapshot: Data = row["snapshot"]
            return try PersistenceCoding.decode(Flow.self, from: snapshot)
        }
    }

    private static func persistedState(_ state: FlowState) -> String {
        switch state {
        case .created:
            "created"
        case .receivingRequest:
            "receiving_request"
        case .connectingUpstream:
            "connecting_upstream"
        case .receivingResponse:
            "receiving_response"
        case .completed:
            "completed"
        case .cancelled:
            "cancelled"
        case .failed:
            "failed"
        }
    }
}
