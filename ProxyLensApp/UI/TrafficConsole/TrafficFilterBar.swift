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
            annotationPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 112)
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
