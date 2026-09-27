import UIKit

private enum ModelPickerMetrics {
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
}

/// The desktop HarnessModel picker as a popover anchored to the composer's
/// model chip, with the same system Liquid Glass as the anchored Wallpaper
/// Effect action sheet. Favorites and provider tabs lead to scoped search, a
/// fixed-height model list with stars, and glass menus for the picked model's
/// settings. Picks keep it open like desktop; a tap outside closes it.
final class ModelPickerViewController: UIViewController, UIPopoverPresentationControllerDelegate, UICollectionViewDataSource, UICollectionViewDelegate, UITextFieldDelegate {
    private enum ScrollMode { case keep, top, picked }

    private struct TabButton {
        let tab: ModelPickerTab
        let button: UIButton
    }

    private var catalog: ModelCatalog
    private var selection: ModelSelection
    private let locked: Bool
    private var remembered: [String: String]
    private var favorites = ModelFavorites.keys
    private var providers: [ModelCatalog.Provider] = []
    private var rows: [ModelPickerRow] = []
    private var groups: [ModelCatalog.SettingGroup]
    private var viewedTab: ModelPickerTab
    private var tabButtons: [TabButton] = []
    private var settingRows: [ModelSettingRow] = []
    private var scrollMode: ScrollMode = .picked
    private var didScrollInitially = false
    private var onDismiss: (() -> Void)?

    private let tabScroll = FadingScrollView()
    private let indicator = UIView()
    private let searchIcon = UIImageView(image: UIImage(systemName: "magnifyingglass", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)))
    private let searchField = UITextField()
    private let topRule = UIView()
    private let middleRule = UIView()
    private let bottomRule = UIView()
    private let emptyNote = UILabel()
    private let tray = UIView()
    private var list: UICollectionView!
    private var cellRegistration: UICollectionView.CellRegistration<ModelRowCell, ModelPickerRow>!

    var onChange: ((ModelSelection) -> Void)?

    init(catalog: ModelCatalog, selection: ModelSelection, locked: Bool, remembered: [String: String] = [:]) {
        self.catalog = catalog
        self.selection = selection
        self.locked = locked
        self.remembered = remembered
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
        view.addSubview(tabScroll)
        indicator.backgroundColor = Palette.accent
        indicator.layer.cornerRadius = 1
        tabScroll.addSubview(indicator)

        for rule in [topRule, middleRule, bottomRule] {
            rule.backgroundColor = Palette.cardRule
            view.addSubview(rule)
        }

        searchIcon.tintColor = Palette.tertiary
        searchIcon.contentMode = .center
        view.addSubview(searchIcon)
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
        searchField.addAction(UIAction { [weak self] _ in
            self?.scrollMode = .top
            self?.reload()
        }, for: .editingChanged)
        view.addSubview(searchField)

        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.backgroundColor = .clear
        configuration.showsSeparators = false
        list = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
        list.backgroundColor = .clear
        list.contentInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        list.dataSource = self
        list.delegate = self
        cellRegistration = UICollectionView.CellRegistration<ModelRowCell, ModelPickerRow> { [weak self] cell, _, row in
            guard let self else { return }
            let picked = row.harness == self.selection.harness && row.model.id == self.pickedModel(in: row.harness)
            let starred = self.favorites.contains(.init(harness: row.harness, model: row.model.id))
            cell.configure(row, picked: picked, starred: starred, twoLine: self.viewedTab == .favorites)
            cell.onStar = { [weak self] in self?.toggleStar(row) }
        }
        view.addSubview(list)

        emptyNote.font = Fonts.ui(.sans, TypeScale.size(13.5))
        emptyNote.textColor = Palette.secondary
        emptyNote.textAlignment = .center
        emptyNote.numberOfLines = 0
        emptyNote.isUserInteractionEnabled = false
        view.addSubview(emptyNote)
        view.addSubview(tray)
        reload()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds.inset(by: view.safeAreaInsets)
        let scale = max(1, traitCollection.displayScale)
        let line = 1 / scale
        let trayHeight = ModelPickerMetrics.trayHeight(groups.count)
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
        let listHeight = max(0, bounds.maxY - y - bottomHeight - trayHeight)
        list.frame = CGRect(x: bounds.minX, y: y, width: bounds.width, height: listHeight)
        if listHeight > 0 {
            emptyNote.frame = list.frame.insetBy(dx: 20, dy: 0)
        } else {
            emptyNote.frame = list.frame
        }
        y += listHeight
        bottomRule.isHidden = groups.isEmpty
        bottomRule.frame = CGRect(x: bounds.minX, y: y, width: bounds.width, height: line)
        y += bottomHeight
        tray.frame = CGRect(x: bounds.minX, y: y, width: bounds.width, height: trayHeight)
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
        let finish = onDismiss
        onDismiss = nil
        finish?()
    }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(dismissOnEscape))]
    }

    @objc private func dismissOnEscape() {
        dismiss(animated: true)
    }

    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        .none
    }

    func present(anchoredTo chip: UIView, holding composer: ComposerBar, over host: UIViewController) {
        let focused = composer.textView.isFirstResponder
        composer.reveal(chip)
        composer.holdsCard = true
        onDismiss = { [weak composer] in
            guard let composer else { return }
            if focused, !composer.textView.isFirstResponder { composer.becomeFirstResponder() }
            composer.holdsCard = false
        }
        modalPresentationStyle = .popover
        preferredContentSize = CGSize(width: min(340, host.view.bounds.width - 24), height: idealHeight())
        guard let popover = popoverPresentationController else { return }
        popover.sourceView = chip
        popover.sourceRect = CGRect(x: 0, y: 0, width: min(chip.bounds.width, 44), height: chip.bounds.height)
        popover.permittedArrowDirections = [.down, .up]
        popover.delegate = self
        host.present(self, animated: true)
    }

    func update(catalog: ModelCatalog) {
        guard catalog != self.catalog else { return }
        self.catalog = catalog
        if isViewLoaded {
            scrollMode = .keep
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
        rememberCurrentModel()
        remembered[row.harness] = row.model.id
        commit(ModelSelection(harness: row.harness, model: row.model.id, effort: selection.effort, options: selection.options), scroll: .keep)
    }

    private func idealHeight() -> CGFloat {
        let rules = groups.isEmpty ? 2 : 3
        return ModelPickerMetrics.tabs + ModelPickerMetrics.search + ModelPickerMetrics.listIdeal
            + ModelPickerMetrics.trayHeight(groups.count) + CGFloat(rules) / max(1, traitCollection.displayScale)
    }

    private func pickedModel(in harness: String) -> String? {
        guard harness == selection.harness else { return nil }
        return selection.model ?? providers.first(where: { $0.id == harness })?.models.first?.id
    }

    private func rememberCurrentModel() {
        if let model = pickedModel(in: selection.harness) { remembered[selection.harness] = model }
    }

    private func show(_ tab: ModelPickerTab) {
        guard tab != viewedTab else { return }
        viewedTab = tab
        scrollMode = .picked
        if case .provider(let id) = tab, !locked, id != selection.harness {
            rememberCurrentModel()
            let provider = providers.first { $0.id == id }
            let model = remembered[id].flatMap { remembered in
                provider?.models.contains(where: { $0.id == remembered }) == true ? remembered : nil
            }
            commit(ModelSelection(harness: id, model: model, effort: selection.effort, options: selection.options), scroll: .picked)
        } else {
            reload()
        }
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
        scrollMode = .keep
        reload()
    }

    private func commit(_ next: ModelSelection, scroll: ScrollMode = .keep) {
        guard next != selection else { return }
        selection = next
        onChange?(next)
        scrollMode = scroll
        reload()
    }

    private func reload() {
        let oldTabs = providers.map(\.id)
        providers = catalog.tabs(for: selection, locked: locked)
        if case .provider(let id) = viewedTab, !providers.contains(where: { $0.id == id }) {
            viewedTab = .provider(selection.harness)
        }
        syncTabs(rebuild: oldTabs != providers.map(\.id))
        rows = ModelCatalog.rows(viewedTab, in: providers, query: searchField.text ?? "", selection: selection, favorites: favorites)
        list?.reloadData()
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
        if view.window != nil { scroll(to: scrollMode) }
        scrollMode = .keep
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
            let actions = group.choices.map { choice in
                UIAction(title: choice.label, subtitle: choice.isDefault ? "Default" : nil, state: choice.id == group.selected ? .on : .off) { [weak self] _ in
                    guard let self else { return }
                    self.commit(self.catalog.picking(choice.id, for: group.setting, in: self.selection))
                }
            }
            settingRows[index].configure(group, menu: UIMenu(title: group.label, options: .singleSelection, children: actions))
        }
        bottomRule.isHidden = groups.isEmpty
        if countChanged {
            preferredContentSize.height = idealHeight()
            view.setNeedsLayout()
        }
    }

    private func scroll(to mode: ScrollMode) {
        guard !rows.isEmpty, list.bounds.height > 0 else { return }
        list.layoutIfNeeded()
        switch mode {
        case .keep:
            break
        case .top:
            list.setContentOffset(CGPoint(x: 0, y: -list.adjustedContentInset.top), animated: false)
        case .picked:
            if let index = rows.firstIndex(where: { $0.harness == selection.harness && $0.model.id == pickedModel(in: $0.harness) }) {
                list.scrollToItem(at: IndexPath(item: index, section: 0), at: .centeredVertically, animated: false)
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
        var starConfiguration = UIButton.Configuration.plain()
        starConfiguration.contentInsets = .zero
        star.configuration = starConfiguration
        star.addAction(UIAction { [weak self] _ in self?.onStar?() }, for: .touchUpInside)
        for subview in [title, attribution, brand, provider, star] as [UIView] { contentView.addSubview(subview) }
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
        background.cornerRadius = 12
        background.backgroundInsets = NSDirectionalEdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6)
        backgroundConfiguration = background
    }

    func configure(_ row: ModelPickerRow, picked: Bool, starred: Bool, twoLine: Bool) {
        let pickedChanged = self.picked != picked
        self.picked = picked
        self.twoLine = twoLine
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
        let available = max(0, starX - textX - 4)
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
