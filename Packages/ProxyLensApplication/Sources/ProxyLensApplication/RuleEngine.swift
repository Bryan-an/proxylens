import Foundation
import ProxyLensCore

public enum RuleEngineError: Error, Equatable, LocalizedError, Sendable {
    case mapLocalFileUnreadable(path: String, message: String)
    case mapLocalFileTooLarge(byteCount: Int64, maximumByteCount: Int64)
    case mapRemoteInvalidDestination(String)
    case redirectInvalidDestination(String)
    case invalidThrottleLatency(TimeInterval)
    case invalidThrottleBandwidth(Int64)
    case invalidThrottlePacketLoss(Double)
    case replacementFileUnreadable(path: String, message: String)
    case replacementFileTooLarge(byteCount: Int64, maximumByteCount: Int64)
    case missingMappedLocalResource(String)
    case duplicateMappedLocalResource(String)
    case unsupportedRuleProfileSchema(Int)

    public var errorDescription: String? {
        switch self {
        case .mapLocalFileUnreadable(let path, let message):
            "Could not read Map Local file \(path): \(message)"
        case .mapLocalFileTooLarge(let byteCount, let maximumByteCount):
            "Map Local file is \(byteCount) bytes; the limit is \(maximumByteCount) bytes"
        case .mapRemoteInvalidDestination(let destination):
            "Map Remote destination is invalid: \(destination)"
        case .redirectInvalidDestination(let destination):
            "Redirect destination is invalid: \(destination)"
        case .invalidThrottleLatency(let latency):
            "Throttle latency must be between 0 and 60 seconds: \(latency)"
        case .invalidThrottleBandwidth(let bytesPerSecond):
            "Throttle bandwidth must be between 1,024 and 1,000,000,000 bytes per second: \(bytesPerSecond)"
        case .invalidThrottlePacketLoss(let percentage):
            "Throttle packet loss must be between 0 and 100 percent: \(percentage)"
        case .replacementFileUnreadable(let path, let message):
            "Could not read replacement body file \(path): \(message)"
        case .replacementFileTooLarge(let byteCount, let maximumByteCount):
            "Replacement body file is \(byteCount) bytes; the limit is \(maximumByteCount) bytes"
        case .missingMappedLocalResource(let resourceID):
            "Map Local resource is unavailable: \(resourceID)"
        case .duplicateMappedLocalResource(let resourceID):
            "Map Local resource is duplicated: \(resourceID)"
        case .unsupportedRuleProfileSchema(let version):
            "Rule profile schema version \(version) is unsupported"
        }
    }
}

public actor RuleEngine {
    public static let defaultMaximumMapLocalBytes: Int64 = 10 * 1_024 * 1_024
    public static let maximumThrottleLatency: TimeInterval = 60
    public static let minimumThrottleBytesPerSecond: Int64 = 1_024
    public static let maximumThrottleBytesPerSecond: Int64 = 1_000_000_000

    public nonisolated let snapshot: MutableRuleSnapshot
    private var rules: [Rule]
    private let maximumRuleFileBytes: Int64

    public init(
        snapshot: MutableRuleSnapshot = MutableRuleSnapshot(),
        maximumMapLocalBytes: Int64 = RuleEngine.defaultMaximumMapLocalBytes
    ) {
        self.snapshot = snapshot
        self.rules = snapshot.currentRules().rules
        self.maximumRuleFileBytes = max(0, maximumMapLocalBytes)
    }

    public func currentRules() -> RuleSet {
        RuleSet(rules: rules)
    }

    public func makeProfile(
        name: String,
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) throws -> RuleProfile {
        let ruleSet = RuleSet(rules: rules)
        let mappedLocals = try Self.mappedLocalResourceIDs(in: ruleSet)
            .sorted()
            .map { resourceID in
                guard let spec = snapshot.mappedLocal(for: resourceID) else {
                    throw RuleEngineError.missingMappedLocalResource(resourceID)
                }
                return spec
            }
        return RuleProfile(
            id: id,
            name: name,
            rules: ruleSet,
            mappedLocals: mappedLocals,
            createdAt: createdAt
        )
    }

    public func apply(_ profile: RuleProfile) throws {
        try Self.validate(profile)
        let specsByID = Dictionary(
            uniqueKeysWithValues: profile.mappedLocals.map {
                ($0.resourceID, $0)
            })
        for resourceID in Self.mappedLocalResourceIDs(in: profile.rules) {
            guard let spec = specsByID[resourceID] else {
                throw RuleEngineError.missingMappedLocalResource(resourceID)
            }
            snapshot.replaceMappedLocal(spec)
        }
        replace(profile.rules)
    }

    public nonisolated static func validate(_ profile: RuleProfile) throws {
        guard profile.schemaVersion == RuleProfile.currentSchemaVersion else {
            throw RuleEngineError.unsupportedRuleProfileSchema(profile.schemaVersion)
        }
        var resourceIDs: Set<String> = []
        for spec in profile.mappedLocals {
            guard resourceIDs.insert(spec.resourceID).inserted else {
                throw RuleEngineError.duplicateMappedLocalResource(spec.resourceID)
            }
        }
        for resourceID in mappedLocalResourceIDs(in: profile.rules) {
            guard resourceIDs.contains(resourceID) else {
                throw RuleEngineError.missingMappedLocalResource(resourceID)
            }
        }
    }

    public func replace(_ ruleSet: RuleSet) {
        rules = ruleSet.rules
        snapshot.replace(ruleSet)
        snapshot.retainMappedLocals(Self.mappedLocalResourceIDs(in: ruleSet))
    }

    public func add(_ rule: Rule) {
        replace(RuleSet(rules: rules + [rule]))
    }

    @discardableResult
    public func update(_ rule: Rule) -> Bool {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else {
            return false
        }

        rules[index] = rule
        replace(RuleSet(rules: rules))
        return true
    }

    public func remove(id: RuleID) {
        replace(RuleSet(rules: rules.filter { $0.id != id }))
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool, for id: RuleID) -> Rule? {
        guard let index = rules.firstIndex(where: { $0.id == id }) else {
            return nil
        }

        let current = rules[index]
        let updated = Rule(
            id: current.id,
            name: current.name,
            enabled: enabled,
            priority: current.priority,
            phase: current.phase,
            matcher: current.matcher,
            action: current.action
        )
        rules[index] = updated
        replace(RuleSet(rules: rules))
        return updated
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
    public func block(graphqlOperation: GraphQLOperationMetadata) -> Rule {
        let rule = Rule(
            name: "Block GraphQL \(graphqlOperation.kind.rawValue) \(graphqlOperation.displayName)",
            priority: 10,
            phase: .requestBody,
            matcher: .graphqlOperation(
                name: .exact(graphqlOperation.displayName),
                kind: graphqlOperation.kind
            ),
            action: .block(reason: "Blocked GraphQL operation")
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
        let spec = try makeMapLocalSpec(fileURL: fileURL, statusCode: statusCode)
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
    public func mapLocal(
        graphqlOperation: GraphQLOperationMetadata,
        fileURL: URL,
        statusCode: Int = 200
    ) throws -> Rule {
        let spec = try makeMapLocalSpec(fileURL: fileURL, statusCode: statusCode)
        snapshot.replaceMappedLocal(spec)
        let rule = Rule(
            name:
                "Map local GraphQL \(graphqlOperation.kind.rawValue) \(graphqlOperation.displayName)",
            priority: 15,
            phase: .requestBody,
            matcher: .graphqlOperation(
                name: .exact(graphqlOperation.displayName),
                kind: graphqlOperation.kind
            ),
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

    @discardableResult
    public func mapRemote(
        graphqlOperation: GraphQLOperationMetadata,
        destination: URL
    ) throws -> Rule {
        do {
            try MappedRemoteHTTPRequest.validateDestination(destination)
        } catch {
            throw RuleEngineError.mapRemoteInvalidDestination(destination.absoluteString)
        }

        let rule = Rule(
            name:
                "Map remote GraphQL \(graphqlOperation.kind.rawValue) \(graphqlOperation.displayName)",
            priority: 15,
            phase: .requestBody,
            matcher: .graphqlOperation(
                name: .exact(graphqlOperation.displayName),
                kind: graphqlOperation.kind
            ),
            action: .mapRemote(url: destination)
        )
        add(rule)
        return rule
    }

    @discardableResult
    public func redirect(
        host: String,
        path: String,
        destination: URL
    ) throws -> Rule {
        let normalizedPath = Self.normalizedPath(path)
        do {
            try MappedRemoteHTTPRequest.validateDestination(destination)
        } catch {
            throw RuleEngineError.redirectInvalidDestination(destination.absoluteString)
        }

        let rule = Rule(
            name: "Redirect \(host)\(normalizedPath)",
            priority: 14,
            phase: .requestHeaders,
            matcher: .allOf([
                .host(.exact(host)),
                .path(.exact(normalizedPath))
            ]),
            action: .redirect(url: destination)
        )
        add(rule)
        return rule
    }

    @discardableResult
    public func throttle(host: String, latency: TimeInterval) throws -> Rule {
        guard latency.isFinite,
            latency >= 0,
            latency <= Self.maximumThrottleLatency
        else {
            throw RuleEngineError.invalidThrottleLatency(latency)
        }

        return try throttle(
            host: host,
            profile: ThrottleProfile(latency: latency),
            label: "\(Self.latencyLabel(latency)) latency"
        )
    }

    @discardableResult
    public func throttle(
        host: String,
        profile: ThrottleProfile,
        label: String
    ) throws -> Rule {
        guard profile.latency.isFinite,
            profile.latency >= 0,
            profile.latency <= Self.maximumThrottleLatency
        else {
            throw RuleEngineError.invalidThrottleLatency(profile.latency)
        }
        for bandwidth in [profile.downloadBytesPerSecond, profile.uploadBytesPerSecond].compactMap({
            $0
        }) {
            guard bandwidth >= Self.minimumThrottleBytesPerSecond,
                bandwidth <= Self.maximumThrottleBytesPerSecond
            else {
                throw RuleEngineError.invalidThrottleBandwidth(bandwidth)
            }
        }
        guard profile.packetLossPercentage.isFinite,
            (0...100).contains(profile.packetLossPercentage)
        else {
            throw RuleEngineError.invalidThrottlePacketLoss(profile.packetLossPercentage)
        }

        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let rule = Rule(
            name: "Throttle \(host) (\(normalizedLabel.isEmpty ? "Custom" : normalizedLabel))",
            priority: 17,
            phase: .requestHeaders,
            matcher: .host(.exact(host)),
            action: .throttle(profile)
        )
        let retainedRules = rules.filter { !Self.isHostThrottleRule($0, host: host) }
        replace(RuleSet(rules: retainedRules + [rule]))
        return rule
    }

    public func clearThrottle(forHost host: String) {
        replace(RuleSet(rules: rules.filter { !Self.isHostThrottleRule($0, host: host) }))
    }

    @discardableResult
    public func replaceRequestBody(
        host: String,
        path: String,
        fileURL: URL
    ) throws -> Rule {
        let normalizedPath = Self.normalizedPath(path)
        let body = try makeReplacementBody(fileURL: fileURL)
        let rule = Rule(
            name: "Replace body \(host)\(normalizedPath)",
            priority: 16,
            phase: .requestBody,
            matcher: .allOf([
                .host(.exact(host)),
                .path(.exact(normalizedPath))
            ]),
            action: .replaceBody(body: body)
        )
        add(rule)
        return rule
    }

    @discardableResult
    public func replaceRequestBody(
        graphqlOperation: GraphQLOperationMetadata,
        fileURL: URL
    ) throws -> Rule {
        let body = try makeReplacementBody(fileURL: fileURL)
        let rule = Rule(
            name:
                "Replace body GraphQL \(graphqlOperation.kind.rawValue) \(graphqlOperation.displayName)",
            priority: 16,
            phase: .requestBody,
            matcher: .graphqlOperation(
                name: .exact(graphqlOperation.displayName),
                kind: graphqlOperation.kind
            ),
            action: .replaceBody(body: body)
        )
        add(rule)
        return rule
    }

    @discardableResult
    public func replaceResponseBody(
        host: String,
        path: String,
        fileURL: URL
    ) throws -> Rule {
        let normalizedPath = Self.normalizedPath(path)
        let body = try makeReplacementBody(fileURL: fileURL)
        let rule = Rule(
            name: "Replace response body \(host)\(normalizedPath)",
            priority: 16,
            phase: .responseBody,
            matcher: .allOf([
                .host(.exact(host)),
                .path(.exact(normalizedPath))
            ]),
            action: .replaceBody(body: body)
        )
        add(rule)
        return rule
    }

    @discardableResult
    public func replaceResponseBody(
        graphqlOperation: GraphQLOperationMetadata,
        fileURL: URL
    ) throws -> Rule {
        let body = try makeReplacementBody(fileURL: fileURL)
        let rule = Rule(
            name:
                "Replace response body GraphQL \(graphqlOperation.kind.rawValue) \(graphqlOperation.displayName)",
            priority: 16,
            phase: .responseBody,
            matcher: .graphqlOperation(
                name: .exact(graphqlOperation.displayName),
                kind: graphqlOperation.kind
            ),
            action: .replaceBody(body: body)
        )
        add(rule)
        return rule
    }

    @discardableResult
    public func breakpoint(
        host: String,
        path: String,
        phase: RulePhase
    ) -> Rule {
        let normalizedPath = Self.normalizedPath(path)
        let resolvedPhase = phase == .responseHeaders ? RulePhase.responseHeaders : .requestHeaders
        let phaseLabel = resolvedPhase == .responseHeaders ? "response" : "request"
        let rule = Rule(
            name: "Breakpoint \(phaseLabel) \(host)\(normalizedPath)",
            priority: 18,
            phase: resolvedPhase,
            matcher: .allOf([
                .host(.exact(host)),
                .path(.exact(normalizedPath))
            ]),
            action: .breakpoint
        )
        add(rule)
        return rule
    }

    @discardableResult
    public func breakpoint(graphqlOperation: GraphQLOperationMetadata) -> Rule {
        let rule = Rule(
            name:
                "Breakpoint GraphQL \(graphqlOperation.kind.rawValue) \(graphqlOperation.displayName)",
            priority: 18,
            phase: .requestBody,
            matcher: .graphqlOperation(
                name: .exact(graphqlOperation.displayName),
                kind: graphqlOperation.kind
            ),
            action: .breakpoint
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

    private static func isHostThrottleRule(_ rule: Rule, host: String) -> Bool {
        guard case .throttle = rule.action else {
            return false
        }
        return rule.phase == .requestHeaders && rule.matcher == .host(.exact(host))
    }

    private func makeMapLocalSpec(fileURL: URL, statusCode: Int) throws -> MapLocalSpec {
        let data = try Self.readMapLocalFile(fileURL, maximumByteCount: maximumRuleFileBytes)
        return MapLocalSpec(
            resourceID: UUID().uuidString,
            filePath: fileURL.path,
            statusCode: statusCode,
            body: BodyReference(
                inline: data,
                metadata: BodyMetadata(contentType: Self.mimeType(for: fileURL))
            )
        )
    }

    private func makeReplacementBody(fileURL: URL) throws -> BodyReference {
        let path = fileURL.isFileURL ? fileURL.path : fileURL.absoluteString
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw RuleEngineError.replacementFileUnreadable(
                path: path,
                message: error.localizedDescription
            )
        }

        let byteCount = Int64(data.count)
        guard byteCount <= maximumRuleFileBytes else {
            throw RuleEngineError.replacementFileTooLarge(
                byteCount: byteCount,
                maximumByteCount: maximumRuleFileBytes
            )
        }
        return BodyReference(
            inline: data,
            metadata: BodyMetadata(contentType: Self.mimeType(for: fileURL))
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

    private static func latencyLabel(_ latency: TimeInterval) -> String {
        if latency < 1 {
            return "\(Int((latency * 1_000).rounded())) ms"
        }
        if latency.rounded() == latency {
            return "\(Int(latency)) s"
        }
        return "\(latency) s"
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
