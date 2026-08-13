import Foundation

public protocol SessionStore: FlowStore, CaptureStartupRecovery {
    func createSession(startedAt: Date) async throws -> Session
    func saveSession(_ session: Session) async throws
    func loadSession(sessionID: SessionID) async throws -> Session?
    func listSessions() async throws -> [Session]
    func listAllFlows() async throws -> [Flow]
    func stopSession(sessionID: SessionID, at date: Date) async throws
    func removeSession(sessionID: SessionID) async throws
}

extension SessionStore {
    public func createSession() async throws -> Session {
        try await createSession(startedAt: Date())
    }

    public func stopSession(sessionID: SessionID) async throws {
        try await stopSession(sessionID: sessionID, at: Date())
    }
}
