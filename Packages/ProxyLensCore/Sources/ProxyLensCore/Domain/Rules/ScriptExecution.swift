import Foundation

public enum ScriptHook: String, Codable, Equatable, Hashable, Sendable {
    case request
    case response

    public var handlerName: String {
        switch self {
        case .request:
            "onRequest"
        case .response:
            "onResponse"
        }
    }
}

public enum ScriptExecutionLimits {
    public static let defaultTimeoutMilliseconds = 250
    public static let maximumTimeoutMilliseconds = 5_000
    public static let maximumSourceByteCount = 64 * 1_024
    public static let maximumInputByteCount = 1 * 1_024 * 1_024
    public static let maximumOutputByteCount = 1 * 1_024 * 1_024
    public static let maximumBodyByteCount = 1 * 1_024 * 1_024
    public static let maximumHeaderCount = 1_000
    public static let maximumLogCount = 100
    public static let maximumLogByteCount = 64 * 1_024
}

public enum ScriptExecutionError: Error, Codable, Equatable, LocalizedError, Sendable {
    case invalidRequestMessage
    case invalidResponseMessage
    case sourceTooLarge(maximumByteCount: Int)
    case bodyTooLarge(maximumByteCount: Int)
    case tooManyHeaders(maximumCount: Int)
    case tooManyLogs(maximumCount: Int)
    case logsTooLarge(maximumByteCount: Int)
    case inputTooLarge(maximumByteCount: Int)
    case outputTooLarge(maximumByteCount: Int)
    case missingHandler(String)
    case javaScriptException(String)
    case asynchronousResultUnsupported
    case invalidOutput(String)
    case timedOut(milliseconds: Int)
    case workerFailed(status: Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidRequestMessage:
            "A request script requires an HTTP method and absolute HTTP, HTTPS, WS, or WSS URL."
        case .invalidResponseMessage:
            "A response script requires a valid HTTP status code."
        case .sourceTooLarge(let maximum):
            "The script exceeds the \(maximum)-byte source limit."
        case .bodyTooLarge(let maximum):
            "The script body exceeds the \(maximum)-byte text limit."
        case .tooManyHeaders(let maximum):
            "The script message exceeds the \(maximum)-header limit."
        case .tooManyLogs(let maximum):
            "The script produced more than \(maximum) log entries."
        case .logsTooLarge(let maximum):
            "The script logs exceed the \(maximum)-byte limit."
        case .inputTooLarge(let maximum):
            "The script worker input exceeds the \(maximum)-byte limit."
        case .outputTooLarge(let maximum):
            "The script worker output exceeds the \(maximum)-byte limit."
        case .missingHandler(let name):
            "The script does not define \(name)(context)."
        case .javaScriptException(let message):
            "JavaScript failed: \(message)"
        case .asynchronousResultUnsupported:
            "Async and Promise-returning scripts are not supported yet."
        case .invalidOutput(let message):
            "The script returned invalid output: \(message)"
        case .timedOut(let milliseconds):
            "The script exceeded its \(milliseconds) ms execution limit."
        case .workerFailed(let status):
            "The script worker exited with status \(status)."
        }
    }
}

public struct ScriptHTTPMessage: Codable, Equatable, Hashable, Sendable {
    public let method: String?
    public let url: String?
    public let statusCode: Int?
    public let headers: [HTTPHeader]
    public let body: String?

    public init(
        method: String? = nil,
        url: String? = nil,
        statusCode: Int? = nil,
        headers: [HTTPHeader] = [],
        body: String? = nil
    ) {
        self.method = method
        self.url = url
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public struct ScriptExecutionRequest: Codable, Equatable, Hashable, Sendable {
    public let hook: ScriptHook
    public let source: String
    public let message: ScriptHTTPMessage

    public init(hook: ScriptHook, source: String, message: ScriptHTTPMessage) throws {
        self.hook = hook
        self.source = source
        self.message = message
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case hook
        case source
        case message
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            hook: container.decode(ScriptHook.self, forKey: .hook),
            source: container.decode(String.self, forKey: .source),
            message: container.decode(ScriptHTTPMessage.self, forKey: .message)
        )
    }

    private func validate() throws {
        guard source.utf8.count <= ScriptExecutionLimits.maximumSourceByteCount else {
            throw ScriptExecutionError.sourceTooLarge(
                maximumByteCount: ScriptExecutionLimits.maximumSourceByteCount
            )
        }
        try Self.validateCommonMessage(message)

        switch hook {
        case .request:
            guard
                let method = message.method,
                Self.isValidMethod(method),
                let rawURL = message.url,
                let url = URL(string: rawURL),
                ["http", "https", "ws", "wss"].contains(url.scheme?.lowercased() ?? ""),
                url.host != nil,
                message.statusCode == nil
            else {
                throw ScriptExecutionError.invalidRequestMessage
            }
        case .response:
            guard
                let statusCode = message.statusCode,
                (100...999).contains(statusCode),
                message.method == nil,
                message.url == nil
            else {
                throw ScriptExecutionError.invalidResponseMessage
            }
        }
    }

    static func validateCommonMessage(_ message: ScriptHTTPMessage) throws {
        guard message.headers.count <= ScriptExecutionLimits.maximumHeaderCount else {
            throw ScriptExecutionError.tooManyHeaders(
                maximumCount: ScriptExecutionLimits.maximumHeaderCount
            )
        }
        for header in message.headers {
            do {
                _ = try HTTPHeader(name: header.name, value: header.value)
            } catch {
                throw ScriptExecutionError.invalidOutput("Message contains an invalid HTTP header")
            }
        }
        guard
            (message.body?.utf8.count ?? 0) <= ScriptExecutionLimits.maximumBodyByteCount
        else {
            throw ScriptExecutionError.bodyTooLarge(
                maximumByteCount: ScriptExecutionLimits.maximumBodyByteCount
            )
        }
    }

    private static func isValidMethod(_ method: String) -> Bool {
        !method.isEmpty
            && method.unicodeScalars.allSatisfy { scalar in
                let value = scalar.value
                if (65...90).contains(value) || (97...122).contains(value)
                    || (48...57).contains(value)
                {
                    return true
                }
                return [33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126]
                    .contains(value)
            }
    }
}

public struct ScriptExecutionResult: Codable, Equatable, Hashable, Sendable {
    public let hook: ScriptHook
    public let message: ScriptHTTPMessage
    public let logs: [String]

    public init(hook: ScriptHook, message: ScriptHTTPMessage, logs: [String] = []) throws {
        self.hook = hook
        self.message = message
        self.logs = logs
        try ScriptExecutionRequest.validateCommonMessage(message)
        guard logs.count <= ScriptExecutionLimits.maximumLogCount else {
            throw ScriptExecutionError.tooManyLogs(
                maximumCount: ScriptExecutionLimits.maximumLogCount
            )
        }
        guard logs.reduce(0, { $0 + $1.utf8.count }) <= ScriptExecutionLimits.maximumLogByteCount
        else {
            throw ScriptExecutionError.logsTooLarge(
                maximumByteCount: ScriptExecutionLimits.maximumLogByteCount
            )
        }
        _ = try ScriptExecutionRequest(hook: hook, source: "", message: message)
    }

    private enum CodingKeys: String, CodingKey {
        case hook
        case message
        case logs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            hook: container.decode(ScriptHook.self, forKey: .hook),
            message: container.decode(ScriptHTTPMessage.self, forKey: .message),
            logs: container.decode([String].self, forKey: .logs)
        )
    }
}
