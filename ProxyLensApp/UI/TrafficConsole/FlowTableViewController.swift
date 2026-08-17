import AppKit
import ProxyLensApplication
import ProxyLensCore
import UniformTypeIdentifiers

@MainActor
final class FlowTableViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSMenuDelegate
{
    private let viewModel: TrafficConsoleViewModel
    private let tableView: NSTableView
    private let networkConditionProfileStore: any TrafficNetworkConditionProfileStoring
    private let emptyLabel = NSTextField(labelWithString: "No traffic captured yet")
    private var rows: [TrafficFlowRow] = []
    private var isRendering = false
    private lazy var annotationMenuController = FlowAnnotationMenuController(
        viewModel: viewModel,
        windowProvider: { [weak self] in self?.view.window }
    )

    init(
        viewModel: TrafficConsoleViewModel,
        tableView: NSTableView = NSTableView(),
        networkConditionProfileStore: any TrafficNetworkConditionProfileStoring =
            InMemoryTrafficNetworkConditionProfileStore()
    ) {
        self.viewModel = viewModel
        self.tableView = tableView
        self.networkConditionProfileStore = networkConditionProfileStore
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
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

        let rowIndexByFlowID = Dictionary(
            uniqueKeysWithValues: rows.indices.map { (rows[$0].id, $0) }
        )
        let selectedRowIndexes = IndexSet(
            snapshot.selectedFlowIDs.compactMap { rowIndexByFlowID[$0] }
        )
        if selectedRowIndexes.isEmpty {
            tableView.deselectAll(nil)
        } else {
            tableView.selectRowIndexes(selectedRowIndexes, byExtendingSelection: false)
            if let selectedFlowID = snapshot.selectedFlowID,
                let row = rows.firstIndex(where: { $0.id == selectedFlowID })
            {
                tableView.scrollRowToVisible(row)
            }
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

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("FlowTableRow")
        let rowView =
            (tableView.makeView(withIdentifier: identifier, owner: self)
                as? FlowAnnotationTableRowView)
            ?? FlowAnnotationTableRowView(identifier: identifier)
        rowView.render(rows.indices.contains(row) ? rows[row].annotation : nil)
        return rowView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRendering else {
            return
        }
        let selectedFlowIDs = tableView.selectedRowIndexes.compactMap { row in
            rows.indices.contains(row) ? rows[row].id : nil
        }
        let selectedRow = tableView.selectedRow
        let primaryFlowID = rows.indices.contains(selectedRow) ? rows[selectedRow].id : nil
        viewModel.selectFlows(selectedFlowIDs, primary: primaryFlowID)
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

        if !tableView.selectedRowIndexes.contains(rowIndex) {
            tableView.selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false)
        }

        let host = rows[rowIndex].host
        let path = Self.mappingPath(for: rows[rowIndex])
        let flowID = rows[rowIndex].id
        let selectedFlowIDs = tableView.selectedRowIndexes.compactMap { row in
            rows.indices.contains(row) ? rows[row].id : nil
        }
        annotationMenuController.appendItems(to: menu, for: rows[rowIndex])
        menu.addItem(.separator())
        menu.addItem(
            exportMenuItem(
                title: "Repeat Request",
                flowID: flowID,
                action: #selector(repeatRequest)
            )
        )
        menu.addItem(
            exportMenuItem(
                title: "Edit & Repeat…",
                flowID: flowID,
                action: #selector(editAndRepeat)
            )
        )
        let compareItem = exportMenuItem(
            title: "Compare Selected Flows…",
            flowIDs: selectedFlowIDs,
            action: #selector(compareSelectedFlows)
        )
        compareItem.isEnabled = selectedFlowIDs.count == 2
        menu.addItem(compareItem)
        menu.addItem(.separator())
        menu.addItem(
            exportMenuItem(
                title: "Generate Request Code…",
                flowID: flowID,
                action: #selector(generateRequestCode)
            )
        )
        menu.addItem(copyMenuItem(for: rows[rowIndex]))
        menu.addItem(
            exportMenuItem(
                title: selectedFlowIDs.count == 1
                    ? "Export HAR…" : "Export \(selectedFlowIDs.count) Flows as HAR…",
                flowIDs: selectedFlowIDs,
                action: #selector(exportHAR)
            )
        )
        menu.addItem(
            exportMenuItem(
                title: selectedFlowIDs.count == 1
                    ? "Export OpenAPI…" : "Export \(selectedFlowIDs.count) Flows as OpenAPI…",
                flowIDs: selectedFlowIDs,
                action: #selector(exportOpenAPI)
            )
        )
        menu.addItem(.separator())
        menu.addItem(ruleMenuItem(title: "Block \(host)", host: host, action: #selector(blockHost)))
        if let operation = rows[rowIndex].graphqlOperationMetadata {
            let operationBlockItem = NSMenuItem(
                title: "Block GraphQL \(operation.kind.rawValue) \(operation.displayName)",
                action: #selector(blockGraphQLOperation),
                keyEquivalent: ""
            )
            operationBlockItem.target = self
            operationBlockItem.representedObject = operation
            menu.addItem(operationBlockItem)
        }
        menu.addItem(ruleMenuItem(title: "Allow \(host)", host: host, action: #selector(allowHost)))
        menu.addItem(
            ruleMenuItem(
                title: "Disable Caching for \(host)",
                host: host,
                action: #selector(disableCaching)
            )
        )
        menu.addItem(
            ruleMenuItem(
                title: "DNS Spoof \(host)…",
                host: host,
                action: #selector(dnsSpoof)
            )
        )
        let networkConditionsItem = NSMenuItem(
            title: "Network Conditions",
            action: nil,
            keyEquivalent: ""
        )
        let networkConditionsMenu = NSMenu(title: "Network Conditions")
        let noThrottlingItem = NSMenuItem(
            title: "No Throttling",
            action: #selector(applyNetworkCondition),
            keyEquivalent: ""
        )
        noThrottlingItem.target = self
        noThrottlingItem.representedObject = HostNetworkConditionMenuTarget(
            host: host,
            preset: nil
        )
        networkConditionsMenu.addItem(noThrottlingItem)
        networkConditionsMenu.addItem(.separator())
        for preset in NetworkConditionPreset.latencyPresets {
            let item = NSMenuItem(
                title: preset.title,
                action: #selector(applyNetworkCondition),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = HostNetworkConditionMenuTarget(
                host: host,
                preset: preset
            )
            networkConditionsMenu.addItem(item)
        }
        networkConditionsMenu.addItem(.separator())
        for preset in NetworkConditionPreset.bandwidthPresets {
            let item = NSMenuItem(
                title: preset.title,
                action: #selector(applyNetworkCondition),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = HostNetworkConditionMenuTarget(
                host: host,
                preset: preset
            )
            networkConditionsMenu.addItem(item)
        }
        let savedProfiles = networkConditionProfileStore.profiles
        if !savedProfiles.isEmpty {
            networkConditionsMenu.addItem(.separator())
            let savedProfilesItem = NSMenuItem(
                title: "Saved Profiles",
                action: nil,
                keyEquivalent: ""
            )
            let savedProfilesMenu = NSMenu(title: "Saved Profiles")
            for profile in savedProfiles {
                let item = NSMenuItem(
                    title: profile.name,
                    action: #selector(applyNetworkCondition),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = HostNetworkConditionMenuTarget(
                    host: host,
                    savedProfile: profile
                )
                savedProfilesMenu.addItem(item)
            }
            savedProfilesItem.submenu = savedProfilesMenu
            networkConditionsMenu.addItem(savedProfilesItem)
        }
        networkConditionsMenu.addItem(.separator())
        let customNetworkConditionItem = NSMenuItem(
            title: "Custom…",
            action: #selector(customNetworkCondition),
            keyEquivalent: ""
        )
        customNetworkConditionItem.target = self
        customNetworkConditionItem.representedObject = host
        networkConditionsMenu.addItem(customNetworkConditionItem)
        if !savedProfiles.isEmpty {
            let removeProfilesItem = NSMenuItem(
                title: "Remove Saved Profile",
                action: nil,
                keyEquivalent: ""
            )
            let removeProfilesMenu = NSMenu(title: "Remove Saved Profile")
            for profile in savedProfiles {
                let item = NSMenuItem(
                    title: profile.name,
                    action: #selector(removeNetworkConditionProfile),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = NetworkConditionProfileMenuTarget(id: profile.id)
                removeProfilesMenu.addItem(item)
            }
            removeProfilesItem.submenu = removeProfilesMenu
            networkConditionsMenu.addItem(removeProfilesItem)
        }
        networkConditionsItem.submenu = networkConditionsMenu
        menu.addItem(networkConditionsItem)
        menu.addItem(.separator())
        let mapLocalItem = NSMenuItem(
            title: "Map Local \(host)\(path)…",
            action: #selector(mapLocal),
            keyEquivalent: ""
        )
        mapLocalItem.target = self
        mapLocalItem.representedObject = HostPathMenuTarget(host: host, path: path)
        menu.addItem(mapLocalItem)
        if let operation = rows[rowIndex].graphqlOperationMetadata {
            let operationMapLocalItem = NSMenuItem(
                title: "Map Local GraphQL \(operation.kind.rawValue) \(operation.displayName)…",
                action: #selector(mapLocalGraphQLOperation),
                keyEquivalent: ""
            )
            operationMapLocalItem.target = self
            operationMapLocalItem.representedObject = operation
            menu.addItem(operationMapLocalItem)
        }
        let mapRemoteItem = NSMenuItem(
            title: "Map Remote \(host)\(path)…",
            action: #selector(mapRemote),
            keyEquivalent: ""
        )
        mapRemoteItem.target = self
        mapRemoteItem.representedObject = HostPathMenuTarget(host: host, path: path)
        menu.addItem(mapRemoteItem)
        let redirectItem = NSMenuItem(
            title: "Redirect \(host)\(path)…",
            action: #selector(redirect),
            keyEquivalent: ""
        )
        redirectItem.target = self
        redirectItem.representedObject = HostPathMenuTarget(host: host, path: path)
        menu.addItem(redirectItem)
        let replaceBodyItem = NSMenuItem(
            title: "Replace Request Body \(host)\(path)…",
            action: #selector(replaceBody),
            keyEquivalent: ""
        )
        replaceBodyItem.target = self
        replaceBodyItem.representedObject = HostPathMenuTarget(host: host, path: path)
        menu.addItem(replaceBodyItem)
        let replaceResponseBodyItem = NSMenuItem(
            title: "Replace Response Body \(host)\(path)…",
            action: #selector(replaceResponseBody),
            keyEquivalent: ""
        )
        replaceResponseBodyItem.target = self
        replaceResponseBodyItem.representedObject = HostPathMenuTarget(host: host, path: path)
        menu.addItem(replaceResponseBodyItem)
        if let operation = rows[rowIndex].graphqlOperationMetadata {
            let operationMapRemoteItem = NSMenuItem(
                title: "Map Remote GraphQL \(operation.kind.rawValue) \(operation.displayName)…",
                action: #selector(mapRemoteGraphQLOperation),
                keyEquivalent: ""
            )
            operationMapRemoteItem.target = self
            operationMapRemoteItem.representedObject = operation
            menu.addItem(operationMapRemoteItem)

            let operationReplaceBodyItem = NSMenuItem(
                title:
                    "Replace Request Body GraphQL \(operation.kind.rawValue) \(operation.displayName)…",
                action: #selector(replaceBodyGraphQLOperation),
                keyEquivalent: ""
            )
            operationReplaceBodyItem.target = self
            operationReplaceBodyItem.representedObject = operation
            menu.addItem(operationReplaceBodyItem)

            let operationReplaceResponseBodyItem = NSMenuItem(
                title:
                    "Replace Response Body GraphQL \(operation.kind.rawValue) \(operation.displayName)…",
                action: #selector(replaceResponseBodyGraphQLOperation),
                keyEquivalent: ""
            )
            operationReplaceResponseBodyItem.target = self
            operationReplaceResponseBodyItem.representedObject = operation
            menu.addItem(operationReplaceResponseBodyItem)
        }
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
        if rows[rowIndex].isWebSocket {
            let webSocketBreakpointItem = NSMenuItem(
                title: "Breakpoint WebSocket responses \(host)\(path)",
                action: #selector(breakpointWebSocketResponse),
                keyEquivalent: ""
            )
            webSocketBreakpointItem.target = self
            webSocketBreakpointItem.representedObject = HostPathMenuTarget(
                host: host,
                path: path
            )
            menu.addItem(webSocketBreakpointItem)
        }
        if let operation = rows[rowIndex].graphqlOperationMetadata {
            let operationBreakpointItem = NSMenuItem(
                title:
                    "Breakpoint GraphQL \(operation.kind.rawValue) \(operation.displayName)",
                action: #selector(breakpointGraphQLOperation),
                keyEquivalent: ""
            )
            operationBreakpointItem.target = self
            operationBreakpointItem.representedObject = operation
            menu.addItem(operationBreakpointItem)
        }
    }

    private func exportMenuItem(title: String, flowID: FlowID, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = flowID
        return item
    }

    private func exportMenuItem(title: String, flowIDs: [FlowID], action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = flowIDs
        return item
    }

    private func copyMenuItem(for row: TrafficFlowRow) -> NSMenuItem {
        let item = NSMenuItem(title: "Copy", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Copy")
        submenu.addItem(
            copyValueMenuItem(title: "URL", row: row, kind: .url, isEnabled: true)
        )
        submenu.addItem(
            copyValueMenuItem(
                title: "Request Headers",
                row: row,
                kind: .requestHeaders,
                isEnabled: true
            )
        )
        submenu.addItem(
            copyValueMenuItem(
                title: "Request Body",
                row: row,
                kind: .requestBody,
                isEnabled: row.hasRequestBody
            )
        )
        submenu.addItem(
            copyValueMenuItem(
                title: "Request Cookies",
                row: row,
                kind: .requestCookies,
                isEnabled: row.hasRequestCookies
            )
        )
        submenu.addItem(.separator())
        submenu.addItem(
            copyValueMenuItem(
                title: "Response Headers",
                row: row,
                kind: .responseHeaders,
                isEnabled: row.hasResponse
            )
        )
        submenu.addItem(
            copyValueMenuItem(
                title: "Response Body",
                row: row,
                kind: .responseBody,
                isEnabled: row.hasResponseBody
            )
        )
        submenu.addItem(
            copyValueMenuItem(
                title: "Response Cookies",
                row: row,
                kind: .responseCookies,
                isEnabled: row.hasResponseCookies
            )
        )
        submenu.addItem(.separator())
        submenu.addItem(
            exportMenuItem(title: "cURL", flowID: row.id, action: #selector(copyCURL))
        )
        item.submenu = submenu
        return item
    }

    private func copyValueMenuItem(
        title: String,
        row: TrafficFlowRow,
        kind: TrafficFlowCopyKind,
        isEnabled: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(copyFlowValue), keyEquivalent: "")
        item.target = self
        item.representedObject = FlowCopyMenuTarget(flowID: row.id, kind: kind)
        item.isEnabled = isEnabled
        return item
    }

    private func ruleMenuItem(title: String, host: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = host
        return item
    }

    @objc private func repeatRequest(_ sender: NSMenuItem) {
        guard let flowID = sender.representedObject as? FlowID else {
            return
        }

        Task { @MainActor in
            do {
                try await viewModel.repeatRequest(flowID: flowID)
            } catch {
                await presentError(error)
            }
        }
    }

    @objc private func editAndRepeat(_ sender: NSMenuItem) {
        guard let flowID = sender.representedObject as? FlowID else {
            return
        }

        Task { @MainActor in
            await presentRequestEditor(flowID: flowID)
        }
    }

    @objc private func compareSelectedFlows(_ sender: NSMenuItem) {
        guard let flowIDs = sender.representedObject as? [FlowID], flowIDs.count == 2 else {
            return
        }

        Task { @MainActor in
            do {
                let comparison = try await viewModel.comparison(flowIDs: flowIDs)
                presentAsSheet(FlowComparisonViewController(comparison: comparison))
            } catch {
                await presentError(error)
            }
        }
    }

    private func presentRequestEditor(flowID: FlowID) async {
        do {
            let draft = try await viewModel.requestEditDraft(flowID: flowID)
            let editor = RequestEditorViewController(draft: draft)
            addChild(editor)
            defer { editor.removeFromParent() }

            let alert = NSAlert()
            alert.messageText = "Edit & Repeat"
            alert.informativeText =
                "Edit the request line, headers, or text body before sending a new request."
            alert.addButton(withTitle: "Send Request")
            let cancelButton = alert.addButton(withTitle: "Cancel")
            cancelButton.keyEquivalent = "\u{1b}"
            alert.accessoryView = editor.view
            alert.window.initialFirstResponder = editor.initialFirstResponder

            let response: NSApplication.ModalResponse
            if let window = view.window {
                response = await alert.beginSheetModal(for: window)
            } else {
                response = alert.runModal()
            }
            guard response == .alertFirstButtonReturn else {
                return
            }

            try await viewModel.editAndRepeat(
                flowID: flowID,
                headersText: editor.headersText,
                bodyText: editor.changedBodyText
            )
        } catch {
            await presentError(error)
        }
    }

    @objc private func copyCURL(_ sender: NSMenuItem) {
        guard let flowID = sender.representedObject as? FlowID else {
            return
        }

        Task { @MainActor in
            do {
                let command = try await viewModel.curlCommand(for: flowID)
                copyToPasteboard(command)
            } catch {
                await presentError(error)
            }
        }
    }

    @objc private func copyFlowValue(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? FlowCopyMenuTarget else {
            return
        }

        Task { @MainActor in
            do {
                let value = try await viewModel.copyText(
                    for: target.flowID,
                    kind: target.kind
                )
                copyToPasteboard(value)
            } catch {
                await presentError(error)
            }
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @objc private func generateRequestCode(_ sender: NSMenuItem) {
        guard let flowID = sender.representedObject as? FlowID else {
            return
        }

        Task { @MainActor in
            do {
                let snippets = try await viewModel.requestCodeSnippets(for: flowID)
                presentAsSheet(RequestCodeViewController(snippets: snippets))
            } catch {
                await presentError(error)
            }
        }
    }

    @objc private func exportHAR(_ sender: NSMenuItem) {
        guard let flowIDs = sender.representedObject as? [FlowID], !flowIDs.isEmpty else {
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.title = "Export HAR"
        panel.nameFieldStringValue = flowIDs.count == 1 ? "flow.har" : "selected-flows.har"
        panel.message =
            flowIDs.count == 1
            ? "Export the selected flow as HAR 1.2."
            : "Export \(flowIDs.count) selected flows as one HAR 1.2 file."
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
                    try await self.viewModel.writeHAR(flowIDs: flowIDs, to: url)
                } catch {
                    await self.presentError(error)
                }
            }
        }
    }

    @objc private func exportOpenAPI(_ sender: NSMenuItem) {
        guard let flowIDs = sender.representedObject as? [FlowID], !flowIDs.isEmpty else {
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.title = "Export OpenAPI"
        panel.nameFieldStringValue =
            flowIDs.count == 1
            ? "flow.openapi.yaml"
            : "selected-flows.openapi.yaml"
        panel.message =
            flowIDs.count == 1
            ? "Export the selected flow as an OpenAPI 3.0 YAML document."
            : "Export \(flowIDs.count) selected flows as one OpenAPI 3.0 YAML document."
        panel.allowedContentTypes = [
            UTType(filenameExtension: "yaml") ?? .plainText,
            UTType(filenameExtension: "yml") ?? .plainText
        ]
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url, let self else {
                return
            }
            Task { @MainActor in
                do {
                    try await self.viewModel.writeOpenAPI(flowIDs: flowIDs, to: url)
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

    @objc private func dnsSpoof(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? String else {
            return
        }
        Task { @MainActor in
            await promptDNSSpoof(host: host)
        }
    }

    @objc private func applyNetworkCondition(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? HostNetworkConditionMenuTarget else {
            return
        }
        Task { @MainActor in
            do {
                if let preset = target.preset {
                    try await viewModel.throttle(
                        host: target.host,
                        profile: preset.profile,
                        label: preset.title
                    )
                } else if let savedProfile = target.savedProfile {
                    try await viewModel.throttle(
                        host: target.host,
                        profile: savedProfile.profile,
                        label: savedProfile.name
                    )
                } else {
                    await viewModel.clearThrottle(forHost: target.host)
                }
            } catch {
                await presentError(error)
            }
        }
    }

    @objc private func customNetworkCondition(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? String else {
            return
        }
        Task { @MainActor in
            await promptCustomNetworkCondition(host: host)
        }
    }

    @objc private func removeNetworkConditionProfile(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? NetworkConditionProfileMenuTarget else {
            return
        }
        networkConditionProfileStore.remove(id: target.id)
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

    @objc private func mapRemoteGraphQLOperation(_ sender: NSMenuItem) {
        guard let operation = sender.representedObject as? GraphQLOperationMetadata else {
            return
        }

        Task { @MainActor in
            await promptMapRemote(graphqlOperation: operation)
        }
    }

    @objc private func redirect(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? HostPathMenuTarget else {
            return
        }

        Task { @MainActor in
            await promptRedirect(target: target)
        }
    }

    @objc private func mapLocalGraphQLOperation(_ sender: NSMenuItem) {
        guard let operation = sender.representedObject as? GraphQLOperationMetadata else {
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Map Local GraphQL Operation"
        panel.message =
            "Choose a file to return for GraphQL \(operation.kind.rawValue) \(operation.displayName)"
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url, let self else {
                return
            }
            Task { @MainActor in
                do {
                    try await self.viewModel.mapLocal(
                        graphqlOperation: operation,
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

    @objc private func replaceBodyGraphQLOperation(_ sender: NSMenuItem) {
        guard let operation = sender.representedObject as? GraphQLOperationMetadata else {
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Replace GraphQL Request Body"
        panel.message =
            "Choose the body sent for GraphQL \(operation.kind.rawValue) \(operation.displayName)"
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url, let self else {
                return
            }
            Task { @MainActor in
                do {
                    try await self.viewModel.replaceRequestBody(
                        graphqlOperation: operation,
                        fileURL: url
                    )
                } catch {
                    await self.presentRuleError(error)
                }
            }
        }
    }

    @objc private func replaceBody(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? HostPathMenuTarget else {
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Replace Request Body"
        panel.message = "Choose the body sent for \(target.host)\(target.path)"
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url, let self else {
                return
            }
            Task { @MainActor in
                do {
                    try await self.viewModel.replaceRequestBody(
                        host: target.host,
                        path: target.path,
                        fileURL: url
                    )
                } catch {
                    await self.presentRuleError(error)
                }
            }
        }
    }

    @objc private func replaceResponseBodyGraphQLOperation(_ sender: NSMenuItem) {
        guard let operation = sender.representedObject as? GraphQLOperationMetadata else {
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Replace GraphQL Response Body"
        panel.message =
            "Choose the body returned for GraphQL \(operation.kind.rawValue) \(operation.displayName)"
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url, let self else {
                return
            }
            Task { @MainActor in
                do {
                    try await self.viewModel.replaceResponseBody(
                        graphqlOperation: operation,
                        fileURL: url
                    )
                } catch {
                    await self.presentRuleError(error)
                }
            }
        }
    }

    @objc private func replaceResponseBody(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? HostPathMenuTarget else {
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Replace Response Body"
        panel.message = "Choose the body returned for \(target.host)\(target.path)"
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url, let self else {
                return
            }
            Task { @MainActor in
                do {
                    try await self.viewModel.replaceResponseBody(
                        host: target.host,
                        path: target.path,
                        fileURL: url
                    )
                } catch {
                    await self.presentRuleError(error)
                }
            }
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

    @objc private func breakpointWebSocketResponse(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? HostPathMenuTarget else {
            return
        }
        viewModel.breakpoint(host: target.host, path: target.path, phase: .webSocketFrame)
    }

    @objc private func breakpointGraphQLOperation(_ sender: NSMenuItem) {
        guard let operation = sender.representedObject as? GraphQLOperationMetadata else {
            return
        }
        viewModel.breakpoint(graphqlOperation: operation)
    }

    @objc private func blockGraphQLOperation(_ sender: NSMenuItem) {
        guard let operation = sender.representedObject as? GraphQLOperationMetadata else {
            return
        }
        viewModel.block(graphqlOperation: operation)
    }

    private func promptMapRemote(target: HostPathMenuTarget) async {
        do {
            guard
                let destination = try await promptMapRemoteDestination(
                    label: "\(target.host)\(target.path)"
                )
            else {
                return
            }
            try await viewModel.mapRemote(
                host: target.host,
                path: target.path,
                destination: destination
            )
        } catch {
            await presentRuleError(error)
        }
    }

    private func promptMapRemote(graphqlOperation: GraphQLOperationMetadata) async {
        let label =
            "GraphQL \(graphqlOperation.kind.rawValue) \(graphqlOperation.displayName)"
        do {
            guard let destination = try await promptMapRemoteDestination(label: label) else {
                return
            }
            try await viewModel.mapRemote(
                graphqlOperation: graphqlOperation,
                destination: destination
            )
        } catch {
            await presentRuleError(error)
        }
    }

    private func promptRedirect(target: HostPathMenuTarget) async {
        let alert = NSAlert()
        alert.messageText = "Redirect"
        alert.informativeText =
            "Enter the absolute HTTP or HTTPS destination returned for \(target.host)\(target.path)."
        alert.addButton(withTitle: "Redirect")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "https://example.com/new-location"
        field.stringValue = "https://"
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
        guard let destination = URL(string: text) else {
            await presentRuleError(ProxyLensError.invalidURL(text))
            return
        }

        do {
            try await viewModel.redirect(
                host: target.host,
                path: target.path,
                destination: destination
            )
        } catch {
            await presentRuleError(error)
        }
    }

    private func promptCustomNetworkCondition(host: String) async {
        let alert = NSAlert()
        alert.messageText = "Custom Network Conditions"
        alert.informativeText =
            "Apply latency, request loss, and optional transfer limits to new requests for \(host). Leave a bandwidth field blank for unlimited."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")

        let latencyField = NSTextField(string: "200")
        latencyField.placeholderString = "0"
        latencyField.setAccessibilityIdentifier("networkConditions.latency")
        let downloadField = NSTextField(string: "512")
        downloadField.placeholderString = "Unlimited"
        downloadField.setAccessibilityIdentifier("networkConditions.download")
        let uploadField = NSTextField(string: "256")
        uploadField.placeholderString = "Unlimited"
        uploadField.setAccessibilityIdentifier("networkConditions.upload")
        let packetLossField = NSTextField(string: "0")
        packetLossField.placeholderString = "0"
        packetLossField.setAccessibilityIdentifier("networkConditions.packetLoss")
        let nameField = NSTextField(string: "")
        nameField.placeholderString = "Optional"
        nameField.setAccessibilityIdentifier("networkConditions.profileName")

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Latency (ms)"), latencyField],
            [NSTextField(labelWithString: "Download (KiB/s)"), downloadField],
            [NSTextField(labelWithString: "Upload (KiB/s)"), uploadField],
            [NSTextField(labelWithString: "Request loss (%)"), packetLossField],
            [NSTextField(labelWithString: "Save as profile"), nameField]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 180
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        alert.accessoryView = grid
        alert.window.initialFirstResponder = latencyField

        let response: NSApplication.ModalResponse
        if let window = view.window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else {
            return
        }

        do {
            let profile = try TrafficNetworkConditionDraft(
                latencyMilliseconds: latencyField.stringValue,
                downloadKibibytesPerSecond: downloadField.stringValue,
                uploadKibibytesPerSecond: uploadField.stringValue,
                packetLossPercentage: packetLossField.stringValue
            ).profile()
            let profileName = nameField.stringValue.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let savedProfile =
                try profileName.isEmpty
                ? nil
                : networkConditionProfileStore.save(name: profileName, profile: profile)
            try await viewModel.throttle(
                host: host,
                profile: profile,
                label: savedProfile?.name ?? "Custom"
            )
        } catch {
            await presentRuleError(error)
        }
    }

    private func promptMapRemoteDestination(label: String) async throws -> URL? {
        let alert = NSAlert()
        alert.messageText = "Map Remote"
        alert.informativeText =
            "Enter the destination URL for \(label). A host-only URL keeps the original path and query."
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
            return nil
        }

        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let destination = URL(string: text) else {
            throw ProxyLensError.invalidURL(text)
        }
        return destination
    }

    private func promptDNSSpoof(host: String) async {
        let alert = NSAlert()
        alert.messageText = "DNS Spoof"
        alert.informativeText =
            "Connect requests for \(host) to a numeric IPv4 or IPv6 address while preserving the original Host header and TLS identity."
        alert.addButton(withTitle: "Create Rule")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "127.0.0.1 or ::1"
        field.setAccessibilityIdentifier("dnsSpoof.address")
        field.setAccessibilityLabel("DNS spoof address")
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

        do {
            try await viewModel.dnsSpoof(host: host, address: field.stringValue)
        } catch {
            await presentRuleError(error)
        }
    }

    private func presentRuleError(_ error: Error) async {
        let errorAlert = NSAlert(error: error)
        if let window = view.window {
            await errorAlert.beginSheetModal(for: window)
        } else {
            errorAlert.runModal()
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

private final class FlowCopyMenuTarget: NSObject {
    let flowID: FlowID
    let kind: TrafficFlowCopyKind

    init(flowID: FlowID, kind: TrafficFlowCopyKind) {
        self.flowID = flowID
        self.kind = kind
    }
}

private final class HostNetworkConditionMenuTarget: NSObject {
    let host: String
    let preset: NetworkConditionPreset?
    let savedProfile: TrafficNetworkConditionProfile?

    init(host: String, preset: NetworkConditionPreset?) {
        self.host = host
        self.preset = preset
        self.savedProfile = nil
    }

    init(host: String, savedProfile: TrafficNetworkConditionProfile) {
        self.host = host
        self.preset = nil
        self.savedProfile = savedProfile
    }
}

private final class NetworkConditionProfileMenuTarget: NSObject {
    let id: UUID

    init(id: UUID) {
        self.id = id
    }
}

private enum NetworkConditionPreset: CaseIterable {
    case lostConnection
    case veryBadNetwork
    case milliseconds200
    case milliseconds500
    case second1
    case seconds2
    case slow3G
    case fast3G
    case wifi

    static let latencyPresets: [Self] = [
        .lostConnection, .veryBadNetwork,
        .milliseconds200, .milliseconds500, .second1, .seconds2
    ]

    static let bandwidthPresets: [Self] = [.slow3G, .fast3G, .wifi]

    var title: String {
        switch self {
        case .lostConnection: "Lost Connection"
        case .veryBadNetwork: "Very Bad Network"
        case .milliseconds200: "200 ms Latency"
        case .milliseconds500: "500 ms Latency"
        case .second1: "1 s Latency"
        case .seconds2: "2 s Latency"
        case .slow3G: "Slow 3G"
        case .fast3G: "Fast 3G"
        case .wifi: "Wi-Fi"
        }
    }

    var profile: ThrottleProfile {
        switch self {
        case .lostConnection:
            ThrottleProfile(packetLossPercentage: 100)
        case .veryBadNetwork:
            ThrottleProfile(
                latency: 1,
                downloadBytesPerSecond: 50_000,
                uploadBytesPerSecond: 20_000,
                packetLossPercentage: 20
            )
        case .milliseconds200: ThrottleProfile(latency: 0.2)
        case .milliseconds500: ThrottleProfile(latency: 0.5)
        case .second1: ThrottleProfile(latency: 1)
        case .seconds2: ThrottleProfile(latency: 2)
        case .slow3G:
            ThrottleProfile(
                latency: 0.4,
                downloadBytesPerSecond: 100_000,
                uploadBytesPerSecond: 50_000
            )
        case .fast3G:
            ThrottleProfile(
                latency: 0.15,
                downloadBytesPerSecond: 1_500_000,
                uploadBytesPerSecond: 750_000
            )
        case .wifi:
            ThrottleProfile(
                latency: 0.03,
                downloadBytesPerSecond: 10_000_000,
                uploadBytesPerSecond: 5_000_000
            )
        }
    }
}

private enum FlowColumn: String, CaseIterable {
    case method
    case host
    case path
    case graphqlOperation
    case status
    case startedAt
    case duration
    case size

    var title: String {
        switch self {
        case .method: "Method"
        case .host: "Host"
        case .path: "Path"
        case .graphqlOperation: "Query"
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
        case .graphqlOperation: 132
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
        case .graphqlOperation: 90
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
        case .graphqlOperation: .graphqlOperation
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
    let isStruckThrough: Bool
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
                toolTip: nil,
                isStruckThrough: flow.annotation?.isStruckThrough == true
            )
        case .host:
            return FlowCellPresentation(
                text: flow.usesTLS ? "🔒 \(flow.host)" : flow.host,
                textColor: .labelColor,
                font: regularFont,
                toolTip: annotationToolTip(flow),
                isStruckThrough: flow.annotation?.isStruckThrough == true
            )
        case .path:
            return FlowCellPresentation(
                text: annotationMarker(flow) + flow.path,
                textColor: .labelColor,
                font: regularFont,
                toolTip: annotationToolTip(flow),
                isStruckThrough: flow.annotation?.isStruckThrough == true
            )
        case .graphqlOperation:
            return FlowCellPresentation(
                text: flow.graphqlOperation ?? "",
                textColor: .secondaryLabelColor,
                font: regularFont,
                toolTip: flow.graphqlOperation,
                isStruckThrough: flow.annotation?.isStruckThrough == true
            )
        case .status:
            return FlowCellPresentation(
                text: statusText(flow),
                textColor: statusColor(flow),
                font: monospacedFont,
                toolTip: nil,
                isStruckThrough: flow.annotation?.isStruckThrough == true
            )
        case .startedAt:
            return FlowCellPresentation(
                text: timeFormatter.string(from: flow.startedAt),
                textColor: .secondaryLabelColor,
                font: monospacedFont,
                toolTip: nil,
                isStruckThrough: flow.annotation?.isStruckThrough == true
            )
        case .duration:
            return FlowCellPresentation(
                text: formattedDuration(flow.duration),
                textColor: .secondaryLabelColor,
                font: monospacedFont,
                toolTip: nil,
                isStruckThrough: flow.annotation?.isStruckThrough == true
            )
        case .size:
            return FlowCellPresentation(
                text: formattedByteCount(flow.byteCount),
                textColor: .secondaryLabelColor,
                font: monospacedFont,
                toolTip: nil,
                isStruckThrough: flow.annotation?.isStruckThrough == true
            )
        }
    }

    private static func annotationMarker(_ flow: TrafficFlowRow) -> String {
        guard let annotation = flow.annotation else {
            return ""
        }
        return switch (annotation.highlight, annotation.comment) {
        case (.some, .some): "● ✎ "
        case (.some, .none): "● "
        case (.none, .some): "✎ "
        case (.none, .none): ""
        }
    }

    private static func annotationToolTip(_ flow: TrafficFlowRow) -> String {
        guard let annotation = flow.annotation else {
            return flow.fullURL
        }
        var lines = [flow.fullURL]
        if let highlight = annotation.highlight {
            lines.append("\(highlight.menuTitle) highlight")
        }
        if annotation.isStruckThrough {
            lines.append("Struck through")
        }
        if let comment = annotation.comment {
            lines.append(comment)
        }
        return lines.joined(separator: "\n")
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
        label.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingMiddle
        var attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: presentation.textColor,
            .font: presentation.font,
            .paragraphStyle: paragraphStyle
        ]
        if presentation.isStruckThrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.strikethroughColor] = NSColor.secondaryLabelColor
        }
        label.attributedStringValue = NSAttributedString(
            string: presentation.text,
            attributes: attributes
        )
        label.toolTip = presentation.toolTip
    }
}
