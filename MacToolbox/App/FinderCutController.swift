import AppKit
import ApplicationServices
import Carbon
import MacToolboxCore

@MainActor
final class FinderCutController {
    private unowned let coordinator: AppCoordinator
    private let reader = FinderSelectionReader()
    private var keys = FinderKeyboardState()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var finderFrontTimer: Timer?
    private var copyConfirmTimer: Timer?
    private var tapRetryTask: Task<Void, Never>?
    private var postInputTask: Task<Void, Never>?
    private var sampleTask: Task<Void, Never>?
    private var axObserver: AXObserver?
    private var axObserverSource: CFRunLoopSource?
    private var axObserverPID: pid_t?
    private var focus: FinderFocusSnapshot?
    private var generation: UInt64 = 0
    private var finderPID: pid_t?
    private var runningFinderPID: pid_t?
    private var tappedPID: pid_t?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var suspendedForSleep = false
    private var latencies: [Double] = []
    private var bridgeCopies = 0
    private var nativeMoves = 0
    private var copyConfirmations = 0
    private var loadedCutSound: NSSound?
    private var didLoadCutSound = false
    private var soundPlayRequests = 0
    private var lastCopyCheck: [String: Any] = [:]
    private var lastReset = "none"
    private(set) var isEnabled = false
    var available: Bool { tap != nil && tap.map { CGEvent.tapIsEnabled(tap: $0) } == true }
    var status: String {
        if !isEnabled { return "Finder 文件剪切已暂停" }
        return available ? "Finder 中 ⌘X 剪切文件，⌘V 移动" : "Finder 文件剪切需要辅助功能权限"
    }
    var diagnostics: [String: Any] {
        let sorted = latencies.sorted()
        let maximum = sorted.last ?? 0
        return ["enabled": isEnabled, "eventTapAvailable": available,
                "tapScope": "Finder-process", "tapProcessID": tappedPID ?? -1,
                "focusKind": focus.map { String(describing: $0.kind) } ?? "none",
                "selectedCount": focus?.selectedURLs.count ?? 0,
                "focusAgeMS": focus.map { (ProcessInfo.processInfo.systemUptime-$0.sampledAt)*1000 } ?? -1,
                "phase": phaseName, "bridgeCopies": bridgeCopies, "nativeMoves": nativeMoves,
                "copyConfirmations": copyConfirmations, "lastCopyCheck": lastCopyCheck, "lastReset": lastReset,
                "soundEnabled": coordinator.finderCutSoundEnabled, "soundAvailable": resolveCutSound() != nil,
                "soundPlayRequests": soundPlayRequests,
                "callbackP95MS": sorted.isEmpty ? 0 : sorted[min(sorted.count-1,Int(Double(sorted.count)*0.95))],
                "callbackMaxMS": maximum]
    }
    private var phaseName: String {
        switch keys.cut.phase { case .idle: "idle"; case .awaitingCopy: "awaitingCopy"; case .ready: "ready" }
    }

    init(coordinator: AppCoordinator) { self.coordinator = coordinator }

    func previewCutSound() { playCutSound() }

    private func resolveCutSound() -> NSSound? {
        if !didLoadCutSound {
            didLoadCutSound = true
            loadedCutSound = NSSound(named: NSSound.Name("Tink"))
        }
        return loadedCutSound
    }

    private func playCutSound() {
        guard let cutSound = resolveCutSound() else { return }
        cutSound.volume = 0.65
        cutSound.stop()
        if cutSound.play() { soundPlayRequests += 1 }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled { stop(); return }
        registerWorkspaceObservers()
        guard !suspendedForSleep else { return }
        resumeActiveWork()
    }

    func stop() {
        pauseActiveWork()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        runningFinderPID = nil
    }

    func setSuspendedForSleep(_ suspended: Bool) {
        guard suspendedForSleep != suspended else { return }
        suspendedForSleep = suspended
        if suspended {
            pauseActiveWork()
        } else if isEnabled {
            resumeActiveWork()
        }
    }

    func clipboardVersionChanged(_ count: Int) {
        switch keys.cut.phase {
        case .awaitingCopy:
            evaluateAwaitingCopy()
        case .ready(let token):
            if count != token.boundChangeCount {
                lastReset = "clipboard-changed"
                keys.invalidate()
                syncCopyConfirmTimer()
            }
        case .idle:
            break
        }
    }

    private func pauseActiveWork() {
        finderFrontTimer?.invalidate(); finderFrontTimer = nil
        stopCopyConfirmTimer()
        tapRetryTask?.cancel(); tapRetryTask = nil
        postInputTask?.cancel(); postInputTask = nil
        removeTap()
        removeAXObserver()
        invalidateFocus()
        keys.tapDisabled()
        finderPID = nil
    }

    private func resumeActiveWork() {
        runningFinderPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier
        ensureTapInstalled()
        frontChanged(frontPID: nil, frontBundleID: nil)
    }

    private func observeWorkspace(
        _ name: NSNotification.Name,
        handler: @escaping @MainActor @Sendable (pid_t?, String?) -> Void
    ) -> NSObjectProtocol {
        NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            let bundleID = app?.bundleIdentifier
            MainActor.assumeIsolated { handler(pid, bundleID) }
        }
    }

    private func registerWorkspaceObservers() {
        guard workspaceObservers.isEmpty else { return }
        workspaceObservers.append(observeWorkspace(NSWorkspace.didActivateApplicationNotification) { [weak self] pid, bundleID in
            self?.frontChanged(frontPID: pid, frontBundleID: bundleID)
        })
        workspaceObservers.append(observeWorkspace(NSWorkspace.didLaunchApplicationNotification) { [weak self] pid, bundleID in
            if bundleID == "com.apple.finder" { self?.finderLaunched(pid: pid) }
        })
        workspaceObservers.append(observeWorkspace(NSWorkspace.didTerminateApplicationNotification) { [weak self] pid, bundleID in
            self?.applicationTerminated(pid: pid, bundleID: bundleID)
        })
    }

    private func removeTap() {
        tapRetryTask?.cancel(); tapRetryTask = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }; tap = nil; source = nil
        tappedPID = nil
    }

    func invalidate() {
        if keys.cut.phase != .idle { lastReset = "own-interaction-or-write" }
        keys.invalidate()
        syncCopyConfirmTimer()
    }

    func permissionChanged() {
        if !coordinator.selection.permissionGranted { stop() }
        else if isEnabled { setEnabled(true) }
    }

    private func finderLaunched(pid: pid_t?) {
        guard isEnabled else { return }
        if let pid { runningFinderPID = pid }
        else { runningFinderPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier }
        guard !suspendedForSleep else { return }
        tapRetryTask?.cancel(); tapRetryTask = nil
        ensureTapInstalled()
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier == "com.apple.finder" {
            frontChanged(frontPID: front?.processIdentifier, frontBundleID: front?.bundleIdentifier)
        }
    }

    private func applicationTerminated(pid: pid_t?, bundleID: String?) {
        let matchesFinder = bundleID == "com.apple.finder"
            || (pid != nil && (pid == runningFinderPID || pid == tappedPID || pid == finderPID || pid == axObserverPID))
        guard matchesFinder else { return }
        runningFinderPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
            .first(where: { $0.processIdentifier != pid })?.processIdentifier
        if tappedPID != runningFinderPID {
            removeTap()
            keys.tapDisabled()
            syncCopyConfirmTimer()
            invalidateFocus()
        }
        if let pid, pid == axObserverPID || pid == finderPID {
            removeAXObserver()
            finderPID = nil
            invalidateFocus()
            updateFinderFrontTimer()
        }
        if isEnabled, !suspendedForSleep {
            ensureTapInstalled()
        }
    }

    private func frontChanged(frontPID: pid_t?, frontBundleID: String?) {
        guard isEnabled, !suspendedForSleep else {
            finderPID = nil
            removeAXObserver()
            updateFinderFrontTimer()
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        let resolvedBundleID = frontBundleID ?? front?.bundleIdentifier
        let resolvedPID = frontPID ?? front?.processIdentifier
        let newFinderPID = resolvedBundleID == "com.apple.finder" ? resolvedPID : nil
        if let newFinderPID { runningFinderPID = newFinderPID }
        if finderPID != newFinderPID {
            if keys.cut.phase != .idle { lastReset = "left-Finder" }
            keys.tapDisabled()
            syncCopyConfirmTimer()
            invalidateFocus()
            finderPID = newFinderPID
        }
        if let pid = finderPID {
            ensureTapInstalled()
            installAXObserver(pid: pid)
            sample()
        } else {
            removeAXObserver()
        }
        updateFinderFrontTimer()
    }

    private func ensureTapInstalled() {
        guard isEnabled, !suspendedForSleep, coordinator.selection.permissionGranted else { return }
        guard let targetPID = runningFinderPID else { return }
        if let tappedPID, tappedPID != targetPID {
            removeTap()
            keys.tapDisabled()
            syncCopyConfirmTimer()
            invalidateFocus()
        }
        guard tap == nil else { return }
        installTap(pid: targetPID)
        if tap != nil {
            tapRetryTask?.cancel(); tapRetryTask = nil
            return
        }
        guard tapRetryTask == nil else { return }
        tapRetryTask = Task { @MainActor [weak self] in
            for _ in 0..<3 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                guard self.isEnabled, !self.suspendedForSleep, self.tap == nil,
                      self.coordinator.selection.permissionGranted,
                      let retryPID = self.runningFinderPID else {
                    self.tapRetryTask = nil
                    return
                }
                self.installTap(pid: retryPID)
                if self.tap != nil { break }
            }
            self?.tapRetryTask = nil
        }
    }

    private func installAXObserver(pid: pid_t) {
        guard isEnabled, !suspendedForSleep, coordinator.selection.permissionGranted else { return }
        if axObserver != nil, axObserverPID == pid { return }
        removeAXObserver()
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            MainActor.assumeIsolated {
                Unmanaged<FinderCutController>.fromOpaque(refcon).takeUnretainedValue().handleAXNotification()
            }
        }
        var created: AXObserver?
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else { return }
        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let notifications = [
            kAXFocusedUIElementChangedNotification,
            kAXFocusedWindowChangedNotification,
            kAXMainWindowChangedNotification,
            kAXSelectedChildrenChangedNotification,
            kAXSelectedRowsChangedNotification,
            kAXValueChangedNotification,
        ]
        var registeredCount = 0
        for name in notifications {
            let err = AXObserverAddNotification(observer, appElement, name as CFString, refcon)
            if err == .success || err == .notificationAlreadyRegistered {
                registeredCount += 1
            }
        }
        guard registeredCount > 0 else { return }
        let runLoopSource = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        axObserver = observer
        axObserverSource = runLoopSource
        axObserverPID = pid
    }

    private func removeAXObserver() {
        if let axObserverSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), axObserverSource, .commonModes)
        }
        axObserverSource = nil
        axObserver = nil
        axObserverPID = nil
    }

    private func handleAXNotification() {
        guard isEnabled, !suspendedForSleep, finderPID != nil else { return }
        invalidateFocus()
        sample()
    }

    private func updateFinderFrontTimer() {
        if isEnabled, !suspendedForSleep, finderPID != nil {
            guard finderFrontTimer == nil else { return }
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.finderFrontTick() }
            }
            timer.tolerance = 0.25
            finderFrontTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else {
            finderFrontTimer?.invalidate()
            finderFrontTimer = nil
        }
    }

    private func finderFrontTick() {
        guard isEnabled, !suspendedForSleep, let pid = finderPID else {
            updateFinderFrontTimer()
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != "com.apple.finder" || front?.processIdentifier != pid {
            frontChanged(frontPID: front?.processIdentifier, frontBundleID: front?.bundleIdentifier)
            return
        }
        ensureTapInstalled()
        if axObserver == nil { installAXObserver(pid: pid) }
        if coordinator.ownInteraction {
            invalidate()
            invalidateFocus()
            return
        }
        let age = focus.map { ProcessInfo.processInfo.systemUptime - $0.sampledAt } ?? .infinity
        if age >= 0.8 { sample() }
        if case .ready(let token) = keys.cut.phase,
           coordinator.broker.changeCount != token.boundChangeCount {
            lastReset = "clipboard-changed"
            keys.invalidate()
            syncCopyConfirmTimer()
        }
    }

    private func syncCopyConfirmTimer() {
        if case .awaitingCopy = keys.cut.phase, isEnabled, !suspendedForSleep {
            guard copyConfirmTimer == nil else { return }
            let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluateAwaitingCopy() }
            }
            timer.tolerance = 0.01
            copyConfirmTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else {
            stopCopyConfirmTimer()
        }
    }

    private func stopCopyConfirmTimer() {
        copyConfirmTimer?.invalidate()
        copyConfirmTimer = nil
    }

    private func schedulePostInputSamples() {
        postInputTask?.cancel()
        postInputTask = Task { @MainActor [weak self] in
            for delay in [250, 200] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard let self, !Task.isCancelled, self.isEnabled, !self.suspendedForSleep,
                      self.finderPID != nil, !self.coordinator.ownInteraction else { return }
                self.sample()
            }
            self?.postInputTask = nil
        }
    }

    private func invalidateFocus() {
        generation &+= 1; focus = nil
        sampleTask?.cancel(); sampleTask = nil
        postInputTask?.cancel(); postInputTask = nil
    }

    private func sample() {
        guard sampleTask == nil, let pid = finderPID, !coordinator.ownInteraction else { return }
        let id = generation
        sampleTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = await self.reader.snapshot(pid: pid, generation: id)
            guard self.generation == id else { return }
            self.sampleTask = nil
            guard !Task.isCancelled, self.finderPID == pid else { return }
            self.focus = snapshot
        }
    }

    private func evaluateAwaitingCopy() {
        guard case .awaitingCopy(let pending) = keys.cut.phase else {
            stopCopyConfirmTimer()
            return
        }
        let count = coordinator.broker.changeCount
        let observation = count == pending.oldChangeCount
            ? (changeCount: count, urls: Optional<[URL]>.none)
            : coordinator.broker.fileObservation()
        let input = context()
        let confirmed = keys.observe(changeCount: observation.changeCount, fileURLs: observation.urls, context: input)
        if confirmed {
            copyConfirmations += 1
            // Clipboard confirmation fires once per cut; keep audio outside the event tap.
            if coordinator.finderCutSoundEnabled { playCutSound() }
        }
        if confirmed || keys.cut.phase == .idle {
            lastCopyCheck = ["confirmed": confirmed, "versionChanged": observation.changeCount != pending.oldChangeCount,
                "fileCount": observation.urls?.count ?? -1,
                "fileIdentityMatches": observation.urls.map { FinderCutState.fileDigest($0) == pending.fileDigest } ?? false,
                "focusKind": focus.map { String(describing: $0.kind) } ?? "none",
                "focusAgeMS": focus.map { (input.uptime-$0.sampledAt)*1000 } ?? -1,
                "expired": input.uptime > pending.deadline, "secureInput": input.secureInput]
        }
        syncCopyConfirmTimer()
    }

    private func context() -> FinderInputContext {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return FinderInputContext(focus: focus, generation: generation,
            finderIsFrontmost: finderPID != nil && front == finderPID, frontmostPID: front,
            ownInteractionActive: coordinator.ownInteraction, inputPermissionAvailable: available,
            secureInput: IsSecureEventInputEnabled(), uptime: ProcessInfo.processInfo.systemUptime,
            maxFocusAge: axObserver != nil ? 2.0 : 0.150)
    }

    private func installTap(pid: pid_t) {
        guard tap == nil else { return }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, pointer in
            guard let pointer else { return Unmanaged.passUnretained(event) }
            let decision = MainActor.assumeIsolated {
                let controller = Unmanaged<FinderCutController>.fromOpaque(pointer).takeUnretainedValue()
                return controller.handle(type, event)
            }
            switch decision {
            case .pass: return Unmanaged.passUnretained(event)
            case .drop: return nil
            case .rewrite(let key, let modifiers):
                guard let replacement = FinderKeyEvent.replacement(for: event, key: key, modifiers: modifiers) else {
                    MainActor.assumeIsolated {
                        Unmanaged<FinderCutController>.fromOpaque(pointer).takeUnretainedValue().keys.tapDisabled()
                    }
                    return Unmanaged.passUnretained(event)
                }
                // CoreGraphics releases a replacement event after dispatching its data.
                return Unmanaged.passRetained(replacement)
            }
        }
        // Attach the event tap directly to the running Finder process.
        guard let tap = CGEvent.tapCreateForPid(pid: pid, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        self.tap = tap
        tappedPID = pid
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> FinderKeyboardState.Decision {
        let start = ProcessInfo.processInfo.systemUptime
        defer {
            if latencies.count >= 512 { latencies.removeFirst(256) }
            latencies.append((ProcessInfo.processInfo.systemUptime-start)*1000)
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            keys.tapDisabled(); syncCopyConfirmTimer(); invalidateFocus()
            if isEnabled, !suspendedForSleep, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return .pass
        }
        if [.leftMouseDown, .leftMouseUp, .rightMouseDown].contains(type) {
            invalidateFocus(); sample(); schedulePostInputSamples(); return .pass
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .flagsChanged { sample(); return .pass }
        let key: FinderKeyboardState.Key = code == 7 ? .x : code == 8 ? .c : code == 9 ? .v : .other
        let modifiers = keyModifiers(event.flags)
        let decision: FinderKeyboardState.Decision
        if type == .keyUp {
            decision = keys.keyUp(key, modifiers: modifiers)
        } else {
            decision = keys.keyDown(key, modifiers: modifiers,
                repeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                context: context(), changeCount: coordinator.broker.changeCount)
            if case .rewrite(let mapped, _) = decision {
                if mapped == .c { bridgeCopies += 1 }
                if mapped == .v { nativeMoves += 1 }
            }
            // Navigation/rename/search invalidates cached AX focus before another command.
            if key == .other { invalidateFocus(); sample(); schedulePostInputSamples() }
        }
        syncCopyConfirmTimer()
        return decision
    }

    private func keyModifiers(_ flags: CGEventFlags) -> KeyModifiers {
        var result: KeyModifiers = []
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskSecondaryFn) { result.insert(KeyModifiers(rawValue: 16)) }
        return result
    }
}
