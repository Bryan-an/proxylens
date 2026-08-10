import Foundation
import ProxyLensCore

public enum PersistenceError: Error, Equatable, LocalizedError, Sendable {
    case bodyNotFound(BodyID)
    case bodyWriterClosed
    case bodyDigestMismatch(expected: BodyDigest, actual: BodyDigest)
    case bodyFileEscapesStorageDirectory(String)
    case invalidMaximumBodyByteCount(Int64)

    public var errorDescription: String? {
        switch self {
        case .bodyNotFound(let bodyID):
            "Body \(bodyID) was not found."
        case .bodyWriterClosed:
            "The body writer has already been finalized or cancelled."
        case .bodyDigestMismatch(let expected, let actual):
            "Body digest mismatch: expected \(expected.value), got \(actual.value)."
        case .bodyFileEscapesStorageDirectory(let path):
            "Body file path escapes the managed storage directory: \(path)"
        case .invalidMaximumBodyByteCount(let value):
            "Maximum body byte count must not be negative: \(value)"
        }
    }
}
