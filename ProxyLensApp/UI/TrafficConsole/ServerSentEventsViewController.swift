import AppKit

@MainActor
final class ServerSentEventsViewController: NSViewController {
    var onEventSelection: ((UUID) -> Void)?
    var onSearchTextChange: ((String) -> Void)?
    var onExport: (() -> Void)?

    private enum Column: String, CaseIterable {
        case sequence
        case event
        case eventID
        case retry
        case time
        case size

        var title: String {
            switch self {
            case .sequence: "#"
            case .event: "Event"
            case .eventID: "ID"
            case .retry: "Retry"
            case .time: "Time"
            case .size: "Size"
            }
        }

        var width: CGFloat {
            switch self {
            case .sequence: 54
            case .event: 170
            case .eventID: 150
            case .retry: 88
            case .time: 112
            case .size: 78
            }
        }
    }

    private enum PresentationMode: Int {
        case eventData
        case accumulated
    }

    private let splitViewController = NSSplitViewController()
    private let tableView = NSTableView()
    private let tableScrollView = NSScrollView()
    private let searchField = NSSearchField()
    private let exportButton = NSButton(title: "Export…", target: nil, action: nil)
    private let statusField = NSTextField(labelWithString: "No Server-Sent Events were captured.")
    private let presentationSelector = NSSegmentedControl(
        labels: ["Event Data", "Accumulated"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let copyAccumulatedButton = NSButton(title: "Copy", target: nil, action: nil)
    private let payloadMetadataField = NSTextField(labelWithString: "")
    private let payloadTextView = NSTextView()
    private let payloadScrollView = NSScrollView()
    private var events: [TrafficServerSentEventRow] = []
    private var inspection: TrafficServerSentEventInspection?
    private var isRendering = false

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    override func loadView() {
        configureTable()
        configurePayload()

        let eventListController = NSViewController()
        eventListController.view = makeEventListView()
        let payloadController = NSViewController()
        payloadController.view = makePayloadView()

        splitViewController.splitView.isVertical = false
        splitViewController.splitView.dividerStyle = .thin
        splitViewController.splitView.setAccessibilityIdentifier("inspector.sse.split")

        let eventListItem = NSSplitViewItem(viewController: eventListController)
        eventListItem.minimumThickness = 80
        eventListItem.preferredThicknessFraction = 0.46
        let payloadItem = NSSplitViewItem(viewController: payloadController)
        payloadItem.minimumThickness = 80
        payloadItem.preferredThicknessFraction = 0.54
        splitViewController.addSplitViewItem(eventListItem)
        splitViewController.addSplitViewItem(payloadItem)

        let container = NSView()
        container.setAccessibilityIdentifier("inspector.sse")
        addChild(splitViewController)
        let splitView = splitViewController.view
        splitView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: container.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        view = container
    }

    func render(_ inspection: TrafficServerSentEventInspection?) {
        isRendering = true
        defer { isRendering = false }

        self.inspection = inspection
        events = inspection?.events ?? []
        tableView.reloadData()
        searchField.isEnabled = inspection != nil
        exportButton.isEnabled = (inspection?.capturedEventCount ?? 0) > 0
        if searchField.stringValue != (inspection?.searchText ?? "") {
            searchField.stringValue = inspection?.searchText ?? ""
        }

        if let selectedEventID = inspection?.selectedEventID,
            let selectedRow = events.firstIndex(where: { $0.id == selectedEventID })
        {
            tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
            tableView.scrollRowToVisible(selectedRow)
        } else {
            tableView.deselectAll(nil)
        }

        let status = inspection?.statusMessage ?? Self.eventCountDescription(events.count)
        if statusField.stringValue != status {
            statusField.stringValue = status
            NSAccessibility.post(element: statusField, notification: .valueChanged)
        }
        presentationSelector.isEnabled = inspection != nil
        renderSelectedPresentation()
    }

    private func configureTable() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 23
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.setAccessibilityIdentifier("inspector.sse.events")
        tableView.setAccessibilityLabel("Server-Sent Events")

        for column in Column.allCases {
            let tableColumn = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier(column.rawValue)
            )
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column == .event ? 110 : min(column.width, 52)
            tableColumn.resizingMask = column == .event ? .autoresizingMask : .userResizingMask
            tableView.addTableColumn(tableColumn)
        }

        tableScrollView.translatesAutoresizingMaskIntoConstraints = false
        tableScrollView.documentView = tableView
        tableScrollView.hasVerticalScroller = true
        tableScrollView.hasHorizontalScroller = true
        tableScrollView.autohidesScrollers = true
        tableScrollView.borderType = .noBorder
    }

    private func configurePayload() {
        presentationSelector.selectedSegment = PresentationMode.eventData.rawValue
        presentationSelector.target = self
        presentationSelector.action = #selector(presentationModeChanged(_:))
        presentationSelector.setAccessibilityIdentifier("inspector.sse.presentation")
        presentationSelector.setAccessibilityLabel("Server-Sent Event payload presentation")
        presentationSelector.toolTip =
            "Switch between the selected event data and derived accumulated streaming text"

        copyAccumulatedButton.bezelStyle = .rounded
        copyAccumulatedButton.target = self
        copyAccumulatedButton.action = #selector(copyAccumulatedText(_:))
        copyAccumulatedButton.setAccessibilityIdentifier("inspector.sse.copy-accumulated")
        copyAccumulatedButton.setAccessibilityLabel("Copy accumulated streaming response text")
        copyAccumulatedButton.toolTip = "Copy the derived accumulated text"

        payloadMetadataField.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        payloadMetadataField.textColor = .secondaryLabelColor
        payloadMetadataField.lineBreakMode = .byTruncatingMiddle
        payloadMetadataField.maximumNumberOfLines = 1
        payloadMetadataField.setAccessibilityIdentifier("inspector.sse.payload.metadata")

        payloadTextView.isEditable = false
        payloadTextView.isSelectable = true
        payloadTextView.isRichText = false
        payloadTextView.usesFindBar = true
        payloadTextView.isIncrementalSearchingEnabled = true
        payloadTextView.textContainerInset = NSSize(width: 10, height: 10)
        payloadTextView.backgroundColor = .textBackgroundColor
        payloadTextView.isHorizontallyResizable = true
        payloadTextView.isVerticallyResizable = true
        payloadTextView.autoresizingMask = [.width]
        payloadTextView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        payloadTextView.textContainer?.widthTracksTextView = false
        payloadTextView.setAccessibilityIdentifier("inspector.sse.payload")
        payloadTextView.setAccessibilityLabel("Selected Server-Sent Event data")

        payloadScrollView.translatesAutoresizingMaskIntoConstraints = false
        payloadScrollView.documentView = payloadTextView
        payloadScrollView.hasVerticalScroller = true
        payloadScrollView.hasHorizontalScroller = true
        payloadScrollView.autohidesScrollers = true
        payloadScrollView.borderType = .noBorder
    }

    private func makeEventListView() -> NSView {
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search events and data"
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.target = self
        searchField.action = #selector(searchTextChanged(_:))
        searchField.setAccessibilityIdentifier("inspector.sse.search")
        searchField.setAccessibilityLabel("Search Server-Sent Events")
        searchField.toolTip = "Search event metadata and bounded data payloads"

        exportButton.translatesAutoresizingMaskIntoConstraints = false
        exportButton.bezelStyle = .rounded
        exportButton.target = self
        exportButton.action = #selector(exportEvents(_:))
        exportButton.setAccessibilityIdentifier("inspector.sse.export")
        exportButton.setAccessibilityLabel("Export all Server-Sent Events")
        exportButton.toolTip = "Export the complete event history as ProxyLens JSON"
        exportButton.setContentHuggingPriority(.required, for: .horizontal)

        let controls = NSStackView(views: [searchField, exportButton])
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 6

        statusField.translatesAutoresizingMaskIntoConstraints = false
        statusField.font = .systemFont(ofSize: 10, weight: .regular)
        statusField.textColor = .secondaryLabelColor
        statusField.lineBreakMode = .byTruncatingTail
        statusField.setAccessibilityIdentifier("inspector.sse.status")
        statusField.setAccessibilityLabel("Server-Sent Event capture status")

        let container = NSView()
        container.addSubview(controls)
        container.addSubview(statusField)
        container.addSubview(tableScrollView)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            controls.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            controls.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            statusField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            statusField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            statusField.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 5),
            tableScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tableScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tableScrollView.topAnchor.constraint(equalTo: statusField.bottomAnchor, constant: 5),
            tableScrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func makePayloadView() -> NSView {
        presentationSelector.translatesAutoresizingMaskIntoConstraints = false
        copyAccumulatedButton.translatesAutoresizingMaskIntoConstraints = false
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let controls = NSStackView(views: [presentationSelector, spacer, copyAccumulatedButton])
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 6

        payloadMetadataField.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(controls)
        container.addSubview(payloadMetadataField)
        container.addSubview(payloadScrollView)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            controls.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            controls.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            payloadMetadataField.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: 10),
            payloadMetadataField.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -10),
            payloadMetadataField.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 5),
            payloadScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            payloadScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            payloadScrollView.topAnchor.constraint(
                equalTo: payloadMetadataField.bottomAnchor, constant: 5),
            payloadScrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    @objc private func searchTextChanged(_ sender: NSSearchField) {
        guard !isRendering else {
            return
        }
        onSearchTextChange?(sender.stringValue)
    }

    @objc private func exportEvents(_ sender: NSButton) {
        onExport?()
    }

    @objc private func presentationModeChanged(_ sender: NSSegmentedControl) {
        renderSelectedPresentation()
    }

    @objc private func copyAccumulatedText(_ sender: NSButton) {
        guard case .content(_, let text) = inspection?.accumulated, !text.isEmpty else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func renderSelectedPresentation() {
        let mode = PresentationMode(rawValue: presentationSelector.selectedSegment) ?? .eventData
        switch mode {
        case .eventData:
            copyAccumulatedButton.isEnabled = false
            payloadTextView.setAccessibilityLabel("Selected Server-Sent Event data")
            renderPayload(
                inspection?.payload
                    ?? .none("Select an event-stream response to inspect captured events."),
                syntax: inspection?.payloadSyntax ?? .plainText
            )
        case .accumulated:
            let accumulated =
                inspection?.accumulated
                ?? .none("Select an event-stream response to build an accumulated preview.")
            if case .content(_, let text) = accumulated {
                copyAccumulatedButton.isEnabled = !text.isEmpty
            } else {
                copyAccumulatedButton.isEnabled = false
            }
            payloadTextView.setAccessibilityLabel("Accumulated streaming response text")
            renderPayload(accumulated, syntax: .plainText)
        }
    }

    private func renderPayload(
        _ presentation: TrafficBodyPresentation,
        syntax: TrafficServerSentEventPayloadSyntax
    ) {
        let metadata: String
        let value: String
        let color: NSColor
        switch presentation {
        case .none(let message):
            metadata = ""
            value = message
            color = .secondaryLabelColor
        case .loading(let message):
            metadata = message
            value = "Loading event data…"
            color = .secondaryLabelColor
        case .content(let bodyMetadata, let bodyValue):
            metadata = bodyMetadata
            value = bodyValue
            color = .textColor
        case .failed(let bodyMetadata, let message):
            metadata = bodyMetadata
            value = message
            color = .systemRed
        }

        payloadMetadataField.stringValue = metadata
        let language: InspectorSyntaxHighlighter.Language = syntax == .json ? .json : .plainText
        let attributed = NSMutableAttributedString(
            attributedString: InspectorSyntaxHighlighter.highlight(value, as: language)
        )
        if syntax != .json || color != .textColor {
            attributed.addAttribute(
                .foregroundColor,
                value: color,
                range: NSRange(location: 0, length: attributed.length)
            )
        }
        payloadTextView.textStorage?.setAttributedString(attributed)
        payloadTextView.scrollToBeginningOfDocument(nil)
    }

    private func value(for event: TrafficServerSentEventRow, column: Column) -> String {
        switch column {
        case .sequence:
            return String(event.sequenceNumber)
        case .event:
            return event.eventType
        case .eventID:
            return event.eventID ?? "—"
        case .retry:
            return event.retryMilliseconds.map { "\($0) ms" } ?? "—"
        case .time:
            return timeFormatter.string(from: event.receivedAt)
        case .size:
            let value = ByteCountFormatter.string(fromByteCount: event.byteCount, countStyle: .file)
            return event.isTruncated ? "\(value)+" : value
        }
    }

    private static func eventCountDescription(_ count: Int) -> String {
        count == 1 ? "1 captured Server-Sent Event" : "\(count) captured Server-Sent Events"
    }
}

extension ServerSentEventsViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        events.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard row >= 0, row < events.count,
            let tableColumn,
            let column = Column(rawValue: tableColumn.identifier.rawValue)
        else {
            return nil
        }

        let identifier = NSUserInterfaceItemIdentifier("sse.cell.\(column.rawValue)")
        let cell =
            tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeCell(identifier: identifier)
        let text = value(for: events[row], column: column)
        cell.textField?.stringValue = text
        cell.textField?.toolTip = text
        cell.textField?.textColor = column == .event ? .systemOrange : .labelColor
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRendering,
            tableView.selectedRow >= 0,
            tableView.selectedRow < events.count
        else {
            return
        }
        onEventSelection?(events[tableView.selectedRow].id)
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        field.lineBreakMode = .byTruncatingMiddle
        field.maximumNumberOfLines = 1
        cell.textField = field
        cell.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}
