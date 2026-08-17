import Foundation
import ProxyLensCore

struct BodyScriptRunResult: Sendable {
    let message: ScriptHTTPMessage
    let traces: [RuleTrace]
}

enum BodyScriptRunner {
    static func run(
        scripts: [PlannedScript],
        hook: ScriptHook,
        initialMessage: ScriptHTTPMessage,
        executor: (any ScriptExecutor)?
    ) async -> BodyScriptRunResult {
        var message = initialMessage
        var traces: [RuleTrace] = []

        for script in scripts {
            do {
                guard let executor else {
                    throw BodyScriptError.executorUnavailable
                }
                let request = try ScriptExecutionRequest(
                    hook: hook,
                    source: script.spec.source,
                    message: message
                )
                let result = try await executor.execute(request)
                message = result.message
                traces.append(
                    trace(
                        for: script,
                        hook: hook,
                        outcome: .applied,
                        logs: result.logs
                    )
                )
            } catch {
                traces.append(
                    trace(
                        for: script,
                        hook: hook,
                        outcome: .failed(message: error.localizedDescription)
                    )
                )
            }
        }

        return BodyScriptRunResult(message: message, traces: traces)
    }

    static func failureTraces(
        scripts: [PlannedScript],
        hook: ScriptHook,
        error: Error
    ) -> [RuleTrace] {
        scripts.map {
            trace(
                for: $0,
                hook: hook,
                outcome: .failed(message: error.localizedDescription)
            )
        }
    }

    static func requestMessage(
        request: HTTPRequest,
        bodyData: Data
    ) throws -> ScriptHTTPMessage {
        ScriptHTTPMessage(
            method: request.method.rawValue,
            url: request.url.absoluteString,
            headers: request.headers.allFields,
            body: try textBody(bodyData, headers: request.headers)
        )
    }

    static func responseMessage(
        response: HTTPResponse,
        bodyData: Data
    ) throws -> ScriptHTTPMessage {
        ScriptHTTPMessage(
            statusCode: response.statusCode,
            headers: response.headers.allFields,
            body: try textBody(bodyData, headers: response.headers)
        )
    }

    static func request(
        from message: ScriptHTTPMessage,
        preserving request: HTTPRequest
    ) throws -> HTTPRequest {
        guard let method = message.method, let rawURL = message.url,
            let url = URL(string: rawURL)
        else {
            throw ScriptExecutionError.invalidRequestMessage
        }
        let target = try ProxyTarget(url: url)
        let body = bodyReference(text: message.body, headers: HTTPHeaders(message.headers))
        let headers = try synchronizedBodyHeaders(
            HTTPHeaders(message.headers),
            byteCount: body?.byteCount ?? 0
        )
        return HTTPRequest(
            method: HTTPMethod(rawValue: method),
            url: url,
            headers: headers,
            body: bodyReference(text: message.body, headers: headers),
            version: request.version,
            rawTarget: target.originForm
        )
    }

    static func response(
        from message: ScriptHTTPMessage,
        preserving response: HTTPResponse
    ) throws -> HTTPResponse {
        guard let statusCode = message.statusCode else {
            throw ScriptExecutionError.invalidResponseMessage
        }
        let initialHeaders = HTTPHeaders(message.headers)
        let body = bodyReference(text: message.body, headers: initialHeaders)
        let headers = try synchronizedBodyHeaders(
            initialHeaders,
            byteCount: body?.byteCount ?? 0
        )
        return try HTTPResponse(
            statusCode: statusCode,
            headers: headers,
            body: bodyReference(text: message.body, headers: headers),
            version: response.version
        )
    }

    private static func trace(
        for script: PlannedScript,
        hook: ScriptHook,
        outcome: RuleTraceOutcome,
        logs: [String] = []
    ) -> RuleTrace {
        RuleTrace(
            ruleID: script.ruleID,
            phase: hook == .request ? .requestBody : .responseBody,
            outcome: outcome,
            ruleName: script.ruleName,
            logs: logs
        )
    }

    private static func textBody(_ data: Data, headers: HTTPHeaders) throws -> String {
        let encodings = headers.values(for: "Content-Encoding")
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && $0 != "identity" }
        guard encodings.isEmpty else {
            throw BodyScriptError.unsupportedContentEncoding(encodings.joined(separator: ", "))
        }
        guard data.count <= ScriptExecutionLimits.maximumBodyByteCount else {
            throw ScriptExecutionError.bodyTooLarge(
                maximumByteCount: ScriptExecutionLimits.maximumBodyByteCount
            )
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw BodyScriptError.bodyIsNotUTF8
        }
        return text
    }

    private static func bodyReference(text: String?, headers: HTTPHeaders) -> BodyReference? {
        guard let text else {
            return nil
        }
        return BodyReference(
            inline: Data(text.utf8),
            metadata: BodyMetadata(
                contentType: headers.firstValue(for: "Content-Type"),
                contentEncoding: headers.firstValue(for: "Content-Encoding")
            )
        )
    }

    private static func synchronizedBodyHeaders(
        _ headers: HTTPHeaders,
        byteCount: Int64
    ) throws -> HTTPHeaders {
        try headers
            .removing(name: "Transfer-Encoding")
            .removing(name: "Content-Length")
            .removing(name: "Content-Encoding")
            .appending(name: "Content-Length", value: "\(byteCount)")
    }
}

private enum BodyScriptError: Error, LocalizedError {
    case executorUnavailable
    case unsupportedContentEncoding(String)
    case bodyIsNotUTF8

    var errorDescription: String? {
        switch self {
        case .executorUnavailable:
            "Script execution is unavailable."
        case .unsupportedContentEncoding(let encoding):
            "Body scripts require identity encoding; received \(encoding)."
        case .bodyIsNotUTF8:
            "Body scripts require valid UTF-8 text."
        }
    }
}
