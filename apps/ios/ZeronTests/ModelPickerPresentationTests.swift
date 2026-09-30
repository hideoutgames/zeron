import UIKit
import XCTest
@testable import Zeron

/// Presentation and interaction regressions that use a local catalog, so a
/// host's available models cannot remove coverage for the Fusion popup.
final class ModelPickerPresentationTests: XCTestCase {
    private func fusionCatalog() -> ModelCatalog {
        let lead = ModelOption(id: "lead", label: "Lead", choices: [.init(id: "fable", label: "Fable"), .init(id: "sol", label: "Sol")], defaultChoice: "fable")
        let sidekick = ModelOption(id: "sidekick", label: "Sidekick", choices: [.init(id: "swe", label: "SWE")], defaultChoice: "swe")
        let speed = ModelOption(id: "speed", label: "Fast Mode", choices: [.init(id: "standard", label: "Standard"), .init(id: "fast", label: "Fast")], defaultChoice: "standard")
        let fusion = ModelInfo(id: "fusion", label: "Fusion", description: nil, reasoningLevels: ["low", "high"], options: [lead, sidekick, speed], defaultReasoning: nil)
        let regular = ModelInfo(id: "regular", label: "Regular", description: nil, reasoningLevels: [], options: [speed], defaultReasoning: nil)
        return ModelCatalog(providers: [.init(id: "devin", label: "Devin", models: [fusion, regular])])
    }

    @MainActor
    private func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    @MainActor
    private func waitUntilPresented(_ controller: UIViewController, file: StaticString = #filePath, line: UInt = #line) throws {
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            controller.viewIfLoaded?.window != nil && !controller.isBeingPresented && controller.transitionCoordinator == nil
        }, object: controller)
        // The first Liquid Glass presentation can compile simulator shaders.
        // Wait for the entire transition before measuring or opening a child.
        let result = XCTWaiter.wait(for: [shown], timeout: 15)
        _ = try XCTUnwrap(result == .completed ? controller : nil, "native presentation did not finish", file: file, line: line)
        controller.view.window?.layoutIfNeeded()
        controller.view.layoutIfNeeded()
    }

    @MainActor
    private func close(_ host: UIViewController, window: UIWindow) {
        var top = host
        while let presented = top.presentedViewController { top = presented }
        let dismiss = {
            host.dismiss(animated: false)
            window.isHidden = true
        }
        if let transition = top.transitionCoordinator,
           transition.animate(alongsideTransition: nil, completion: { _ in dismiss() }) {
            return
        }
        // A failed presentation must not make teardown start another UIKit
        // transition before the first has finished.
        if top.isBeingPresented || top.isBeingDismissed {
            window.isHidden = true
        } else {
            dismiss()
        }
    }

    @MainActor
    private func present(_ picker: ModelPickerViewController) throws -> (UIWindow, UIViewController, ComposerBar) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.isHidden = false
        let composer = ComposerBar()
        host.view.addSubview(composer)
        composer.frame = CGRect(x: 16, y: 100, width: 320, height: 140)
        let chip = UIButton(frame: CGRect(x: 16, y: 100, width: 100, height: 40))
        composer.addSubview(chip)
        picker.present(anchoredTo: chip, holding: composer, over: host)
        do {
            try waitUntilPresented(picker)
        } catch {
            close(host, window: window)
            throw error
        }
        return (window, host, composer)
    }

    @MainActor
    func testDrawerUsesInsetSelectionCornersAndMutesInactiveClaude() throws {
        let model = ModelInfo(id: "one", label: "One", description: nil, reasoningLevels: [], options: [], defaultReasoning: nil)
        let catalog = ModelCatalog(providers: [.init(id: "claude-code", label: "Claude Code", models: [model])])
        let picker = ModelPickerViewController(catalog: catalog, selection: .init(harness: "claude-code", model: "one"), locked: true)
        let (window, host, composer) = try present(picker)
        defer { close(host, window: window) }
        XCTAssertEqual(picker.modalPresentationStyle, .pageSheet)
        XCTAssertTrue(composer.holdsCard)
        let sheet = try XCTUnwrap(picker.sheetPresentationController)
        XCTAssertTrue(sheet.prefersGrabberVisible)
        let list = try XCTUnwrap(descendants(of: picker.view).compactMap { $0 as? UICollectionView }.first)
        list.layoutIfNeeded()
        let row = try XCTUnwrap(list.cellForItem(at: IndexPath(item: 0, section: 0)))
        XCTAssertTrue(row.accessibilityTraits.contains(.selected))
        let rowRadius = try XCTUnwrap(row.backgroundConfiguration).cornerRadius
        XCTAssertGreaterThan(rowRadius, 0)
        XCTAssertLessThan(rowRadius, row.bounds.height / 2, "the selected row has rounded corners rather than capsule ends")
        XCTAssertLessThan(rowRadius, try XCTUnwrap(sheet.preferredCornerRadius), "an inset row has tighter corners than the drawer")

        let buttons = descendants(of: picker.view).compactMap { $0 as? UIButton }
        let claude = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier == "model-tab-claude-code" })
        let favorites = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier == "model-tab-favorites" })
        XCTAssertEqual(claude.configuration?.image?.renderingMode, .alwaysOriginal)
        favorites.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(claude.configuration?.image?.renderingMode, .alwaysTemplate)
        XCTAssertFalse(claude.accessibilityTraits.contains(.selected))
        claude.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(claude.configuration?.image?.renderingMode, .alwaysOriginal)
        XCTAssertTrue(claude.accessibilityTraits.contains(.selected))
    }

    @MainActor
    func testSettingsReuseDrawerHeightAndReturnUnusedSpaceToModelList() throws {
        let tier = ModelOption(id: "serviceTier", label: "Service Tier", choices: [.init(id: "standard", label: "Standard"), .init(id: "fast", label: "Fast")], defaultChoice: "standard")
        let context = ModelOption(id: "contextWindow", label: "Context Window", choices: [.init(id: "small", label: "Small"), .init(id: "large", label: "Large")], defaultChoice: "small")
        let plain = ModelInfo(id: "layout-plain", label: "Plain", description: nil, reasoningLevels: [], options: [], defaultReasoning: nil)
        let oneSetting = ModelInfo(id: "layout-one", label: "One Setting", description: nil, reasoningLevels: ["low", "high"], options: [], defaultReasoning: nil)
        let threeSettings = ModelInfo(id: "layout-three", label: "Three Settings", description: nil, reasoningLevels: ["low", "high"], options: [tier, context], defaultReasoning: nil)
        let manyOptions = (0..<12).map { index in
            ModelOption(id: "extra-\(index)", label: "Option \(index)", choices: tier.choices, defaultChoice: tier.defaultChoice)
        }
        let manySettings = ModelInfo(id: "layout-many", label: "Many Settings", description: nil, reasoningLevels: [], options: manyOptions, defaultReasoning: nil)
        let catalog = ModelCatalog(providers: [.init(id: "codex", label: "Codex", models: [plain, oneSetting, threeSettings, manySettings])])
        let picker = ModelPickerViewController(catalog: catalog, selection: .init(harness: "codex", model: plain.id), locked: true)
        let (window, host, _) = try present(picker)
        defer { close(host, window: window) }
        let list = try XCTUnwrap(descendants(of: picker.view).compactMap { $0 as? UICollectionView }.first)
        let originalFrame = picker.view.convert(picker.view.bounds, to: window)
        let originalSize = picker.preferredContentSize
        let fullListHeight = list.bounds.height

        func contentBottom() -> CGFloat {
            min(picker.view.bounds.maxY, picker.view.convert(window.safeAreaLayoutGuide.layoutFrame, from: window).maxY)
        }

        func checkDrawer() {
            window.layoutIfNeeded()
            picker.view.layoutIfNeeded()
            let frame = picker.view.convert(picker.view.bounds, to: window)
            XCTAssertEqual(frame.minY, originalFrame.minY, accuracy: 1, "changing model settings keeps the drawer in place")
            XCTAssertEqual(frame.height, originalFrame.height, accuracy: 1)
            XCTAssertEqual(picker.preferredContentSize, originalSize, "the drawer's requested size does not depend on settings count")
        }

        func checkSettings(_ expectedCount: Int) throws {
            let settings = descendants(of: picker.view).compactMap { $0 as? ModelSettingRow }
            XCTAssertEqual(settings.count, expectedCount)
            let last = try XCTUnwrap(settings.last)
            let tray = try XCTUnwrap(last.superview as? UIScrollView)
            tray.scrollRectToVisible(last.frame, animated: false)
            tray.layoutIfNeeded()
            let rowFrame = last.convert(last.bounds, to: picker.view)
            let trayFrame = tray.convert(tray.bounds, to: picker.view)
            XCTAssertGreaterThanOrEqual(rowFrame.minY, trayFrame.minY - 1)
            XCTAssertLessThanOrEqual(rowFrame.maxY, trayFrame.maxY + 1, "the last setting remains reachable")
            XCTAssertEqual(trayFrame.maxY, contentBottom(), accuracy: 1, "only device home-indicator clearance remains below the settings tray")
            if tray.contentSize.height <= tray.bounds.height + 1 {
                let first = try XCTUnwrap(settings.first)
                XCTAssertEqual(trayFrame.maxY - rowFrame.maxY, first.frame.minY, accuracy: 1, "the final option has only the same inset as the first option")
            }
        }

        XCTAssertEqual(list.convert(list.bounds, to: picker.view).maxY, contentBottom(), accuracy: 1)
        // Sheet-owned insets must not add another blank band above the
        // actual device clearance, including when UIKit changes them.
        picker.additionalSafeAreaInsets.bottom = 30
        checkDrawer()
        XCTAssertEqual(list.bounds.height, fullListHeight, accuracy: 1)
        XCTAssertEqual(list.convert(list.bounds, to: picker.view).maxY, contentBottom(), accuracy: 1)
        picker.update(selection: .init(harness: "codex", model: oneSetting.id))
        checkDrawer()
        try checkSettings(1)
        let oneSettingListHeight = list.bounds.height
        XCTAssertLessThan(oneSettingListHeight, fullListHeight, "settings consume space from the model list")

        picker.update(selection: .init(harness: "codex", model: threeSettings.id))
        checkDrawer()
        try checkSettings(3)
        XCTAssertGreaterThan(list.bounds.height, 0)
        XCTAssertLessThan(list.bounds.height, oneSettingListHeight)
        let threeSettingListHeight = list.bounds.height

        picker.update(selection: .init(harness: "codex", model: manySettings.id))
        checkDrawer()
        try checkSettings(12)
        let lastSetting = try XCTUnwrap(descendants(of: picker.view).compactMap { $0 as? ModelSettingRow }.last)
        let tray = try XCTUnwrap(lastSetting.superview as? UIScrollView)
        XCTAssertGreaterThan(tray.contentSize.height, tray.bounds.height)
        XCTAssertGreaterThan(tray.contentOffset.y, 0, "a long settings catalog scrolls to its final option")
        picker.update(selection: .init(harness: "codex", model: threeSettings.id))
        checkDrawer()
        XCTAssertLessThanOrEqual(tray.contentOffset.y, max(0, tray.contentSize.height - tray.bounds.height) + 1, "shrinking the catalog cannot leave its settings scrolled offscreen")
        try checkSettings(3)
        XCTAssertEqual(list.bounds.height, threeSettingListHeight, accuracy: 1)

        // A host can remove settings from a model without changing its ID.
        let refreshed = ModelInfo(id: threeSettings.id, label: threeSettings.label, description: nil, reasoningLevels: [], options: [], defaultReasoning: nil)
        picker.update(catalog: ModelCatalog(providers: [.init(id: "codex", label: "Codex", models: [plain, oneSetting, refreshed])]))
        checkDrawer()
        XCTAssertFalse(descendants(of: picker.view).contains { $0 is ModelSettingRow })
        XCTAssertEqual(list.bounds.height, fullListHeight, accuracy: 1, "the list takes back the settings area")
        XCTAssertEqual(list.convert(list.bounds, to: picker.view).maxY, contentBottom(), accuracy: 1)

        // Empty results use that same full list area, including its bottom.
        let search = try XCTUnwrap(descendants(of: picker.view).compactMap { $0 as? UITextField }.first)
        search.text = "no matching model"
        search.sendActions(for: .editingChanged)
        checkDrawer()
        XCTAssertEqual(list.numberOfItems(inSection: 0), 0)
        let empty = try XCTUnwrap(descendants(of: picker.view).compactMap { $0 as? UILabel }.first { $0.text == "No models found" })
        XCTAssertFalse(empty.isHidden)
        XCTAssertEqual(empty.convert(empty.bounds, to: picker.view).maxY, list.convert(list.bounds, to: picker.view).maxY, accuracy: 1)
    }

    @MainActor
    func testSettingChoicesKeepDrawerStableAndRejectObsoleteSelections() throws {
        let picker = ModelPickerViewController(catalog: fusionCatalog(), selection: .init(harness: "devin", model: "regular"), locked: true)
        var changes: [ModelSelection] = []
        picker.onChange = { changes.append($0) }
        let (window, host, composer) = try present(picker)
        defer { close(host, window: window) }
        let row = try XCTUnwrap(descendants(of: picker.view).compactMap { $0 as? ModelSettingRow }.first)
        let originalFrame = picker.view.convert(picker.view.bounds, to: window)
        let originalSize = picker.preferredContentSize
        XCTAssertNil(row.menu, "a setting presents independently of its enclosing glass drawer")
        row.sendActions(for: .touchUpInside)
        let popup = try XCTUnwrap(picker.presentedViewController as? ModelChoiceViewController)
        try waitUntilPresented(popup)
        XCTAssertEqual(popup.modalPresentationStyle, .popover)
        let presentation = try XCTUnwrap(popup.popoverPresentationController)
        XCTAssertTrue(presentation.sourceView === row)
        XCTAssertEqual(popup.adaptivePresentationStyle(for: presentation, traitCollection: UITraitCollection(horizontalSizeClass: .compact)), .none)
        XCTAssertTrue(host.presentedViewController === picker)
        XCTAssertTrue(composer.holdsCard)
        XCTAssertEqual(picker.view.convert(picker.view.bounds, to: window), originalFrame)
        XCTAssertEqual(picker.preferredContentSize, originalSize)

        let table = try XCTUnwrap(descendants(of: popup.view).compactMap { $0 as? UITableView }.first)
        XCTAssertEqual(table.numberOfRows(inSection: 0), 2)
        popup.tableView(table, didSelectRowAt: IndexPath(row: 1, section: 0))
        let picked = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            picker.presentedViewController == nil
        }, object: picker)
        wait(for: [picked], timeout: 5)
        XCTAssertEqual(changes.last?.options, ["speed": "fast"])
        XCTAssertEqual(row.accessibilityValue, "Fast")
        XCTAssertTrue(host.presentedViewController === picker)
        XCTAssertEqual(picker.view.convert(picker.view.bounds, to: window), originalFrame)

        row.sendActions(for: .touchUpInside)
        let obsolete = try XCTUnwrap(picker.presentedViewController as? ModelChoiceViewController)
        try waitUntilPresented(obsolete)
        let oldTable = try XCTUnwrap(descendants(of: obsolete.view).compactMap { $0 as? UITableView }.first)
        picker.update(selection: .init(harness: "devin", model: "fusion"))
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            picker.presentedViewController == nil
        }, object: picker)
        wait(for: [closed], timeout: 5)
        obsolete.tableView(oldTable, didSelectRowAt: IndexPath(row: 0, section: 0))
        XCTAssertEqual(changes.count, 1, "a delayed choice cannot update another model even when it offers the same option")
        XCTAssertTrue(host.presentedViewController === picker)
        XCTAssertEqual(picker.view.convert(picker.view.bounds, to: window), originalFrame)
    }

    @MainActor
    func testFusionSettingsOpenInIndependentPopoverWithoutBackButton() throws {
        let catalog = fusionCatalog()
        let picker = ModelPickerViewController(catalog: catalog, selection: .init(harness: "devin", model: "fusion"), locked: true)
        var changes: [ModelSelection] = []
        picker.onChange = { changes.append($0) }
        let (window, host, _) = try present(picker)
        defer { close(host, window: window) }
        let list = try XCTUnwrap(descendants(of: picker.view).compactMap { $0 as? UICollectionView }.first)
        picker.collectionView(list, didSelectItemAt: IndexPath(item: 0, section: 0))
        let popup = try XCTUnwrap(picker.presentedViewController as? ModelConfigViewController)
        try waitUntilPresented(popup)
        XCTAssertEqual(popup.modalPresentationStyle, .popover)
        let presentation = try XCTUnwrap(popup.popoverPresentationController)
        XCTAssertEqual(popup.adaptivePresentationStyle(for: presentation, traitCollection: UITraitCollection(horizontalSizeClass: .compact)), .none)
        XCTAssertEqual(popup.card.header.text, "Fusion")
        XCTAssertTrue(popup.card.header.accessibilityTraits.contains(.header))
        let controls = descendants(of: popup.view)
        XCTAssertFalse(controls.contains { $0.accessibilityIdentifier == "model-card-back" })
        XCTAssertEqual(controls.compactMap { $0 as? ModelSettingRow }.map(\.accessibilityLabel), ["Lead", "Effort", "Sidekick"])
        let toggle = try XCTUnwrap(controls.compactMap { $0 as? UISwitch }.first)
        toggle.setOn(true, animated: false)
        toggle.sendActions(for: .valueChanged)
        XCTAssertEqual(changes.last?.options, ["speed": "fast"])

        let lead = try XCTUnwrap(controls.compactMap { $0 as? ModelSettingRow }.first { $0.accessibilityIdentifier == "model-setting-lead" })
        let cardFrame = popup.view.convert(popup.view.bounds, to: window)
        lead.sendActions(for: .touchUpInside)
        let choices = try XCTUnwrap(popup.presentedViewController as? ModelChoiceViewController)
        try waitUntilPresented(choices)
        XCTAssertEqual(choices.modalPresentationStyle, .popover)
        XCTAssertTrue(picker.presentedViewController === popup, "the choice popup sits above the Fusion card")
        XCTAssertEqual(popup.view.convert(popup.view.bounds, to: window), cardFrame)
        let choicesTable = try XCTUnwrap(descendants(of: choices.view).compactMap { $0 as? UITableView }.first)
        choices.tableView(choicesTable, didSelectRowAt: IndexPath(row: 1, section: 0))
        let choicesClosed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            popup.presentedViewController == nil
        }, object: popup)
        wait(for: [choicesClosed], timeout: 5)
        XCTAssertEqual(changes.last?.options, ["speed": "fast", "lead": "sol"])
        XCTAssertEqual(lead.accessibilityValue, "Sol")
        XCTAssertTrue(picker.presentedViewController === popup)

        let dismissed = expectation(description: "Fusion popup dismissed")
        popup.dismiss(animated: false) { dismissed.fulfill() }
        wait(for: [dismissed], timeout: 5)
        XCTAssertTrue(host.presentedViewController === picker, "closing Fusion leaves the model drawer open")
        XCTAssertNil(picker.presentedViewController)
        XCTAssertTrue(list.window != nil)
    }

    @MainActor
    func testExternalModelChangeDismissesFusionAndRejectsItsPendingControls() throws {
        let picker = ModelPickerViewController(catalog: fusionCatalog(), selection: .init(harness: "devin", model: "fusion"), locked: true)
        var changes: [ModelSelection] = []
        picker.onChange = { changes.append($0) }
        let (window, host, _) = try present(picker)
        defer { close(host, window: window) }
        let list = try XCTUnwrap(descendants(of: picker.view).compactMap { $0 as? UICollectionView }.first)
        picker.collectionView(list, didSelectItemAt: IndexPath(item: 0, section: 0))
        let popup = try XCTUnwrap(picker.presentedViewController as? ModelConfigViewController)
        try waitUntilPresented(popup)
        let staleToggle = try XCTUnwrap(descendants(of: popup.view).compactMap { $0 as? UISwitch }.first)
        let lead = try XCTUnwrap(descendants(of: popup.view).compactMap { $0 as? ModelSettingRow }.first { $0.accessibilityIdentifier == "model-setting-lead" })
        lead.sendActions(for: .touchUpInside)
        let staleChoices = try XCTUnwrap(popup.presentedViewController as? ModelChoiceViewController)
        try waitUntilPresented(staleChoices)
        let staleTable = try XCTUnwrap(descendants(of: staleChoices.view).compactMap { $0 as? UITableView }.first)

        picker.update(selection: .init(harness: "devin", model: "regular"))
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            picker.presentedViewController == nil && popup.presentedViewController == nil
        }, object: picker)
        wait(for: [dismissed], timeout: 5)
        XCTAssertTrue(changes.isEmpty, "external model updates do not echo a selection back")

        // Both models offer the same speed option, so validation alone would
        // let a delayed event from Fusion overwrite the new model's setting.
        withExtendedLifetime(popup) {
            staleToggle.setOn(true, animated: false)
            staleToggle.sendActions(for: .valueChanged)
        }
        staleChoices.tableView(staleTable, didSelectRowAt: IndexPath(row: 1, section: 0))
        XCTAssertTrue(changes.isEmpty, "a dismissed model's control cannot configure the current model")
        XCTAssertTrue(host.presentedViewController === picker)
    }
}
