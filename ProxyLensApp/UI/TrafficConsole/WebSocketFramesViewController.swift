import AppKit
import ProxyLensCore

@MainActor
final class WebSocketFramesViewController: NSViewController {
    var onFrameSelection: ((UUID) -> Void)?
    var onDirectionFilterChange: ((TrafficWebSocketDirectionFilter) -> Void)?
    var onSearchTextChange: ((String) -> Void)?
    var onPayloadModeChange: ((TrafficWebSocketPayloadMode) -> Void)?
    var onCompose: (() -> Void)?
    var onReconnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onExport: (() -> Void)?

    private enum Column: String, CaseIterable {
        case sequence
        case direction
        case opcode
        case flags
        case time
        case size

        var title: String {
            switch self {
            case .sequence: "#"
            case .direction: "Direction"
            case .opcode: "Type"
            case .flags: "Flags"
            case .time: "Time"
            case .size: "Size"
            }
        }

        var width: CGFloat {
            switch self {
            case .sequence: 54
            case .direction: 150
            case .opcode: 94
            case .flags: 88
            case .time: 112
            case .size: 78
            }
        }
    }

    private let splitViewController = NSSplitViewController()
    private let tableView = NSTableView()
    private let tableScrollView = NSScrollView()
    private let directionSelector = NSSegmentedControl(
        labels: TrafficWebSocketDirectionFilter.allCases.map(\.rawValue),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let searchField = NSSearchField()
    private let connectionStatusField = NSTextField(labelWithString: "Closed")
    private let composeButton = NSButton(title: "Compose…", target: nil, action: nil)
    private let disconnectButton = NSButton(title: "Disconnect", target: nil, action: nil)
    private let exportButton = NSButton(title: "Export…", target: nil, action: nil)
    private let statusField = NSTextField(labelWithString: "No WebSocket frames were captured.")
    private let payloadMetadataField = NSTextField(labelWithString: "")
    private let payloadModeSelector = NSSegmentedControl(
        labels: TrafficWebSocketPayloadMode.allCases.map(\.rawValue),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let payloadTextView = NSTextView()
    private let payloadScrollView = NSScrollView()
    private var frames: [TrafficWebSocketFrameInspection] = []
    private var isRendering = false
    private var reconnectsOnPrimaryAction = false
    private var renderedBreakpoint: TrafficWebSocketBreakpointInspection?

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    override func loadView() {
        configureTable()
        configurePayload()

        let frameListView = makeFrameListView()
        let payloadView = makePayloadView()
        let frameListController = NSViewController()
        frameListController.view = frameListView
        let payloadController = NSViewController()
        payloadController.view = payloadView

        splitViewController.splitView.isVertical = false
        splitViewController.splitView.dividerStyle = .thin
        splitViewController.splitView.setAccessibilityIdentifier("inspector.websocket.split")

        let frameListItem = NSSplitViewItem(viewController: frameListController)
        frameListItem.minimumThickness = 80
        frameListItem.preferredThicknessFraction = 0.46
        let payloadItem = NSSplitViewItem(viewController: payloadController)
        payloadItem.minimumThickness = 80
        payloadItem.preferredThicknessFraction = 0.54
        splitViewController.addSplitViewItem(frameListItem)
        splitViewController.addSplitViewItem(payloadItem)

        let container = NSView()
        container.setAccessibilityIdentifier("inspector.websocket")
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

    func render(
        _ inspection: TrafficWebSocketInspection?,
        breakpoint: TrafficWebSocketBreakpointInspection? = nil,
        resetBreakpoint: Bool = false
    ) {
        isRendering = true
        defer { isRendering = false }

        let isPaused = breakpoint != nil
        let isNewBreakpoint =
            resetBreakpoint
            || breakpoint?.sequenceNumber != renderedBreakpoint?.sequenceNumber
        frames = inspection?.frames ?? []
        tableView.reloadData()
        directionSelector.selectedSegment = Self.segmentIndex(
            for: inspection?.directionFilter ?? .all
        )
        if searchField.stringValue != (inspection?.searchText ?? "") {
            searchField.stringValue = inspection?.searchText ?? ""
        }
        directionSelector.isEnabled = inspection != nil && !isPaused
        searchField.isEnabled = inspection != nil && !isPaused
        tableView.isEnabled = inspection != nil && !isPaused
        let canCompose = inspection?.canCompose == true
        let canReconnect = inspection?.canReconnect == true
        reconnectsOnPrimaryAction = !canCompose && canReconnect
        composeButton.title = reconnectsOnPrimaryAction ? "Reconnect…" : "Compose…"
        composeButton.isEnabled = (canCompose || canReconnect) && !isPaused
        composeButton.setAccessibilityLabel(
            reconnectsOnPrimaryAction
                ? "Reconnect WebSocket"
                : "Compose WebSocket frame"
        )
        disconnectButton.isHidden = inspection?.canDisconnect != true
        disconnectButton.isEnabled = inspection?.canDisconnect == true && !isPaused
        exportButton.isEnabled = (inspection?.capturedFrameCount ?? 0) > 0 && !isPaused
        payloadModeSelector.selectedSegment = Self.payloadModeSegmentIndex(
            for: inspection?.payloadMode ?? .automatic
        )
        payloadModeSelector.isEnabled = inspection?.selectedFrameID != nil && !isPaused
        payloadModeSelector.setEnabled(
            inspection?.canDecodePayloadAsProtobuf == true,
            forSegment: Self.payloadModeSegmentIndex(for: .protobuf)
        )

        let isLive = canCompose
        connectionStatusField.stringValue = isPaused ? "Paused" : (isLive ? "Live" : "Closed")
        connectionStatusField.textColor =
            isPaused
            ? .systemOrange
            : (isLive ? .systemGreen : .secondaryLabelColor)
        let composeHelp =
            inspection?.composeStatusMessage
            ?? (isLive
                ? "Send a text or binary frame on the live WebSocket connection"
                : "Open a fresh connection from this captured WebSocket")
        connectionStatusField.toolTip = composeHelp
        composeButton.toolTip = composeHelp
        composeButton.setAccessibilityHelp(composeHelp)
        disconnectButton.toolTip = "Close this replay WebSocket connection"
        disconnectButton.setAccessibilityHelp(disconnectButton.toolTip)

        if let selectedFrameID = inspection?.selectedFrameID,
            let selectedRow = frames.firstIndex(where: { $0.id == selectedFrameID })
        {
            tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
            tableView.scrollRowToVisible(selectedRow)
        } else {
            tableView.deselectAll(nil)
        }

        let statusMessage =
            breakpoint?.statusMessage
            ?? inspection?.statusMessage
            ?? Self.frameCountDescription(frames.count)
        if statusField.stringValue != statusMessage {
            statusField.stringValue = statusMessage
            NSAccessibility.post(element: statusField, notification: .valueChanged)
        }
        if let breakpoint {
            payloadTextView.isEditable = breakpoint.canEditPayload
            payloadTextView.setAccessibilityLabel(
                breakpoint.canEditPayload
                    ? "Editable paused WebSocket response payload"
                    : "Read-only paused WebSocket response payload"
            )
            if isNewBreakpoint {
                renderPayload(
                    .content(
                        metadata:
                            "Server → Client • \(Self.opcodeLabel(breakpoint.opcode)) • Frame #\(breakpoint.sequenceNumber)",
                        value: breakpoint.payload
                    ),
                    syntax: breakpoint.syntax
                )
            }
        } else {
            payloadTextView.isEditable = false
            payloadTextView.setAccessibilityLabel("Selected WebSocket frame payload")
            renderPayload(
                inspection?.payload
                    ?? .none("Select a WebSocket flow to inspect captured frames."),
                syntax: inspection?.payloadSyntax ?? .plainText
            )
        }
        renderedBreakpoint = breakpoint
    }

    func pendingBreakpointPayloadText() -> String? {
        guard renderedBreakpoint?.canEditPayload == true else {
            return nil
        }
        return payloadTextView.string
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
        tableView.setAccessibilityIdentifier("inspector.websocket.frames")
        tableView.setAccessibilityLabel("WebSocket frames")

        for column in Column.allCases {
            let tableColumn = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column == .direction ? 116 : min(column.width, 52)
            tableColumn.resizingMask = column == .direction ? .autoresizingMask : .userResizingMask
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
        payloadMetadataField.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        payloadMetadataField.textColor = .secondaryLabelColor
        payloadMetadataField.lineBreakMode = .byTruncatingMiddle
        payloadMetadataField.maximumNumberOfLines = 1
        payloadMetadataField.setAccessibilityIdentifier("inspector.websocket.payload.metadata")
        payloadMetadataField.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )

        payloadModeSelector.target = self
        payloadModeSelector.action = #selector(payloadModeChanged(_:))
        payloadModeSelector.setAccessibilityIdentifier(
            "inspector.websocket.payload.representation"
        )
        payloadModeSelector.setAccessibilityLabel("Payload representation")
        payloadModeSelector.setAccessibilityHelp(
            "Auto and Protobuf inspect the complete reconstructed message. Hex shows the exact bytes of the selected frame."
        )
        payloadModeSelector.toolTip =
            "Auto/Protobuf: complete message; Hex: selected frame bytes"
        payloadModeSelector.setContentHuggingPriority(.required, for: .horizontal)
        payloadModeSelector.setContentCompressionResistancePriority(.required, for: .horizontal)

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
        payloadTextView.setAccessibilityIdentifier("inspector.websocket.payload")
        payloadTextView.setAccessibilityLabel("Selected WebSocket frame payload")

        payloadScrollView.translatesAutoresizingMaskIntoConstraints = false
        payloadScrollView.documentView = payloadTextView
        payloadScrollView.hasVerticalScroller = true
        payloadScrollView.hasHorizontalScroller = true
        payloadScrollView.autohidesScrollers = true
        payloadScrollView.borderType = .noBorder
    }

    private func makeFrameListView() -> NSView {
        directionSelector.translatesAutoresizingMaskIntoConstraints = false
        directionSelector.selectedSegment = 0
        directionSelector.target = self
        directionSelector.action = #selector(directionSelectionChanged(_:))
        directionSelector.setAccessibilityIdentifier("inspector.websocket.direction")
        directionSelector.setAccessibilityLabel("WebSocket frame direction")
        directionSelector.toolTip = "Show all, sent, or received frames"

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search frame payloads"
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.target = self
        searchField.action = #selector(searchTextChanged(_:))
        searchField.setAccessibilityIdentifier("inspector.websocket.search")
        searchField.setAccessibilityLabel("Search WebSocket frame payloads")
        searchField.toolTip = "Search frame metadata and bounded text payloads"
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        connectionStatusField.translatesAutoresizingMaskIntoConstraints = false
        connectionStatusField.font = .systemFont(ofSize: 10, weight: .semibold)
        connectionStatusField.alignment = .center
        connectionStatusField.setAccessibilityIdentifier("inspector.websocket.connectionStatus")
        connectionStatusField.setAccessibilityLabel("WebSocket connection status")
        connectionStatusField.setContentHuggingPriority(.required, for: .horizontal)
        connectionStatusField.setContentCompressionResistancePriority(.required, for: .horizontal)

        composeButton.translatesAutoresizingMaskIntoConstraints = false
        composeButton.bezelStyle = .rounded
        composeButton.target = self
        composeButton.action = #selector(composeFrame(_:))
        composeButton.setAccessibilityIdentifier("inspector.websocket.compose")
        composeButton.setAccessibilityLabel("Compose WebSocket frame")
        composeButton.setContentHuggingPriority(.required, for: .horizontal)

        disconnectButton.translatesAutoresizingMaskIntoConstraints = false
        disconnectButton.bezelStyle = .rounded
        disconnectButton.target = self
        disconnectButton.action = #selector(disconnectConnection(_:))
        disconnectButton.setAccessibilityIdentifier("inspector.websocket.disconnect")
        disconnectButton.setAccessibilityLabel("Disconnect WebSocket")
        disconnectButton.setContentHuggingPriority(.required, for: .horizontal)

        exportButton.translatesAutoresizingMaskIntoConstraints = false
        exportButton.bezelStyle = .rounded
        exportButton.target = self
        exportButton.action = #selector(exportFrames(_:))
        exportButton.setAccessibilityIdentifier("inspector.websocket.export")
        exportButton.setAccessibilityLabel("Export all WebSocket frames")
        exportButton.toolTip = "Export the complete frame history as ProxyLens JSON"

        let controls = NSStackView(views: [
            directionSelector,
            searchField,
            connectionStatusField,
            composeButton,
            disconnectButton,
            exportButton
        ])
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 6

        statusField.translatesAutoresizingMaskIntoConstraints = false
        statusField.font = .systemFont(ofSize: 10, weight: .regular)
        statusField.textColor = .secondaryLabelColor
        statusField.lineBreakMode = .byTruncatingTail
        statusField.setAccessibilityIdentifier("inspector.websocket.status")
        statusField.setAccessibilityLabel("WebSocket inspector status")

        let container = NSView()
        container.addSubview(controls)
        container.addSubview(statusField)
        container.addSubview(tableScrollView)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            controls.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            controls.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
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

    @objc private func directionSelectionChanged(_ sender: NSSegmentedControl) {
        guard !isRendering,
            TrafficWebSocketDirectionFilter.allCases.indices.contains(sender.selectedSegment)
        else {
            return
        }
        onDirectionFilterChange?(
            TrafficWebSocketDirectionFilter.allCases[sender.selectedSegment]
        )
    }

    @objc private func searchTextChanged(_ sender: NSSearchField) {
        guard !isRendering else {
            return
        }
        onSearchTextChange?(sender.stringValue)
    }

    @objc private func exportFrames(_ sender: NSButton) {
        onExport?()
    }

    @objc private func composeFrame(_ sender: NSButton) {
        if reconnectsOnPrimaryAction {
            onReconnect?()
        } else {
            onCompose?()
        }
    }

    @objc private func disconnectConnection(_ sender: NSButton) {
        onDisconnect?()
    }

    private func makePayloadView() -> NSView {
        payloadMetadataField.translatesAutoresizingMaskIntoConstraints = false
        payloadModeSelector.translatesAutoresizingMaskIntoConstraints = false
        let header = NSStackView(views: [payloadMetadataField, payloadModeSelector])
        header.translatesAutoresizingMaskIntoConstraints = false
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        let container = NSView()
        container.addSubview(header)
        container.addSubview(payloadScrollView)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -10),
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            payloadScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            payloadScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            payloadScrollView.topAnchor.constraint(
                equalTo: header.bottomAnchor, constant: 5),
            payloadScrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    @objc private func payloadModeChanged(_ sender: NSSegmentedControl) {
        guard !isRendering,
            TrafficWebSocketPayloadMode.allCases.indices.contains(sender.selectedSegment)
        else {
            return
        }
        onPayloadModeChange?(TrafficWebSocketPayloadMode.allCases[sender.selectedSegment])
    }

    private func renderPayload(
        _ presentation: TrafficBodyPresentation,
        syntax: TrafficWebSocketPayloadSyntax
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
            value = "Loading payload…"
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
        let language: InspectorSyntaxHighlighter.Language =
            switch syntax {
            case .json: .json
            case .protobuf: .protobuf
            case .plainText, .binary: .plainText
            }
        let attributed = NSMutableAttributedString(
            attributedString: InspectorSyntaxHighlighter.highlight(value, as: language)
        )
        if (syntax != .json && syntax != .protobuf) || color != .textColor {
            attributed.addAttribute(
                .foregroundColor,
                value: color,
                range: NSRange(location: 0, length: attributed.length)
            )
        }
        payloadTextView.textStorage?.setAttributedString(attributed)
        payloadTextView.scrollToBeginningOfDocument(nil)
    }

    private static func frameCountDescription(_ count: Int) -> String {
        count == 1 ? "1 captured WebSocket frame" : "\(count) captured WebSocket frames"
    }

    private static func opcodeLabel(_ opcode: WebSocketFrameOpcode) -> String {
        switch opcode {
        case .continuation: "Continuation"
        case .text: "Text"
        case .binary: "Binary"
        case .close: "Close"
        case .ping: "Ping"
        case .pong: "Pong"
        case .unknown(let value): String(format: "Unknown 0x%02X", value)
        }
    }

    private static func segmentIndex(for filter: TrafficWebSocketDirectionFilter) -> Int {
        TrafficWebSocketDirectionFilter.allCases.firstIndex(of: filter) ?? 0
    }

    private static func payloadModeSegmentIndex(
        for mode: TrafficWebSocketPayloadMode
    ) -> Int {
        TrafficWebSocketPayloadMode.allCases.firstIndex(of: mode) ?? 0
    }

    private func value(for frame: TrafficWebSocketFrameInspection, column: Column) -> String {
        switch column {
        case .sequence:
            String(frame.sequenceNumber)
        case .direction:
            frame.directionLabel
        case .opcode:
            frame.opcodeLabel
        case .flags:
            [frame.isFinal ? "FIN" : "Fragment", frame.wasMasked ? "Masked" : nil]
                .compactMap { $0 }
                .joined(separator: " · ")
        case .time:
            timeFormatter.string(from: frame.receivedAt)
        case .size:
            ByteCountFormatter.string(fromByteCount: frame.byteCount, countStyle: .file)
        }
    }
}

extension WebSocketFramesViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        frames.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard row >= 0, row < frames.count,
            let tableColumn,
            let column = Column(rawValue: tableColumn.identifier.rawValue)
        else {
            return nil
        }

        let identifier = NSUserInterfaceItemIdentifier("websocket.cell.\(column.rawValue)")
        let cell =
            tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeCell(identifier: identifier)
        let text = value(for: frames[row], column: column)
        cell.textField?.stringValue = text
        cell.textField?.toolTip = text
        cell.textField?.textColor =
            column == .direction
            ? Self.directionColor(frames[row].direction)
            : .labelColor
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRendering,
            tableView.selectedRow >= 0,
            tableView.selectedRow < frames.count
        else {
            return
        }
        onFrameSelection?(frames[tableView.selectedRow].id)
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

    private static func directionColor(_ direction: WebSocketFrameDirection) -> NSColor {
        switch direction {
        case .clientToServer: .systemBlue
        case .serverToClient: .systemGreen
        }
    }
}
