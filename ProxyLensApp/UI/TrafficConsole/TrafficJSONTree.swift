import CoreFoundation
import Foundation

enum TrafficJSONTreeValueKind: Hashable, Sendable {
    case container
    case string
    case number
    case literal
    case notice
}

struct TrafficJSONTreeNode: Hashable, Sendable {
    let identity: Int
    let key: String
    let value: String
    let kind: TrafficJSONTreeValueKind
    let children: [TrafficJSONTreeNode]

    var isExpandable: Bool {
        !children.isEmpty
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(identity)
    }
}

enum TrafficJSONTreePresentation: Equatable, Sendable {
    case none(String)
    case loading(String)
    case content(TrafficJSONTreeNode)
    case failed(String)
}

/// Creates a bounded, presentation-only JSON tree from an already decoded JSON view.
enum TrafficJSONTreeBuilder {
    static let maximumNodeCount = 10_000
    static let maximumDepth = 64

    static func build(
        _ json: String,
        maximumNodeCount: Int = maximumNodeCount,
        maximumDepth: Int = maximumDepth
    ) -> TrafficJSONTreePresentation {
        guard let data = json.data(using: .utf8) else {
            return .failed("Could not decode the JSON tree as UTF-8.")
        }

        do {
            let value = try JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            )
            var builder = Builder(
                remainingNodeCount: max(1, maximumNodeCount),
                maximumDepth: max(1, maximumDepth),
                nextIdentity: 0
            )
            guard let root = builder.node(key: "JSON", value: value, depth: 0) else {
                return .failed("The JSON tree is empty.")
            }
            return .content(root)
        } catch {
            return .failed("Could not build the JSON tree: \(error.localizedDescription)")
        }
    }

    private struct Builder {
        var remainingNodeCount: Int
        let maximumDepth: Int
        var nextIdentity: Int

        mutating func node(key: String, value: Any, depth: Int) -> TrafficJSONTreeNode? {
            guard remainingNodeCount > 0 else {
                return nil
            }
            remainingNodeCount -= 1
            let identity = nextIdentity
            nextIdentity += 1

            if let object = value as? [String: Any] {
                let keys = object.keys.sorted()
                return containerNode(
                    identity: identity,
                    key: key,
                    summary: object.count == 1 ? "{1 key}" : "{\(object.count) keys}",
                    valueCount: keys.count,
                    depth: depth,
                    valueAt: { index in
                        let objectKey = keys[index]
                        return (objectKey, object[objectKey] as Any)
                    }
                )
            }
            if let array = value as? [Any] {
                return containerNode(
                    identity: identity,
                    key: key,
                    summary: array.count == 1 ? "[1 item]" : "[\(array.count) items]",
                    valueCount: array.count,
                    depth: depth,
                    valueAt: { index in ("[\(index)]", array[index]) }
                )
            }
            if value is NSNull {
                return TrafficJSONTreeNode(
                    identity: identity,
                    key: key,
                    value: "null",
                    kind: .literal,
                    children: []
                )
            }
            if let string = value as? String {
                return TrafficJSONTreeNode(
                    identity: identity,
                    key: key,
                    value: quotedAndBounded(string),
                    kind: .string,
                    children: []
                )
            }
            if let number = value as? NSNumber {
                let isBoolean = CFGetTypeID(number) == CFBooleanGetTypeID()
                return TrafficJSONTreeNode(
                    identity: identity,
                    key: key,
                    value: isBoolean ? (number.boolValue ? "true" : "false") : number.stringValue,
                    kind: isBoolean ? .literal : .number,
                    children: []
                )
            }
            return TrafficJSONTreeNode(
                identity: identity,
                key: key,
                value: String(describing: value),
                kind: .literal,
                children: []
            )
        }

        private mutating func containerNode(
            identity: Int,
            key: String,
            summary: String,
            valueCount: Int,
            depth: Int,
            valueAt: (Int) -> (String, Any)
        ) -> TrafficJSONTreeNode {
            guard valueCount > 0 else {
                return TrafficJSONTreeNode(
                    identity: identity,
                    key: key,
                    value: summary,
                    kind: .container,
                    children: []
                )
            }
            guard depth < maximumDepth else {
                return TrafficJSONTreeNode(
                    identity: identity,
                    key: key,
                    value: summary,
                    kind: .container,
                    children: noticeChildren("Maximum tree depth reached")
                )
            }

            var children: [TrafficJSONTreeNode] = []
            children.reserveCapacity(min(valueCount, remainingNodeCount))
            for index in 0..<valueCount {
                if remainingNodeCount == 1, index < valueCount - 1 {
                    children.append(noticeNode("More values omitted"))
                    remainingNodeCount -= 1
                    break
                }
                let entry = valueAt(index)
                guard let child = node(key: entry.0, value: entry.1, depth: depth + 1) else {
                    break
                }
                children.append(child)
            }
            return TrafficJSONTreeNode(
                identity: identity,
                key: key,
                value: summary,
                kind: .container,
                children: children
            )
        }

        private mutating func noticeChildren(_ value: String) -> [TrafficJSONTreeNode] {
            guard remainingNodeCount > 0 else {
                return []
            }
            remainingNodeCount -= 1
            return [noticeNode(value)]
        }

        private mutating func noticeNode(_ value: String) -> TrafficJSONTreeNode {
            let identity = nextIdentity
            nextIdentity += 1
            return TrafficJSONTreeNode(
                identity: identity,
                key: "…",
                value: value,
                kind: .notice,
                children: []
            )
        }

        private func quotedAndBounded(_ value: String) -> String {
            let maximumCharacterCount = 4_096
            let bounded: String
            if value.count > maximumCharacterCount {
                bounded = String(value.prefix(maximumCharacterCount)) + "…"
            } else {
                bounded = value
            }
            return String(reflecting: bounded)
        }
    }
}
