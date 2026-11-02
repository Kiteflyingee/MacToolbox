import AppKit
import Foundation

public enum ClipboardAccessError: Error, Equatable, Sendable { case permission, changed, writeFailed, missingFiles(Int), unavailable }

@MainActor
public final class ClipboardBroker {
    public static let marker = NSPasteboard.PasteboardType("local.mactoolbox.write-id")
    private let pasteboard: NSPasteboard
    private let ingestor: HistoryIngestor
    private let codec = ImageCodec()
    private var ledger: ClipboardLedger
    private var observedCount: Int
    private var timer: Timer?
    private var polling = false
    private var legacyAllowed = false
    private var sensitive: Set<ContentDigest> = []
    public private(set) var isEnabled = false
    public var onExternalChange: ((Int, String?) -> Void)?
    public var onBeforeOwnWrite: (() -> Void)?
    public var onUpdate: (() -> Void)?
    public var onIssue: ((String) -> Void)?
    public var changeCount: Int { pasteboard.changeCount }

    public func copyAnnotations(_ annotations: [Annotation]) throws {
        let data = try AnnotationClipboard.encode(annotations)
        let item = NSPasteboardItem(), id = UUID()
        let type = NSPasteboard.PasteboardType(AnnotationClipboard.typeIdentifier)
        item.setData(data, forType: type); item.setString(id.uuidString, forType: Self.marker)
        onBeforeOwnWrite?()
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]), pasteboard.data(forType: type) == data else { throw ClipboardAccessError.writeFailed }
        observedCount = pasteboard.changeCount
        ledger.register(try WriteReceipt(id: id, origin: .annotationCopy, finalChangeCount: observedCount,
                                        fingerprint: ContentDigest(data: data)))
    }

    public func annotationsForPaste() throws -> [Annotation]? {
        if #available(macOS 15.4, *), pasteboard.accessBehavior == .ask || pasteboard.accessBehavior == .alwaysDeny {
            throw ClipboardAccessError.permission
        }
        guard let data = pasteboard.data(forType: .init(AnnotationClipboard.typeIdentifier)) else { return nil }
        return try AnnotationClipboard.decodeForPaste(data)
    }

    /// Read only while confirming Finder's native copy; does not consume history polling.
    public func fileObservation() -> (changeCount: Int, urls: [URL]?) {
        let count = pasteboard.changeCount
        if #available(macOS 15.4, *), pasteboard.accessBehavior == .ask || pasteboard.accessBehavior == .alwaysDeny {
            return (count, nil)
        }
        guard let items = pasteboard.pasteboardItems, !items.isEmpty, items.count <= AppLimits.fileCount else { return (count, nil) }
        let urls = items.compactMap { $0.string(forType: .fileURL).flatMap(URL.init(string:)) }
        guard pasteboard.changeCount == count, urls.count == items.count, urls.allSatisfy(FileReference.isSupportedURL) else { return (count, nil) }
        return (count, urls)
    }

    public init(pasteboard: NSPasteboard = .general, ingestor: HistoryIngestor, lastSequence: Int64) {
        self.pasteboard = pasteboard; self.ingestor = ingestor
        ledger = ClipboardLedger(lastSequence: lastSequence)
        observedCount = pasteboard.changeCount
    }

    public func enableFromUserAction() throws {
        if #available(macOS 15.4, *) {
            guard pasteboard.accessBehavior != .alwaysDeny else { throw ClipboardAccessError.permission }
            // One explicit read while the user is enabling, never a repeated background prompt.
            if let item = pasteboard.pasteboardItems?.first, let type = item.types.first { _ = item.data(forType: type) }
            guard pasteboard.accessBehavior != .ask, pasteboard.accessBehavior != .alwaysDeny else { throw ClipboardAccessError.permission }
        }
        try resumeMonitoringIfAllowed()
    }

    /// Startup never reads the previous contents or asks for new permission.
    public func resumeMonitoringIfAllowed() throws {
        if #available(macOS 15.4, *), pasteboard.accessBehavior == .ask || pasteboard.accessBehavior == .alwaysDeny {
            throw ClipboardAccessError.permission
        }
        legacyAllowed = true
        observedCount = pasteboard.changeCount // Do not record startup/previous contents.
        isEnabled = true
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    public func disable() {
        isEnabled = false; legacyAllowed = false
        timer?.invalidate(); timer = nil
        onBeforeOwnWrite?()
    }

    public func registerSensitive(_ digest: ContentDigest) async throws {
        sensitive.insert(digest)
        try await ingestor.registerSensitiveDigest(digest)
    }

    public func isSensitiveText(_ text: String) -> Bool { sensitive.contains(ContentDigest(data: Data(text.utf8))) }

    public func poll() async {
        guard isEnabled, legacyAllowed, !polling else { return }
        polling = true
        defer { polling = false }
        if #available(macOS 15.4, *), pasteboard.accessBehavior == .ask || pasteboard.accessBehavior == .alwaysDeny {
            disable(); onIssue?("剪贴板监控已暂停，请在设置中允许读取后重新启用。")
            return
        }
        let count = pasteboard.changeCount
        if count != observedCount {
            let raw: RawContent
            do { raw = try readRaw() }
            catch { observedCount = count; onExternalChange?(count, nil); onIssue?("这次剪贴板内容未能读取。请重新复制。"); return }
            guard pasteboard.changeCount == count else { return }
            observedCount = count
            let text: String?
            if case .ready(.text(let payload)) = raw, !sensitive.contains(payload.plainDigest) { text = payload.plain }
            else { text = nil }
            onExternalChange?(count, text)
            do {
                let sequence = try ledger.nextSequence()
                let hint = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                let codec = self.codec
                try await ingestor.enqueue(sequence: sequence, byteCount: raw.byteCount) {
                    let content: ClipboardContent
                    switch raw {
                    case .ready(let value): content = value
                    case .files(let urls):
                        let references = try urls.map { url -> FileReference in
                            let isLink = (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
                            return try FileReference(url: url, bookmark: isLink ? nil : try? url.bookmarkData(options: .minimalBookmark))
                        }
                        content = .files(references)
                    case .image(let data):
                        do { content = .image(try await codec.normalize(data)) }
                        catch { content = .unavailable(.tooLarge, summary: "图片过大或格式无法读取") }
                    }
                    return try ClipboardSnapshot(sequence: sequence, changeCount: count, frontmostAppHint: hint, content: content)
                }
            } catch { onIssue?("历史记录暂未保存，请检查存储空间或重新启用监控。") }
        }
        let events = await ingestor.takeEvents()
        if events.contains(where: { if case .failed = $0 { true } else { false } }) { onIssue?("历史保存失败，已有记录仍然保留。") }
        if !events.isEmpty { onUpdate?() }
    }

    public func write(_ content: ClipboardContent, origin: ClipboardOrigin) async throws {
        guard origin.isOwnWrite else { throw CoreError.invalidContent }
        try content.validate()
        onBeforeOwnWrite?()
        let id = UUID()
        var items: [NSPasteboardItem] = []
        switch content {
        case .text(let value):
            let item = NSPasteboardItem()
            item.setString(value.plain, forType: .string)
            if let data = value.rtf { item.setData(data, forType: .rtf) }
            if let data = value.html { item.setData(data, forType: .html) }
            items = [item]
        case .image(let value):
            let item = NSPasteboardItem(); item.setData(value.png, forType: .png); items = [item]
        case .files(let references):
            var missing = 0
            for reference in references {
                var url = reference.originalURL
                if let bookmark = reference.bookmark {
                    var stale = false
                    if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale) { url = resolved }
                }
                guard (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil else { missing += 1; continue }
                let item = NSPasteboardItem(); item.setString(url.absoluteString, forType: .fileURL); items.append(item)
            }
            guard missing == 0 else { throw ClipboardAccessError.missingFiles(missing) }
        case .unavailable: throw ClipboardAccessError.unavailable
        }
        items.first?.setString(id.uuidString, forType: Self.marker)
        pasteboard.clearContents()
        guard pasteboard.writeObjects(items) else { throw ClipboardAccessError.writeFailed }
        let count = pasteboard.changeCount
        // Check the exact representations, as well as marker and ownership version.
        guard let actual = pasteboard.pasteboardItems, actual.count == items.count else { throw ClipboardAccessError.changed }
        for (expected, received) in zip(items, actual) {
            for type in expected.types where expected.data(forType: type) != received.data(forType: type) { throw ClipboardAccessError.changed }
        }
        guard pasteboard.changeCount == count else { throw ClipboardAccessError.changed }
        ledger.register(try WriteReceipt(id: id, origin: origin, finalChangeCount: count, fingerprint: content.fingerprint))
        observedCount = count // Explicit ingestion below; polling must not ingest it again.
        if origin.recordsHistory {
            do {
                let sequence = try ledger.nextSequence()
                try await ingestor.enqueue(ClipboardSnapshot(sequence: sequence, changeCount: count, content: content))
            } catch { onIssue?("已复制，但这条历史未能保存。已有记录仍然保留。") }
        }
        onUpdate?()
    }

    private enum RawContent: Sendable {
        case ready(ClipboardContent), image(Data), files([URL])
        var byteCount: Int { switch self { case .ready(let value): value.byteCount; case .image(let data): data.count; case .files(let urls): urls.reduce(0) { $0+$1.absoluteString.utf8.count } } }
    }

    private func readRaw() throws -> RawContent {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return .ready(.unavailable(.unsupported, summary: "空剪贴板")) }
        let files = items.compactMap { $0.string(forType: .fileURL).flatMap(URL.init(string:)) }
        if !files.isEmpty {
            guard files.count == items.count, files.count <= AppLimits.fileCount else { return .ready(.unavailable(.unsupported, summary: "无法完整记录这一组文件")) }
            guard FinderCutState.fileDigest(files) != nil else { return .ready(.unavailable(.tooLarge, summary: "文件记录过大")) }
            return .files(files)
        }
        guard items.count == 1, let item = items.first else { return .ready(.unavailable(.unsupported, summary: "暂不支持的混合内容")) }
        if item.types.contains(.png) || item.types.contains(.tiff) {
            guard let data = item.data(forType: item.types.contains(.png) ? .png : .tiff) else { throw ClipboardAccessError.unavailable }
            return data.count <= AppLimits.imageBytes ? .image(data) : .ready(.unavailable(.tooLarge, summary: "图片超过16MiB"))
        }
        if let text = item.string(forType: .string) {
            let content = ClipboardContent.text(TextPayload(plain: text, rtf: item.data(forType: .rtf), html: item.data(forType: .html)))
            do { try content.validate(); return .ready(content) }
            catch { return .ready(.unavailable(.tooLarge, summary: "文字超过1MiB")) }
        }
        return .ready(.unavailable(.unsupported, summary: "暂不支持的剪贴板格式"))
    }
}
