import Foundation

/// Errors that can be produced while validating or evolving core domain values.
public enum ProxyLensError: Error, Equatable, LocalizedError, Sendable {
    case invalidHeaderName(String)
    case invalidHeaderValue(String)
    case invalidStatusCode(Int)
    case invalidBodySize(Int64)
    case invalidFlowTransition(from: FlowState, to: FlowState)
    case invalidPattern(String)
    case invalidURL(String)
    case unsupportedOperation(String)

    public var errorDescription: String? {
        switch self {
        case .invalidHeaderName(let name):
            "Invalid HTTP header name: \(name)"
        case .invalidHeaderValue(let value):
            "Invalid HTTP header value: \(value)"
        case .invalidStatusCode(let statusCode):
            "Invalid HTTP status code: \(statusCode)"
        case .invalidBodySize(let size):
            "Invalid body size: \(size)"
        case .invalidFlowTransition(let from, let to):
            "Invalid flow transition from \(from) to \(to)"
        case .invalidPattern(let pattern):
            "Invalid matcher pattern: \(pattern)"
        case .invalidURL(let url):
            "Invalid URL: \(url)"
        case .unsupportedOperation(let operation):
            "Unsupported operation: \(operation)"
        }
    }
}
