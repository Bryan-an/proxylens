import Foundation
import ProxyLensApplication
import ProxyLensCore

enum TrafficSourceSelection: Equatable, Hashable, Sendable {
    case allTraffic
    case application(String)
    case domain(String)
}

struct TrafficApplicationSummary: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let bundlePath: String?
    let flowCount: Int
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
    let json: TrafficBodyPresentation
    let bodyContentType: String?
}

struct TrafficFlowInspection: Equatable, Sendable {
    let flowID: FlowID?
    let title: String
    let request: TrafficMessageInspection?
    let response: TrafficMessageInspection?
    let rules: String
    let breakpoint: TrafficBreakpointInspection?

    static let empty = TrafficFlowInspection(
        flowID: nil,
        title: "No Flow Selected",
        request: nil,
        response: nil,
        rules: "Select a captured flow to inspect applied rules.",
        breakpoint: nil
    )
}

struct TrafficBreakpointInspection: Equatable, Sendable {
    let phase: BreakpointPhase
    let canEditBody: Bool
}

struct TrafficConsoleSnapshot: Equatable, Sendable {
    let capture: TrafficCapturePresentation
    let workspaceWarning: String?
    let certificateTrust: CertificateTrustState?
    let allFlowCount: Int
    let applications: [TrafficApplicationSummary]
    let domains: [TrafficDomainSummary]
    let selectedSource: TrafficSourceSelection
    let displayFilter: TrafficDisplayFilter
    let visibleRows: [TrafficFlowRow]
    let selectedFlowID: FlowID?
    let inspection: TrafficFlowInspection

    static let initial = TrafficConsoleSnapshot(
        capture: .recovering,
        workspaceWarning: nil,
        certificateTrust: nil,
        allFlowCount: 0,
        applications: [],
        domains: [],
        selectedSource: .allTraffic,
        displayFilter: .all,
        visibleRows: [],
        selectedFlowID: nil,
        inspection: .empty
    )
}

struct TrafficConsoleStore {
    private var flowsByID: [FlowID: Flow] = [:]
    private var orderedFlowIDs: [FlowID] = []
    private var orderIndexByID: [FlowID: Int] = [:]
    private var searchableTextByID: [FlowID: String] = [:]
    private var applicationProjections: [String: ApplicationProjection] = [:]
    private var applicationSummaries: [TrafficApplicationSummary] = []
    private var domainCounts: [String: Int] = [:]
    private var domainSummaries: [TrafficDomainSummary] = []
    private var visibleRows: [TrafficFlowRow] = []
    private var visibleFlowIDs: Set<FlowID> = []
    private(set) var selectedSource: TrafficSourceSelection = .allTraffic
    private(set) var selectedFlowID: FlowID?
    private(set) var displayFilter: TrafficDisplayFilter = .all
    private var searchTokens: [String] = []
    private var sort: TrafficConsoleSort?

    var selectedFlow: Flow? {
        selectedFlowID.flatMap { flowsByID[$0] }
    }

    func flow(id: FlowID) -> Flow? {
        flowsByID[id]
    }

    mutating func apply(_ events: [FlowEvent]) {
        var applicationProjectionChanged = false
        var domainProjectionChanged = false
        var needsSort = false

        for event in events {
            let flow = event.flow
            let previousFlow = flowsByID[flow.id]
            if previousFlow == nil {
                orderIndexByID[flow.id] = orderedFlowIDs.count
                orderedFlowIDs.append(flow.id)
            }

            flowsByID[flow.id] = flow
            searchableTextByID[flow.id] = TrafficDisplayFilter.searchableText(for: flow)
            applicationProjectionChanged =
                updateApplicationProjections(previousFlow: previousFlow, currentFlow: flow)
                || applicationProjectionChanged
            domainProjectionChanged =
                updateDomainCounts(previousFlow: previousFlow, currentFlow: flow)
                || domainProjectionChanged

            let wasVisible = visibleFlowIDs.contains(flow.id)
            let isVisible = matchesCurrentProjection(flow)
            switch (wasVisible, isVisible) {
            case (true, true):
                guard let index = visibleRows.firstIndex(where: { $0.id == flow.id }) else {
                    rebuildVisibleProjection()
                    continue
                }
                visibleRows[index] = TrafficFlowRow(flow: flow)
                needsSort = needsSort || sort != nil
            case (true, false):
                visibleFlowIDs.remove(flow.id)
                if let index = visibleRows.firstIndex(where: { $0.id == flow.id }) {
                    visibleRows.remove(at: index)
                }
            case (false, true):
                let row = TrafficFlowRow(flow: flow)
                visibleFlowIDs.insert(flow.id)
                if sort == nil {
                    visibleRows.insert(row, at: captureOrderInsertionIndex(for: flow.id))
                } else {
                    visibleRows.append(row)
                    needsSort = true
                }
            case (false, false):
                break
            }
        }

        if applicationProjectionChanged {
            rebuildApplicationSummaries()
        }
        if domainProjectionChanged {
            rebuildDomainSummaries()
        }
        if needsSort {
            restoreVisibleOrder()
        }
        clearSelectionIfHidden()
    }

    mutating func replaceAll(_ flows: [Flow]) {
        flowsByID = [:]
        orderedFlowIDs = []
        orderIndexByID = [:]
        searchableTextByID = [:]
        applicationProjections = [:]
        applicationSummaries = []
        domainCounts = [:]
        domainSummaries = []
        visibleRows = []
        visibleFlowIDs = []
        selectedFlowID = nil
        apply(flows.map(FlowEvent.finished))
    }

    mutating func selectSource(_ source: TrafficSourceSelection) {
        guard selectedSource != source else {
            return
        }
        selectedSource = source
        rebuildVisibleProjection()
        clearSelectionIfHidden()
    }

    mutating func setDisplayFilter(_ filter: TrafficDisplayFilter) {
        guard displayFilter != filter else {
            return
        }
        displayFilter = filter
        searchTokens = filter.normalizedSearchTokens
        rebuildVisibleProjection()
        clearSelectionIfHidden()
    }

    mutating func clearFilters() {
        guard selectedSource != .allTraffic || displayFilter != .all else {
            return
        }
        selectedSource = .allTraffic
        displayFilter = .all
        searchTokens = []
        rebuildVisibleProjection()
    }

    mutating func selectFlow(_ flowID: FlowID?) {
        guard let flowID else {
            selectedFlowID = nil
            return
        }
        selectedFlowID = visibleFlowIDs.contains(flowID) ? flowID : nil
    }

    mutating func setSort(_ sort: TrafficConsoleSort?) {
        guard self.sort != sort else {
            return
        }
        self.sort = sort
        restoreVisibleOrder()
    }

    func snapshot(
        capture: TrafficCapturePresentation,
        inspection: TrafficFlowInspection,
        workspaceWarning: String? = nil,
        certificateTrust: CertificateTrustState? = nil
    ) -> TrafficConsoleSnapshot {
        TrafficConsoleSnapshot(
            capture: capture,
            workspaceWarning: workspaceWarning,
            certificateTrust: certificateTrust,
            allFlowCount: flowsByID.count,
            applications: applicationSummaries,
            domains: domainSummaries,
            selectedSource: selectedSource,
            displayFilter: displayFilter,
            visibleRows: visibleRows,
            selectedFlowID: selectedFlowID,
            inspection: inspection
        )
    }

    private func matchesCurrentProjection(_ flow: Flow) -> Bool {
        switch selectedSource {
        case .allTraffic:
            break
        case .application(let applicationID):
            guard Self.applicationProjection(for: flow)?.id == applicationID else {
                return false
            }
        case .domain(let host):
            guard TrafficFlowRow.host(for: flow) == host else {
                return false
            }
        }
        return displayFilter.matches(
            flow,
            searchableText: searchableTextByID[flow.id]
                ?? TrafficDisplayFilter.searchableText(for: flow),
            searchTokens: searchTokens
        )
    }

    private mutating func rebuildVisibleProjection() {
        var rebuiltRows: [TrafficFlowRow] = []
        rebuiltRows.reserveCapacity(visibleRows.count)
        for flowID in orderedFlowIDs {
            guard let flow = flowsByID[flowID], matchesCurrentProjection(flow) else {
                continue
            }
            rebuiltRows.append(TrafficFlowRow(flow: flow))
        }
        visibleRows = rebuiltRows
        visibleFlowIDs = Set(rebuiltRows.map(\.id))
        restoreVisibleOrder()
    }

    private mutating func updateDomainCounts(
        previousFlow: Flow?,
        currentFlow: Flow
    ) -> Bool {
        let currentHost = TrafficFlowRow.host(for: currentFlow)
        guard let previousFlow else {
            domainCounts[currentHost, default: 0] += 1
            return true
        }

        let previousHost = TrafficFlowRow.host(for: previousFlow)
        guard previousHost != currentHost else {
            return false
        }
        decrementDomainCount(previousHost)
        domainCounts[currentHost, default: 0] += 1
        return true
    }

    private mutating func updateApplicationProjections(
        previousFlow: Flow?,
        currentFlow: Flow
    ) -> Bool {
        let current = Self.applicationProjection(for: currentFlow)
        guard let previousFlow else {
            guard let current else {
                return false
            }
            incrementApplicationProjection(current)
            return true
        }

        let previous = Self.applicationProjection(for: previousFlow)
        guard previous != current else {
            return false
        }
        if let previous {
            decrementApplicationProjection(previous.id)
        }
        if let current {
            incrementApplicationProjection(current)
        }
        return true
    }

    private mutating func incrementApplicationProjection(_ projection: ApplicationProjection) {
        var updated = applicationProjections[projection.id] ?? projection
        updated.flowCount += 1
        applicationProjections[projection.id] = updated
    }

    private mutating func decrementApplicationProjection(_ id: String) {
        guard var projection = applicationProjections[id] else {
            return
        }
        if projection.flowCount == 1 {
            applicationProjections.removeValue(forKey: id)
        } else {
            projection.flowCount -= 1
            applicationProjections[id] = projection
        }
    }

    private mutating func rebuildApplicationSummaries() {
        applicationSummaries = applicationProjections.values
            .map {
                TrafficApplicationSummary(
                    id: $0.id,
                    name: $0.name,
                    bundlePath: $0.bundlePath,
                    flowCount: $0.flowCount
                )
            }
            .sorted {
                if $0.id == ApplicationProjection.unknownID {
                    return false
                }
                if $1.id == ApplicationProjection.unknownID {
                    return true
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    private static func applicationProjection(for flow: Flow) -> ApplicationProjection? {
        guard flow.source.kind == .desktopProxy else {
            return nil
        }
        guard let application = flow.source.application else {
            return .unknown
        }
        return ApplicationProjection(
            id: application.groupingIdentifier,
            name: application.name,
            bundlePath: application.bundlePath
        )
    }

    private mutating func decrementDomainCount(_ host: String) {
        guard let count = domainCounts[host] else {
            return
        }
        if count == 1 {
            domainCounts.removeValue(forKey: host)
        } else {
            domainCounts[host] = count - 1
        }
    }

    private mutating func rebuildDomainSummaries() {
        domainSummaries =
            domainCounts
            .map { TrafficDomainSummary(host: $0.key, flowCount: $0.value) }
            .sorted { $0.host.localizedStandardCompare($1.host) == .orderedAscending }
    }

    private func captureOrderInsertionIndex(for flowID: FlowID) -> Int {
        let targetOrder = orderIndexByID[flowID] ?? Int.max
        var lowerBound = 0
        var upperBound = visibleRows.count
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            let midpointOrder = orderIndexByID[visibleRows[midpoint].id] ?? Int.max
            if midpointOrder < targetOrder {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        return lowerBound
    }

    private mutating func restoreVisibleOrder() {
        let orderIndices = orderIndexByID
        guard let sort else {
            visibleRows.sort {
                (orderIndices[$0.id] ?? Int.max) < (orderIndices[$1.id] ?? Int.max)
            }
            return
        }

        visibleRows.sort { lhs, rhs in
            let comparison = Self.compare(lhs, rhs, key: sort.key)
            if comparison == .orderedSame {
                if lhs.startedAt != rhs.startedAt {
                    return lhs.startedAt < rhs.startedAt
                }
                return (orderIndices[lhs.id] ?? Int.max) < (orderIndices[rhs.id] ?? Int.max)
            }
            return sort.ascending
                ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    private mutating func clearSelectionIfHidden() {
        guard let selectedFlowID else {
            return
        }
        if !visibleFlowIDs.contains(selectedFlowID) {
            self.selectedFlowID = nil
        }
    }

    private static func compare(
        _ lhs: TrafficFlowRow,
        _ rhs: TrafficFlowRow,
        key: TrafficConsoleSortKey
    ) -> ComparisonResult {
        switch key {
        case .method:
            return lhs.method.localizedStandardCompare(rhs.method)
        case .host:
            return lhs.host.localizedStandardCompare(rhs.host)
        case .path:
            return lhs.path.localizedStandardCompare(rhs.path)
        case .status:
            return compare(lhs.statusCode ?? -1, rhs.statusCode ?? -1)
        case .startedAt:
            return compare(lhs.startedAt, rhs.startedAt)
        case .duration:
            return compare(lhs.duration ?? -1, rhs.duration ?? -1)
        case .size:
            return compare(lhs.byteCount, rhs.byteCount)
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

private struct ApplicationProjection: Equatable {
    static let unknownID = "application:unknown"
    static let unknown = ApplicationProjection(
        id: unknownID,
        name: "Unknown App",
        bundlePath: nil
    )

    let id: String
    let name: String
    let bundlePath: String?
    var flowCount = 0
}

extension FlowEvent {
    fileprivate var flow: Flow {
        switch self {
        case .started(let flow), .updated(let flow), .finished(let flow):
            flow
        }
    }
}
