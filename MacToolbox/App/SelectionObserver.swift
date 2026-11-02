import AppKit
import ApplicationServices
import MacToolboxCore

@MainActor
final class SelectionObserver {
    private let reader = SelectionReader()
    private let permissionProbe = AccessibilityProbe()
    private var permissionTimer: Timer?
    private var permissionCheckRunning = false
    private var reinstallRequested = false
    private var promptRequested = false
    private var hasPrompted = false
    private var monitor: Any?
    private var task: Task<Void, Never>?
    private var downPoint: NSPoint?
    private var generation = UUID()
    private var mouseDowns = 0
    private var mouseUps = 0
    private var reads = 0
    private var delivered = 0
    private var lastRead = "idle"
    private var lastSourceBundleID = "none"
    #if DEBUG
    var probeSourceBundleIDs: Set<String>?
    #endif
    var isEnabled = true
    private(set) var permissionGranted = AXIsProcessTrusted()
    private(set) var permissionReport = AccessibilityReport(trustedFlag: false, apiResult: -25211)
    var onSelection: ((String, NSPoint, pid_t) -> Void)?
    var allowsSelection: (() -> Bool)?
    var onPermissionChange: (() -> Void)?
    var diagnostics: [String: Any] {
        ["enabled": isEnabled, "monitorInstalled": monitor != nil, "mouseDowns": mouseDowns,
         "mouseUps": mouseUps, "selectionReads": reads, "delivered": delivered, "lastRead": lastRead,
         "lastSourceBundleID": lastSourceBundleID]
    }

    func start() {
        if permissionTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshPermission() }
            }
            permissionTimer = timer; RunLoop.main.add(timer, forMode: .common)
        }
        refreshPermission()
        installMonitor()
    }

    func refreshPermission(forceReinstall: Bool = false, requestIfDenied: Bool = false) {
        reinstallRequested = reinstallRequested || forceReinstall
        promptRequested = promptRequested || requestIfDenied
        guard !permissionCheckRunning else { return }
        permissionCheckRunning = true
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let front = NSWorkspace.shared.frontmostApplication
        let target = front?.processIdentifier == ownPID
            ? NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier
            : front?.processIdentifier
        Task { @MainActor [weak self] in
            guard let self else { return }
            let report = await self.permissionProbe.check(processID: target)
            self.permissionCheckRunning = false
            let forceReinstall = self.reinstallRequested, requestIfDenied = self.promptRequested
            self.reinstallRequested = false; self.promptRequested = false
            let changed = self.permissionGranted != report.canRead
            self.permissionReport = report; self.permissionGranted = report.canRead
            if changed || forceReinstall {
                self.removeMonitor()
                if report.canRead { self.installMonitor() }
                self.onPermissionChange?()
            }
            if requestIfDenied, !report.canRead {
                if !self.hasPrompted {
                    self.hasPrompted = true
                    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                }
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
            }
        }
    }

    private func installMonitor() {
        guard permissionGranted else { return }
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            let isDown = event.type == .leftMouseDown, clicks = event.clickCount
            let eventPoint = event.cgEvent?.location
            MainActor.assumeIsolated {
                guard let self else { return }
                let top = NSScreen.screens.first?.frame.maxY ?? 0
                let point = eventPoint.map { CGPoint(x: $0.x,y: top-$0.y) } ?? NSEvent.mouseLocation
                if isDown {
                    self.mouseDowns += 1
                    self.task?.cancel(); self.generation = UUID(); self.downPoint = point
                } else {
                    self.mouseUps += 1
                    let distance = self.downPoint.map { hypot(point.x-$0.x, point.y-$0.y) } ?? 0
                    guard distance >= 3 || clicks >= 2 else { return }
                    self.read(at: point)
                }
            }
        }
    }

    func requestPermission(enableSelection: Bool = true) {
        if enableSelection { isEnabled = true }
        refreshPermission(forceReinstall: true, requestIfDenied: true)
    }

    func stop() {
        permissionTimer?.invalidate(); permissionTimer = nil
        removeMonitor()
    }
    private func removeMonitor() {
        task?.cancel(); generation = UUID()
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
    }

    private func read(at anchor: NSPoint) {
        guard isEnabled else { lastRead = "disabled"; return }
        guard permissionGranted else { lastRead = "permission-unavailable"; return }
        guard allowsSelection?() == true else { lastRead = "own-interaction"; return }
        guard let source = NSWorkspace.shared.frontmostApplication,
              source.processIdentifier != ProcessInfo.processInfo.processIdentifier else { lastRead = "source-changed"; return }
        lastSourceBundleID = source.bundleIdentifier ?? "unknown"
        #if DEBUG
        if let allowed = probeSourceBundleIDs,!allowed.contains(source.bundleIdentifier ?? "") { lastRead = "probe-app-excluded"; return }
        #endif
        let pid = source.processIdentifier
        let id = generation
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let hitPoint = CGPoint(x: anchor.x,y: top-anchor.y)
        task = Task { @MainActor [weak self] in
            for delay in [140,180] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard let self,!Task.isCancelled,self.generation == id,self.allowsSelection?() == true,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                self.reads += 1
                let outcome = await self.reader.readSelection(processID: pid,at: hitPoint)
                guard !Task.isCancelled,self.generation == id,self.allowsSelection?() == true,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                self.lastRead = outcome.status
                if let text = outcome.text {
                    self.delivered += 1
                    self.onSelection?(text,anchor,pid)
                    return
                }
                if outcome.status == "secure-field" { return }
            }
        }
    }
}
