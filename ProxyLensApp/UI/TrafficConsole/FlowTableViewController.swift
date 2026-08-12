import AppKit
import ProxyLensCore

@MainActor
final class FlowTableViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let viewModel: TrafficConsoleViewModel
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "No traffic captured yet")
    private var rows: [TrafficFlowRow] = []
    private var isRendering = false

    init(viewModel: TrafficConsoleViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.rowSizeStyle = .default
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityIdentifier("traffic.flows")

        for column in FlowColumn.allCases {
            let tableColumn = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column.minimumWidth
            tableColumn.resizingMask =
                column == .path ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(
                key: column.sortKey.rawValue,
                ascending: true
            )
            tableView.addTableColumn(tableColumn)
        }

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 15, weight: .medium)

        let container = NSView()
        container.addSubview(scrollView)
        container.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        view = container
    }

    func render(_ snapshot: TrafficConsoleSnapshot) {
        isRendering = true
        defer { isRendering = false }

        let oldRows = rows
        let oldIDs = oldRows.map(\.id)
        let newRows = snapshot.visibleRows
        let newIDs = newRows.map(\.id)
        rows = newRows

        if oldIDs == newIDs {
            let changed = IndexSet(newRows.indices.filter { oldRows[$0] != newRows[$0] })
            if !changed.isEmpty {
                tableView.reloadData(
                    forRowIndexes: changed,
                    columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
                )
            }
        } else if newIDs.count > oldIDs.count, Array(newIDs.prefix(oldIDs.count)) == oldIDs {
            tableView.beginUpdates()
            let inserted = IndexSet(integersIn: oldIDs.count..<newIDs.count)
            tableView.insertRows(at: inserted, withAnimation: [])
            let changed = IndexSet(oldRows.indices.filter { oldRows[$0] != newRows[$0] })
            if !changed.isEmpty {
                tableView.reloadData(
                    forRowIndexes: changed,
                    columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
                )
            }
            tableView.endUpdates()
        } else {
            tableView.reloadData()
        }

        emptyLabel.isHidden = !rows.isEmpty
        if rows.isEmpty {
            if snapshot.allFlowCount == 0 {
                emptyLabel.stringValue = "No traffic captured yet"
            } else if snapshot.displayFilter.isActive {
                emptyLabel.stringValue = "No flows match the active filters"
            } else {
                emptyLabel.stringValue = "No flows in this source"
            }
        }

        if let selectedFlowID = snapshot.selectedFlowID,
            let row = rows.firstIndex(where: { $0.id == selectedFlowID })
        {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        } else {
            tableView.deselectAll(nil)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let tableColumn,
            let column = FlowColumn(rawValue: tableColumn.identifier.rawValue)
        else {
            return nil
        }

        let identifier = NSUserInterfaceItemIdentifier("FlowCell.\(column.rawValue)")
        let cell =
            (tableView.makeView(withIdentifier: identifier, owner: self) as? FlowTableCellView)
            ?? FlowTableCellView(identifier: identifier)
        let flow = rows[row]
        let presentation = FlowCellFormatter.presentation(for: column, flow: flow)
        cell.render(presentation)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRendering else {
            return
        }
        let selectedRow = tableView.selectedRow
        viewModel.selectFlow(selectedRow >= 0 ? rows[selectedRow].id : nil)
    }

    func tableView(
        _ tableView: NSTableView,
        sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
    ) {
        guard !isRendering else {
            return
        }
        guard let descriptor = tableView.sortDescriptors.first,
            let key = descriptor.key.flatMap(TrafficConsoleSortKey.init(rawValue:))
        else {
            viewModel.clearSort()
            return
        }
        viewModel.sortRows(by: key, ascending: descriptor.ascending)
    }
}

private enum FlowColumn: String, CaseIterable {
    case method
    case host
    case path
    case status
    case startedAt
    case duration
    case size

    var title: String {
        switch self {
        case .method: "Method"
        case .host: "Host"
        case .path: "Path"
        case .status: "Status"
        case .startedAt: "Time"
        case .duration: "Duration"
        case .size: "Size"
        }
    }

    var width: CGFloat {
        switch self {
        case .method: 68
        case .host: 160
        case .path: 240
        case .status: 72
        case .startedAt: 88
        case .duration: 82
        case .size: 76
        }
    }

    var minimumWidth: CGFloat {
        switch self {
        case .method: 58
        case .host: 100
        case .path: 120
        case .status: 60
        case .startedAt: 72
        case .duration: 68
        case .size: 60
        }
    }

    var sortKey: TrafficConsoleSortKey {
        switch self {
        case .method: .method
        case .host: .host
        case .path: .path
        case .status: .status
        case .startedAt: .startedAt
        case .duration: .duration
        case .size: .size
        }
    }
}

private struct FlowCellPresentation {
    let text: String
    let textColor: NSColor
    let font: NSFont
    let toolTip: String?
}

@MainActor
private enum FlowCellFormatter {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func presentation(
        for column: FlowColumn,
        flow: TrafficFlowRow
    ) -> FlowCellPresentation {
        let regularFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let monospacedFont = NSFont.monospacedSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .regular
        )
        switch column {
        case .method:
            return FlowCellPresentation(
                text: flow.method,
                textColor: methodColor(flow.method),
                font: .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                toolTip: nil
            )
        case .host:
            return FlowCellPresentation(
                text: flow.usesTLS ? "🔒 \(flow.host)" : flow.host,
                textColor: .labelColor,
                font: regularFont,
                toolTip: flow.fullURL
            )
        case .path:
            return FlowCellPresentation(
                text: flow.path,
                textColor: .labelColor,
                font: regularFont,
                toolTip: flow.fullURL
            )
        case .status:
            return FlowCellPresentation(
                text: statusText(flow),
                textColor: statusColor(flow),
                font: monospacedFont,
                toolTip: nil
            )
        case .startedAt:
            return FlowCellPresentation(
                text: timeFormatter.string(from: flow.startedAt),
                textColor: .secondaryLabelColor,
                font: monospacedFont,
                toolTip: nil
            )
        case .duration:
            return FlowCellPresentation(
                text: formattedDuration(flow.duration),
                textColor: .secondaryLabelColor,
                font: monospacedFont,
                toolTip: nil
            )
        case .size:
            return FlowCellPresentation(
                text: formattedByteCount(flow.byteCount),
                textColor: .secondaryLabelColor,
                font: monospacedFont,
                toolTip: nil
            )
        }
    }

    private static func methodColor(_ method: String) -> NSColor {
        switch method {
        case "GET": .systemBlue
        case "POST": .systemGreen
        case "PUT", "PATCH": .systemOrange
        case "DELETE": .systemRed
        default: .labelColor
        }
    }

    private static func statusText(_ flow: TrafficFlowRow) -> String {
        if let statusCode = flow.statusCode {
            return String(statusCode)
        }
        switch flow.state {
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .completed: return "Done"
        case .created, .receivingRequest, .connectingUpstream, .receivingResponse: return "Pending"
        }
    }

    private static func statusColor(_ flow: TrafficFlowRow) -> NSColor {
        if let statusCode = flow.statusCode {
            switch statusCode {
            case 200..<300: return .systemGreen
            case 300..<400: return .systemBlue
            case 400..<500: return .systemOrange
            default: return .systemRed
            }
        }
        switch flow.state {
        case .failed, .cancelled: return .systemRed
        default: return .secondaryLabelColor
        }
    }

    private static func formattedDuration(_ duration: TimeInterval?) -> String {
        guard let duration else {
            return "—"
        }
        if duration < 1 {
            return String(format: "%.0f ms", duration * 1_000)
        }
        return String(format: "%.2f s", duration)
    }

    private static func formattedByteCount(_ byteCount: Int64) -> String {
        if byteCount < 1_000 {
            return "\(byteCount) B"
        }
        if byteCount < 1_000_000 {
            return String(format: "%.1f KB", Double(byteCount) / 1_000)
        }
        return String(format: "%.1f MB", Double(byteCount) / 1_000_000)
    }
}

@MainActor
private final class FlowTableCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(_ presentation: FlowCellPresentation) {
        label.stringValue = presentation.text
        label.textColor = presentation.textColor
        label.font = presentation.font
        label.toolTip = presentation.toolTip
    }
}
