import AppKit
import ProxyLensApplication
import ProxyLensCore
import UniformTypeIdentifiers

@MainActor
final class SourceListViewController: NSViewController, NSOutlineViewDataSource,
    NSOutlineViewDelegate, NSMenuDelegate
{
    private let viewModel: TrafficConsoleViewModel
    private let outlineView = NSOutlineView()
    private var roots: [SourceOutlineNode] = []
    private var pinnedDomainHosts: Set<String> = []
    private var isRendering = false
    /// Groups the user collapsed, by node id. Nodes are rebuilt on every render, so
    /// AppKit's own expansion state cannot survive; this is what restores it.
    private var collapsedNodeIDs: Set<String> = []
    /// What the outline currently shows, so an unchanged sidebar is not reloaded at all.
    private var renderedSignature: String?

    init(viewModel: TrafficConsoleViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        column.title = "Sources"
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .default
        outlineView.style = .sourceList
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.setAccessibilityIdentifier("traffic.sources")
        let menu = NSMenu(title: "Source List")
        menu.delegate = self
        outlineView.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        view = scrollView
    }

    func render(_ snapshot: TrafficConsoleSnapshot) {
        isRendering = true
        defer { isRendering = false }
        pinnedDomainHosts = Set(snapshot.pinnedDomains.map(\.host))

        let allTraffic = SourceOutlineNode(
            id: "all-traffic",
            title: "All Traffic",
            count: snapshot.allFlowCount,
            symbolName: "tray.full",
            selection: .allTraffic
        )
        let sessions = SourceOutlineNode(
            id: "sessions",
            title: "Sessions",
            count: snapshot.sessions.count,
            countSingular: "session",
            symbolName: "clock.arrow.circlepath",
            selection: nil,
            children: snapshot.sessions.map { session in
                let presentation = Self.presentation(for: session.state)
                return SourceOutlineNode(
                    id: "session:\(session.id)",
                    title: session.name
                        ?? Self.sessionDateFormatter.string(from: session.startedAt),
                    count: session.flowCount,
                    symbolName: presentation.symbolName,
                    symbolTintColor: presentation.tintColor,
                    statusDescription: presentation.statusDescription,
                    selection: .session(session.id),
                    sessionID: session.id,
                    sessionName: session.name,
                    sessionState: session.state
                )
            }
        )
        let applications = SourceOutlineNode(
            id: "applications",
            title: "Apps",
            count: snapshot.applications.count,
            countSingular: "application",
            symbolName: "square.grid.2x2",
            selection: nil,
            children: snapshot.applications.map {
                SourceOutlineNode(
                    id: "application:\($0.id)",
                    title: $0.name,
                    count: $0.flowCount,
                    symbolName: $0.name == "Unknown App" ? "questionmark.app" : "app",
                    bundlePath: $0.bundlePath,
                    selection: .application($0.id)
                )
            }
        )
        let domains = SourceOutlineNode(
            id: "domains",
            title: "Domains",
            count: snapshot.domains.count,
            countSingular: "domain",
            symbolName: "globe",
            selection: nil,
            children: snapshot.domains.map {
                SourceOutlineNode(
                    id: "domain:\($0.host)",
                    title: $0.host,
                    count: $0.flowCount,
                    symbolName: "network",
                    selection: .domain($0.host),
                    domainHost: $0.host
                )
            }
        )
        let pinned = SourceOutlineNode(
            id: "pinned-domains",
            title: "Pinned",
            count: snapshot.pinnedDomains.count,
            countSingular: "domain",
            symbolName: "pin.fill",
            selection: nil,
            children: snapshot.pinnedDomains.map {
                SourceOutlineNode(
                    id: "pinned-domain:\($0.host)",
                    title: $0.host,
                    count: $0.flowCount,
                    symbolName: "pin.fill",
                    selection: .domain($0.host),
                    domainHost: $0.host
                )
            }
        )
        let devices = SourceOutlineNode(
            id: "devices",
            title: "Devices",
            count: snapshot.remoteAccess.devices.count,
            countSingular: "device",
            symbolName: "iphone.gen3",
            selection: nil,
            children: snapshot.remoteAccess.devices.map {
                SourceOutlineNode(
                    id: "device:\($0.id)",
                    title: $0.displayName,
                    count: $0.flowCount,
                    symbolName: $0.isTrusted ? "checkmark.shield" : "iphone.gen3",
                    selection: .device($0.id)
                )
            }
        )
        var updatedRoots = [allTraffic]
        if !sessions.children.isEmpty {
            updatedRoots.append(sessions)
        }
        if !pinned.children.isEmpty {
            updatedRoots.append(pinned)
        }
        updatedRoots.append(contentsOf: [applications, domains])
        // Devices only appear once one has connected, so the sidebar stays as it was for a
        // desktop-only session.
        if !devices.children.isEmpty {
            updatedRoots.append(devices)
        }

        // Flow counts change on nearly every batch, so this only skips work while traffic is
        // idle; the state restored below is what makes the frequent reloads survivable.
        let signature = Self.signature(of: updatedRoots)
        if signature != renderedSignature {
            let scrollOrigin = enclosingScrollView?.contentView.bounds.origin
            roots = updatedRoots
            outlineView.reloadData()
            restoreExpansionState()
            if let scrollOrigin {
                restoreScrollOrigin(scrollOrigin)
            }
            renderedSignature = signature
        }

        let nodes = roots.flatMap { root in
            [root] + root.children
        }
        if let node = nodes.first(where: { $0.selection == snapshot.selectedSource }) {
            let row = outlineView.row(forItem: node)
            if row >= 0, outlineView.selectedRow != row {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
    }

    /// Re-expands every group except the ones the user collapsed. New groups start expanded,
    /// which is how the sidebar has always behaved.
    private func restoreExpansionState() {
        for root in roots where !root.children.isEmpty {
            if collapsedNodeIDs.contains(root.id) {
                outlineView.collapseItem(root)
            } else {
                outlineView.expandItem(root)
            }
        }
    }

    private func restoreScrollOrigin(_ origin: NSPoint) {
        guard let scrollView = enclosingScrollView, origin.y > 0 else {
            return
        }
        outlineView.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private var enclosingScrollView: NSScrollView? {
        view as? NSScrollView
    }

    private static func signature(of roots: [SourceOutlineNode]) -> String {
        var parts: [String] = []
        for root in roots {
            parts.append("\(root.id)#\(root.title)#\(root.count)")
            for child in root.children {
                parts.append("\(child.id)#\(child.title)#\(child.count)")
            }
        }
        return parts.joined(separator: "|")
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isRendering,
            let node = notification.userInfo?["NSObject"] as? SourceOutlineNode
        else {
            return
        }
        collapsedNodeIDs.remove(node.id)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isRendering,
            let node = notification.userInfo?["NSObject"] as? SourceOutlineNode
        else {
            return
        }
        collapsedNodeIDs.insert(node.id)
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        numberOfChildrenOfItem item: Any?
    ) -> Int {
        (item as? SourceOutlineNode)?.children.count ?? roots.count
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        child index: Int,
        ofItem item: Any?
    ) -> Any {
        (item as? SourceOutlineNode)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? SourceOutlineNode else {
            return false
        }
        return !node.children.isEmpty
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? SourceOutlineNode else {
            return nil
        }
        let identifier = NSUserInterfaceItemIdentifier("SourceCell")
        let cell =
            (outlineView.makeView(withIdentifier: identifier, owner: self) as? SourceCellView)
            ?? SourceCellView(identifier: identifier)
        cell.render(
            title: node.title,
            count: node.count,
            countSingular: node.countSingular,
            symbolName: node.symbolName,
            bundlePath: node.bundlePath,
            symbolTintColor: node.symbolTintColor,
            statusDescription: node.statusDescription
        )
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SourceOutlineNode)?.selection != nil
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isRendering,
            outlineView.selectedRow >= 0,
            let node = outlineView.item(atRow: outlineView.selectedRow) as? SourceOutlineNode,
            let selection = node.selection
        else {
            return
        }
        viewModel.selectSource(selection)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0,
            let node = outlineView.item(atRow: row) as? SourceOutlineNode
        else {
            return
        }

        if node.sessionID != nil {
            addSessionActions(for: node, to: menu)
            return
        }

        guard let host = node.domainHost else {
            return
        }

        let isPinned = pinnedDomainHosts.contains(host)
        let item = NSMenuItem(
            title: isPinned ? "Unpin Domain" : "Pin Domain",
            action: #selector(togglePinnedDomain(_:)),
            keyEquivalent: ""
        )
        item.image = NSImage(
            systemSymbolName: isPinned ? "pin.slash" : "pin",
            accessibilityDescription: nil
        )
        item.target = self
        item.representedObject = host
        menu.addItem(item)
    }

    @objc private func togglePinnedDomain(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? String else {
            return
        }
        viewModel.setPinnedDomain(host, isPinned: !pinnedDomainHosts.contains(host))
    }

    private func addSessionActions(for node: SourceOutlineNode, to menu: NSMenu) {
        let canModify = node.sessionState != .recording
        let exportPortable = NSMenuItem(
            title: "Export ProxyLens Session…",
            action: #selector(exportPortableSession(_:)),
            keyEquivalent: ""
        )
        exportPortable.image = NSImage(
            systemSymbolName: "shippingbox",
            accessibilityDescription: nil
        )
        exportPortable.target = self
        exportPortable.representedObject = node
        menu.addItem(exportPortable)

        let exportHAR = NSMenuItem(
            title: "Export Session as HAR…",
            action: #selector(exportSessionHAR(_:)),
            keyEquivalent: ""
        )
        exportHAR.image = NSImage(
            systemSymbolName: "square.and.arrow.up",
            accessibilityDescription: nil
        )
        exportHAR.target = self
        exportHAR.representedObject = node
        exportHAR.isEnabled = node.count > 0
        menu.addItem(exportHAR)
        menu.addItem(.separator())

        let rename = NSMenuItem(
            title: "Rename Session…",
            action: #selector(renameSession(_:)),
            keyEquivalent: ""
        )
        rename.image = NSImage(
            systemSymbolName: "pencil",
            accessibilityDescription: nil
        )
        rename.target = self
        rename.representedObject = node
        rename.isEnabled = canModify
        menu.addItem(rename)

        let delete = NSMenuItem(
            title: "Delete Session…",
            action: #selector(deleteSession(_:)),
            keyEquivalent: ""
        )
        delete.image = NSImage(
            systemSymbolName: "trash",
            accessibilityDescription: nil
        )
        delete.target = self
        delete.representedObject = node
        delete.isEnabled = canModify
        menu.addItem(delete)
    }

    @objc private func exportPortableSession(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SourceOutlineNode,
            let sessionID = node.sessionID
        else {
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.title = "Export ProxyLens Session"
        panel.message =
            "Preserve this session's raw bodies, metadata, timings, annotations, and rule traces."
        panel.prompt = "Export"
        panel.nameFieldStringValue = Self.portableFileName(for: node.title)
        panel.allowedContentTypes = [Self.portableSessionType]

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] result in
            guard result == .OK, let fileURL = panel.url, let self else {
                return
            }
            Task { @MainActor in
                do {
                    try await self.viewModel.writePortableSession(
                        sessionID: sessionID,
                        to: fileURL
                    )
                } catch {
                    self.present(error)
                }
            }
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    @objc private func exportSessionHAR(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SourceOutlineNode,
            let sessionID = node.sessionID
        else {
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.title = "Export Session as HAR"
        panel.message = "Export every captured flow in this session as one HAR 1.2 file."
        panel.prompt = "Export"
        panel.nameFieldStringValue = Self.harFileName(for: node.title)
        if let harType = UTType(filenameExtension: "har") {
            panel.allowedContentTypes = [harType]
        } else {
            panel.allowedContentTypes = [.json]
        }

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] result in
            guard result == .OK, let fileURL = panel.url, let self else {
                return
            }
            Task { @MainActor in
                do {
                    try await self.viewModel.writeHAR(sessionID: sessionID, to: fileURL)
                } catch {
                    self.present(error)
                }
            }
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    @objc private func renameSession(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SourceOutlineNode,
            let sessionID = node.sessionID
        else {
            return
        }

        let alert = NSAlert()
        alert.messageText = "Rename Session"
        alert.informativeText = "Use a short name that describes this capture."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let nameField = NSTextField(string: node.sessionName ?? "")
        nameField.placeholderString = "Session name"
        nameField.setAccessibilityLabel("Session name")
        nameField.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = nameField
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        Task {
            do {
                try await viewModel.renameSession(sessionID, to: nameField.stringValue)
            } catch {
                present(error)
            }
        }
    }

    @objc private func deleteSession(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SourceOutlineNode,
            let sessionID = node.sessionID
        else {
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(node.title)”?"
        alert.informativeText =
            "This removes the saved session and all of its captured flows from this Mac."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        Task {
            do {
                try await viewModel.deleteSession(sessionID)
            } catch {
                present(error)
            }
        }
    }

    private func present(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private static let sessionDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let portableSessionType = UTType(
        exportedAs: "com.proxylens.session",
        conformingTo: .package
    )

    private static func portableFileName(for sessionTitle: String) -> String {
        "\(sanitizedFileName(for: sessionTitle)).\(PortableSessionService.fileExtension)"
    }

    private static func harFileName(for sessionTitle: String) -> String {
        "\(sanitizedFileName(for: sessionTitle)).har"
    }

    private static func sanitizedFileName(for sessionTitle: String) -> String {
        let sanitized =
            sessionTitle
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "session" : sanitized
    }

    private static func presentation(for state: SessionState) -> SessionPresentation {
        switch state {
        case .recording:
            SessionPresentation(
                symbolName: "record.circle.fill",
                tintColor: .systemRed,
                statusDescription: "Recording"
            )
        case .stopped:
            SessionPresentation(
                symbolName: "clock",
                tintColor: .secondaryLabelColor,
                statusDescription: "Stopped"
            )
        case .interrupted:
            SessionPresentation(
                symbolName: "exclamationmark.triangle.fill",
                tintColor: .systemOrange,
                statusDescription: "Interrupted"
            )
        }
    }
}

private struct SessionPresentation {
    let symbolName: String
    let tintColor: NSColor
    let statusDescription: String
}

@MainActor
private final class SourceOutlineNode: NSObject {
    let id: String
    let title: String
    let count: Int
    let countSingular: String
    let symbolName: String
    let bundlePath: String?
    let symbolTintColor: NSColor?
    let statusDescription: String?
    let selection: TrafficSourceSelection?
    let domainHost: String?
    let sessionID: SessionID?
    let sessionName: String?
    let sessionState: SessionState?
    let children: [SourceOutlineNode]

    init(
        id: String,
        title: String,
        count: Int,
        countSingular: String = "flow",
        symbolName: String,
        bundlePath: String? = nil,
        symbolTintColor: NSColor? = nil,
        statusDescription: String? = nil,
        selection: TrafficSourceSelection?,
        domainHost: String? = nil,
        sessionID: SessionID? = nil,
        sessionName: String? = nil,
        sessionState: SessionState? = nil,
        children: [SourceOutlineNode] = []
    ) {
        self.id = id
        self.title = title
        self.count = count
        self.countSingular = countSingular
        self.symbolName = symbolName
        self.bundlePath = bundlePath
        self.symbolTintColor = symbolTintColor
        self.statusDescription = statusDescription
        self.selection = selection
        self.domainHost = domainHost
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.sessionState = sessionState
        self.children = children
    }
}

@MainActor
private final class SourceCellView: NSTableCellView {
    private let symbolView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let countField = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 13, weight: .regular)
        symbolView.contentTintColor = .secondaryLabelColor
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.lineBreakMode = .byTruncatingMiddle
        countField.translatesAutoresizingMaskIntoConstraints = false
        countField.textColor = .secondaryLabelColor
        countField.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize, weight: .regular)
        setAccessibilityElement(true)

        addSubview(symbolView)
        addSubview(titleField)
        addSubview(countField)
        NSLayoutConstraint.activate([
            symbolView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 16),
            symbolView.heightAnchor.constraint(equalToConstant: 16),
            titleField.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: 6),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            countField.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleField.trailingAnchor, constant: 6),
            countField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            countField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(
        title: String,
        count: Int,
        countSingular: String,
        symbolName: String,
        bundlePath: String?,
        symbolTintColor: NSColor?,
        statusDescription: String?
    ) {
        if let bundlePath {
            symbolView.image = NSWorkspace.shared.icon(forFile: bundlePath)
            symbolView.contentTintColor = nil
        } else {
            symbolView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            symbolView.contentTintColor = symbolTintColor ?? .secondaryLabelColor
        }
        symbolView.toolTip = statusDescription
        titleField.stringValue = title
        countField.stringValue = count.formatted()
        let countDescription = count == 1 ? countSingular : "\(countSingular)s"
        let status = statusDescription.map { ", \($0)" } ?? ""
        setAccessibilityLabel("\(title)\(status), \(count) \(countDescription)")
    }
}
