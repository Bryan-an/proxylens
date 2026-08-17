import AppKit
import ProxyLensCore
import UniformTypeIdentifiers

@MainActor
final class RuleManagerViewController: NSViewController, NSTableViewDataSource,
    NSTableViewDelegate
{
    var onClose: (() -> Void)?

    private let viewModel: TrafficConsoleViewModel
    private let tableView = NSTableView()
    private let emptyState = NSTextField(labelWithString: "No rules yet")
    private let addButton = NSButton(title: "New Rule…", target: nil, action: nil)
    private let editButton = NSButton(title: "Edit…", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let profilePopUp = NSPopUpButton()
    private let saveProfileButton = NSButton(title: "Save Current…", target: nil, action: nil)
    private let applyProfileButton = NSButton(title: "Apply", target: nil, action: nil)
    private let deleteProfileButton = NSButton(title: "Delete", target: nil, action: nil)
    private let importProfileButton = NSButton(title: "Import…", target: nil, action: nil)
    private let exportProfileButton = NSButton(title: "Export…", target: nil, action: nil)
    private var rows: [TrafficRulePresentation] = []
    private var profiles: [RuleProfile] = []

    private static let ruleProfileType = UTType(
        exportedAs: "com.proxylens.rule-profile",
        conformingTo: .json
    )

    init(viewModel: TrafficConsoleViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 860, height: 480)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        container.setAccessibilityIdentifier("ruleManager")

        let title = NSTextField(labelWithString: "Rules")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 18, weight: .semibold)

        let subtitle = NSTextField(
            wrappingLabelWithString:
                "Rules run in priority order. Disable a rule temporarily or remove it permanently."
        )
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.textColor = .secondaryLabelColor

        configureTable()
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = tableView

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.font = .systemFont(ofSize: 14, weight: .medium)
        emptyState.textColor = .secondaryLabelColor
        emptyState.alignment = .center
        emptyState.setAccessibilityIdentifier("ruleManager.empty")

        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addRule)
        addButton.setAccessibilityIdentifier("ruleManager.add")

        editButton.translatesAutoresizingMaskIntoConstraints = false
        editButton.bezelStyle = .rounded
        editButton.target = self
        editButton.action = #selector(editSelectedRule)
        editButton.isEnabled = false
        editButton.setAccessibilityIdentifier("ruleManager.edit")

        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeSelectedRule)
        removeButton.isEnabled = false
        removeButton.setAccessibilityIdentifier("ruleManager.remove")

        let profileLabel = NSTextField(labelWithString: "Profile")
        profileLabel.translatesAutoresizingMaskIntoConstraints = false
        profileLabel.textColor = .secondaryLabelColor

        profilePopUp.translatesAutoresizingMaskIntoConstraints = false
        profilePopUp.target = self
        profilePopUp.action = #selector(profileSelectionChanged)
        profilePopUp.setAccessibilityIdentifier("ruleManager.profile")

        saveProfileButton.translatesAutoresizingMaskIntoConstraints = false
        saveProfileButton.bezelStyle = .rounded
        saveProfileButton.target = self
        saveProfileButton.action = #selector(saveCurrentProfile)
        saveProfileButton.setAccessibilityIdentifier("ruleManager.saveProfile")

        applyProfileButton.translatesAutoresizingMaskIntoConstraints = false
        applyProfileButton.bezelStyle = .rounded
        applyProfileButton.target = self
        applyProfileButton.action = #selector(applySelectedProfile)
        applyProfileButton.setAccessibilityIdentifier("ruleManager.applyProfile")

        deleteProfileButton.translatesAutoresizingMaskIntoConstraints = false
        deleteProfileButton.bezelStyle = .rounded
        deleteProfileButton.target = self
        deleteProfileButton.action = #selector(deleteSelectedProfile)
        deleteProfileButton.setAccessibilityIdentifier("ruleManager.deleteProfile")

        importProfileButton.translatesAutoresizingMaskIntoConstraints = false
        importProfileButton.bezelStyle = .rounded
        importProfileButton.target = self
        importProfileButton.action = #selector(importProfile)
        importProfileButton.setAccessibilityIdentifier("ruleManager.importProfile")

        exportProfileButton.translatesAutoresizingMaskIntoConstraints = false
        exportProfileButton.bezelStyle = .rounded
        exportProfileButton.target = self
        exportProfileButton.action = #selector(exportSelectedProfile)
        exportProfileButton.setAccessibilityIdentifier("ruleManager.exportProfile")

        let closeButton = NSButton(title: "Close", target: self, action: #selector(close))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.setAccessibilityIdentifier("ruleManager.close")

        container.addSubview(title)
        container.addSubview(subtitle)
        container.addSubview(scrollView)
        container.addSubview(emptyState)
        container.addSubview(addButton)
        container.addSubview(editButton)
        container.addSubview(removeButton)
        container.addSubview(profileLabel)
        container.addSubview(profilePopUp)
        container.addSubview(saveProfileButton)
        container.addSubview(applyProfileButton)
        container.addSubview(deleteProfileButton)
        container.addSubview(importProfileButton)
        container.addSubview(exportProfileButton)
        container.addSubview(closeButton)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 14),
            scrollView.bottomAnchor.constraint(equalTo: profileLabel.topAnchor, constant: -14),
            emptyState.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            addButton.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            addButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            editButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 8),
            editButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            removeButton.leadingAnchor.constraint(equalTo: editButton.trailingAnchor, constant: 8),
            removeButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            profileLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            profileLabel.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -14),
            profilePopUp.leadingAnchor.constraint(
                equalTo: profileLabel.trailingAnchor, constant: 6),
            profilePopUp.centerYAnchor.constraint(equalTo: profileLabel.centerYAnchor),
            profilePopUp.widthAnchor.constraint(equalToConstant: 180),
            saveProfileButton.leadingAnchor.constraint(
                equalTo: profilePopUp.trailingAnchor, constant: 6),
            saveProfileButton.centerYAnchor.constraint(equalTo: profileLabel.centerYAnchor),
            applyProfileButton.leadingAnchor.constraint(
                equalTo: saveProfileButton.trailingAnchor, constant: 6),
            applyProfileButton.centerYAnchor.constraint(equalTo: profileLabel.centerYAnchor),
            deleteProfileButton.leadingAnchor.constraint(
                equalTo: applyProfileButton.trailingAnchor, constant: 6),
            deleteProfileButton.centerYAnchor.constraint(equalTo: profileLabel.centerYAnchor),
            importProfileButton.leadingAnchor.constraint(
                greaterThanOrEqualTo: deleteProfileButton.trailingAnchor, constant: 20),
            importProfileButton.centerYAnchor.constraint(equalTo: profileLabel.centerYAnchor),
            exportProfileButton.leadingAnchor.constraint(
                equalTo: importProfileButton.trailingAnchor, constant: 6),
            exportProfileButton.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            exportProfileButton.centerYAnchor.constraint(equalTo: profileLabel.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor)
        ])

        view = container
        renderEmptyState()
        renderProfiles()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        Task { await reloadRules() }
    }

    func reloadRules() async {
        rows = await viewModel.currentRulePresentations()
        tableView.reloadData()
        editButton.isEnabled = false
        removeButton.isEnabled = false
        renderEmptyState()
        await reloadProfiles()
    }

    func reloadProfiles(selecting profileID: UUID? = nil) async {
        let selectedID = profileID ?? selectedProfileID
        do {
            profiles = try await viewModel.currentRuleProfiles()
            renderProfiles(selecting: selectedID)
        } catch {
            profiles = []
            renderProfiles()
            showProfileError(error)
        }
    }

    func numberOfRows(in _: NSTableView) -> Int {
        rows.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard rows.indices.contains(row), let identifier = tableColumn?.identifier else {
            return nil
        }
        let rule = rows[row]

        if identifier == .enabled {
            let button =
                tableView.makeView(withIdentifier: identifier, owner: self) as? RuleToggleButton
                ?? makeToggleButton(identifier: identifier)
            button.ruleID = rule.id
            button.state = rule.enabled ? .on : .off
            button.setAccessibilityLabel(
                rule.enabled ? "Disable \(rule.name)" : "Enable \(rule.name)")
            return button
        }

        let cell =
            tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeTextCell(identifier: identifier)
        switch identifier {
        case .name:
            cell.textField?.stringValue = rule.name
            cell.textField?.font = .systemFont(ofSize: 12, weight: .medium)
        case .action:
            cell.textField?.stringValue = rule.action
        case .phase:
            cell.textField?.stringValue = rule.phase
        case .matcher:
            cell.textField?.stringValue = rule.matcher
        case .priority:
            cell.textField?.stringValue = String(rule.priority)
        default:
            cell.textField?.stringValue = ""
        }
        cell.textField?.toolTip = cell.textField?.stringValue
        return cell
    }

    func tableViewSelectionDidChange(_: Notification) {
        guard rows.indices.contains(tableView.selectedRow) else {
            editButton.isEnabled = false
            removeButton.isEnabled = false
            return
        }
        editButton.isEnabled = rows[tableView.selectedRow].canEdit
        removeButton.isEnabled = true
    }

    private func configureTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(editSelectedRule)
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 26
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.setAccessibilityIdentifier("ruleManager.table")

        addColumn(identifier: .enabled, title: "On", width: 44, minimumWidth: 44)
        addColumn(identifier: .name, title: "Rule", width: 230, minimumWidth: 150)
        addColumn(identifier: .action, title: "Action", width: 130, minimumWidth: 90)
        addColumn(identifier: .phase, title: "Phase", width: 135, minimumWidth: 100)
        addColumn(identifier: .priority, title: "Priority", width: 70, minimumWidth: 60)
        addColumn(identifier: .matcher, title: "Matcher", width: 240, minimumWidth: 150)
    }

    private func addColumn(
        identifier: NSUserInterfaceItemIdentifier,
        title: String,
        width: CGFloat,
        minimumWidth: CGFloat
    ) {
        let column = NSTableColumn(identifier: identifier)
        column.title = title
        column.width = width
        column.minWidth = minimumWidth
        tableView.addTableColumn(column)
    }

    private func makeToggleButton(identifier: NSUserInterfaceItemIdentifier) -> RuleToggleButton {
        let button = RuleToggleButton(
            checkboxWithTitle: "", target: self, action: #selector(toggleRule))
        button.identifier = identifier
        button.alignment = .center
        return button
    }

    private func makeTextCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingTail
        textField.textColor = .labelColor
        textField.font = .systemFont(ofSize: 12)
        cell.textField = textField
        cell.addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func renderEmptyState() {
        emptyState.isHidden = !rows.isEmpty
        tableView.isHidden = rows.isEmpty
    }

    @objc private func toggleRule(_ sender: RuleToggleButton) {
        guard let ruleID = sender.ruleID else {
            return
        }
        sender.isEnabled = false
        Task {
            await viewModel.setRuleEnabled(sender.state == .on, id: ruleID)
            await reloadRules()
        }
    }

    @objc private func removeSelectedRule() {
        guard rows.indices.contains(tableView.selectedRow) else {
            return
        }
        let ruleID = rows[tableView.selectedRow].id
        removeButton.isEnabled = false
        Task {
            await viewModel.removeRule(id: ruleID)
            await reloadRules()
        }
    }

    @objc private func addRule() {
        let editor = TrafficRuleEditorViewController()
        editor.onCancel = { [weak self, weak editor] in
            guard let self, let editor else {
                return
            }
            self.dismiss(editor)
        }
        editor.onSubmit = { [weak self, weak editor] rule in
            guard let self, let editor else {
                return
            }
            Task {
                await self.viewModel.addRule(rule)
                self.dismiss(editor)
                await self.reloadRules()
            }
        }
        presentAsSheet(editor)
    }

    @objc private func editSelectedRule() {
        guard rows.indices.contains(tableView.selectedRow) else {
            return
        }
        let ruleID = rows[tableView.selectedRow].id
        editButton.isEnabled = false
        Task {
            guard let draft = await viewModel.ruleDraft(id: ruleID) else {
                tableViewSelectionDidChange(
                    Notification(name: NSTableView.selectionDidChangeNotification)
                )
                return
            }
            let editor = TrafficRuleEditorViewController(draft: draft)
            editor.onCancel = { [weak self, weak editor] in
                guard let self, let editor else {
                    return
                }
                self.dismiss(editor)
            }
            editor.onSubmit = { [weak self, weak editor] rule in
                guard let self, let editor else {
                    return
                }
                Task {
                    _ = await self.viewModel.updateRule(rule)
                    self.dismiss(editor)
                    await self.reloadRules()
                }
            }
            presentAsSheet(editor)
        }
    }

    @objc private func profileSelectionChanged() {
        updateProfileButtons()
    }

    @objc private func saveCurrentProfile() {
        let alert = NSAlert()
        alert.messageText = "Save Rule Profile"
        alert.informativeText =
            "Save the complete active rule set so it can be restored later. An existing profile with the same name will be updated."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(string: profilePopUp.titleOfSelectedItem ?? "")
        nameField.placeholderString = "Profile name"
        nameField.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        nameField.setAccessibilityIdentifier("ruleManager.profileName")
        alert.accessoryView = nameField

        if let window = view.window {
            alert.beginSheetModal(for: window) { [weak self, weak nameField] response in
                guard response == .alertFirstButtonReturn, let name = nameField?.stringValue else {
                    return
                }
                self?.saveProfile(named: name)
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            saveProfile(named: nameField.stringValue)
        }
    }

    private func saveProfile(named name: String) {
        saveProfileButton.isEnabled = false
        Task {
            do {
                let profile = try await viewModel.saveRuleProfile(name: name)
                await reloadProfiles(selecting: profile.id)
            } catch {
                showProfileError(error)
            }
            saveProfileButton.isEnabled = true
        }
    }

    @objc private func applySelectedProfile() {
        guard let profileID = selectedProfileID else {
            return
        }
        applyProfileButton.isEnabled = false
        Task {
            do {
                try await viewModel.applyRuleProfile(id: profileID)
                await reloadRules()
                selectProfile(id: profileID)
            } catch {
                showProfileError(error)
                updateProfileButtons()
            }
        }
    }

    @objc private func deleteSelectedProfile() {
        guard let profileID = selectedProfileID,
            let profile = profiles.first(where: { $0.id == profileID })
        else {
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete \(profile.name)?"
        alert.informativeText = "This removes the saved profile. Active rules are not changed."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        let remove = { [weak self] in
            guard let self else {
                return
            }
            self.deleteProfileButton.isEnabled = false
            Task {
                do {
                    try await self.viewModel.removeRuleProfile(id: profileID)
                    await self.reloadProfiles()
                } catch {
                    self.showProfileError(error)
                    self.updateProfileButtons()
                }
            }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    remove()
                }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            remove()
        }
    }

    @objc private func exportSelectedProfile() {
        guard let profileID = selectedProfileID,
            let profile = profiles.first(where: { $0.id == profileID })
        else {
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.title = "Export Rule Profile"
        panel.message = "Export the selected rules and embedded Map Local resources."
        panel.prompt = "Export"
        panel.nameFieldStringValue = Self.portableFileName(for: profile.name)
        panel.allowedContentTypes = [Self.ruleProfileType]

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let fileURL = panel.url, let self else {
                return
            }
            self.exportProfileButton.isEnabled = false
            Task { @MainActor in
                defer { self.updateProfileButtons() }
                do {
                    try await self.viewModel.exportRuleProfile(id: profileID, to: fileURL)
                } catch {
                    self.showProfileError(error)
                }
            }
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    @objc private func importProfile() {
        let panel = NSOpenPanel()
        panel.title = "Import Rule Profile"
        panel.message =
            "Choose a ProxyLens rule profile. Existing profiles with the same identity or name will be updated."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [Self.ruleProfileType, .json]

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let fileURL = panel.url, let self else {
                return
            }
            self.importProfileButton.isEnabled = false
            Task { @MainActor in
                do {
                    let profile = try await self.viewModel.importRuleProfile(from: fileURL)
                    await self.reloadProfiles(selecting: profile.id)
                } catch {
                    self.showProfileError(error)
                }
                self.importProfileButton.isEnabled = true
            }
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private var selectedProfileID: UUID? {
        guard profiles.indices.contains(profilePopUp.indexOfSelectedItem) else {
            return nil
        }
        return profiles[profilePopUp.indexOfSelectedItem].id
    }

    private func renderProfiles(selecting profileID: UUID? = nil) {
        profilePopUp.removeAllItems()
        if profiles.isEmpty {
            profilePopUp.addItem(withTitle: "No saved profiles")
            profilePopUp.isEnabled = false
        } else {
            profilePopUp.addItems(withTitles: profiles.map(\.name))
            profilePopUp.isEnabled = true
            selectProfile(id: profileID)
        }
        updateProfileButtons()
    }

    private func selectProfile(id profileID: UUID?) {
        guard let profileID,
            let index = profiles.firstIndex(where: { $0.id == profileID })
        else {
            if !profiles.isEmpty {
                profilePopUp.selectItem(at: 0)
            }
            updateProfileButtons()
            return
        }
        profilePopUp.selectItem(at: index)
        updateProfileButtons()
    }

    private func updateProfileButtons() {
        let hasSelection = selectedProfileID != nil
        applyProfileButton.isEnabled = hasSelection
        deleteProfileButton.isEnabled = hasSelection
        exportProfileButton.isEnabled = hasSelection
    }

    private static func portableFileName(for profileName: String) -> String {
        let baseName =
            profileName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(baseName.isEmpty ? "rules" : baseName).proxylensrules"
    }

    private func showProfileError(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @objc private func close() {
        onClose?()
    }
}

private final class RuleToggleButton: NSButton {
    var ruleID: RuleID?
}

extension NSUserInterfaceItemIdentifier {
    fileprivate static let enabled = NSUserInterfaceItemIdentifier("rule.enabled")
    fileprivate static let name = NSUserInterfaceItemIdentifier("rule.name")
    fileprivate static let action = NSUserInterfaceItemIdentifier("rule.action")
    fileprivate static let phase = NSUserInterfaceItemIdentifier("rule.phase")
    fileprivate static let priority = NSUserInterfaceItemIdentifier("rule.priority")
    fileprivate static let matcher = NSUserInterfaceItemIdentifier("rule.matcher")
}
