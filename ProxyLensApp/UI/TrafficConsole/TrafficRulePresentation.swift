import Foundation
import ProxyLensCore

struct TrafficRulePresentation: Equatable, Identifiable, Sendable {
    let id: RuleID
    let name: String
    let enabled: Bool
    let action: String
    let phase: String
    let matcher: String
    let priority: Int
    let canEdit: Bool

    init(rule: Rule) {
        id = rule.id
        name = rule.name
        enabled = rule.enabled
        action = Self.actionTitle(rule.action)
        phase = Self.phaseTitle(rule.phase)
        matcher = Self.matcherTitle(rule.matcher)
        priority = rule.priority
        canEdit = TrafficRuleDraft(rule: rule) != nil
    }

    private static func actionTitle(_ action: RuleAction) -> String {
        switch action {
        case .mapLocal:
            "Map Local"
        case .mapRemote:
            "Map Remote"
        case .breakpoint:
            "Breakpoint"
        case .block:
            "Block"
        case .allow:
            "Allow"
        case .replaceBody:
            "Replace Body"
        case .throttle:
            "Network Conditions"
        case .redirect:
            "Redirect"
        case .annotate:
            "Annotate"
        case .noCache:
            "No Cache"
        }
    }

    private static func phaseTitle(_ phase: RulePhase) -> String {
        switch phase {
        case .connection:
            "Connection"
        case .requestHeaders:
            "Request Headers"
        case .requestBody:
            "Request Body"
        case .responseHeaders:
            "Response Headers"
        case .responseBody:
            "Response Body"
        case .webSocketFrame:
            "WebSocket Frame"
        }
    }

    private static func matcherTitle(_ matcher: Matcher) -> String {
        switch matcher {
        case .any:
            "All traffic"
        case .host(let pattern):
            "Host \(patternTitle(pattern))"
        case .path(let pattern):
            "Path \(patternTitle(pattern))"
        case .query(let pattern):
            "Query \(patternTitle(pattern))"
        case .method(let method):
            "Method \(method.rawValue)"
        case .header(let name, let value):
            value.map { "Header \(name): \(patternTitle($0))" } ?? "Header \(name)"
        case .source(let pattern):
            "Source \(patternTitle(pattern))"
        case .status(let status):
            "Status \(status)"
        case .contentType(let pattern):
            "Content-Type \(patternTitle(pattern))"
        case .graphqlOperation(let name, let kind):
            [kind?.rawValue, name.map(patternTitle)]
                .compactMap { $0 }
                .joined(separator: " ")
                .withPrefix("GraphQL")
        case .allOf(let matchers):
            matchers.map(matcherTitle).joined(separator: " and ")
        case .anyOf(let matchers):
            matchers.map(matcherTitle).joined(separator: " or ")
        case .not(let matcher):
            "Not (\(matcherTitle(matcher)))"
        }
    }

    private static func patternTitle(_ pattern: StringPattern) -> String {
        switch pattern.kind {
        case .exact:
            pattern.value
        case .wildcard:
            "wildcard \(pattern.value)"
        case .regularExpression:
            "regex /\(pattern.value)/"
        }
    }
}

extension String {
    fileprivate func withPrefix(_ prefix: String) -> String {
        isEmpty ? prefix : "\(prefix) \(self)"
    }
}
