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
    private var timer: Timer?
    private var sampleTask: Task<Void, Never>?
    private var focus: FinderFocusSnapshot?
    private var generation: UInt64 = 0
    private var finderPID: pid_t?
    private var tappedPID: pid_t?
    private var activationObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var latencies: [Double] = []
    private var bridgeCopies = 0
    private var nativeMoves = 0
    private var lastTapAttempt: TimeInterval = 0
    private var copyConfirmations = 0
    private let cutSound = NSSound(named: NSSound.Name("Tink"))
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
                "soundEnabled": coordinator.finderCutSoundEnabled, "soundAvailable": cutSound != nil,
                "soundPlayRequests": soundPlayRequests,
                "callbackP95MS": sorted.isEmpty ? 0 : sorted[min(sorted.count-1,Int(Double(sorted.count)*0.95))],
                "callbackMaxMS": maximum]
    }
    private var phaseName: String {
        switch keys.cut.phase { case .idle: "idle"; case .awaitingCopy: "awaitingCopy"; case .ready: "ready" }
    }

    init(coordinator: AppCoordinator) { self.coordinator = coordinator }

    func previewCutSound() { playCutSound() }

    private func playCutSound() {
        guard let cutSound else { return }
        cutSound.volume = 0.65
        cutSound.stop()
        if cutSound.play() { soundPlayRequests += 1 }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled { stop(); return }
        if activationObserver == nil {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.frontChanged() } }
            sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
                object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.invalidateFocus(); self?.keys.tapDisabled() } }
        }
        if timer == nil {
            let timer = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        }
        frontChanged(); tick()
    }

    func stop() {
        timer?.invalidate(); timer = nil; sampleTask?.cancel(); sampleTask = nil
        removeTap()
        for observer in [activationObserver, sleepObserver].compactMap({ $0 }) { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        activationObserver = nil; sleepObserver = nil
        invalidateFocus(); keys.tapDisabled()
    }

    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }; tap = nil; source = nil
        tappedPID = nil
    }

    func invalidate() { if keys.cut.phase != .idle { lastReset = "own-interaction-or-write" }; keys.invalidate() }

    func permissionChanged() {
        if !coordinator.selection.permissionGranted { stop() }
        else if isEnabled { setEnabled(true) }
    }

    private func frontChanged() {
        let front = NSWorkspace.shared.frontmostApplication
        let pid = front?.bundleIdentifier == "com.apple.finder" ? front?.processIdentifier : nil
        if finderPID != pid {
            if keys.cut.phase != .idle { lastReset = "left-Finder" }
            keys.tapDisabled(); invalidateFocus(); finderPID = pid
        }
        sample()
    }

    private func invalidateFocus() {
        generation &+= 1; focus = nil
        sampleTask?.cancel(); sampleTask = nil
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

    private func tick() {
        guard isEnabled else { return }
        let front = NSWorkspace.shared.frontmostApplication
        let currentPID = front?.bundleIdentifier == "com.apple.finder" ? front?.processIdentifier : nil
        if currentPID != finderPID { frontChanged() }
        let now = ProcessInfo.processInfo.systemUptime
        let runningFinder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier
        if let tappedPID, tappedPID != runningFinder {
            removeTap(); keys.tapDisabled(); invalidateFocus(); lastTapAttempt = 0
        }
        if tap == nil, let runningFinder, coordinator.selection.permissionGranted, now-lastTapAttempt >= 1 {
            lastTapAttempt = now; installTap(pid: runningFinder)
        }
        if coordinator.ownInteraction { invalidate(); invalidateFocus(); return }
        if let focus, ProcessInfo.processInfo.systemUptime-focus.sampledAt < 0.045 { }
        else { sample() }
        switch keys.cut.phase {
        case .awaitingCopy(let pending):
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
        case .ready(let token):
            if coordinator.broker.changeCount != token.boundChangeCount { lastReset = "clipboard-changed"; keys.invalidate() }
        case .idle: break
        }
    }

    private func context() -> FinderInputContext {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return FinderInputContext(focus: focus, generation: generation,
            finderIsFrontmost: finderPID != nil && front == finderPID, frontmostPID: front,
            ownInteractionActive: coordinator.ownInteraction, inputPermissionAvailable: available,
            secureInput: IsSecureEventInputEnabled(), uptime: ProcessInfo.processInfo.systemUptime)
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
        // REA: Command X's current listener attaches to the target application;
        // its global event-posting path is a separate legacy implementation.
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
            keys.tapDisabled(); invalidateFocus()
            if isEnabled, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return .pass
        }
        if [.leftMouseDown, .leftMouseUp, .rightMouseDown].contains(type) {
            invalidateFocus(); sample(); return .pass
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .flagsChanged { sample(); return .pass }
        let key: FinderKeyboardState.Key = code == 7 ? .x : code == 8 ? .c : code == 9 ? .v : .other
        let modifiers = keyModifiers(event.flags)
        let decision: FinderKeyboardState.Decision
        if type == .keyUp { decision = keys.keyUp(key, modifiers: modifiers) }
        else {
            decision = keys.keyDown(key, modifiers: modifiers,
                repeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                context: context(), changeCount: coordinator.broker.changeCount)
            if case .rewrite(let mapped, _) = decision {
                if mapped == .c { bridgeCopies += 1 }
                if mapped == .v { nativeMoves += 1 }
            }
            // Navigation/rename/search invalidates cached AX focus before another command.
            if key == .other { invalidateFocus(); sample() }
        }
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
