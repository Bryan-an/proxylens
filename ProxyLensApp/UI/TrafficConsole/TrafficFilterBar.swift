import AppKit

@MainActor
final class TrafficFilterBar: NSView, NSSearchFieldDelegate {
    private let viewModel: TrafficConsoleViewModel
    private let searchField = NSSearchField()
    private let methodPopup = NSPopUpButton()
    private let statusPopup = NSPopUpButton()
    private let contentTypePopup = NSPopUpButton()
    private let originPopup = NSPopUpButton()
    private let annotationPopup = NSPopUpButton()
    private let customFilterPopup = NSPopUpButton()
    private let countField = NSTextField(labelWithString: "0 flows")
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private var isEditingSearch = false

    init(viewModel: TrafficConsoleViewModel) {
        self.viewModel = viewModel
        super.init(frame: .zero)
        configureControls()
        configureLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(_ snapshot: TrafficConsoleSnapshot) {
        let filter = snapshot.displayFilter
        if !isEditingSearch, searchField.stringValue != filter.searchText {
            searchField.stringValue = filter.searchText
        }
        select(filter.method, in: methodPopup, cases: TrafficMethodFilter.allCases)
        select(filter.status, in: statusPopup, cases: TrafficStatusFilter.allCases)
        select(filter.contentType, in: contentTypePopup, cases: TrafficContentTypeFilter.allCases)
        select(filter.origin, in: originPopup, cases: TrafficOriginFilter.allCases)
        select(filter.annotation, in: annotationPopup, cases: TrafficAnnotationFilter.allCases)
        rebuildCustomFilterMenu(filter: filter)

        let visibleCount = snapshot.visibleRows.count
        countField.stringValue =
            visibleCount == snapshot.allFlowCount
            ? Self.flowCountText(visibleCount)
            : "\(visibleCount) of \(Self.flowCountText(snapshot.allFlowCount))"
        clearButton.isEnabled = filter.isActive || snapshot.selectedSource != .allTraffic
    }

    private func configureControls() {
        searchField.placeholderString = "Search URL, headers, metadata"
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = true
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(commitSearch)
        searchField.setAccessibilityIdentifier("traffic.search")
        searchField.setAccessibilityLabel("Search traffic")

        configure(
            methodPopup,
            titles: TrafficMethodFilter.allCases.map(\.title),
            accessibilityIdentifier: "traffic.filter.method",
            accessibilityLabel: "Filter by HTTP method",
            action: #selector(methodChanged)
        )
        configure(
            statusPopup,
            titles: TrafficStatusFilter.allCases.map(\.title),
            accessibilityIdentifier: "traffic.filter.status",
            accessibilityLabel: "Filter by response status",
            action: #selector(statusChanged)
        )
        configure(
            contentTypePopup,
            titles: TrafficContentTypeFilter.allCases.map(\.title),
            accessibilityIdentifier: "traffic.filter.contentType",
            accessibilityLabel: "Filter by content type",
            action: #selector(contentTypeChanged)
        )
        configure(
            originPopup,
            titles: TrafficOriginFilter.allCases.map(\.title),
            accessibilityIdentifier: "traffic.filter.source",
            accessibilityLabel: "Filter by traffic source",
            action: #selector(originChanged)
        )
        configure(
            annotationPopup,
            titles: TrafficAnnotationFilter.allCases.map(\.title),
            accessibilityIdentifier: "traffic.filter.annotation",
            accessibilityLabel: "Filter by comment or highlight",
            action: #selector(annotationChanged)
        )

        customFilterPopup.setAccessibilityIdentifier("traffic.filter.custom")
        customFilterPopup.setAccessibilityLabel("Custom traffic filters")
        customFilterPopup.toolTip = "Custom Filters"
        customFilterPopup.cell?.lineBreakMode = .byTruncatingTail

        countField.textColor = .secondaryLabelColor
        countField.alignment = .right
        countField.setContentHuggingPriority(.required, for: .horizontal)
        countField.setAccessibilityIdentifier("traffic.filter.count")

        clearButton.bezelStyle = .inline
        clearButton.target = self
        clearButton.action = #selector(clearFilters)
        clearButton.setAccessibilityIdentifier("traffic.filter.clear")
        clearButton.setAccessibilityLabel("Clear traffic filters")
    }

    private func configureLayout() {
        translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [
            searchField,
            methodPopup,
            statusPopup,
            contentTypePopup,
            originPopup,
            annotationPopup,
            customFilterPopup,
            NSView(),
            countField,
            clearButton
        ])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.setCustomSpacing(12, after: searchField)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            methodPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 106),
            statusPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 112),
            contentTypePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 104),
            originPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 108),
            annotationPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 112),
            customFilterPopup.widthAnchor.constraint(equalToConstant: 104)
        ])
    }

    private func configure(
        _ popup: NSPopUpButton,
        titles: [String],
        accessibilityIdentifier: String,
        accessibilityLabel: String,
        action: Selector
    ) {
        popup.addItems(withTitles: titles)
        popup.target = self
        popup.action = action
        popup.setAccessibilityIdentifier(accessibilityIdentifier)
        popup.setAccessibilityLabel(accessibilityLabel)
    }

    private func select<Value: Equatable>(_ value: Value, in popup: NSPopUpButton, cases: [Value]) {
        guard let index = cases.firstIndex(of: value), popup.indexOfSelectedItem != index else {
            return
        }
        popup.selectItem(at: index)
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        isEditingSearch = true
    }
    func controlTextDidChange(_ notification: Notification) {
        scheduleSearch()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(commitSearch),
            object: nil
        )
        commitSearch()
        isEditingSearch = false
    }

    private func scheduleSearch() {
        isEditingSearch = true
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(commitSearch),
            object: nil
        )
        perform(#selector(commitSearch), with: nil, afterDelay: 0.15)
    }

    @objc private func commitSearch() {
        viewModel.setSearchText(searchField.stringValue)
    }

    @objc private func methodChanged() {
        guard TrafficMethodFilter.allCases.indices.contains(methodPopup.indexOfSelectedItem) else {
            return
        }
        viewModel.setMethodFilter(TrafficMethodFilter.allCases[methodPopup.indexOfSelectedItem])
    }

    @objc private func statusChanged() {
        guard TrafficStatusFilter.allCases.indices.contains(statusPopup.indexOfSelectedItem) else {
            return
        }
        viewModel.setStatusFilter(TrafficStatusFilter.allCases[statusPopup.indexOfSelectedItem])
    }

    @objc private func contentTypeChanged() {
        guard
            TrafficContentTypeFilter.allCases.indices.contains(contentTypePopup.indexOfSelectedItem)
        else {
            return
        }
        viewModel.setContentTypeFilter(
            TrafficContentTypeFilter.allCases[contentTypePopup.indexOfSelectedItem]
        )
    }

    @objc private func originChanged() {
        guard TrafficOriginFilter.allCases.indices.contains(originPopup.indexOfSelectedItem) else {
            return
        }
        viewModel.setOriginFilter(TrafficOriginFilter.allCases[originPopup.indexOfSelectedItem])
    }

    @objc private func annotationChanged() {
        guard
            TrafficAnnotationFilter.allCases.indices.contains(
                annotationPopup.indexOfSelectedItem
            )
        else {
            return
        }
        viewModel.setAnnotationFilter(
            TrafficAnnotationFilter.allCases[annotationPopup.indexOfSelectedItem]
        )
    }

    @objc private func clearFilters() {
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(commitSearch),
            object: nil
        )
        isEditingSearch = false
        searchField.stringValue = ""
        viewModel.clearDisplayFilters()
    }

    private func rebuildCustomFilterMenu(filter: TrafficDisplayFilter) {
        customFilterPopup.removeAllItems()
        guard let menu = customFilterPopup.menu else {
            return
        }
        let presets = viewModel.customFilterPresets
        let matchingPreset = presets.first { $0.filter == filter }
        let heading = NSMenuItem(
            title: matchingPreset?.name ?? "Custom Filters",
            action: nil,
            keyEquivalent: ""
        )
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())

        if presets.isEmpty {
            let emptyItem = NSMenuItem(title: "No Saved Filters", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for preset in presets {
                let item = NSMenuItem(
                    title: preset.name,
                    action: #selector(applyCustomFilterPreset(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = preset.id.uuidString
                item.state = preset.id == matchingPreset?.id ? .on : .off
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let saveItem = NSMenuItem(
            title: "Save Current Filter…",
            action: #selector(saveCurrentFilterPreset),
            keyEquivalent: ""
        )
        saveItem.target = self
        menu.addItem(saveItem)

        if let matchingPreset {
            let renameItem = NSMenuItem(
                title: "Rename \(matchingPreset.name)…",
                action: #selector(renameCurrentFilterPreset(_:)),
                keyEquivalent: ""
            )
            renameItem.target = self
            renameItem.representedObject = matchingPreset.id.uuidString
            menu.addItem(renameItem)

            let deleteItem = NSMenuItem(
                title: "Delete \(matchingPreset.name)",
                action: #selector(deleteCurrentFilterPreset(_:)),
                keyEquivalent: ""
            )
            deleteItem.target = self
            deleteItem.representedObject = matchingPreset.id.uuidString
            menu.addItem(deleteItem)
        }
        customFilterPopup.selectItem(at: 0)
    }

    @objc private func applyCustomFilterPreset(_ sender: NSMenuItem) {
        guard let id = presetID(from: sender) else {
            return
        }
        do {
            try viewModel.applyCustomFilterPreset(id: id)
        } catch {
            showPresetError(error)
        }
    }

    @objc private func saveCurrentFilterPreset() {
        presentNameDialog(
            title: "Save Custom Filter",
            informativeText:
                "Save the complete search and filter combination. A filter with the same name will be updated.",
            actionTitle: "Save",
            initialValue: viewModel.matchingCustomFilterPreset?.name ?? "",
            accessibilityIdentifier: "traffic.filter.customName"
        ) { [weak self] name in
            guard let self else { return }
            do {
                _ = try viewModel.saveCustomFilterPreset(named: name)
            } catch {
                showPresetError(error)
            }
        }
    }

    @objc private func renameCurrentFilterPreset(_ sender: NSMenuItem) {
        guard let id = presetID(from: sender),
            let preset = viewModel.customFilterPresets.first(where: { $0.id == id })
        else {
            return
        }
        presentNameDialog(
            title: "Rename Custom Filter",
            informativeText: "Choose a unique name for this saved filter.",
            actionTitle: "Rename",
            initialValue: preset.name,
            accessibilityIdentifier: "traffic.filter.customRename"
        ) { [weak self] name in
            guard let self else { return }
            do {
                _ = try viewModel.renameCustomFilterPreset(id: id, name: name)
            } catch {
                showPresetError(error)
            }
        }
    }

    @objc private func deleteCurrentFilterPreset(_ sender: NSMenuItem) {
        guard let id = presetID(from: sender),
            let preset = viewModel.customFilterPresets.first(where: { $0.id == id })
        else {
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete \(preset.name)?"
        alert.informativeText = "This removes only the saved filter. Captured traffic is unchanged."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.viewModel.removeCustomFilterPreset(id: id)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    private func presentNameDialog(
        title: String,
        informativeText: String,
        actionTitle: String,
        initialValue: String,
        accessibilityIdentifier: String,
        completion: @escaping (String) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = informativeText
        alert.addButton(withTitle: actionTitle)
        alert.addButton(withTitle: "Cancel")
        let nameField = NSTextField(string: initialValue)
        nameField.placeholderString = "Filter name"
        nameField.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        nameField.setAccessibilityIdentifier(accessibilityIdentifier)
        nameField.setAccessibilityLabel("Custom filter name")
        alert.accessoryView = nameField
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            completion(nameField.stringValue)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    private func presetID(from item: NSMenuItem) -> UUID? {
        (item.representedObject as? String).flatMap(UUID.init(uuidString:))
    }

    private func showPresetError(_ error: any Error) {
        let alert = NSAlert(error: error)
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private static func flowCountText(_ count: Int) -> String {
        "\(count) \(count == 1 ? "flow" : "flows")"
    }
}

extension TrafficMethodFilter {
    fileprivate var title: String {
        switch self {
        case .all: "All Methods"
        case .get: "GET"
        case .post: "POST"
        case .put: "PUT"
        case .patch: "PATCH"
        case .delete: "DELETE"
        case .head: "HEAD"
        case .options: "OPTIONS"
        case .connect: "CONNECT"
        case .other: "Other Method"
        }
    }
}

extension TrafficStatusFilter {
    fileprivate var title: String {
        switch self {
        case .all: "All Statuses"
        case .informational: "1xx Informational"
        case .success: "2xx Success"
        case .redirection: "3xx Redirect"
        case .clientError: "4xx Client Error"
        case .serverError: "5xx Server Error"
        case .pending: "Pending"
        }
    }
}

extension TrafficContentTypeFilter {
    fileprivate var title: String {
        switch self {
        case .all: "All Types"
        case .graphql: "GraphQL"
        case .json: "JSON"
        case .html: "HTML"
        case .xml: "XML"
        case .text: "Text"
        case .image: "Image"
        case .media: "Audio/Video"
        case .binary: "Binary"
        case .other: "Other Type"
        }
    }
}

extension TrafficOriginFilter {
    fileprivate var title: String {
        switch self {
        case .all: "All Sources"
        case .desktopProxy: "Desktop Proxy"
        case .socks5Proxy: "SOCKS5 Proxy"
        case .reverseProxy: "Reverse Proxy"
        case .importedSession: "Imported"
        case .replay: "Replay"
        }
    }
}

extension TrafficAnnotationFilter {
    fileprivate var title: String {
        switch self {
        case .all: "All Marks"
        case .commented: "Comments"
        case .highlighted: "Highlighted"
        case .struckThrough: "Struck Through"
        case .red: "Red"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .purple: "Purple"
        case .gray: "Gray"
        }
    }
}
