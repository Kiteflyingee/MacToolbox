import AppKit
import MacToolboxCore

@MainActor
final class AppCoordinator: NSObject, NSMenuDelegate {
    let directory: URL
    let history: HistoryStore
    let ingestor: HistoryIngestor
    let broker: ClipboardBroker
    let settings: TranslationSettingsStore
    let client = OpenAITranslationClient()
    let selection = SelectionObserver()
    lazy var captureController = CaptureController(coordinator: self)
    lazy var colorPicker = ColorPickerController(coordinator: self)
    lazy var finderCut = FinderCutController(coordinator: self)
    private var item: NSStatusItem?
    private var settingsWindow: SettingsWindow?
    private let preferences: UserDefaults
    lazy var captureShortcut = CaptureShortcutController(preferences: preferences) { [weak self] in
        guard let self, !self.captureIsActive else { return }
        self.captureAction?()
    }
    var translationTarget: TargetLanguage {
        get { preferences.string(forKey: "translationTarget").flatMap(TargetLanguage.init(rawValue:)) ?? .automatic }
        set { preferences.set(newValue.rawValue, forKey: "translationTarget") }
    }
    var screenPermissionRequested: Bool {
        get { preferences.bool(forKey: "screenPermissionRequested") }
        set { preferences.set(newValue, forKey: "screenPermissionRequested") }
    }
    var finderCutSoundEnabled: Bool {
        get { preferences.object(forKey: "finderCutSoundEnabled") as? Bool ?? true }
        set { preferences.set(newValue, forKey: "finderCutSoundEnabled") }
    }
    private var historyRows: [HistorySummary] = []
    private var refreshingHistory = false
    private var statusMenuOpen = false
    private var startupSecretsReady = false
    lazy var translation = TranslationController(coordinator: self)
    var captureIsActive = false
    var colorIsActive = false
    var captureAction: (() -> Void)?
    private var historyMenu: NSMenu? { item?.menu?.items.first { $0.identifier?.rawValue == "clipboardHistory" }?.submenu }
    var needsKeyAuthorization: Bool { !startupSecretsReady }
    var menuHistoryCount: Int { historyMenu?.items.filter { $0.representedObject is UUID }.count ?? 0 }
    var menuLayout: [String: [String]] {
        ["topLevel": item?.menu?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? [],
         "withSeparators": item?.menu?.items.map { $0.isSeparatorItem ? "---" : $0.title } ?? [],
         "checked": item?.menu?.items.filter { $0.state == .on }.map(\.title) ?? [],
         "submenus": item?.menu?.items.filter { $0.submenu != nil }.map(\.title) ?? []]
    }
    var status = "正在启动剪贴板监控…" { didSet { settingsWindow?.refreshStatus(); rebuildStatusMenu() } }
    var ownInteraction: Bool { statusMenuOpen || captureIsActive || colorIsActive || translation.isInteracting || (NSApp.isActive && settingsWindow?.window?.isKeyWindow == true) }

    init(arguments args: [String] = CommandLine.arguments) async throws {
        let defaultSecretService = "local.devkite.MacToolbox.translation"
        let secretService: String
        if let index = args.firstIndex(of: "--data-directory"), args.indices.contains(index+1) {
            directory = URL(fileURLWithPath: args[index+1], isDirectory: true)
            // A disposable profile must never collect another profile's credentials.
            secretService = defaultSecretService + ".profile." + ContentDigest(data: Data(directory.standardizedFileURL.path.utf8)).hex
        } else {
            directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("local.devkite.MacToolbox", isDirectory: true)
            secretService = defaultSecretService
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        history = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let lastSequence = await history.maximumSequence()
        ingestor = HistoryIngestor(store: history, lastSequence: lastSequence)
        let board: NSPasteboard
        if let index = args.firstIndex(of: "--pasteboard"), args.indices.contains(index+1) { board = NSPasteboard(name: .init(args[index+1])) }
        else { board = .general }
        broker = ClipboardBroker(pasteboard: board, ingestor: ingestor, lastSequence: lastSequence)
        settings = try TranslationSettingsStore(directory: directory,
            secrets: KeychainStore(service: secretService))
        preferences = UserDefaults(suiteName: secretService + ".preferences") ?? .standard
        super.init()
        broker.onExternalChange = { [weak self] count, text in self?.translation.externalCopy(count: count, text: text) }
        broker.onIssue = { [weak self] message in self?.status = message }
        broker.onUpdate = { [weak self] in self?.refreshHistory() }
        selection.isEnabled = preferences.object(forKey: "selectionTranslationEnabled") as? Bool ?? true
        selection.allowsSelection = { [weak self] in self?.ownInteraction == false }
        selection.onSelection = { [weak self] text, anchor, pid in self?.translation.selectedText(text, anchor: anchor, pid: pid) }
        selection.onPermissionChange = { [weak self] in self?.finderCut.permissionChanged(); self?.settingsWindow?.refreshStatus(); self?.rebuildStatusMenu() }
        selection.start()
        broker.onBeforeOwnWrite = { [weak self] in self?.finderCut.invalidate() }
        finderCut.setEnabled(preferences.object(forKey: "finderCutEnabled") as? Bool ?? true)
        captureAction = { [weak self] in self?.colorPicker.close(restoreFocus: false); self?.captureController.begin() }
        _ = captureShortcut
        do {
            if let digest = try await settings.validateStartupAndCollectUnusedKeys() { try await broker.registerSensitive(digest) }
            startupSecretsReady = true
        } catch { status = errorMessage(error) }
        historyRows = try await history.summaries()
        if startupSecretsReady, preferences.object(forKey: "clipboardMonitoringEnabled") as? Bool != false {
            do { try broker.resumeMonitoringIfAllowed(); status = "正在记录剪贴板 · 自动保留最近20条" }
            catch { status = errorMessage(error) }
        } else if startupSecretsReady { status = "剪贴板监控已暂停" }
    }

    func installMenu() {
        let mainMenu = NSMenu()
        let appMenu = NSMenu(); let appRoot = NSMenuItem(); appRoot.submenu = appMenu
        mainMenu.addItem(appRoot)
        let editMenu = NSMenu(title: "编辑"); let editRoot = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        editRoot.submenu = editMenu; mainMenu.addItem(editRoot)
        for (title, selector, key) in [("撤销", Selector(("undo:")), "z"), ("剪切", #selector(NSText.cut(_:)), "x"),
                                      ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"),
                                      ("全选", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(withTitle: title, action: selector, keyEquivalent: key)
        }
        NSApp.mainMenu = mainMenu
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item?.button?.image = StatusIcon.image()
        item?.button?.setAccessibilityLabel("MacToolbox 工具菜单")
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        guard let item, !statusMenuOpen else { return }
        item.button?.toolTip = "MacToolbox · \(status)"
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        let captureItem = NSMenuItem(title: "截图", action: #selector(capture), keyEquivalent: "")
        captureItem.target = self; captureItem.isEnabled = captureAction != nil; menu.addItem(captureItem)
        let history = NSMenu(title: "剪贴板记录")
        history.autoenablesItems = false
        let historyItem = NSMenuItem(title: "剪贴板记录", action: nil, keyEquivalent: "")
        historyItem.identifier = .init("clipboardHistory")
        historyItem.submenu = history; menu.addItem(historyItem)
        let heading = NSMenuItem(title: "最近记录 · \(historyRows.count)/20", action: nil, keyEquivalent: "")
        heading.isEnabled = false; history.addItem(heading)
        if historyRows.isEmpty {
            let empty = NSMenuItem(title: broker.isEnabled ? "还没有记录，复制内容后会显示在这里" : "请先开启剪贴板历史", action: nil, keyEquivalent: "")
            empty.isEnabled = false; history.addItem(empty)
        }
        for entry in historyRows {
            let singleLine = entry.summary.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let title = singleLine.isEmpty ? "空白文字" : String(singleLine.prefix(48)) + (singleLine.count > 48 ? "…" : "")
            let row = NSMenuItem(title: title, action: #selector(replayHistory(_:)), keyEquivalent: "")
            row.target = self; row.representedObject = entry.id
            row.toolTip = entry.summary + "\n" + entry.observedAt.formatted(date: .omitted, time: .shortened)
            row.isEnabled = entry.status != "unavailable"
            if let data = entry.thumbnail { row.image = NSImage(data: data) }
            else { row.image = NSImage(systemSymbolName: entry.kind == "files" ? "folder" : "doc.text", accessibilityDescription: nil) }
            row.image?.size = NSSize(width: 22, height: 22)
            history.addItem(row)
        }
        menu.addItem(.separator())
        for (title, action) in [("Command X", #selector(toggleFinderCut)),
                                ("划词翻译", #selector(toggleSelection)),
                                ("剪贴板历史", #selector(toggleMonitoring))] {
            let row = NSMenuItem(title: title, action: action, keyEquivalent: "")
            row.target = self; menu.addItem(row)
        }
        menu.addItem(.separator())
        let preferences = NSMenuItem(title: "偏好设置…", action: #selector(openSettings), keyEquivalent: ",")
        preferences.target = self; menu.addItem(preferences)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 MacToolbox", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        refreshFeatureChecks(menu); item.menu = menu
        // Preferences' application menu exposes the same controls as the status item.
        if let appMenu = menu.copy() as? NSMenu {
            appMenu.delegate = self
            NSApp.mainMenu?.items.first?.submenu = appMenu
        }
    }

    private func refreshFeatureChecks(_ menu: NSMenu) {
        for row in menu.items {
            if row.action == #selector(toggleFinderCut) {
                row.title = finderCut.isEnabled ? "Command X：已开启" : "Command X：已关闭"
                row.state = finderCut.isEnabled ? .on : .off; row.toolTip = finderCut.status
            }
            if row.action == #selector(toggleSelection) {
                row.title = selection.isEnabled ? "划词翻译：已开启" : "划词翻译：已关闭"
                row.state = selection.isEnabled ? .on : .off
                row.toolTip = selection.permissionGranted ? "鼠标划选文字后显示翻译按钮；WPS 等场景可复制文字后翻译，或使用截图翻译。" : "请在偏好设置中允许辅助功能。"
            }
            if row.action == #selector(toggleMonitoring) {
                row.title = broker.isEnabled ? "剪贴板历史：已开启" : "剪贴板历史：已关闭"
                row.state = broker.isEnabled ? .on : .off; row.toolTip = status
            }
        }
    }

    private func refreshHistory() {
        guard !refreshingHistory else { return }
        refreshingHistory = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.refreshingHistory = false }
            do { self.historyRows = try await self.history.summaries(); self.rebuildStatusMenu() }
            catch { self.status = errorMessage(error) }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshFeatureChecks(menu)
        statusMenuOpen = true; finderCut.invalidate(); translation.close(); refreshHistory()
    }
    func menuDidClose(_ menu: NSMenu) {
        statusMenuOpen = false
        Task { @MainActor [weak self] in self?.rebuildStatusMenu() }
    }

    @objc private func capture() { captureAction?() }
    @objc private func toggleMonitoring() { setMonitoring(!broker.isEnabled) }
    @objc private func toggleSelection() { setSelectionTranslation(!selection.isEnabled) }
    @objc private func toggleFinderCut() {
        let enabled = !finderCut.isEnabled
        preferences.set(enabled, forKey: "finderCutEnabled"); finderCut.setEnabled(enabled)
        if enabled, !selection.permissionGranted { selection.requestPermission(enableSelection: false) }
        settingsWindow?.refreshStatus(); rebuildStatusMenu()
    }
    @objc private func replayHistory(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.colorPicker.close(restoreFocus: false); self.captureController.close(restoreFocus: false)
                guard let entry = try await self.history.entry(id: id) else { self.refreshHistory(); return }
                try await self.broker.write(entry.snapshot.content, origin: .historyReplay)
            } catch { self.status = errorMessage(error) }
        }
    }
    @objc private func openSettings() { showSettings() }
    @objc private func quitApp() { finderCut.stop(); selection.stop(); colorPicker.close(restoreFocus: false); captureController.close(); broker.disable(); NSApp.terminate(nil) }

    func showSettings() {
        colorPicker.close(restoreFocus: false)
        captureController.suspendForSettings()
        translation.close()
        if settingsWindow == nil { settingsWindow = SettingsWindow(coordinator: self) }
        settingsWindow?.showWindow(nil); NSApp.activate(); settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    func setSelectionTranslation(_ enabled: Bool) {
        preferences.set(enabled, forKey: "selectionTranslationEnabled")
        selection.isEnabled = enabled
        if enabled, !selection.permissionGranted { selection.requestPermission() }
        if !enabled { translation.close() }
        settingsWindow?.refreshStatus(); rebuildStatusMenu()
    }

    func showHistory() {
        translation.close()
        item?.button?.performClick(nil)
    }

    func setMonitoring(_ enabled: Bool) {
        if enabled, !startupSecretsReady {
            status = "请先在设置中授权已保存的 Key，监控暂缓以避免记录 Key。"
            showSettings(); return
        }
        preferences.set(enabled, forKey: "clipboardMonitoringEnabled")
        do {
            if enabled { try broker.enableFromUserAction(); status = "正在记录剪贴板 · 自动保留最近20条" }
            else { broker.disable(); translation.close(); status = "剪贴板监控已暂停" }
        } catch { status = errorMessage(error) }
        settingsWindow?.refreshStatus()
    }

    func credentialsBecameAvailable() async throws {
        if let digest = try await settings.validateStartupAndCollectUnusedKeys() { try await broker.registerSensitive(digest) }
        startupSecretsReady = true
        if preferences.object(forKey: "clipboardMonitoringEnabled") as? Bool != false {
            try broker.resumeMonitoringIfAllowed(); status = "正在记录剪贴板 · 自动保留最近20条"
        } else { status = "剪贴板监控已暂停" }
    }
}
