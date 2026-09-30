import UIKit

private enum ModelPickerMetrics {
    static let cornerRadius: CGFloat = 26
    static let grabberClearance: CGFloat = 20
    static let tabs: CGFloat = 44
    static let tabWidth: CGFloat = 44
    static let search: CGFloat = 44
    static var compactRow: CGFloat { (44 * TypeScale.factor).rounded() }
    static var twoLineRow: CGFloat { (54 * TypeScale.factor).rounded() }
    static var listIdeal: CGFloat { (264 * TypeScale.factor).rounded() }
    static var settingRow: CGFloat { (44 * TypeScale.factor).rounded() }
    static let trayPadding: CGFloat = 6

    static func trayHeight(_ count: Int) -> CGFloat {
        count == 0 ? 0 : CGFloat(count) * settingRow + trayPadding * 2
    }

    static func cardHeight(_ count: Int, line: CGFloat) -> CGFloat {
        settingRow + line + CGFloat(count) * settingRow + trayPadding * 2
    }
}

/// Native drawer retaining the provider tabs, scoped search, favorites, model
/// list and settings tray from ZRemote's iOS picker. Selections keep the drawer
/// open. A model configured in place (Devin Fusion) opens a separate glass
/// popover over the drawer, without replacing the list or adding a back button.
final class ModelPickerViewController: UIViewController, UISheetPresentationControllerDelegate, UICollectionViewDataSource, UICollectionViewDelegate, UITextFieldDelegate {
    private enum ScrollMode { case keep, top, picked }

    private struct TabButton {
        let tab: ModelPickerTab
        let button: UIButton
    }

    private struct ModelIdentity: Equatable {
        let harness: String
        let model: String?
    }

    private var settingTarget: ModelIdentity {
        ModelIdentity(harness: selection.harness, model: catalog.modelInfo(for: selection)?.id ?? selection.model)
    }

    private var catalog: ModelCatalog
    private var selection: ModelSelection
    private let locked: Bool
    private var favorites = ModelFavorites.keys
    private var providers: [ModelCatalog.Provider] = []
    private var rows: [ModelPickerRow] = []
    private var groups: [ModelCatalog.SettingGroup]
    private var viewedTab: ModelPickerTab
    private var tabButtons: [TabButton] = []
    private var settingRows: [ModelSettingRow] = []
    private var didScrollInitially = false
    private var onDismiss: (() -> Void)?
    private let listPage = UIView()
    private weak var configPopup: ModelConfigViewController?
    private var configTarget: ModelIdentity?

    private let tabScroll = FadingScrollView()
    private let indicator = UIView()
    private let searchIcon = UIImageView(image: UIImage(systemName: "magnifyingglass", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)))
    private let searchField = UITextField()
    private let topRule = UIView()
    private let middleRule = UIView()
    private let bottomRule = UIView()
    private let emptyNote = UILabel()
    private let tray = UIScrollView()
    private var list: UICollectionView!
    private var cellRegistration: UICollectionView.CellRegistration<ModelRowCell, ModelPickerRow>!

    var onChange: ((ModelSelection) -> Void)?

    init(catalog: ModelCatalog, selection: ModelSelection, locked: Bool) {
        self.catalog = catalog
        self.selection = selection
        self.locked = locked
        self.groups = catalog.settingGroups(for: selection)
        self.viewedTab = !locked && !ModelFavorites.isEmpty ? .favorites : .provider(selection.harness)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityIdentifier = "model-picker"

        tabScroll.showsHorizontalScrollIndicator = false
        listPage.addSubview(tabScroll)
        indicator.backgroundColor = Palette.accent
        indicator.layer.cornerRadius = 1
        tabScroll.addSubview(indicator)

        for rule in [topRule, middleRule, bottomRule] {
            rule.backgroundColor = Palette.cardRule
            listPage.addSubview(rule)
        }

        searchIcon.tintColor = Palette.tertiary
        searchIcon.contentMode = .center
        listPage.addSubview(searchIcon)
        searchField.font = Fonts.ui(.sans, TypeScale.size(15.5))
        searchField.textColor = Palette.text
        searchField.tintColor = Palette.accent
        searchField.attributedPlaceholder = NSAttributedString(string: "Search models…", attributes: [.foregroundColor: Palette.tertiary])
        searchField.clearButtonMode = .whileEditing
        searchField.returnKeyType = .done
        searchField.autocorrectionType = .no
        searchField.autocapitalizationType = .none
        searchField.spellCheckingType = .no
        searchField.delegate = self
        searchField.accessibilityIdentifier = "model-search"
        searchField.addAction(UIAction { [weak self] _ in self?.reload(scrollingTo: .top) }, for: .editingChanged)
        listPage.addSubview(searchField)

        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.backgroundColor = .clear
        configuration.showsSeparators = false
        list = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
        list.backgroundColor = .clear
        list.keyboardDismissMode = .onDrag
        list.contentInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        list.dataSource = self
        list.delegate = self
        cellRegistration = UICollectionView.CellRegistration<ModelRowCell, ModelPickerRow> { [weak self] cell, _, row in
            guard let self else { return }
            let picked = self.isPicked(row)
            let starred = self.favorites.contains(.init(harness: row.harness, model: row.model.id))
            let configurable = !row.selectedOnly && (!self.locked || row.harness == self.selection.harness)
                && ModelCatalog.isConfiguredInPlace(row.model)
            cell.configure(row, picked: picked, starred: starred, twoLine: self.viewedTab == .favorites, configurable: configurable)
            cell.onStar = { [weak self] in self?.toggleStar(row) }
        }
        listPage.addSubview(list)

        emptyNote.font = Fonts.ui(.sans, TypeScale.size(13.5))
        emptyNote.textColor = Palette.secondary
        emptyNote.textAlignment = .center
        emptyNote.numberOfLines = 0
        emptyNote.isUserInteractionEnabled = false
        listPage.addSubview(emptyNote)
        tray.keyboardDismissMode = .onDrag
        listPage.addSubview(tray)
        listPage.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(listPage)
        NSLayoutConstraint.activate([
            listPage.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: ModelPickerMetrics.grabberClearance),
            listPage.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            listPage.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            listPage.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        reload()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutListPage()
    }

    private func layoutListPage() {
        let bounds = listPage.bounds
        let scale = max(1, traitCollection.displayScale)
        let line = 1 / scale
        let desiredTrayHeight = ModelPickerMetrics.trayHeight(groups.count)
        var y = bounds.minY
        tabScroll.frame = CGRect(x: bounds.minX, y: y, width: bounds.width, height: ModelPickerMetrics.tabs)
        y += ModelPickerMetrics.tabs
        topRule.frame = CGRect(x: bounds.minX, y: y, width: bounds.width, height: line)
        y += line
        searchIcon.frame = CGRect(x: bounds.minX + 10, y: y, width: 26, height: ModelPickerMetrics.search)
        searchField.frame = CGRect(x: bounds.minX + 42, y: y, width: max(0, bounds.width - 52), height: ModelPickerMetrics.search)
        y += ModelPickerMetrics.search
        middleRule.frame = CGRect(x: bounds.minX, y: y, width: bounds.width, height: line)
        y += line
        let bottomHeight = groups.isEmpty ? 0 : line
        // Keep a model row reachable even with a long options catalog or the
        // keyboard open; the pinned tray scrolls within the remaining budget.
        let trayHeight = min(desiredTrayHeight, max(0, bounds.maxY - y - bottomHeight - ModelPickerMetrics.compactRow))
        let listHeight = max(0, bounds.maxY - y - bottomHeight - trayHeight)
        list.frame = CGRect(x: bounds.minX, y: y, width: bounds.width, height: listHeight)
        emptyNote.frame = list.frame.insetBy(dx: min(20, list.frame.width / 2), dy: 0)
        y += listHeight
        bottomRule.isHidden = groups.isEmpty
        bottomRule.frame = CGRect(x: bounds.minX, y: y, width: bounds.width, height: line)
        y += bottomHeight
        tray.frame = CGRect(x: bounds.minX, y: y, width: bounds.width, height: trayHeight)
        tray.contentSize = CGSize(width: tray.bounds.width, height: desiredTrayHeight)
        for (index, row) in settingRows.enumerated() {
            row.frame = CGRect(x: 0, y: ModelPickerMetrics.trayPadding + CGFloat(index) * ModelPickerMetrics.settingRow, width: tray.bounds.width, height: ModelPickerMetrics.settingRow)
        }
        layoutTabs()
        if !didScrollInitially, listHeight > 0 {
            didScrollInitially = true
            scroll(to: .picked)
            revealViewedTab(animated: false)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { finishPresentation() }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        finishPresentation()
    }

    private func finishPresentation() {
        let finish = onDismiss
        onDismiss = nil
        finish?()
    }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(dismissOnEscape))]
    }

    @objc private func dismissOnEscape() {
        if let configPopup {
            configPopup.dismiss(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        dismissOnEscape()
        return true
    }

    func present(anchoredTo chip: UIView, holding composer: ComposerBar, over host: UIViewController) {
        guard host.presentedViewController == nil else { return }
        let focused = composer.textView.isFirstResponder
        composer.reveal(chip)
        composer.holdsCard = true
        composer.textView.resignFirstResponder()
        onDismiss = { [weak composer] in
            guard let composer else { return }
            if focused, composer.window != nil, !composer.textView.isFirstResponder { composer.becomeFirstResponder() }
            composer.holdsCard = false
        }
        modalPresentationStyle = .pageSheet
        preferredContentSize = CGSize(width: min(340, host.view.bounds.width - 24), height: idealHeight())
        if let sheet = sheetPresentationController {
            let compact = UISheetPresentationController.Detent.Identifier("model-picker")
            sheet.detents = [.custom(identifier: compact) { [weak self] context in
                min(self?.idealHeight() ?? context.maximumDetentValue, context.maximumDetentValue)
            }, .large()]
            sheet.selectedDetentIdentifier = compact
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = ModelPickerMetrics.cornerRadius
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
            sheet.prefersEdgeAttachedInCompactHeight = true
            sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = true
            sheet.delegate = self
        }
        host.present(self, animated: true)
    }

    /// Session snapshots can change the selected model while the drawer is
    /// open. Refresh the visible pick without sending that change back again.
    func update(selection next: ModelSelection) {
        guard next != selection, !locked || next.harness == selection.harness else { return }
        selection = next
        if isViewLoaded { reload() } else { groups = catalog.settingGroups(for: next) }
    }

    func update(catalog: ModelCatalog) {
        guard catalog != self.catalog else { return }
        self.catalog = catalog
        if isViewLoaded {
            reload()
        } else {
            groups = catalog.settingGroups(for: selection)
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        rows.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        collectionView.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: rows[indexPath.item])
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        !rows[indexPath.item].selectedOnly
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        let row = rows[indexPath.item]
        guard !row.selectedOnly, !locked || row.harness == selection.harness else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        commit(ModelSelection(harness: row.harness, model: row.model.id, effort: selection.effort, options: selection.options))
        if ModelCatalog.isConfiguredInPlace(row.model) { openCard() }
    }

    private func idealHeight() -> CGFloat {
        let rules = groups.isEmpty ? 2 : 3
        return ModelPickerMetrics.grabberClearance + ModelPickerMetrics.tabs + ModelPickerMetrics.search + ModelPickerMetrics.listIdeal
            + ModelPickerMetrics.trayHeight(groups.count) + CGFloat(rules) / max(1, traitCollection.displayScale)
    }

    private func isPicked(_ row: ModelPickerRow) -> Bool {
        guard row.harness == selection.harness else { return false }
        return row.model.id == (selection.model ?? providers.first(where: { $0.id == row.harness })?.models.first?.id)
    }

    private func show(_ tab: ModelPickerTab) {
        guard tab != viewedTab else { return }
        viewedTab = tab
        reload(scrollingTo: .picked)
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        if reduceMotion {
            layoutIndicator()
        } else {
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.layoutIndicator()
            }
        }
        revealViewedTab(animated: !reduceMotion)
    }

    private func toggleStar(_ row: ModelPickerRow) {
        UISelectionFeedbackGenerator().selectionChanged()
        ModelFavorites.toggle(.init(harness: row.harness, model: row.model.id))
        favorites = ModelFavorites.keys
        reload()
    }

    private func commit(_ next: ModelSelection) {
        guard next != selection else { return }
        selection = next
        onChange?(next)
        reload()
    }

    private func reload(scrollingTo mode: ScrollMode = .keep) {
        let oldTabs = providers.map(\.id)
        providers = catalog.tabs(for: selection, locked: locked)
        if case .provider(let id) = viewedTab, !providers.contains(where: { $0.id == id }) {
            viewedTab = .provider(selection.harness)
        }
        syncTabs(rebuild: oldTabs != providers.map(\.id))
        rows = ModelCatalog.rows(viewedTab, in: providers, query: searchField.text ?? "", selection: selection, favorites: favorites)
        list.reloadData()
        let query = (searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            emptyNote.text = "No models found"
        } else if viewedTab == .favorites {
            emptyNote.text = "No starred models yet — tap a row's star"
        } else {
            emptyNote.text = "No models"
        }
        emptyNote.isHidden = !rows.isEmpty
        syncTray()
        syncCard()
        if view.window != nil { scroll(to: mode) }
    }

    private func syncTabs(rebuild: Bool) {
        let wanted: [ModelPickerTab] = [.favorites] + providers.map { .provider($0.id) }
        if rebuild || tabButtons.map(\.tab) != wanted {
            tabButtons.forEach { $0.button.removeFromSuperview() }
            tabButtons = wanted.map { tab in
                var configuration = UIButton.Configuration.plain()
                configuration.contentInsets = .zero
                configuration.background.cornerRadius = 10
                configuration.background.backgroundInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
                let label: String
                let identifier: String
                switch tab {
                case .favorites:
                    configuration.image = UIImage(systemName: "star.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
                    label = "Favorites"
                    identifier = "model-tab-favorites"
                case .provider(let id):
                    configuration.image = BrandMarks.image(for: id, side: 17)
                    label = providers.first(where: { $0.id == id })?.label ?? harnessLabel(harness: id)
                    identifier = "model-tab-\(id)"
                }
                let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.show(tab) })
                button.accessibilityLabel = label
                button.accessibilityIdentifier = identifier
                button.configurationUpdateHandler = { button in
                    var update = button.configuration
                    update?.background.backgroundColor = button.isHighlighted ? Palette.controlFill : .clear
                    button.configuration = update
                }
                tabScroll.addSubview(button)
                return TabButton(tab: tab, button: button)
            }
        }
        for item in tabButtons {
            let selected = item.tab == viewedTab
            var configuration = item.button.configuration
            configuration?.baseForegroundColor = selected ? Palette.text : Palette.tertiary
            item.button.configuration = configuration
            if case .provider(let id) = item.tab {
                // Claude's cached mark is alwaysOriginal. Template only the
                // inactive tab so it uses the same muted shade as its peers.
                let image = BrandMarks.image(for: id, side: 17)
                item.button.configuration?.image = selected ? image : image?.withRenderingMode(.alwaysTemplate)
                item.button.accessibilityLabel = providers.first(where: { $0.id == id })?.label ?? harnessLabel(harness: id)
            }
            item.button.accessibilityTraits = selected ? [.button, .selected] : .button
        }
        view.setNeedsLayout()
    }

    private func layoutTabs() {
        for (index, item) in tabButtons.enumerated() {
            item.button.frame = CGRect(x: 6 + CGFloat(index) * ModelPickerMetrics.tabWidth, y: 0, width: ModelPickerMetrics.tabWidth, height: ModelPickerMetrics.tabs)
        }
        tabScroll.contentSize = CGSize(width: 12 + CGFloat(tabButtons.count) * ModelPickerMetrics.tabWidth, height: ModelPickerMetrics.tabs)
        layoutIndicator()
    }

    private func layoutIndicator() {
        guard let index = tabButtons.firstIndex(where: { $0.tab == viewedTab }) else { return }
        indicator.frame = CGRect(
            x: 6 + CGFloat(index) * ModelPickerMetrics.tabWidth + 11,
            y: ModelPickerMetrics.tabs - 2,
            width: 22,
            height: 2
        )
    }

    private func revealViewedTab(animated: Bool) {
        guard let index = tabButtons.firstIndex(where: { $0.tab == viewedTab }) else { return }
        let rect = CGRect(
            x: 6 + CGFloat(index) * ModelPickerMetrics.tabWidth,
            y: 0,
            width: ModelPickerMetrics.tabWidth,
            height: ModelPickerMetrics.tabs
        ).insetBy(dx: -12, dy: 0)
        tabScroll.scrollRectToVisible(rect, animated: animated)
    }

    private func syncTray() {
        let nextGroups = catalog.settingGroups(for: selection)
        let countChanged = groups.count != nextGroups.count
        groups = nextGroups
        while settingRows.count < groups.count {
            let row = ModelSettingRow()
            tray.addSubview(row)
            settingRows.append(row)
        }
        while settingRows.count > groups.count {
            settingRows.removeLast().removeFromSuperview()
        }
        for (index, group) in groups.enumerated() {
            settingRows[index].configure(group, menu: menu(for: group))
        }
        bottomRule.isHidden = groups.isEmpty
        if countChanged { updatePreferredHeight() }
    }

    /// A setting's native glass menu, tray and card alike.
    private func menu(for group: ModelCatalog.SettingGroup) -> UIMenu {
        let target = settingTarget
        let actions = group.choices.map { choice in
            UIAction(title: choice.label, subtitle: choice.isDefault ? "Default" : nil, state: choice.id == group.selected ? .on : .off) { [weak self] _ in
                guard let self, let current = self.currentGroup(group.setting, for: target),
                      current.choices.contains(where: { $0.id == choice.id }) else { return }
                self.commit(self.catalog.picking(choice.id, for: group.setting, in: self.selection))
            }
        }
        return UIMenu(title: group.label, options: .singleSelection, children: actions)
    }

    /// An open native menu can outlive a catalog refresh or a remote model
    /// change. Only apply its action to the model and choices it still owns.
    private func currentGroup(_ setting: ModelCatalog.Setting, for target: ModelIdentity) -> ModelCatalog.SettingGroup? {
        guard target == settingTarget else { return nil }
        let current = catalog.settingGroups(for: selection) + catalog.cardGroups(for: selection)
        return current.first { $0.setting == setting }
    }

    private func updatePreferredHeight() {
        let height = idealHeight()
        guard preferredContentSize.height != height else { return }
        preferredContentSize.height = height
        if let sheet = sheetPresentationController {
            if view.window != nil, !UIAccessibility.isReduceMotionEnabled {
                sheet.animateChanges { sheet.invalidateDetents() }
            } else {
                sheet.invalidateDetents()
            }
        }
        view.setNeedsLayout()
    }

    private func openCard() {
        guard presentedViewController == nil, !catalog.cardGroups(for: selection).isEmpty else { return }
        view.endEditing(true)
        view.layoutIfNeeded()
        let popup = ModelConfigViewController()
        let target = settingTarget
        popup.card.onToggle = { [weak self] group in
            guard let self, let current = self.currentGroup(group.setting, for: target),
                  current.isToggle, let next = current.toggledChoice else { return }
            self.commit(self.catalog.picking(next.id, for: group.setting, in: self.selection))
        }
        popup.configure(title: catalog.title(for: selection), groups: catalog.cardGroups(for: selection), menu: menu(for:))
        popup.modalPresentationStyle = .popover
        if let popover = popup.popoverPresentationController {
            popover.sourceView = list
            let rowBounds = rows.firstIndex(where: isPicked).flatMap {
                list.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame
            }
            let anchor = rowBounds?.intersection(list.bounds)
            popover.sourceRect = anchor.flatMap { $0.isEmpty || $0.isNull ? nil : $0 } ?? CGRect(x: list.bounds.midX, y: list.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = [.up, .down]
            popover.delegate = popup
        }
        configPopup = popup
        configTarget = target
        present(popup, animated: true)
    }

    /// The popover follows option picks and refreshed catalogs independently
    /// of the drawer. UIKit owns its outside-tap dismissal and focus return.
    private func syncCard() {
        guard let popup = configPopup else { return }
        let cardGroups = catalog.cardGroups(for: selection)
        guard configTarget == settingTarget, !cardGroups.isEmpty else {
            configPopup = nil
            configTarget = nil
            popup.dismiss(animated: true)
            return
        }
        popup.configure(title: catalog.title(for: selection), groups: cardGroups, menu: menu(for:))
    }

    private func scroll(to mode: ScrollMode) {
        guard !rows.isEmpty, list.bounds.height > 0 else { return }
        list.layoutIfNeeded()
        switch mode {
        case .keep:
            break
        case .top, .picked:
            if mode == .picked, let index = rows.firstIndex(where: isPicked) {
                list.scrollToItem(at: IndexPath(item: index, section: 0), at: .centeredVertically, animated: false)
            } else {
                list.setContentOffset(CGPoint(x: 0, y: -list.adjustedContentInset.top), animated: false)
            }
        }
    }
}

/// A fixed-height model row with its pick wash, attribution, and favorite star.
final class ModelRowCell: UICollectionViewListCell {
    var onStar: (() -> Void)?

    private let title = FadingLabel()
    private let attribution = FadingLabel()
    private let brand = UIImageView()
    private let provider = FadingLabel()
    private let star = UIButton(configuration: .plain())
    private let disclosure = UIImageView(image: UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)))
    private var picked = false
    private var twoLine = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        title.font = Fonts.ui(.sansMedium, TypeScale.size(15))
        title.textColor = Palette.text
        attribution.font = Fonts.ui(.sans, TypeScale.size(13))
        attribution.textColor = Palette.tertiary
        brand.contentMode = .scaleAspectFit
        brand.tintColor = Palette.secondary
        provider.font = Fonts.ui(.sans, TypeScale.size(12.5))
        provider.textColor = Palette.secondary
        disclosure.tintColor = Palette.tertiary
        disclosure.contentMode = .center
        var starConfiguration = UIButton.Configuration.plain()
        starConfiguration.contentInsets = .zero
        star.configuration = starConfiguration
        star.addAction(UIAction { [weak self] _ in self?.onStar?() }, for: .touchUpInside)
        for subview in [title, attribution, brand, provider, star, disclosure] as [UIView] { contentView.addSubview(subview) }
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        onStar = nil
    }

    override func preferredLayoutAttributesFitting(_ attrs: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        attrs.size.height = twoLine ? ModelPickerMetrics.twoLineRow : ModelPickerMetrics.compactRow
        return attrs
    }

    override func updateConfiguration(using state: UICellConfigurationState) {
        var background = UIBackgroundConfiguration.listCell().updated(for: state)
        background.backgroundColor = picked ? Palette.cardSelected : state.isHighlighted ? Palette.controlFill : .clear
        background.strokeColor = picked ? Palette.cardSelectedRing : .clear
        background.strokeWidth = picked ? 1 : 0
        background.cornerRadius = ModelPickerMetrics.cornerRadius
        background.backgroundInsets = NSDirectionalEdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6)
        backgroundConfiguration = background
    }

    func configure(_ row: ModelPickerRow, picked: Bool, starred: Bool, twoLine: Bool, configurable: Bool) {
        let pickedChanged = self.picked != picked
        self.picked = picked
        self.twoLine = twoLine
        disclosure.isHidden = !configurable
        title.text = row.model.label
        let description = row.model.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let showAttribution = row.ambiguous && !description.isEmpty && description.caseInsensitiveCompare(row.providerLabel) != .orderedSame
        attribution.text = showAttribution ? description : nil
        attribution.isHidden = !showAttribution
        brand.image = BrandMarks.image(for: row.harness, side: 12)
        provider.text = row.providerLabel
        brand.isHidden = !twoLine
        provider.isHidden = !twoLine
        var configuration = star.configuration
        configuration?.image = UIImage(systemName: starred ? "star.fill" : "star", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        configuration?.baseForegroundColor = starred ? Palette.warning : Palette.tertiary
        star.configuration = configuration
        star.isHidden = row.selectedOnly
        accessibilityLabel = [row.model.label, twoLine ? row.providerLabel : nil, showAttribution ? description : nil].compactMap { $0 }.joined(separator: ", ")
        accessibilityTraits = picked ? [.button, .selected] : .button
        accessibilityValue = starred ? "Favorite" : nil
        accessibilityIdentifier = "model-row-\(row.model.id)"
        accessibilityHint = configurable ? "Shows its settings" : nil
        accessibilityCustomActions = row.selectedOnly ? [] : [UIAccessibilityCustomAction(name: starred ? "Remove from Favorites" : "Add to Favorites") { [weak self] _ in
            self?.onStar?()
            return true
        }]
        if pickedChanged { setNeedsUpdateConfiguration() }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        let textX: CGFloat = 18
        let starX = bounds.width - 50
        star.frame = CGRect(x: starX, y: 0, width: 44, height: bounds.height)
        disclosure.frame = disclosure.isHidden ? .zero : CGRect(x: starX - 14, y: 0, width: 14, height: bounds.height)
        let available = max(0, (disclosure.isHidden ? starX : disclosure.frame.minX) - textX - 4)
        let k = TypeScale.factor
        let titleHeight = (20 * k).rounded()
        let lineHeight = (16 * k).rounded()
        let titleY = twoLine
            ? ((bounds.height - titleHeight - lineHeight) / 2).rounded()
            : (bounds.height - titleHeight) / 2
        if attribution.isHidden {
            title.frame = CGRect(x: textX, y: titleY, width: available, height: titleHeight)
            attribution.frame = .zero
        } else {
            let titleWidth = min(available * 0.65, ceil(title.sizeThatFits(CGSize(width: available, height: titleHeight)).width))
            title.frame = CGRect(x: textX, y: titleY, width: titleWidth, height: titleHeight)
            attribution.frame = CGRect(x: title.frame.maxX + 6, y: titleY, width: max(0, available - titleWidth - 6), height: titleHeight)
        }
        if twoLine {
            let providerY = title.frame.maxY
            brand.frame = CGRect(x: textX, y: (providerY + (lineHeight - 12) / 2).rounded(), width: 12, height: 12)
            provider.frame = CGRect(x: brand.frame.maxX + 5, y: providerY, width: max(0, available - 17), height: lineHeight)
        } else {
            brand.frame = .zero
            provider.frame = .zero
        }
    }
}

/// A full-width picked-model setting that opens its native glass menu.
final class ModelSettingRow: UIButton {
    private let name = UILabel()
    private let value = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.up.chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)))

    override init(frame: CGRect) {
        var configuration = UIButton.Configuration.plain()
        configuration.background.cornerRadius = 12
        configuration.background.backgroundInsets = NSDirectionalEdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6)
        super.init(frame: frame)
        self.configuration = configuration
        configurationUpdateHandler = { button in
            var update = button.configuration
            update?.background.backgroundColor = button.isHighlighted ? Palette.controlFill : .clear
            button.configuration = update
        }
        showsMenuAsPrimaryAction = true
        name.font = Fonts.ui(.sansMedium, TypeScale.size(15))
        name.textColor = Palette.text
        value.font = Fonts.ui(.sans, TypeScale.size(15))
        value.textColor = Palette.secondary
        value.textAlignment = .right
        chevron.tintColor = Palette.tertiary
        chevron.contentMode = .center
        for subview in [name, value, chevron] as [UIView] {
            subview.isUserInteractionEnabled = false
            addSubview(subview)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ group: ModelCatalog.SettingGroup, menu: UIMenu) {
        name.text = group.label
        value.text = group.selectedChoice?.label
        self.menu = menu
        accessibilityLabel = group.label
        accessibilityValue = group.selectedChoice?.label
        switch group.setting {
        case .effort: accessibilityIdentifier = "model-setting-effort"
        case .option(let id): accessibilityIdentifier = "model-setting-\(id)"
        }
        setNeedsLayout()
    }

    /// The menu opens from the value on the trailing side, not the row's
    /// leading edge.
    override func menuAttachmentPoint(for configuration: UIContextMenuConfiguration) -> CGPoint {
        CGPoint(x: chevron.frame.maxX, y: super.menuAttachmentPoint(for: configuration).y)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = self.bounds
        let chevronX = bounds.width - 30
        chevron.frame = CGRect(x: chevronX, y: 0, width: 12, height: bounds.height)
        let valueWidth = min(bounds.width / 2, ceil(value.sizeThatFits(CGSize(width: bounds.width / 2, height: bounds.height)).width))
        value.frame = CGRect(x: chevronX - 10 - valueWidth, y: 0, width: valueWidth, height: bounds.height)
        name.frame = CGRect(x: 18, y: 0, width: max(0, value.frame.minX - 28), height: bounds.height)
    }
}

/// A native glass popover even in compact width. It owns dismissal separately
/// from the model drawer and scrolls if the device cannot fit all settings.
final class ModelConfigViewController: UIViewController, UIPopoverPresentationControllerDelegate {
    let card = ModelConfigCard()
    private let scroll = UIScrollView()
    private var contentHeight: CGFloat = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityIdentifier = "model-config-card"
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.addSubview(card)
        view.addSubview(scroll)
    }

    func configure(title: String, groups: [ModelCatalog.SettingGroup], menu: (ModelCatalog.SettingGroup) -> UIMenu) {
        card.configure(title: title, groups: groups, menu: menu)
        let line = 1 / max(1, traitCollection.displayScale)
        contentHeight = ModelPickerMetrics.cardHeight(groups.count, line: line)
        preferredContentSize = CGSize(width: 304, height: contentHeight)
        viewIfLoaded?.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scroll.frame = view.bounds.inset(by: view.safeAreaInsets)
        card.frame = CGRect(x: 0, y: 0, width: scroll.bounds.width, height: contentHeight)
        scroll.contentSize = card.bounds.size
    }

    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        .none
    }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(dismissOnEscape))]
    }

    @objc private func dismissOnEscape() { dismiss(animated: true) }

    override func accessibilityPerformEscape() -> Bool {
        dismissOnEscape()
        return true
    }
}

/// Fusion's title, setting rows with native glass menus, and switches.
/// The title is a label; this popup has no navigation or back button.
final class ModelConfigCard: UIView {
    var onToggle: ((ModelCatalog.SettingGroup) -> Void)?
    let header = UILabel()
    private let rule = UIView()
    private var settingRows: [ModelSettingRow] = []
    private var toggleRows: [ModelToggleRow] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        header.font = Fonts.ui(.sansSemibold, TypeScale.size(15))
        header.textColor = Palette.text
        header.lineBreakMode = .byTruncatingTail
        header.accessibilityTraits = .header
        header.accessibilityIdentifier = "model-card-title"
        rule.backgroundColor = Palette.cardRule
        addSubview(header)
        addSubview(rule)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, groups: [ModelCatalog.SettingGroup], menu: (ModelCatalog.SettingGroup) -> UIMenu) {
        header.text = title
        let pickers = groups.filter { !$0.isToggle }
        let switches = groups.filter(\.isToggle)
        while settingRows.count < pickers.count {
            let row = ModelSettingRow()
            addSubview(row)
            settingRows.append(row)
        }
        while settingRows.count > pickers.count {
            settingRows.removeLast().removeFromSuperview()
        }
        for (index, group) in pickers.enumerated() {
            settingRows[index].configure(group, menu: menu(group))
        }
        while toggleRows.count < switches.count {
            let row = ModelToggleRow()
            addSubview(row)
            toggleRows.append(row)
        }
        while toggleRows.count > switches.count {
            toggleRows.removeLast().removeFromSuperview()
        }
        for (index, group) in switches.enumerated() {
            let row = toggleRows[index]
            row.configure(group)
            row.onChange = { [weak self] in self?.onToggle?(group) }
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let line = 1 / max(1, traitCollection.displayScale)
        header.frame = CGRect(x: 18, y: 0, width: max(0, bounds.width - 36), height: ModelPickerMetrics.settingRow)
        rule.frame = CGRect(x: 0, y: header.frame.maxY, width: bounds.width, height: line)
        var y = rule.frame.maxY + ModelPickerMetrics.trayPadding
        for row in settingRows {
            row.frame = CGRect(x: 0, y: y, width: bounds.width, height: ModelPickerMetrics.settingRow)
            y += ModelPickerMetrics.settingRow
        }
        for row in toggleRows {
            row.frame = CGRect(x: 0, y: y, width: bounds.width, height: ModelPickerMetrics.settingRow)
            y += ModelPickerMetrics.settingRow
        }
    }

}

/// A card switch (desktop `toggle_switch`), on at the option's non-default
/// choice.
final class ModelToggleRow: UIView {
    var onChange: (() -> Void)?
    private let name = UILabel()
    private let toggle = UISwitch()

    override init(frame: CGRect) {
        super.init(frame: frame)
        name.font = Fonts.ui(.sansMedium, TypeScale.size(15))
        name.textColor = Palette.text
        name.isAccessibilityElement = false
        toggle.onTintColor = Palette.accent
        toggle.addAction(UIAction { [weak self] _ in self?.onChange?() }, for: .valueChanged)
        addSubview(name)
        addSubview(toggle)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ group: ModelCatalog.SettingGroup) {
        name.text = group.label
        if toggle.isOn != group.isOn { toggle.setOn(group.isOn, animated: window != nil) }
        toggle.accessibilityLabel = group.label
        if case .option(let id) = group.setting {
            toggle.accessibilityIdentifier = "model-toggle-\(id)"
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = toggle.intrinsicContentSize
        toggle.frame = CGRect(
            x: bounds.width - 18 - size.width,
            y: ((bounds.height - size.height) / 2).rounded(),
            width: size.width,
            height: size.height
        )
        name.frame = CGRect(x: 18, y: 0, width: max(0, toggle.frame.minX - 28), height: bounds.height)
    }
}
