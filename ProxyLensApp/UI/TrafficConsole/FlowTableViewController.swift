import AppKit
import ProxyLensCore
import UniformTypeIdentifiers

@MainActor
final class FlowTableViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSMenuDelegate
{
    private let viewModel: TrafficConsoleViewModel
    private let tableView: NSTableView
    private let emptyLabel = NSTextField(labelWithString: "No traffic captured yet")
    private var rows: [TrafficFlowRow] = []
    private var isRendering = false

    init(
        viewModel: TrafficConsoleViewModel,
        tableView: NSTableView = NSTableView()
    ) {
        self.viewModel = viewModel
        self.tableView = tableView
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

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

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

        if oldIDs == newIDs {
            rows = newRows
            let changed = IndexSet(newRows.indices.filter { oldRows[$0] != newRows[$0] })
            reloadRows(changed)
        } else {
            applyStructuralChanges(from: oldRows, to: newRows)
            let oldRowsByID = Dictionary(uniqueKeysWithValues: oldRows.map { ($0.id, $0) })
            let changed = IndexSet(
                newRows.indices.filter { index in
                    guard let oldRow = oldRowsByID[newRows[index].id] else {
                        return false
                    }
                    return oldRow != newRows[index]
                }
            )
            reloadRows(changed)
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

    private func applyStructuralChanges(
        from oldRows: [TrafficFlowRow],
        to newRows: [TrafficFlowRow]
    ) {
        let oldIDs = oldRows.map(\.id)
        let newIDs = newRows.map(\.id)
        precondition(Set(oldIDs).count == oldIDs.count)
        precondition(Set(newIDs).count == newIDs.count)

        var working = oldRows
        let newIDSet = Set(newIDs)
        tableView.beginUpdates()

        for index in working.indices.reversed()
        where !newIDSet.contains(working[index].id) {
            working.remove(at: index)
            rows = working
            tableView.removeRows(at: IndexSet(integer: index), withAnimation: [])
        }

        for (targetIndex, newRow) in newRows.enumerated() {
            if targetIndex < working.count, working[targetIndex].id == newRow.id {
                continue
            }
            if let currentIndex = working.firstIndex(where: { $0.id == newRow.id }) {
                let row = working.remove(at: currentIndex)
                working.insert(row, at: targetIndex)
                rows = working
                tableView.moveRow(at: currentIndex, to: targetIndex)
            } else {
                working.insert(newRow, at: targetIndex)
                rows = working
                tableView.insertRows(at: IndexSet(integer: targetIndex), withAnimation: [])
            }
        }

        rows = newRows
        tableView.endUpdates()
        precondition(working.map(\.id) == newIDs)
    }

    private func reloadRows(_ rowIndexes: IndexSet) {
        guard !rowIndexes.isEmpty else {
            return
        }
        tableView.reloadData(
            forRowIndexes: rowIndexes,
            columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
        )
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
            let column = FlowColumn(rawValue: tableColumn.identifier.rawValue),
            rows.indices.contains(row)
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

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let rowIndex = tableView.clickedRow
        guard rows.indices.contains(rowIndex) else {
            return
        }

        let host = rows[rowIndex].host
        let path = Self.mappingPath(for: rows[rowIndex])
        let flowID = rows[rowIndex].id
        menu.addItem(
            exportMenuItem(title: "Copy as cURL", flowID: flowID, action: #selector(copyCURL))
        )
        menu.addItem(
            exportMenuItem(title: "Export HAR…", flowID: flowID, action: #selector(exportHAR))
        )
        menu.addItem(.separator())
        menu.addItem(ruleMenuItem(title: "Block \(host)", host: host, action: #selector(blockHost)))
        menu.addItem(ruleMenuItem(title: "Allow \(host)", host: host, action: #selector(allowHost)))
        menu.addItem(
            ruleMenuItem(
                title: "Disable Caching for \(host)",
                host: host,
                action: #selector(disableCaching)
            )
        )
        menu.addItem(.separator())
        let mapLocalItem = NSMenuItem(
            title: "Map Local \(host)\(path)…",
            action: #selector(mapLocal),
            keyEquivalent: ""
        )
        mapLocalItem.target = self
        mapLocalItem.representedObject = HostPathMenuTarget(host: host, path: path)
        menu.addItem(mapLocalItem)
        let mapRemoteItem = NSMenuItem(
            title: "Map Remote \(host)\(path)…",
            action: #selector(mapRemote),
            keyEquivalent: ""
        )
        mapRemoteItem.target = self
        mapRemoteItem.representedObject = HostPathMenuTarget(host: host, path: path)
        menu.addItem(mapRemoteItem)
        menu.addItem(.separator())
        let requestBreakpointItem = NSMenuItem(
            title: "Breakpoint request \(host)\(path)",
            action: #selector(breakpointRequest),
            keyEquivalent: ""
        )
        requestBreakpointItem.target = self
        requestBreakpointItem.representedObject = HostPathMenuTarget(host: host, path: path)
        menu.addItem(requestBreakpointItem)
        let responseBreakpointItem = NSMenuItem(
            title: "Breakpoint response \(host)\(path)",
            action: #selector(breakpointResponse),
            keyEquivalent: ""
        )
        responseBreakpointItem.target = self
        responseBreakpointItem.representedObject = HostPathMenuTarget(host: host, path: path)
        menu.addItem(responseBreakpointItem)
    }

    private func exportMenuItem(title: String, flowID: FlowID, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = flowID
        return item
    }

    private func ruleMenuItem(title: String, host: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = host
        return item
    }

    @objc private func copyCURL(_ sender: NSMenuItem) {
        guard let flowID = sender.representedObject as? FlowID else {
            return
        }

        Task { @MainActor in
            do {
                let command = try await viewModel.curlCommand(for: flowID)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } catch {
                await presentError(error)
            }
        }
    }

    @objc private func exportHAR(_ sender: NSMenuItem) {
        guard let flowID = sender.representedObject as? FlowID else {
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.title = "Export HAR"
        panel.nameFieldStringValue = "flow.har"
        if let harType = UTType(filenameExtension: "har") {
            panel.allowedContentTypes = [harType]
        } else {
            panel.allowedContentTypes = [.json]
        }
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url, let self else {
                return
            }
            Task { @MainActor in
                do {
                    let data = try await self.viewModel.harFile(for: flowID)
                    try data.write(to: url)
                } catch {
                    await self.presentError(error)
                }
            }
        }
    }

    private func presentError(_ error: Error) async {
        let alert = NSAlert(error: error)
        if let window = view.window {
            await alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @objc private func blockHost(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? String else {
            return
        }
        viewModel.blockHost(host)
    }

    @objc private func allowHost(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? String else {
            return
        }
        viewModel.allowHost(host)
    }

    @objc private func disableCaching(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? String else {
            return
        }
        viewModel.disableCaching(forHost: host)
    }

    @objc private func mapLocal(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? HostPathMenuTarget else {
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Map Local"
        panel.message = "Choose a file to return for \(target.host)\(target.path)"
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url, let self else {
                return
            }
            Task { @MainActor in
                do {
                    try await self.viewModel.mapLocal(
                        host: target.host,
                        path: target.path,
                        fileURL: url
                    )
                } catch {
                    let alert = NSAlert(error: error)
                    if let window = self.view.window {
                        await alert.beginSheetModal(for: window)
                    } else {
                        alert.runModal()
                    }
                }
            }
        }
    }

    @objc private func mapRemote(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? HostPathMenuTarget else {
            return
        }

        Task { @MainActor in
            await promptMapRemote(target: target)
        }
    }

    @objc private func breakpointRequest(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? HostPathMenuTarget else {
            return
        }
        viewModel.breakpoint(host: target.host, path: target.path, phase: .requestHeaders)
    }

    @objc private func breakpointResponse(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? HostPathMenuTarget else {
            return
        }
        viewModel.breakpoint(host: target.host, path: target.path, phase: .responseHeaders)
    }

    private func promptMapRemote(target: HostPathMenuTarget) async {
        let alert = NSAlert()
        alert.messageText = "Map Remote"
        alert.informativeText =
            "Enter the destination URL for \(target.host)\(target.path). A host-only URL keeps the original path and query."
        alert.addButton(withTitle: "Map")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "http://127.0.0.1:8080"
        field.stringValue = "http://"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let response: NSApplication.ModalResponse
        if let window = view.window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else {
            return
        }

        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard let destination = URL(string: text) else {
                throw ProxyLensError.invalidURL(text)
            }
            try await viewModel.mapRemote(
                host: target.host,
                path: target.path,
                destination: destination
            )
        } catch {
            let errorAlert = NSAlert(error: error)
            if let window = view.window {
                await errorAlert.beginSheetModal(for: window)
            } else {
                errorAlert.runModal()
            }
        }
    }

    private static func mappingPath(for row: TrafficFlowRow) -> String {
        let path =
            row.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? "/"
        return path.isEmpty ? "/" : path
    }
}

private final class HostPathMenuTarget: NSObject {
    let host: String
    let path: String

    init(host: String, path: String) {
        self.host = host
        self.path = path
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
        case .paused: return "Paused"
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
        case .paused: return .systemOrange
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
