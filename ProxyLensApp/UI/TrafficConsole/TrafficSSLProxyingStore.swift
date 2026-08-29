import Foundation
import ProxyLensCore

enum TrafficSSLProxyingStoreError: Error, Equatable, LocalizedError {
    case documentTooLarge

    var errorDescription: String? {
        switch self {
        case .documentTooLarge:
            "The SSL proxying list is too large to save."
        }
    }
}

@MainActor
protocol TrafficSSLProxyingStoring: AnyObject {
    var policy: TLSInterceptionPolicy { get }

    func save(_ policy: TLSInterceptionPolicy) throws
}

@MainActor
final class InMemoryTrafficSSLProxyingStore: TrafficSSLProxyingStoring {
    private(set) var policy: TLSInterceptionPolicy

    init(policy: TLSInterceptionPolicy = TLSInterceptionPolicy()) {
        self.policy = policy
    }

    func save(_ policy: TLSInterceptionPolicy) throws {
        self.policy = policy
    }
}

@MainActor
final class UserDefaultsTrafficSSLProxyingStore: TrafficSSLProxyingStoring {
    static let defaultKey = "TrafficConsole.sslProxyingList"
    // Comfortably above the largest policy Core can produce (256 entries × up to a
    // 253-character host, plus a 2-character wildcard prefix, plus JSON overhead —
    // roughly 66 KB), so a valid policy is never silently dropped by this cap.
    private static let maximumDocumentBytes = 128 * 1_024

    private struct Document: Codable {
        let version: Int
        let policy: TLSInterceptionPolicy
    }

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    var policy: TLSInterceptionPolicy {
        guard let data = defaults.data(forKey: key),
            data.count <= Self.maximumDocumentBytes,
            let document = try? JSONDecoder().decode(Document.self, from: data),
            document.version == 1
        else {
            return TLSInterceptionPolicy()
        }
        return document.policy
    }

    func save(_ policy: TLSInterceptionPolicy) throws {
        let document = Document(version: 1, policy: policy)
        let data = try JSONEncoder().encode(document)
        guard data.count <= Self.maximumDocumentBytes else {
            throw TrafficSSLProxyingStoreError.documentTooLarge
        }
        defaults.set(data, forKey: key)
    }
}
