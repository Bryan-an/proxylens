import Foundation
import ProxyLensCore

public enum RuleEngineError: Error, Equatable, LocalizedError, Sendable {
    case mapLocalFileUnreadable(path: String, message: String)
    case mapLocalFileTooLarge(byteCount: Int64, maximumByteCount: Int64)
    case mapRemoteInvalidDestination(String)

    public var errorDescription: String? {
        switch self {
        case .mapLocalFileUnreadable(let path, let message):
            "Could not read Map Local file \(path): \(message)"
        case .mapLocalFileTooLarge(let byteCount, let maximumByteCount):
            "Map Local file is \(byteCount) bytes; the limit is \(maximumByteCount) bytes"
        case .mapRemoteInvalidDestination(let destination):
            "Map Remote destination is invalid: \(destination)"
        }
    }
}

public actor RuleEngine {
    public static let defaultMaximumMapLocalBytes: Int64 = 10 * 1_024 * 1_024

    public nonisolated let snapshot: MutableRuleSnapshot
    private var rules: [Rule]
    private let maximumMapLocalBytes: Int64

    public init(
        snapshot: MutableRuleSnapshot = MutableRuleSnapshot(),
        maximumMapLocalBytes: Int64 = RuleEngine.defaultMaximumMapLocalBytes
    ) {
        self.snapshot = snapshot
        self.rules = snapshot.currentRules().rules
        self.maximumMapLocalBytes = max(0, maximumMapLocalBytes)
    }

    public func currentRules() -> RuleSet {
        RuleSet(rules: rules)
    }

    public func replace(_ ruleSet: RuleSet) {
        rules = ruleSet.rules
        snapshot.replace(ruleSet)
        snapshot.retainMappedLocals(Self.mappedLocalResourceIDs(in: ruleSet))
    }

    public func add(_ rule: Rule) {
        replace(RuleSet(rules: rules + [rule]))
    }

    public func remove(id: RuleID) {
        replace(RuleSet(rules: rules.filter { $0.id != id }))
    }

    @discardableResult
    public func blockHost(_ host: String, reason: String? = nil) -> Rule {
        let rule = Rule(
            name: "Block \(host)",
            priority: 10,
            phase: .requestHeaders,
            matcher: .host(.exact(host)),
            action: .block(reason: reason ?? "Blocked host")
        )
        add(rule)
        return rule
    }

    @discardableResult
    public func allowHost(_ host: String) -> Rule {
        let rule = Rule(
            name: "Allow \(host)",
            priority: 0,
            phase: .requestHeaders,
            matcher: .host(.exact(host)),
            action: .allow
        )
        add(rule)
        return rule
    }

    @discardableResult
    public func disableCaching(forHost host: String) -> [Rule] {
        let requestRule = Rule(
            name: "No cache \(host) request",
            priority: 20,
            phase: .requestHeaders,
            matcher: .host(.exact(host)),
            action: .noCache
        )
        let responseRule = Rule(
            name: "No cache \(host) response",
            priority: 20,
            phase: .responseHeaders,
            matcher: .host(.exact(host)),
            action: .noCache
        )
        add(requestRule)
        add(responseRule)
        return [requestRule, responseRule]
    }

    @discardableResult
    public func mapLocal(
        host: String,
        path: String,
        fileURL: URL,
        statusCode: Int = 200
    ) throws -> Rule {
        let normalizedPath = Self.normalizedPath(path)
        let data = try Self.readMapLocalFile(fileURL, maximumByteCount: maximumMapLocalBytes)
        let contentType = Self.mimeType(for: fileURL)
        let spec = MapLocalSpec(
            resourceID: UUID().uuidString,
            filePath: fileURL.path,
            statusCode: statusCode,
            body: BodyReference(
                inline: data,
                metadata: BodyMetadata(contentType: contentType)
            )
        )
        snapshot.replaceMappedLocal(spec)
        let rule = Rule(
            name: "Map local \(host)\(normalizedPath)",
            priority: 15,
            phase: .requestHeaders,
            matcher: .allOf([
                .host(.exact(host)),
                .path(.exact(normalizedPath))
            ]),
            action: .mapLocal(resourceID: spec.resourceID)
        )
        add(rule)
        return rule
    }

    @discardableResult
    public func mapRemote(
        host: String,
        path: String,
        destination: URL
    ) throws -> Rule {
        let normalizedPath = Self.normalizedPath(path)
        do {
            try MappedRemoteHTTPRequest.validateDestination(destination)
        } catch {
            throw RuleEngineError.mapRemoteInvalidDestination(destination.absoluteString)
        }

        let rule = Rule(
            name: "Map remote \(host)\(normalizedPath)",
            priority: 15,
            phase: .requestHeaders,
            matcher: .allOf([
                .host(.exact(host)),
                .path(.exact(normalizedPath))
            ]),
            action: .mapRemote(url: destination)
        )
        add(rule)
        return rule
    }

    private static func mappedLocalResourceIDs(in ruleSet: RuleSet) -> Set<String> {
        Set(
            ruleSet.rules.compactMap { rule in
                if case .mapLocal(let resourceID) = rule.action {
                    return resourceID
                }
                return nil
            }
        )
    }

    private static func normalizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutQuery =
            trimmed.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        if withoutQuery.isEmpty {
            return "/"
        }
        return withoutQuery.hasPrefix("/") ? withoutQuery : "/\(withoutQuery)"
    }

    private static func readMapLocalFile(
        _ fileURL: URL,
        maximumByteCount: Int64
    ) throws -> Data {
        let path = fileURL.isFileURL ? fileURL.path : fileURL.absoluteString
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw RuleEngineError.mapLocalFileUnreadable(
                path: path,
                message: error.localizedDescription
            )
        }

        let byteCount = Int64(data.count)
        guard byteCount <= maximumByteCount else {
            throw RuleEngineError.mapLocalFileTooLarge(
                byteCount: byteCount,
                maximumByteCount: maximumByteCount
            )
        }
        return data
    }

    private static func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "json":
            "application/json"
        case "html", "htm":
            "text/html; charset=utf-8"
        case "txt":
            "text/plain; charset=utf-8"
        case "js", "mjs":
            "text/javascript"
        case "css":
            "text/css"
        case "xml":
            "application/xml"
        case "svg":
            "image/svg+xml"
        case "png":
            "image/png"
        case "jpg", "jpeg":
            "image/jpeg"
        case "gif":
            "image/gif"
        case "webp":
            "image/webp"
        case "pdf":
            "application/pdf"
        default:
            "application/octet-stream"
        }
    }
}
