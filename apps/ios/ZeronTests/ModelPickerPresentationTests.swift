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
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            picker.viewIfLoaded?.window != nil && !picker.isBeingPresented
        }, object: picker)
        wait(for: [shown], timeout: 5)
        picker.view.layoutIfNeeded()
        return (window, host, composer)
    }

    @MainActor
    func testDrawerKeepsMatchingSelectionCornersAndMutesInactiveClaude() throws {
        let model = ModelInfo(id: "one", label: "One", description: nil, reasoningLevels: [], options: [], defaultReasoning: nil)
        let catalog = ModelCatalog(providers: [.init(id: "claude-code", label: "Claude Code", models: [model])])
        let picker = ModelPickerViewController(catalog: catalog, selection: .init(harness: "claude-code", model: "one"), locked: true)
        let (window, host, composer) = try present(picker)
        defer {
            host.dismiss(animated: false)
            window.isHidden = true
        }
        XCTAssertEqual(picker.modalPresentationStyle, .pageSheet)
        XCTAssertTrue(composer.holdsCard)
        let sheet = try XCTUnwrap(picker.sheetPresentationController)
        XCTAssertTrue(sheet.prefersGrabberVisible)
        let list = try XCTUnwrap(descendants(of: picker.view).compactMap { $0 as? UICollectionView }.first)
        list.layoutIfNeeded()
        let row = try XCTUnwrap(list.cellForItem(at: IndexPath(item: 0, section: 0)))
        XCTAssertTrue(row.accessibilityTraits.contains(.selected))
        XCTAssertEqual(try XCTUnwrap(row.backgroundConfiguration).cornerRadius, try XCTUnwrap(sheet.preferredCornerRadius))

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
    func testFusionSettingsOpenInIndependentPopoverWithoutBackButton() throws {
        let catalog = fusionCatalog()
        let picker = ModelPickerViewController(catalog: catalog, selection: .init(harness: "devin", model: "fusion"), locked: true)
        var changes: [ModelSelection] = []
        picker.onChange = { changes.append($0) }
        let (window, host, _) = try present(picker)
        defer {
            host.dismiss(animated: false)
            window.isHidden = true
        }
        let list = try XCTUnwrap(descendants(of: picker.view).compactMap { $0 as? UICollectionView }.first)
        picker.collectionView(list, didSelectItemAt: IndexPath(item: 0, section: 0))
        let popup = try XCTUnwrap(picker.presentedViewController as? ModelConfigViewController)
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            popup.viewIfLoaded?.window != nil && !popup.isBeingPresented
        }, object: popup)
        wait(for: [shown], timeout: 5)
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

        let dismissed = expectation(description: "Fusion popup dismissed")
        popup.dismiss(animated: false) { dismissed.fulfill() }
        wait(for: [dismissed], timeout: 5)
        XCTAssertTrue(host.presentedViewController === picker, "closing Fusion leaves the model drawer open")
        XCTAssertNil(picker.presentedViewController)
        XCTAssertTrue(list.window != nil)
    }

    @MainActor
    func testExternalModelChangeDismissesFusionAndRejectsItsPendingToggle() throws {
        let picker = ModelPickerViewController(catalog: fusionCatalog(), selection: .init(harness: "devin", model: "fusion"), locked: true)
        var changes: [ModelSelection] = []
        picker.onChange = { changes.append($0) }
        let (window, host, _) = try present(picker)
        defer {
            host.dismiss(animated: false)
            window.isHidden = true
        }
        let list = try XCTUnwrap(descendants(of: picker.view).compactMap { $0 as? UICollectionView }.first)
        picker.collectionView(list, didSelectItemAt: IndexPath(item: 0, section: 0))
        let popup = try XCTUnwrap(picker.presentedViewController as? ModelConfigViewController)
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            popup.viewIfLoaded?.window != nil && !popup.isBeingPresented
        }, object: popup)
        wait(for: [shown], timeout: 5)
        let staleToggle = try XCTUnwrap(descendants(of: popup.view).compactMap { $0 as? UISwitch }.first)

        picker.update(selection: .init(harness: "devin", model: "regular"))
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            picker.presentedViewController == nil
        }, object: picker)
        wait(for: [dismissed], timeout: 5)
        XCTAssertTrue(changes.isEmpty, "external model updates do not echo a selection back")

        // Both models offer the same speed option, so validation alone would
        // let a delayed event from Fusion overwrite the new model's setting.
        withExtendedLifetime(popup) {
            staleToggle.setOn(true, animated: false)
            staleToggle.sendActions(for: .valueChanged)
        }
        XCTAssertTrue(changes.isEmpty, "a dismissed model's control cannot configure the current model")
        XCTAssertTrue(host.presentedViewController === picker)
    }
}
