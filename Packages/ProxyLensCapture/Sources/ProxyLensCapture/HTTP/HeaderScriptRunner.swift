import Foundation
import ProxyLensCore

struct HeaderScriptRunResult: Sendable {
    let message: ScriptHTTPMessage
    let traces: [RuleTrace]
}

enum HeaderScriptPolicy: Sendable {
    case http
    case webSocketHandshake
}

enum HeaderScriptRunner {
    static func run(
        scripts: [PlannedScript],
        hook: ScriptHook,
        phase: RulePhase,
        initialMessage: ScriptHTTPMessage,
        executor: (any ScriptExecutor)?,
        policy: HeaderScriptPolicy = .http
    ) async -> HeaderScriptRunResult {
        var message = initialMessage
        var traces: [RuleTrace] = []

        for script in scripts {
            do {
                guard let executor else {
                    throw HeaderScriptError.executorUnavailable
                }
                let request = try ScriptExecutionRequest(
                    hook: hook,
                    source: script.spec.source,
                    message: message
                )
                let result = try await executor.execute(request)
                guard result.message.body == nil else {
                    throw HeaderScriptError.bodyMutationUnsupported
                }
                try validate(
                    result.message,
                    against: initialMessage,
                    hook: hook,
                    policy: policy
                )
                message = result.message
                traces.append(
                    trace(
                        for: script,
                        phase: phase,
                        outcome: .applied,
                        logs: result.logs
                    )
                )
            } catch {
                traces.append(
                    trace(
                        for: script,
                        phase: phase,
                        outcome: .failed(message: error.localizedDescription)
                    )
                )
            }
        }

        return HeaderScriptRunResult(message: message, traces: traces)
    }

    static func failureTraces(
        scripts: [PlannedScript],
        phase: RulePhase,
        error: Error
    ) -> [RuleTrace] {
        scripts.map {
            trace(
                for: $0,
                phase: phase,
                outcome: .failed(message: error.localizedDescription)
            )
        }
    }

    static func skippedTraces(
        scripts: [PlannedScript],
        phase: RulePhase,
        reason: String
    ) -> [RuleTrace] {
        scripts.map {
            trace(
                for: $0,
                phase: phase,
                outcome: .skipped(reason: reason)
            )
        }
    }

    static func requestMessage(
        _ request: HTTPRequest,
        webSocketHandshake: Bool = false
    ) -> ScriptHTTPMessage {
        ScriptHTTPMessage(
            method: request.method.rawValue,
            url: scriptURL(
                for: request.url,
                webSocketHandshake: webSocketHandshake
            ).absoluteString,
            headers: request.headers.allFields
        )
    }

    static func responseMessage(_ response: HTTPResponse) -> ScriptHTTPMessage {
        ScriptHTTPMessage(
            statusCode: response.statusCode,
            headers: response.headers.allFields
        )
    }

    static func request(
        from message: ScriptHTTPMessage,
        preserving request: HTTPRequest,
        policy: HeaderScriptPolicy = .http
    ) throws -> HTTPRequest {
        guard let method = message.method, let rawURL = message.url,
            let url = URL(string: rawURL)
        else {
            throw ScriptExecutionError.invalidRequestMessage
        }
        _ = try ProxyTarget(url: url)
        let acceptedSchemes =
            policy == .webSocketHandshake
            ? ["ws", "wss"]
            : ["http", "https"]
        guard acceptedSchemes.contains(url.scheme?.lowercased() ?? "") else {
            throw ScriptExecutionError.invalidRequestMessage
        }
        return HTTPRequest(
            method: HTTPMethod(rawValue: method),
            url: url,
            headers: preservingFramingHeaders(
                in: HTTPHeaders(message.headers),
                from: request.headers
            ),
            body: request.body,
            version: request.version,
            rawTarget: request.rawTarget,
            graphqlOperation: request.graphqlOperation
        )
    }

    static func response(
        from message: ScriptHTTPMessage,
        preserving response: HTTPResponse
    ) throws -> HTTPResponse {
        guard let statusCode = message.statusCode else {
            throw ScriptExecutionError.invalidResponseMessage
        }
        return try HTTPResponse(
            statusCode: statusCode,
            reasonPhrase: statusCode == response.statusCode ? response.reasonPhrase : nil,
            headers: preservingFramingHeaders(
                in: HTTPHeaders(message.headers),
                from: response.headers
            ),
            body: response.body,
            version: response.version
        )
    }

    private static func trace(
        for script: PlannedScript,
        phase: RulePhase,
        outcome: RuleTraceOutcome,
        logs: [String] = []
    ) -> RuleTrace {
        RuleTrace(
            ruleID: script.ruleID,
            phase: phase,
            outcome: outcome,
            ruleName: script.ruleName,
            logs: logs
        )
    }

    private static func validate(
        _ candidate: ScriptHTTPMessage,
        against original: ScriptHTTPMessage,
        hook: ScriptHook,
        policy: HeaderScriptPolicy
    ) throws {
        guard policy == .webSocketHandshake else {
            return
        }

        switch hook {
        case .request:
            guard candidate.method == original.method else {
                throw HeaderScriptError.protectedWebSocketHandshakeField("method")
            }
            guard
                let rawURL = candidate.url,
                let url = URL(string: rawURL),
                ["ws", "wss"].contains(url.scheme?.lowercased() ?? ""),
                url.host != nil
            else {
                throw HeaderScriptError.invalidWebSocketURL
            }
            try validateProtectedHeaders(
                candidate.headers,
                against: original.headers,
                names: [
                    "Host",
                    "Connection",
                    "Upgrade",
                    "Sec-WebSocket-Key",
                    "Sec-WebSocket-Version",
                    "Sec-WebSocket-Protocol",
                    "Sec-WebSocket-Extensions"
                ]
            )
        case .response:
            guard candidate.statusCode == original.statusCode else {
                throw HeaderScriptError.protectedWebSocketHandshakeField("statusCode")
            }
            try validateProtectedHeaders(
                candidate.headers,
                against: original.headers,
                names: [
                    "Connection",
                    "Upgrade",
                    "Sec-WebSocket-Accept",
                    "Sec-WebSocket-Protocol",
                    "Sec-WebSocket-Extensions"
                ]
            )
        }
    }

    private static func validateProtectedHeaders(
        _ candidate: [HTTPHeader],
        against original: [HTTPHeader],
        names: [String]
    ) throws {
        for name in names where values(for: name, in: candidate) != values(for: name, in: original)
        {
            throw HeaderScriptError.protectedWebSocketHandshakeField(name)
        }
    }

    private static func values(for name: String, in headers: [HTTPHeader]) -> [String] {
        headers.compactMap {
            $0.name.caseInsensitiveCompare(name) == .orderedSame ? $0.value : nil
        }
    }

    private static func scriptURL(
        for url: URL,
        webSocketHandshake: Bool
    ) -> URL {
        guard webSocketHandshake,
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return url
        }
        let secure = ["https", "wss"].contains(components.scheme?.lowercased() ?? "")
        components.scheme = secure ? "wss" : "ws"
        return components.url ?? url
    }

    private static func preservingFramingHeaders(
        in edited: HTTPHeaders,
        from original: HTTPHeaders
    ) -> HTTPHeaders {
        let protectedNames = ["Content-Length", "Transfer-Encoding", "Content-Encoding", "Trailer"]
        let normalizedNames = Set(protectedNames.map { $0.lowercased() })
        let editableFields = edited.allFields.filter {
            !normalizedNames.contains($0.name.lowercased())
        }
        let framingFields = original.allFields.filter {
            normalizedNames.contains($0.name.lowercased())
        }
        return HTTPHeaders(editableFields + framingFields)
    }
}

private enum HeaderScriptError: Error, LocalizedError {
    case executorUnavailable
    case bodyMutationUnsupported
    case invalidWebSocketURL
    case protectedWebSocketHandshakeField(String)

    var errorDescription: String? {
        switch self {
        case .executorUnavailable:
            "Script execution is unavailable."
        case .bodyMutationUnsupported:
            "Header scripts cannot return a message body."
        case .invalidWebSocketURL:
            "A WebSocket handshake request requires an absolute WS or WSS URL."
        case .protectedWebSocketHandshakeField(let field):
            "WebSocket handshake field '\(field)' is transport-owned and cannot be changed."
        }
    }
}
