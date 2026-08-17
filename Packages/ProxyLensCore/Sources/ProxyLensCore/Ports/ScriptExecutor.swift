public protocol ScriptExecutor: Sendable {
    func execute(_ request: ScriptExecutionRequest) async throws -> ScriptExecutionResult
}
