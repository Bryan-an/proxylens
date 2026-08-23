import AppKit
import ProxyLensCore

/// Manages the SSL Proxying List: which hosts have their TLS tunnel intercepted with the
/// local CA versus spliced through untouched. Unlike `ReverseProxyManagerViewController`,
/// this policy applies live while capture is running, so nothing here is disabled or
/// gated behind a "stop capture" lock message.
@MainActor
final class SSLProxyingManagerViewController: NSViewController, NSTableViewDataSource,
    NSTableViewDelegate
{
    var onClose: (() -> Void)?

    private let viewModel: TrafficConsoleViewModel
    private let tableView = NSTableView()
    private let entryField = NSTextField()
    private let modeControl = NSSegmentedControl(
        labels: ["Intercept all except", "Intercept only listed"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let addButton = NSButton()
    private let removeButton = NSButton()
    private let emptyState = NSTextField(labelWithString: "No hosts are excluded.")
    private let validationLabel = NSTextField(labelWithString: "")
    private var rows: [String] = []

    var numberOfEntries: Int { rows.count }

    init(viewModel: TrafficConsoleViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 620, height: 520)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        container.setAccessibilityIdentifier("sslProxyingManager")

        let title = NSTextField(labelWithString: "SSL Proxying List")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 18, weight: .semibold)

        let subtitle = NSTextField(
            wrappingLabelWithString:
                "Hosts listed here are tunneled without decryption. Use *.example.com to "
                + "match subdomains. This policy applies live — changes take effect on the "
                + "next connection, even while capture is running."
        )
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.textColor = .secondaryLabelColor

        modeControl.translatesAutoresizingMaskIntoConstraints = false
        modeControl.target = self
        modeControl.action = #selector(changeInterceptionMode)
        modeControl.setAccessibilityIdentifier("sslProxyingManager.mode")
        modeControl.setAccessibilityLabel("SSL proxying mode")

        entryField.translatesAutoresizingMaskIntoConstraints = false
        entryField.placeholderString = "pinned.example.com or *.example.com"
        entryField.setAccessibilityIdentifier("sslProxyingManager.entry")
        entryField.setAccessibilityLabel("Host pattern")

        validationLabel.translatesAutoresizingMaskIntoConstraints = false
        validationLabel.textColor = .systemRed
        validationLabel.isHidden = true
        validationLabel.lineBreakMode = .byWordWrapping
        validationLabel.maximumNumberOfLines = 2
        validationLabel.setAccessibilityIdentifier("sslProxyingManager.validation")

        configureTable()
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = tableView

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.textColor = .secondaryLabelColor
        emptyState.alignment = .center
        emptyState.setAccessibilityIdentifier("sslProxyingManager.empty")

        configureButton(
            addButton,
            title: "Add",
            action: #selector(addEntry),
            identifier: "sslProxyingManager.add"
        )
        configureButton(
            removeButton,
            title: "Remove",
            action: #selector(removeSelectedEntry),
            identifier: "sslProxyingManager.remove"
        )

        let closeButton = NSButton(title: "Close", target: self, action: #selector(close))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.setAccessibilityIdentifier("sslProxyingManager.close")

        // This sheet has hit the "chrome row absorbs the slack" layout bug pattern twice
        // elsewhere in this repo (see the inspector pane pitfalls). The scroll view is the
        // only view meant to grow: pin every chrome row's vertical size explicitly so the
        // solver never has a choice about which view yields when space is tight.
        for chromeRow in [title, subtitle, modeControl, entryField, addButton, validationLabel] {
            chromeRow.setContentHuggingPriority(.required, for: .vertical)
            chromeRow.setContentCompressionResistancePriority(.required, for: .vertical)
        }

        for subview in [
            title, subtitle, modeControl, entryField, addButton, validationLabel,
            scrollView, emptyState, removeButton, closeButton
        ] {
            container.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            modeControl.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            modeControl.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 12),
            entryField.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            entryField.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 12),
            entryField.trailingAnchor.constraint(
                equalTo: addButton.leadingAnchor, constant: -8),
            addButton.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            addButton.centerYAnchor.constraint(equalTo: entryField.centerYAnchor),
            validationLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            validationLabel.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            validationLabel.topAnchor.constraint(
                equalTo: entryField.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            scrollView.topAnchor.constraint(
                equalTo: validationLabel.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(
                equalTo: removeButton.topAnchor, constant: -14),
            emptyState.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            removeButton.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            removeButton.bottomAnchor.constraint(
                equalTo: container.bottomAnchor, constant: -16),
            closeButton.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: removeButton.centerYAnchor)
        ])

        view = container
        reloadPolicy()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reloadPolicy()
    }

    func reloadPolicy() {
        let policy = viewModel.currentTLSInterceptionPolicy()
        modeControl.selectedSegment = policy.mode == .interceptAllExcept ? 0 : 1
        rows = policy.entries
        tableView.reloadData()
        emptyState.isHidden = !rows.isEmpty
        emptyState.stringValue =
            policy.mode == .interceptAllExcept
            ? "No hosts are excluded — every HTTPS host is intercepted."
            : "No hosts are listed — no HTTPS host is intercepted."
        removeButton.isEnabled = tableView.selectedRow >= 0
    }

    func numberOfRows(in _: NSTableView) -> Int { rows.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard rows.indices.contains(row), tableColumn != nil else { return nil }
        let label = NSTextField(labelWithString: rows[row])
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }

    func tableViewSelectionDidChange(_: Notification) {
        removeButton.isEnabled = tableView.selectedRow >= 0
    }

    @objc private func changeInterceptionMode() {
        let mode: TLSInterceptionMode =
            modeControl.selectedSegment == 0 ? .interceptAllExcept : .interceptOnly
        applyChange { try viewModel.setTLSInterceptionMode(mode) }
    }

    @objc private func addEntry() {
        let entry = entryField.stringValue
        let current = viewModel.currentTLSInterceptionPolicy()
        applyChange {
            let policy = try TLSInterceptionPolicy(
                mode: current.mode,
                entries: current.entries + [entry]
            )
            try viewModel.saveTLSInterceptionPolicy(policy)
            entryField.stringValue = ""
        }
    }

    @objc private func removeSelectedEntry() {
        let selection = tableView.selectedRow
        guard rows.indices.contains(selection) else { return }
        let current = viewModel.currentTLSInterceptionPolicy()
        var entries = current.entries
        entries.remove(at: selection)
        applyChange {
            let policy = try TLSInterceptionPolicy(mode: current.mode, entries: entries)
            try viewModel.saveTLSInterceptionPolicy(policy)
        }
    }

    @objc private func close() {
        onClose?()
    }

    private func applyChange(_ change: () throws -> Void) {
        do {
            try change()
            validationLabel.stringValue = ""
            validationLabel.isHidden = true
        } catch {
            validationLabel.stringValue = error.localizedDescription
            validationLabel.isHidden = false
            NSAccessibility.post(element: validationLabel, notification: .valueChanged)
        }
        reloadPolicy()
    }

    private func configureTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 24
        tableView.delegate = self
        tableView.dataSource = self
        tableView.setAccessibilityIdentifier("sslProxyingManager.table")
        tableView.setAccessibilityLabel("SSL proxying host patterns")

        let host = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("host"))
        host.title = "Host pattern"
        host.width = 420
        host.minWidth = 200
        tableView.addTableColumn(host)
    }

    private func configureButton(
        _ button: NSButton,
        title: String,
        action: Selector,
        identifier: String
    ) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = title
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        button.setAccessibilityIdentifier(identifier)
    }
}
