import Foundation
import ProxyLensCore

@MainActor
protocol TrafficSSLProxyingStoring: AnyObject {
    var policy: TLSInterceptionPolicy { get }

    func save(_ policy: TLSInterceptionPolicy)
}

@MainActor
final class InMemoryTrafficSSLProxyingStore: TrafficSSLProxyingStoring {
    private(set) var policy: TLSInterceptionPolicy

    init(policy: TLSInterceptionPolicy = TLSInterceptionPolicy()) {
        self.policy = policy
    }

    func save(_ policy: TLSInterceptionPolicy) {
        self.policy = policy
    }
}

@MainActor
final class UserDefaultsTrafficSSLProxyingStore: TrafficSSLProxyingStoring {
    static let defaultKey = "TrafficConsole.sslProxyingList"
    private static let maximumDocumentBytes = 64 * 1_024

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

    func save(_ policy: TLSInterceptionPolicy) {
        let document = Document(version: 1, policy: policy)
        guard let data = try? JSONEncoder().encode(document),
            data.count <= Self.maximumDocumentBytes
        else {
            return
        }
        defaults.set(data, forKey: key)
    }
}
