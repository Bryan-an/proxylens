import Foundation
import ProxyLensCore

enum TrafficDiffKind: Equatable, Sendable {
    case unchanged
    case modified
    case removed
    case added
}

struct TrafficDiffRow: Equatable, Sendable {
    let leftLineNumber: Int?
    let rightLineNumber: Int?
    let leftText: String?
    let rightText: String?
    let kind: TrafficDiffKind
}

struct TrafficMessageComparison: Equatable, Sendable {
    let rows: [TrafficDiffRow]

    var changedRowCount: Int {
        rows.lazy.filter { $0.kind != .unchanged }.count
    }
}

struct TrafficFlowComparison: Equatable, Sendable {
    let leftTitle: String
    let rightTitle: String
    let request: TrafficMessageComparison
    let response: TrafficMessageComparison
}

enum TrafficUnifiedDiff {
    static func text(
        leftTitle: String,
        rightTitle: String,
        sectionTitle: String,
        comparison: TrafficMessageComparison
    ) -> String {
        let leftLineCount = comparison.rows.compactMap(\.leftLineNumber).max() ?? 0
        let rightLineCount = comparison.rows.compactMap(\.rightLineNumber).max() ?? 0
        var lines = [
            "--- \(leftTitle)",
            "+++ \(rightTitle)",
            "@@ -\(range(lineCount: leftLineCount)) +\(range(lineCount: rightLineCount)) @@ \(sectionTitle)"
        ]
        for row in comparison.rows {
            switch row.kind {
            case .unchanged:
                lines.append("  \(row.leftText ?? row.rightText ?? "")")
            case .modified:
                lines.append("- \(row.leftText ?? "")")
                lines.append("+ \(row.rightText ?? "")")
            case .removed:
                lines.append("- \(row.leftText ?? "")")
            case .added:
                lines.append("+ \(row.rightText ?? "")")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func range(lineCount: Int) -> String {
        lineCount == 0 ? "0,0" : "1,\(lineCount)"
    }
}

enum TrafficLineDiff {
    private enum Operation {
        case unchanged(leftNumber: Int, rightNumber: Int, text: String)
        case removed(number: Int, text: String)
        case added(number: Int, text: String)
    }

    /// Aligns two texts for a side-by-side diff. LCS work is bounded so large captures cannot
    /// allocate an unbounded matrix; oversized inputs use a deterministic positional fallback.
    static func rows(
        left: String,
        right: String,
        maximumMatrixCellCount: Int = 250_000
    ) -> [TrafficDiffRow] {
        let leftLines = left.components(separatedBy: "\n")
        let rightLines = right.components(separatedBy: "\n")
        let rowCount = leftLines.count + 1
        let columnCount = rightLines.count + 1
        guard
            maximumMatrixCellCount > 0,
            rowCount <= maximumMatrixCellCount / max(1, columnCount)
        else {
            return positionalRows(left: leftLines, right: rightLines)
        }

        var matrix = Array(
            repeating: Array(repeating: 0, count: columnCount),
            count: rowCount
        )
        for leftIndex in leftLines.indices.reversed() {
            for rightIndex in rightLines.indices.reversed() {
                if leftLines[leftIndex] == rightLines[rightIndex] {
                    matrix[leftIndex][rightIndex] = matrix[leftIndex + 1][rightIndex + 1] + 1
                } else {
                    matrix[leftIndex][rightIndex] = max(
                        matrix[leftIndex + 1][rightIndex],
                        matrix[leftIndex][rightIndex + 1]
                    )
                }
            }
        }

        var operations: [Operation] = []
        var leftIndex = 0
        var rightIndex = 0
        while leftIndex < leftLines.count || rightIndex < rightLines.count {
            if leftIndex < leftLines.count,
                rightIndex < rightLines.count,
                leftLines[leftIndex] == rightLines[rightIndex]
            {
                operations.append(
                    .unchanged(
                        leftNumber: leftIndex + 1,
                        rightNumber: rightIndex + 1,
                        text: leftLines[leftIndex]
                    )
                )
                leftIndex += 1
                rightIndex += 1
            } else if leftIndex < leftLines.count,
                rightIndex == rightLines.count
                    || matrix[leftIndex + 1][rightIndex]
                        >= matrix[leftIndex][rightIndex + 1]
            {
                operations.append(
                    .removed(number: leftIndex + 1, text: leftLines[leftIndex])
                )
                leftIndex += 1
            } else {
                operations.append(
                    .added(number: rightIndex + 1, text: rightLines[rightIndex])
                )
                rightIndex += 1
            }
        }
        return alignedRows(operations)
    }

    private static func alignedRows(_ operations: [Operation]) -> [TrafficDiffRow] {
        var result: [TrafficDiffRow] = []
        var index = 0
        while index < operations.count {
            if case .unchanged(let leftNumber, let rightNumber, let text) = operations[index] {
                result.append(
                    TrafficDiffRow(
                        leftLineNumber: leftNumber,
                        rightLineNumber: rightNumber,
                        leftText: text,
                        rightText: text,
                        kind: .unchanged
                    )
                )
                index += 1
                continue
            }

            var removed: [(number: Int, text: String)] = []
            var added: [(number: Int, text: String)] = []
            while index < operations.count {
                switch operations[index] {
                case .unchanged:
                    break
                case .removed(let number, let text):
                    removed.append((number, text))
                    index += 1
                    continue
                case .added(let number, let text):
                    added.append((number, text))
                    index += 1
                    continue
                }
                break
            }

            for offset in 0..<max(removed.count, added.count) {
                let left = removed.indices.contains(offset) ? removed[offset] : nil
                let right = added.indices.contains(offset) ? added[offset] : nil
                let kind: TrafficDiffKind
                if left != nil, right != nil {
                    kind = .modified
                } else if left != nil {
                    kind = .removed
                } else {
                    kind = .added
                }
                result.append(
                    TrafficDiffRow(
                        leftLineNumber: left?.number,
                        rightLineNumber: right?.number,
                        leftText: left?.text,
                        rightText: right?.text,
                        kind: kind
                    )
                )
            }
        }
        return result
    }

    private static func positionalRows(
        left: [String],
        right: [String]
    ) -> [TrafficDiffRow] {
        (0..<max(left.count, right.count)).map { index in
            let leftText = left.indices.contains(index) ? left[index] : nil
            let rightText = right.indices.contains(index) ? right[index] : nil
            let kind: TrafficDiffKind
            if leftText == rightText {
                kind = .unchanged
            } else if rightText == nil {
                kind = .removed
            } else if leftText == nil {
                kind = .added
            } else {
                kind = .modified
            }
            return TrafficDiffRow(
                leftLineNumber: leftText == nil ? nil : index + 1,
                rightLineNumber: rightText == nil ? nil : index + 1,
                leftText: leftText,
                rightText: rightText,
                kind: kind
            )
        }
    }
}

enum TrafficComparisonTextBuilder {
    static func title(for flow: Flow) -> String {
        "\(flow.request.method.rawValue) \(flow.request.url.absoluteString)"
    }

    static func requestText(for flow: Flow, bodyText: String?) -> String {
        joined(headers: HTTPMessageText.requestHeaders(flow.request), body: bodyText)
    }

    static func responseText(for flow: Flow, bodyText: String?) -> String {
        guard let response = flow.response else {
            return "[No response captured]"
        }
        return joined(headers: HTTPMessageText.responseHeaders(response), body: bodyText)
    }

    static func bodyText(
        data: Data,
        reference: BodyReference,
        maximumDecodedByteCount: Int
    ) -> String {
        let decoded: Data
        do {
            decoded = try HTTPContentCoding.decode(
                data,
                contentEncoding: reference.contentEncoding,
                maximumOutputByteCount: maximumDecodedByteCount
            )
        } catch HTTPContentCoding.CodingError.exceedsLimit {
            return "[Decoded body omitted because it exceeds the comparison limit.]"
        } catch {
            return "[Body could not be decoded for comparison: \(error.localizedDescription)]"
        }

        guard let text = String(data: decoded, encoding: .utf8), isText(decoded) else {
            return "[Binary body — \(formattedByteCount(reference.byteCount))]"
        }
        return text
    }

    static func omittedBodyText(for reference: BodyReference, maximumByteCount: Int64) -> String {
        "[Body omitted — \(formattedByteCount(reference.byteCount)) exceeds the "
            + "\(formattedByteCount(maximumByteCount)) comparison limit.]"
    }

    static func failedBodyText(_ error: Error) -> String {
        "[Body could not be loaded for comparison: \(error.localizedDescription)]"
    }

    private static func joined(headers: String, body: String?) -> String {
        guard let body else {
            return headers
        }
        return "\(headers)\n\n\(body)"
    }

    private static func isText(_ data: Data) -> Bool {
        let sample = data.prefix(min(data.count, 8_192))
        return !sample.contains { byte in
            byte == 0 || byte < 9 || (byte > 13 && byte < 32)
        }
    }

    private static func formattedByteCount(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}
