import AppKit
import Foundation
import MacToolboxCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?
    private var diagnosticTimer: Timer?
    private var reopenRequested = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                let coordinator = try await AppCoordinator()
                self.coordinator = coordinator
                coordinator.installMenu()
                #if DEBUG
                if CommandLine.arguments.contains("--dark-preview") { NSApp.appearance = NSAppearance(named: .darkAqua) }
                if CommandLine.arguments.contains("--light-preview") { NSApp.appearance = NSAppearance(named: .aqua) }
                #endif
                if CommandLine.arguments.contains("--capture-fixture") {
                    coordinator.selection.isEnabled = false
                    coordinator.finderCut.setEnabled(false)
                    coordinator.broker.disable()
                }
                #if DEBUG
                if let index = CommandLine.arguments.firstIndex(of: "--translation-fixture"), CommandLine.arguments.indices.contains(index+1) {
                    coordinator.selection.isEnabled = false
                    coordinator.finderCut.setEnabled(false)
                    coordinator.broker.disable()
                    let text = try String(contentsOfFile: CommandLine.arguments[index+1], encoding: .utf8)
                    let exportIndex = CommandLine.arguments.firstIndex(of: "--translation-preview-export")
                    let directory = exportIndex.flatMap { CommandLine.arguments.indices.contains($0+1) ? URL(fileURLWithPath: CommandLine.arguments[$0+1]) : nil }
                    if CommandLine.arguments.contains("--dark-preview") { NSApp.appearance = NSAppearance(named: .darkAqua) }
                    if CommandLine.arguments.contains("--light-preview") { NSApp.appearance = NSAppearance(named: .aqua) }
                    coordinator.translation.beginFixture(text: text, exportDirectory: directory)
                }
                #endif
                let args = CommandLine.arguments
                let isFixture = args.contains("--capture-fixture") || args.contains("--translation-fixture") || args.contains("--color-fixture")
                if reopenRequested || args.contains("--show-settings") || (!isFixture && !args.contains("--background") && !args.contains("--show-history")) {
                    coordinator.showSettings()
                }
                if let index = CommandLine.arguments.firstIndex(of: "--capture-fixture"), CommandLine.arguments.indices.contains(index+1) {
                    let png = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index+1]), options: .mappedIfSafe)
                    #if DEBUG
                    coordinator.captureAction = { [weak coordinator] in try? coordinator?.captureController.beginFixture(png: png) }
                    #endif
                    try coordinator.captureController.beginFixture(png: png)
                }
                if let index = CommandLine.arguments.firstIndex(of: "--color-fixture"), CommandLine.arguments.indices.contains(index+1) {
                    let png = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index+1]),options: .mappedIfSafe)
                    coordinator.colorPicker.beginFixture(png: png)
                }
                if let index = CommandLine.arguments.firstIndex(of: "--smoke-report"), CommandLine.arguments.indices.contains(index+1) {
                    let url = URL(fileURLWithPath: CommandLine.arguments[index+1])
                    try self.writeReport(coordinator, to: url)
                    if CommandLine.arguments.contains("--continuous-report") {
                        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self, weak coordinator] _ in
                            MainActor.assumeIsolated { if let coordinator { try? self?.writeReport(coordinator, to: url) } }
                        }
                        self.diagnosticTimer = timer; RunLoop.main.add(timer, forMode: .common)
                    }
                }
                if CommandLine.arguments.contains("--show-history") {
                    RunLoop.main.perform { MainActor.assumeIsolated { coordinator.showHistory() } }
                }
            } catch { showError("启动失败", "无法初始化本地数据。已有文件未被删除。\n\(errorMessage(error))") }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !CommandLine.arguments.contains("--capture-fixture"),!CommandLine.arguments.contains("--translation-fixture"),!CommandLine.arguments.contains("--color-fixture") else { return false }
        if let coordinator { coordinator.showSettings() }
        else { reopenRequested = true }
        return false
    }
    private func writeReport(_ coordinator: AppCoordinator, to url: URL) throws {
        let report: [String: Any] = ["bundleID": Bundle.main.bundleIdentifier ?? "",
            "bundlePath": Bundle.main.bundlePath, "pid": ProcessInfo.processInfo.processIdentifier,
            "monitoringEnabled": coordinator.broker.isEnabled, "menuHistoryCount": coordinator.menuHistoryCount,
            "menuLayout": coordinator.menuLayout, "selectionPermissionGranted": coordinator.selection.permissionGranted,
            "AXTrustedFlag": coordinator.selection.permissionReport.trustedFlag,
            "AXAPIResult": coordinator.selection.permissionReport.apiResult,
            "selection": coordinator.selection.diagnostics,
            "frontmostBundleID": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none",
            "ownInteraction": coordinator.ownInteraction,
            "finder": coordinator.finderCut.diagnostics,
            "capture": coordinator.captureController.diagnostics,
            "windows": NSApp.windows.map { ["title": $0.title, "visible": $0.isVisible,
                "x": $0.frame.minX, "y": $0.frame.minY,
                "width": $0.frame.width, "height": $0.frame.height] as [String: Any] }]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
withExtendedLifetime(appDelegate) { application.run() }
