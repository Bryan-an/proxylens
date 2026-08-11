import Foundation
import ProxyLensApplication
import ProxyLensCore

enum TrafficSourceSelection: Equatable, Hashable, Sendable {
    case allTraffic
    case domain(String)
}

struct TrafficDomainSummary: Equatable, Identifiable, Sendable {
    let host: String
    let flowCount: Int

    var id: String { host }
}

enum TrafficConsoleSortKey: String, Sendable {
    case method
    case host
    case path
    case status
    case startedAt
    case duration
    case size
}

struct TrafficConsoleSort: Equatable, Sendable {
    let key: TrafficConsoleSortKey
    let ascending: Bool
}

struct TrafficFlowRow: Equatable, Identifiable, Sendable {
    let id: FlowID
    let method: String
    let host: String
    let path: String
    let fullURL: String
    let statusCode: Int?
    let state: FlowState
    let startedAt: Date
    let duration: TimeInterval?
    let byteCount: Int64
    let usesTLS: Bool

    init(flow: Flow) {
        id = flow.id
        method = flow.request.method.rawValue
        host = Self.host(for: flow)
        path = Self.path(for: flow.request.url)
        fullURL = flow.request.url.absoluteString
        statusCode = flow.response?.statusCode
        state = flow.state
        startedAt = flow.createdAt
        duration = flow.timing.totalDuration
        byteCount = Self.totalBytes(flow)
        usesTLS =
            flow.connection?.protocolKind == .https
            || flow.connection?.protocolKind == .secureWebSocket
            || flow.request.url.scheme?.lowercased() == "https"
    }

    static func host(for flow: Flow) -> String {
        flow.request.url.host?.lowercased()
            ?? flow.connection?.upstreamHost.lowercased()
            ?? "Unknown Host"
    }

    private static func path(for url: URL) -> String {
        var value = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty {
            value += "?\(query)"
        }
        return value
    }

    private static func totalBytes(_ flow: Flow) -> Int64 {
        let requestBytes = flow.request.body?.byteCount ?? 0
        let responseBytes = flow.response?.body?.byteCount ?? 0
        let (total, overflowed) = requestBytes.addingReportingOverflow(responseBytes)
        return overflowed ? Int64.max : total
    }
}

enum TrafficCapturePresentation: Equatable, Sendable {
    case recovering
    case stopped
    case starting
    case running(CaptureContext, warning: String?)
    case stopping
    case failed(String)
}

enum TrafficBodyPresentation: Equatable, Sendable {
    case none(String)
    case loading(String)
    case content(metadata: String, value: String)
    case failed(metadata: String, message: String)
}

struct TrafficMessageInspection: Equatable, Sendable {
    let title: String
    let headers: String
    let body: TrafficBodyPresentation
}

struct TrafficFlowInspection: Equatable, Sendable {
    let flowID: FlowID?
    let title: String
    let request: TrafficMessageInspection?
    let response: TrafficMessageInspection?

    static let empty = TrafficFlowInspection(
        flowID: nil,
        title: "No Flow Selected",
        request: nil,
        response: nil
    )
}

struct TrafficConsoleSnapshot: Equatable, Sendable {
    let capture: TrafficCapturePresentation
    let allFlowCount: Int
    let domains: [TrafficDomainSummary]
    let selectedSource: TrafficSourceSelection
    let visibleRows: [TrafficFlowRow]
    let selectedFlowID: FlowID?
    let inspection: TrafficFlowInspection

    static let initial = TrafficConsoleSnapshot(
        capture: .recovering,
        allFlowCount: 0,
        domains: [],
        selectedSource: .allTraffic,
        visibleRows: [],
        selectedFlowID: nil,
        inspection: .empty
    )
}

struct TrafficConsoleStore {
    private var flowsByID: [FlowID: Flow] = [:]
    private var orderedFlowIDs: [FlowID] = []
    private(set) var selectedSource: TrafficSourceSelection = .allTraffic
    private(set) var selectedFlowID: FlowID?
    private var sort: TrafficConsoleSort?

    var selectedFlow: Flow? {
        selectedFlowID.flatMap { flowsByID[$0] }
    }

    mutating func apply(_ events: [FlowEvent]) {
        for event in events {
            let flow = event.flow
            if flowsByID[flow.id] == nil {
                orderedFlowIDs.append(flow.id)
            }
            flowsByID[flow.id] = flow
        }
        clearSelectionIfHidden()
    }

    mutating func selectSource(_ source: TrafficSourceSelection) {
        selectedSource = source
        clearSelectionIfHidden()
    }

    mutating func selectFlow(_ flowID: FlowID?) {
        guard let flowID else {
            selectedFlowID = nil
            return
        }
        selectedFlowID = visibleFlows().contains(where: { $0.id == flowID }) ? flowID : nil
    }

    mutating func setSort(_ sort: TrafficConsoleSort?) {
        self.sort = sort
    }

    func snapshot(
        capture: TrafficCapturePresentation,
        inspection: TrafficFlowInspection
    ) -> TrafficConsoleSnapshot {
        let domainCounts = flowsByID.values.reduce(into: [String: Int]()) { counts, flow in
            counts[TrafficFlowRow.host(for: flow), default: 0] += 1
        }
        let domains =
            domainCounts
            .map { TrafficDomainSummary(host: $0.key, flowCount: $0.value) }
            .sorted { $0.host.localizedStandardCompare($1.host) == .orderedAscending }

        return TrafficConsoleSnapshot(
            capture: capture,
            allFlowCount: flowsByID.count,
            domains: domains,
            selectedSource: selectedSource,
            visibleRows: visibleFlows().map(TrafficFlowRow.init),
            selectedFlowID: selectedFlowID,
            inspection: inspection
        )
    }

    private func visibleFlows() -> [Flow] {
        var flows = orderedFlowIDs.compactMap { flowsByID[$0] }
        if case .domain(let host) = selectedSource {
            flows.removeAll { TrafficFlowRow.host(for: $0) != host }
        }
        guard let sort else {
            return flows
        }
        return flows.sorted { lhs, rhs in
            let comparison = Self.compare(lhs, rhs, key: sort.key)
            if comparison == .orderedSame {
                return lhs.createdAt < rhs.createdAt
            }
            return sort.ascending
                ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    private mutating func clearSelectionIfHidden() {
        guard let selectedFlowID else {
            return
        }
        if !visibleFlows().contains(where: { $0.id == selectedFlowID }) {
            self.selectedFlowID = nil
        }
    }

    private static func compare(
        _ lhs: Flow,
        _ rhs: Flow,
        key: TrafficConsoleSortKey
    ) -> ComparisonResult {
        let left = TrafficFlowRow(flow: lhs)
        let right = TrafficFlowRow(flow: rhs)
        switch key {
        case .method:
            return left.method.localizedStandardCompare(right.method)
        case .host:
            return left.host.localizedStandardCompare(right.host)
        case .path:
            return left.path.localizedStandardCompare(right.path)
        case .status:
            return compare(left.statusCode ?? -1, right.statusCode ?? -1)
        case .startedAt:
            return compare(left.startedAt, right.startedAt)
        case .duration:
            return compare(left.duration ?? -1, right.duration ?? -1)
        case .size:
            return compare(left.byteCount, right.byteCount)
        }
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs {
            return .orderedAscending
        }
        if lhs > rhs {
            return .orderedDescending
        }
        return .orderedSame
    }
}

extension FlowEvent {
    fileprivate var flow: Flow {
        switch self {
        case .started(let flow), .updated(let flow), .finished(let flow):
            flow
        }
    }
}
