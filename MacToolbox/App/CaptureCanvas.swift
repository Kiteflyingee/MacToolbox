import AppKit
import MacToolboxCore

@MainActor
final class CaptureCanvas: NSView {
    enum Tool: CaseIterable, Hashable {
        case pointer, arrow, shape, number, remark, text, highlight, pen, pixelate, blur, magnifier
        var title: String {
            switch self {
            case .pointer: "选择与移动"; case .arrow: "箭头与线条"; case .shape: "形状"; case .number: "步骤编号"
            case .remark: "备注"; case .text: "文字"; case .highlight: "突出区域"; case .pen: "画笔与荧光笔"
            case .pixelate: "马赛克"; case .blur: "模糊"; case .magnifier: "放大镜"
            }
        }
        var symbol: String {
            switch self {
            case .pointer: "cursorarrow"; case .arrow: "arrow.up.right"; case .shape: "square.on.circle"
            case .number: "1.circle"; case .remark: "text.bubble"; case .text: "textformat"
            case .highlight: "viewfinder"; case .pen: "pencil.tip"; case .pixelate: "square.grid.3x3.fill"
            case .blur: "drop.halffull"; case .magnifier: "plus.magnifyingglass"
            }
        }
    }
    private enum Gesture { case draw, moveCrop, resizeCrop(Int), moveObject(Annotation), resizeObject(Annotation, Int), arrowControl(Annotation), rotateObject(Annotation, Double) }
    weak var controller: CaptureController?
    let pixels: PixelSize
    private let image: NSImage
    private let source: CGImage?
    var editedImage: NSImage?
    var selection = CGRect.zero
    var windowRegions: [CGRect] = []
    var isEditing = false, isBusy = false
    var selectedID: UUID? { didSet { needsDisplay = true } }
    var tool = Tool.arrow { didSet { selectedID = nil; installToolbar(); needsDisplay = true } }
    var style = AnnotationStyle()
    private var shape = ShapeKind.rectangle
    private var pixelStrength = PixelStrength.medium
    private var blurStrength = BlurStrength.gaussian
    private var magnification = Magnification.two
    private var highlighter = false, brushMask = false
    private enum ColorTarget: Equatable { case annotation, background, outline }
    private var colorTarget = ColorTarget.annotation
    private static let fontFamilies = NSFontManager.shared.availableFontFamilies.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    private var aspectRatio: CGFloat?
    private var start = CGPoint.zero, current = CGPoint.zero, hover = CGPoint(x: -1000,y: -1000)
    private var originalSelection = CGRect.zero
    private var points: [CGPoint] = []
    private var gesture: Gesture?
    private var spaceHeld = false
    private var toolbar: CaptureBar?
    private var stylePanel: CaptureStylePanel?
    private var toolButtons: [Tool: CaptureButton] = [:]
    private var hoverHint: CaptureSurface?
    private var hoverTask: Task<Void,Never>?
    private var closeStyleTask: Task<Void,Never>?
    private var stylePinned = false
    private var manualToolbarOrigin: CGPoint?
    var chromeBounds = CGRect.zero
    private var controlBounds: CGRect { chromeBounds.isEmpty ? bounds : chromeBounds }
    var toolbarDiagnostics: [String: Any] {
        ["rows": toolbar == nil ? 0 : 1,"groups": ["标注工具","高级工具","操作工具"],
         "customGlyphsLoaded": CaptureIcons.loadedGlyphCount,"stylePanelVisible": stylePanel != nil,
         "stylePanelBelowToolbar": stylePanel?.appearsBelow == true,
         "frame": toolbar.map { [$0.frame.minX,$0.frame.minY,$0.frame.width,$0.frame.height] } ?? [],
         "safeBounds": [controlBounds.minX,controlBounds.minY,controlBounds.width,controlBounds.height],
         "lineWidth": style.lineWidth]
    }
    private var tracking: NSTrackingArea?
    private var hoveredWindow: CGRect?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private var selectionWasDragged = false
    private(set) var selectionMouseDownCount = 0
    private(set) var lastSelectionWasDrag = false

    init(frame: CGRect, image: NSImage, pixels: PixelSize) {
        self.image = image; self.pixels = pixels
        source = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        super.init(frame: frame)
        setAccessibilityLabel("截图编辑器：拖动选择区域，边缘可调整。工具栏提供标注、复制、保存与翻译。")
    }
    required init?(coder: NSCoder) { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: isEditing && tool == .pointer ? .arrow : .crosshair) }
    func pixelRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX/bounds.width*CGFloat(pixels.width), y: rect.minY/bounds.height*CGFloat(pixels.height),
               width: rect.width/bounds.width*CGFloat(pixels.width), height: rect.height/bounds.height*CGFloat(pixels.height))
    }
    func viewRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX/CGFloat(pixels.width)*bounds.width, y: rect.minY/CGFloat(pixels.height)*bounds.height,
               width: rect.width/CGFloat(pixels.width)*bounds.width, height: rect.height/CGFloat(pixels.height)*bounds.height)
    }
    func annotationRect(_ rect: CGRect) -> CGRect { pixelRect(rect).offsetBy(dx: -pixelRect(selection).minX, dy: -pixelRect(selection).minY) }
    func objectRect(_ rect: CGRect) -> CGRect { viewRect(rect.offsetBy(dx: pixelRect(selection).minX, dy: pixelRect(selection).minY)) }
    private func pixelPoint(_ point: CGPoint) -> CGPoint { annotationRect(CGRect(origin: point, size: .zero)).origin }
    private func point(_ event: NSEvent, clippedTo rect: CGRect? = nil) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil), clip = rect ?? bounds
        return CGPoint(x: max(clip.minX, min(p.x, clip.maxX)), y: max(clip.minY, min(p.y, clip.maxY)))
    }
    private var gestureRect: CGRect {
        var end = current
        if let ratio = aspectRatio, !isEditing {
            let width = min(abs(end.x-start.x), abs(end.y-start.y)*ratio)
            end = CGPoint(x: start.x+(end.x >= start.x ? width : -width), y: start.y+(end.y >= start.y ? width/ratio : -width/ratio))
        }
        return CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(start.x-end.x), height: abs(start.y-end.y))
    }
    private func handles(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX,y: rect.minY), CGPoint(x: rect.midX,y: rect.minY), CGPoint(x: rect.maxX,y: rect.minY),
         CGPoint(x: rect.maxX,y: rect.midY), CGPoint(x: rect.maxX,y: rect.maxY), CGPoint(x: rect.midX,y: rect.maxY),
         CGPoint(x: rect.minX,y: rect.maxY), CGPoint(x: rect.minX,y: rect.midY)]
    }
    private func handle(at p: CGPoint, rect: CGRect) -> Int? { handles(rect).firstIndex { hypot($0.x-p.x, $0.y-p.y) <= 7 } }
    private func resized(_ rect: CGRect, handle: Int, to p: CGPoint) -> CGRect {
        var left = rect.minX, right = rect.maxX, top = rect.minY, bottom = rect.maxY
        if [0,6,7].contains(handle) { left = min(p.x, right-4) }
        if [2,3,4].contains(handle) { right = max(p.x, left+4) }
        if [0,1,2].contains(handle) { top = min(p.y, bottom-4) }
        if [4,5,6].contains(handle) { bottom = max(p.y, top+4) }
        return CGRect(x: left, y: top, width: right-left, height: bottom-top)
    }
    private var selected: Annotation? { controller?.annotations.first { $0.id == selectedID } }
    override func mouseMoved(with event: NSEvent) {
        hover = point(event)
        if !isEditing { hoveredWindow = windowRegions.first { $0.contains(hover) } }
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) { hover = CGPoint(x: -1000,y: -1000); needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        guard !isBusy else { return }
        hideStylePanel(); hideHint()
        window?.makeKey(); window?.makeFirstResponder(self); start = point(event); current = start
        selectionWasDragged = false
        if !isEditing { selectionMouseDownCount += 1 }
        originalSelection = selection; points = [start]
        if !isEditing { hoveredWindow = windowRegions.first { $0.contains(start) } }
        if isEditing {
            if let selected,selected.canRotate {
                let knob = rotationHandle(selected), rect = objectRect(selected.bounds)
                if hypot(start.x-knob.x,start.y-knob.y) <= 9 {
                    gesture = .rotateObject(selected,atan2(start.y-rect.midY,start.x-rect.midX)); return
                }
            }
            if let selected, case .arrow(_, _, let control) = selected.geometry {
                let c = objectRect(CGRect(origin: control, size: .zero)).origin
                if hypot(start.x-c.x, start.y-c.y) <= 7 { gesture = .arrowControl(selected); return }
            }
            if let selected, let index = handle(at: start, rect: objectRect(selected.bounds)) {
                gesture = .resizeObject(selected, index); return
            }
            if let index = handle(at: start, rect: selection) { gesture = .resizeCrop(index); toolbar?.isHidden = true; return }
            guard selection.contains(start) else { selectedID = nil; return }
            if spaceHeld { gesture = .moveCrop; toolbar?.isHidden = true; return }
            if tool == .pointer {
                let p = pixelPoint(start)
                let value = controller?.annotations.reversed().first { $0.bounds.insetBy(dx: -5,dy: -5).contains(p) }
                selectedID = value?.id
                if let value,event.clickCount >= 2 {
                    switch value.geometry {
                    case .text,.remark: style = value.style; controller?.editText(at: start,annotation: value); return
                    default: break
                    }
                }
                if let value { adoptToolOptions(value); gesture = .moveObject(value) }
                installToolbar(); return
            }
            if tool == .text || tool == .remark { controller?.editText(at: start); return }
            if tool == .number {
                let p = pixelPoint(start)
                let number = (controller?.annotations.compactMap { if case .numbered(let n, _, _, _, _) = $0.geometry { return n }; return nil }.max() ?? 0)+1
                controller?.commit(Annotation(geometry: .numbered(number, center: p, label: "", labelBox: CGRect(x: p.x,y: p.y,width: 1,height: 1), connector: p), style: style)); return
            }
            selectedID = nil
        }
        gesture = .draw
    }
    override func mouseDragged(with event: NSEvent) {
        guard let gesture, !isBusy else { return }
        let previousPoint = current
        current = point(event)
        if !isEditing, hypot(current.x-start.x,current.y-start.y) >= 3 { selectionWasDragged = true }
        if case .draw = gesture,!isEditing,spaceHeld {
            let dx = max(-selection.minX,min(current.x-previousPoint.x,bounds.maxX-selection.maxX))
            let dy = max(-selection.minY,min(current.y-previousPoint.y,bounds.maxY-selection.maxY))
            start.x += dx; start.y += dy
            current = CGPoint(x: previousPoint.x+dx,y: previousPoint.y+dy)
        }
        let dx = current.x-start.x, dy = current.y-start.y
        switch gesture {
        case .rotateObject(let value,let initial):
            let rect = objectRect(value.bounds)
            var angle = value.rotation+atan2(current.y-rect.midY,current.x-rect.midX)-initial
            if event.modifierFlags.contains(.shift) { angle = (angle/(Double.pi/12)).rounded()*Double.pi/12 }
            if let rotated = try? value.rotated(to: angle) { controller?.previewEdit(rotated) }
        case .moveCrop:
            selection = originalSelection.offsetBy(dx: max(-originalSelection.minX,min(dx,bounds.maxX-originalSelection.maxX)),
                dy: max(-originalSelection.minY,min(dy,bounds.maxY-originalSelection.maxY)))
        case .resizeCrop(let index): selection = resized(originalSelection, handle: index, to: current).intersection(bounds)
        case .moveObject(var value):
            value.geometry = value.geometry.translated(x: dx*CGFloat(pixels.width)/bounds.width, y: dy*CGFloat(pixels.height)/bounds.height)
            controller?.previewEdit(value)
        case .resizeObject(var value, let index):
            let old = value.bounds
            let new = annotationRect(resized(objectRect(old), handle: index, to: point(event, clippedTo: selection)))
            if let geometry = try? value.geometry.resized(from: old, to: new) { value.geometry = geometry; controller?.previewEdit(value) }
        case .arrowControl(var value):
            if case .arrow(let a, let b, _) = value.geometry {
                value.geometry = .arrow(start: a, end: b, control: pixelPoint(point(event, clippedTo: selection)))
                controller?.previewEdit(value)
            }
        case .draw:
            if points.count < 50_000 { points.append(point(event, clippedTo: isEditing ? selection : bounds)) }
            if !isEditing { selection = gestureRect }
            if isEditing,[Tool.pixelate,.blur,.magnifier,.highlight].contains(tool),let value = draftAnnotation() {
                controller?.previewDrawing(value)
            }
        }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let gesture, !isBusy else { return }
        current = point(event); self.gesture = nil
        switch gesture {
        case .moveCrop, .resizeCrop: controller?.select(selection)
        case .moveObject, .resizeObject, .arrowControl, .rotateObject: controller?.finishEdit()
        case .draw:
            if !isEditing {
                lastSelectionWasDrag = selectionWasDragged || hypot(current.x-start.x,current.y-start.y) >= 3
                if !lastSelectionWasDrag { selection = hoveredWindow ?? bounds }
                else { selection = gestureRect }
                if selection.width >= 2, selection.height >= 2 { controller?.select(selection) }
            } else {
                controller?.finishDrawing(hypot(current.x-start.x,current.y-start.y) >= 2 ? draftAnnotation() : nil)
            }
        }
        needsDisplay = true
    }
    private func draftAnnotation() -> Annotation? {
        let a = pixelPoint(start), b = pixelPoint(pointInSelection(current))
        let box = annotationRect(CGRect(x: min(start.x,pointInSelection(current).x), y: min(start.y,pointInSelection(current).y), width: abs(start.x-pointInSelection(current).x), height: abs(start.y-pointInSelection(current).y)))
        let geometry: AnnotationGeometry
        switch tool {
        case .arrow: geometry = .arrow(start: a, end: b, control: CGPoint(x: (a.x+b.x)/2,y: (a.y+b.y)/2))
        case .shape: geometry = .shape(shape, box: box, rotation: 0)
        case .pen: geometry = .stroke(Array((points+[pointInSelection(current)]).prefix(50_000)).map(pixelPoint), highlighter: highlighter)
        case .highlight: geometry = .highlight(box)
        case .pixelate: geometry = .effect(.pixelate(pixelStrength), brushMask ? .brush((points+[pointInSelection(current)]).map(pixelPoint), width: max(12, style.lineWidth*8)) : .rectangle(box))
        case .blur: geometry = .effect(.blur(blurStrength), brushMask ? .brush((points+[pointInSelection(current)]).map(pixelPoint), width: max(12,style.lineWidth*8)) : .rectangle(box))
        case .magnifier: geometry = .magnifier(source: a, lens: box, scale: magnification)
        default: return nil
        }
        let value = Annotation(geometry: geometry, style: style)
        return (try? value.validate()) != nil ? value : nil
    }
    private func pointInSelection(_ p: CGPoint) -> CGPoint { CGPoint(x: max(selection.minX,min(p.x,selection.maxX)), y: max(selection.minY,min(p.y,selection.maxY))) }
    override func cancelOperation(_ sender: Any?) { if stylePanel != nil { hideStylePanel() } else { controller?.close() } }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil); return }
        guard !isBusy else { return }
        if event.keyCode == 49 { spaceHeld = true; NSCursor.openHand.set(); return }
        if event.modifierFlags.contains(.command) {
            switch event.keyCode {
            case 6: event.modifierFlags.contains(.shift) ? controller?.redo() : controller?.undo()
            case 8: isEditing ? controller?.copySelected() : controller?.copyPointerColor(hex(at: hover))
            case 9: controller?.pasteAnnotations()
            case 1: controller?.output(.save)
            default: super.keyDown(with: event)
            }
        } else if event.keyCode == 51 || event.keyCode == 117 { controller?.deleteSelected() }
        else if event.keyCode == 36 { controller?.output(.copy) }
        else if event.charactersIgnoringModifiers?.lowercased() == "c" { controller?.copyPointerColor(hex(at: hover)) }
        else { super.keyDown(with: event) }
    }
    override func keyUp(with event: NSEvent) { if event.keyCode == 49 { spaceHeld = false; window?.invalidateCursorRects(for: self) } else { super.keyUp(with: event) } }
    @objc func undo(_ sender: Any?) { controller?.undo() }
    @objc func redo(_ sender: Any?) { controller?.redo() }
    @objc func copy(_ sender: Any?) { controller?.copySelected() }
    @objc func paste(_ sender: Any?) { controller?.pasteAnnotations() }
    func setBusy(_ busy: Bool) {
        isBusy = busy
        if busy { hideStylePanel(); hideHint(); hoverTask?.cancel() }
        if !busy { installToolbar(); return }
        func enable(_ view: NSView) { if let button = view as? NSButton { button.isEnabled = !busy }; for child in view.subviews { enable(child) } }
        if let toolbar { enable(toolbar) }
    }

    func installToolbar() {
        guard isEditing else { return }
        let restorePanel = stylePanel != nil
        let wasPinned = stylePinned
        hoverTask?.cancel(); closeStyleTask?.cancel(); hideHint(); hideStylePanel()
        toolbar?.removeFromSuperview()
        toolButtons.removeAll()
        let tools: [NSView] = [toolButton(.pointer),toolButton(.remark),toolButton(.number),
            toolButton(.shape),toolButton(.arrow),toolButton(.text),
            toolButton(.highlight),toolButton(.pen),toolButton(.pixelate),toolButton(.magnifier)]
        let selection = CaptureButton("选区与尺寸",symbol: "crop") { [weak self] in self?.showSelectionMenu() }
        let color = CaptureButton("取色 · C 复制指针颜色",symbol: "eyedropper") { [weak self] in self?.controller?.output(.color) }
        let translate = CaptureButton("翻译截图",symbol: "character.bubble") { [weak self] in self?.controller?.output(.translate) }
        let advanced = [selection,color,translate]
        let actions: [(String,String,() -> Void)] = [
            ("撤销 · ⌘Z","arrow.uturn.backward",{ [weak self] in self?.controller?.undo() }),
            ("重做 · ⇧⌘Z","arrow.uturn.forward",{ [weak self] in self?.controller?.redo() }),
            ("关闭 · Esc","xmark",{ [weak self] in self?.controller?.close() }),
            ("保存 · ⌘S","square.and.arrow.down",{ [weak self] in self?.controller?.output(.save) }),
            ("完成并复制截图 · Return","checkmark",{ [weak self] in self?.controller?.output(.copy) })]
        let actionButtons = actions.map { CaptureButton($0.0,symbol: $0.1,action: $0.2) }
        actionButtons[0].isEnabled = controller?.canUndo == true
        actionButtons[1].isEnabled = controller?.canRedo == true
        actionButtons[2].tint = .systemRed; actionButtons[3].tint = .systemBlue
        actionButtons[4].primary = true
        for button in advanced+actionButtons { configureHover(button) }
        var controls: [NSView] = [CaptureGrip()]
        controls += tools; controls.append(divider()); controls += advanced
        controls.append(divider()); controls += actionButtons
        let row = stack(controls,horizontal: true,spacing: 2)
        let bar = CaptureBar(rows: [row])
        bar.movementBounds = controlBounds
        bar.frame = ToolbarPlacement.toolbar(size: bar.frame.size,selection: self.selection,bounds: controlBounds)
        if let origin = manualToolbarOrigin {
            bar.frame = ToolbarPlacement.clamped(CGRect(origin: origin,size: bar.frame.size),to: controlBounds)
        }
        bar.onMoved = { [weak self,weak bar] in self?.manualToolbarOrigin = bar?.frame.origin; self?.hideStylePanel(); self?.hideHint() }
        addSubview(bar); toolbar = bar
        bar.layoutSubtreeIfNeeded()
        if restorePanel,let anchor = toolButtons[selected.map { toolFor($0.geometry) } ?? tool] { showStylePanel(from: anchor,pinned: wasPinned) }
        window?.invalidateCursorRects(for: self)
    }

    private func toolButton(_ value: Tool,kind: ShapeKind? = nil) -> CaptureButton {
        let symbol = kind == .ellipse ? "circle" : value.symbol
        let title = kind == .ellipse ? "椭圆与圆形" : value == .pixelate ? "马赛克与模糊" : value.title
        let button = CaptureButton(title,symbol: symbol) { [weak self] in
            guard let self else { return }
            let actual = value == .pixelate && self.tool == .blur ? Tool.blur : value
            let sameTool = self.tool == actual && (kind == nil || kind == self.shape)
            let open = !sameTool || self.stylePanel == nil
            if let kind { self.shape = kind }
            if !sameTool || self.selected == nil { self.controller?.changeTool(actual) }
            if (value != .pointer || self.selected != nil),open,let anchor = self.toolButtons[value] { self.showStylePanel(from: anchor) }
            else { self.hideStylePanel() }
        }
        button.selected = (tool == value || value == .pixelate && tool == .blur) && (kind == nil || kind == shape)
        if value != .shape || kind == .rectangle || button.selected { toolButtons[value] = button }
        if value == .pixelate { toolButtons[.blur] = button }
        configureHover(button,styleTool: value)
        return button
    }

    private func configureHover(_ button: CaptureButton,styleTool: Tool? = nil) {
        button.toolTip = nil
        button.onHover = { [weak self,weak button] entered in
            guard let self,let button else { return }
            self.hoverTask?.cancel(); self.hideHint()
            guard entered else { self.scheduleStyleClose(); return }
            self.closeStyleTask?.cancel()
            self.hoverTask = Task { @MainActor [weak self,weak button] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self,let button,!Task.isCancelled,button.superview != nil else { return }
                if let styleTool,(styleTool == self.tool && styleTool != .pointer || self.selected != nil && styleTool == .pointer) {
                    self.showStylePanel(from: button,pinned: false)
                } else { self.showHint(button.helpText,from: button) }
            }
        }
    }

    private func showHint(_ text: String,from button: CaptureButton) {
        guard stylePanel == nil,let toolbar else { return }
        let title = label(text,size: 11)
        let view = CaptureSurface(frame: CGRect(x: 0,y: 0,width: title.fittingSize.width+18,height: 27))
        title.frame = CGRect(x: 9,y: 6,width: title.fittingSize.width,height: 16); view.addSubview(title)
        let anchor = convert(button.bounds,from: button)
        view.frame = ToolbarPlacement.panel(size: view.frame.size,anchor: anchor,toolbar: toolbar.frame,bounds: controlBounds).frame
        addSubview(view); hoverHint = view
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            view.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in context.duration = 0.12; view.animator().alphaValue = 1 }
        }
    }
    private func hideHint() { hoverHint?.removeFromSuperview(); hoverHint = nil }
    private func scheduleStyleClose() {
        guard !stylePinned else { return }
        closeStyleTask?.cancel()
        closeStyleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }; self?.hideStylePanel()
        }
    }
    private func hideStylePanel() { stylePanel?.removeFromSuperview(); stylePanel = nil; stylePinned = false; closeStyleTask?.cancel() }
    private func showStylePanel(from button: CaptureButton,pinned: Bool = true) {
        if !pinned,stylePinned,stylePanel != nil { return }
        guard let toolbar else { return }
        let activeTool = selected.map { toolFor($0.geometry) } ?? tool
        guard activeTool != .pointer else { return }
        hideHint(); stylePanel?.removeFromSuperview(); closeStyleTask?.cancel(); stylePinned = pinned
        let colors = NSMenu()
        if ![Tool.pixelate,.blur].contains(activeTool) {
            for (name,color) in [("红色",RGBAColor.red),("黄色",RGBAColor(red: 1,green: 0.75,blue: 0.1)),("绿色",RGBAColor(red: 0.2,green: 0.85,blue: 0.45)),("蓝色",RGBAColor(red: 0.2,green: 0.6,blue: 1)),("白色",RGBAColor(red: 1,green: 1,blue: 1)),("黑色",RGBAColor(red: 0,green: 0,blue: 0))] {
                colors.addItem(CaptureMenuItem(name,checked: style.color == color) { [weak self] in self?.style.color = color; self?.applyStyle() })
            }
            colors.addItem(CaptureMenuItem("自定义颜色…") { [weak self] in self?.chooseColor() })
        }
        let panel = CaptureStylePanel(title: activeTool.title,menu: styleMenu(),colorMenu: colors.items.isEmpty ? nil : colors,color: style.color.nsColor,
            background: style.text.background?.nsColor,outline: style.text.outline?.nsColor,
            maxWidth: controlBounds.width-16,
            onInteraction: { [weak self] in self?.stylePinned = true })
        let anchor = convert(button.bounds,from: button)
        let placement = ToolbarPlacement.panel(size: panel.frame.size,anchor: anchor,toolbar: toolbar.frame,bounds: controlBounds)
        panel.frame = placement.frame; panel.appearsBelow = placement.below; panel.arrowX = anchor.midX-panel.frame.minX
        panel.onHover = { [weak self] entered in if entered { self?.closeStyleTask?.cancel() } else { self?.scheduleStyleClose() } }
        addSubview(panel); stylePanel = panel
        controller?.exportFixture()
    }
    private func divider() -> NSView {
        let view = NSView(); view.wantsLayer = true; view.layer?.backgroundColor = NSColor.separatorColor.cgColor
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true; view.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return view
    }
    #if DEBUG
    func exportToolbar(to url: URL) {
        guard let toolbar,let bitmap = toolbar.bitmapImageRepForCachingDisplay(in: toolbar.bounds) else { return }
        toolbar.cacheDisplay(in: toolbar.bounds,to: bitmap)
        if let png = bitmap.representation(using: .png,properties: [:]) { try? png.write(to: url,options: .atomic) }
    }
    func exportStylePanel(to url: URL) {
        guard let panel = stylePanel,let bitmap = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) else { return }
        panel.cacheDisplay(in: panel.bounds,to: bitmap)
        if let png = bitmap.representation(using: .png,properties: [:]) { try? png.write(to: url,options: .atomic) }
    }
    #endif
    private func applyStyle() {
        if var selected {
            let rotation = selected.style.rotation
            selected.style = style; selected.style.rotation = rotation; controller?.update(selected)
        }
        controller?.refreshTextStyle()
        installToolbar(); needsDisplay = true
    }
    private func chooseColor(_ target: ColorTarget = .annotation) {
        colorTarget = target
        let value: RGBAColor
        switch target {
        case .annotation: value = style.color
        case .background: value = style.text.background ?? RGBAColor(red: 1,green: 1,blue: 1)
        case .outline: value = style.text.outline ?? RGBAColor(red: 0,green: 0,blue: 0)
        }
        let panel = NSColorPanel.shared; panel.color = value.nsColor; panel.showsAlpha = false
        panel.setTarget(self); panel.setAction(#selector(colorChanged)); panel.orderFront(nil)
    }
    @objc private func colorChanged() {
        let value = RGBAColor(NSColorPanel.shared.color)
        switch colorTarget {
        case .annotation: style.color = value
        case .background: style.text.background = value
        case .outline: style.text.outline = value
        }
        applyStyle()
    }
    private func menu(_ values: [(String,Bool,() -> Void)]) -> NSMenu {
        let menu = NSMenu()
        for value in values { menu.addItem(CaptureMenuItem(value.0,checked: value.1,action: value.2)) }
        return menu
    }
    private func pop(_ menu: NSMenu) {
        guard let toolbar else { return }
        menu.popUp(positioning: nil,at: CGPoint(x: 12,y: toolbar.frame.height-5),in: toolbar)
    }
    private func showSelectionMenu() {
        let menu = NSMenu()
        menu.addItem(CaptureMenuItem("全屏") { [weak self] in guard let self else { return }; self.controller?.select(self.bounds) })
        for (name,ratio) in [("自由比例",CGFloat(0)),("1 : 1",1),("16 : 9",16.0/9),("9 : 16",9.0/16),("4 : 3",4.0/3),("3 : 4",3.0/4)] {
            menu.addItem(CaptureMenuItem(name,checked: aspectRatio == (ratio == 0 ? nil : ratio)) { [weak self] in
                guard let self else { return }; self.aspectRatio = ratio == 0 ? nil : ratio
                if ratio > 0 {
                    let width = min(self.selection.width,self.selection.height*ratio)
                    self.controller?.select(CGRect(x: self.selection.minX,y: self.selection.minY,width: width,height: width/ratio))
                }
            })
        }
        menu.addItem(CaptureMenuItem("精确像素尺寸…") { [weak self] in self?.chooseSize() })
        if let recent = controller?.recentSelections(), recent.count > 1 {
            menu.addItem(.separator())
            for rect in recent.dropFirst() {
                menu.addItem(CaptureMenuItem("最近选区 · \(Int(rect.width)) × \(Int(rect.height))") { [weak self] in
                    guard let self else { return }; self.controller?.select(self.viewRect(rect).intersection(self.bounds))
                })
            }
        }
        pop(menu)
    }
    private func chooseSize() {
        let alert = NSAlert(); alert.messageText = "选区像素尺寸"; alert.addButton(withTitle: "应用"); alert.addButton(withTitle: "取消")
        let width = NSTextField(string: String(Int(pixelRect(selection).width.rounded())))
        let height = NSTextField(string: String(Int(pixelRect(selection).height.rounded())))
        width.setAccessibilityLabel("宽度，像素"); height.setAccessibilityLabel("高度，像素")
        let fields = stack([label("宽度"),width,label("高度"),height]); fields.frame = CGRect(x: 0,y: 0,width: 220,height: 125)
        alert.accessoryView = fields
        guard alert.runModal() == .alertFirstButtonReturn, let w = Double(width.stringValue),let h = Double(height.stringValue),
              w.isFinite,h.isFinite,w >= 2,h >= 2,w <= Double(pixels.width),h <= Double(pixels.height) else { return }
        let size = viewRect(CGRect(x: 0,y: 0,width: w,height: h)).size
        controller?.select(CGRect(x: min(selection.minX,bounds.maxX-size.width),y: min(selection.minY,bounds.maxY-size.height),width: size.width,height: size.height))
    }
    private func styleMenu() -> NSMenu {
        let tool = selected.map { toolFor($0.geometry) } ?? self.tool
        let root = NSMenu()
        func section(_ title: String, _ options: [(String,Bool,() -> Void)]) {
            let item = NSMenuItem(title: title,action: nil,keyEquivalent: ""); item.submenu = menu(options); root.addItem(item)
        }
        if ![Tool.text,.remark,.number].contains(tool) {
            section("线条粗细",[2.0,4,6,10,16].map { value in ("\(Int(value)) px",style.lineWidth == value,{ [weak self] in self?.style.lineWidth = value; self?.applyStyle() }) })
        }
        if tool == .shape {
            let names = ["矩形","圆角矩形","椭圆","三角形","五角星","五边形","六边形","对话框"]
            section("形状",Array(zip(ShapeKind.allCases,names)).map { kind,name in (name,shape == kind,{ [weak self] in
                guard let self else { return }; self.shape = kind
                if var value = self.selected, case .shape(_,let box,let angle) = value.geometry {
                    value.geometry = .shape(kind,box: box,rotation: angle); self.controller?.update(value)
                } else { self.installToolbar() }
            }) })
            let fills = ["空心","半透明填充","实心","虚线空心","虚线半透明","斜线填充"]
            section("填充",Array(zip(ShapeFill.allCases,fills)).map { fill,name in (name,style.fill == fill,{ [weak self] in self?.style.fill = fill; self?.applyStyle() }) })
        }
        if tool == .arrow {
            section("箭头端点",Array(zip(ArrowHeads.allCases,["无箭头","单向","双向"])).map { value,name in (name,style.arrow.heads == value,{ [weak self] in self?.style.arrow.heads = value; self?.applyStyle() }) })
            section("箭头样式",Array(zip(ArrowHeadShape.allCases,["开放","三角","燕尾"])).map { value,name in (name,style.arrow.headShape == value,{ [weak self] in self?.style.arrow.headShape = value; self?.applyStyle() }) })
            root.addItem(CaptureMenuItem("虚线",checked: style.arrow.dashed) { [weak self] in self?.style.arrow.dashed.toggle(); self?.applyStyle() })
            root.addItem(CaptureMenuItem("渐变粗细",checked: style.arrow.tapered) { [weak self] in self?.style.arrow.tapered.toggle(); self?.applyStyle() })
        }
        if tool == .pen { root.addItem(CaptureMenuItem("荧光笔",checked: highlighter) { [weak self] in self?.highlighter.toggle(); self?.applyToolOptions() }) }
        if tool == .pixelate || tool == .blur {
            section("遮挡方式",[("像素马赛克",tool == .pixelate,{ [weak self] in self?.useEffect(blur: false) }),
                ("模糊",tool == .blur,{ [weak self] in self?.useEffect(blur: true) })])
        }
        if tool == .pixelate {
            section("像素大小",Array(zip(PixelStrength.allCases,["细","中","粗"])).map { value,name in (name,pixelStrength == value,{ [weak self] in self?.pixelStrength = value; self?.applyToolOptions() }) })
        }
        if tool == .blur {
            section("模糊程度",Array(zip(BlurStrength.allCases,["轻度","高斯","强烈"])).map { value,name in (name,blurStrength == value,{ [weak self] in self?.blurStrength = value; self?.applyToolOptions() }) })
        }
        if selected == nil,tool == .pixelate || tool == .blur { root.addItem(CaptureMenuItem("画笔涂抹（关闭时为矩形）",checked: brushMask) { [weak self] in self?.brushMask.toggle() }) }
        if tool == .magnifier {
            section("放大倍数",Magnification.allCases.map { value in ("\(value.rawValue)×",magnification == value,{ [weak self] in self?.magnification = value; self?.applyToolOptions() }) })
        }
        if [.text,.remark,.number].contains(tool) {
            section("字号",[16.0,20,24,32,40,56].map { value in (String(Int(value)),style.text.fontSize == value,{ [weak self] in self?.style.text.fontSize = value; self?.applyStyle() }) })
            let customSize = ![16.0,20,24,32,40,56].contains(style.text.fontSize)
            root.items.last?.submenu?.addItem(CaptureMenuItem(customSize ? "\(Int(style.text.fontSize)) 自定字号…" : "自定字号…",checked: customSize) { [weak self] in self?.chooseFontSize() })
            section("字体",([""]+Self.fontFamilies).map { name in (name.isEmpty ? "系统字体" : name,style.text.fontName == name,{ [weak self] in self?.style.text.fontName = name; self?.applyStyle() }) })
            root.addItem(CaptureMenuItem("粗体",checked: style.text.bold) { [weak self] in self?.style.text.bold.toggle(); self?.applyStyle() })
            root.addItem(CaptureMenuItem("斜体",checked: style.text.italic) { [weak self] in self?.style.text.italic.toggle(); self?.applyStyle() })
            root.addItem(CaptureMenuItem("下划线",checked: style.text.underline) { [weak self] in self?.style.text.underline.toggle(); self?.applyStyle() })
            root.addItem(CaptureMenuItem("删除线",checked: style.text.strikethrough) { [weak self] in self?.style.text.strikethrough.toggle(); self?.applyStyle() })
            for (name,target) in [("文字底色",ColorTarget.background),("文字描边",ColorTarget.outline)] {
                let current = target == .background ? style.text.background : style.text.outline
                var options: [(String,Bool,() -> Void)] = [("无",current == nil,{ [weak self] in
                    guard let self else { return }
                    if target == .background { self.style.text.background = nil } else { self.style.text.outline = nil }; self.applyStyle()
                })]
                for (caption,value) in [("白色",RGBAColor(red: 1,green: 1,blue: 1)),("黄色",RGBAColor(red: 1,green: 0.9,blue: 0.3)),("黑色",RGBAColor(red: 0,green: 0,blue: 0))] {
                    options.append((caption,current == value,{ [weak self] in
                        guard let self else { return }
                        if target == .background { self.style.text.background = value } else { self.style.text.outline = value }; self.applyStyle()
                    }))
                }
                section(name,options)
                root.items.last?.submenu?.addItem(CaptureMenuItem("自定义颜色…") { [weak self] in self?.chooseColor(target) })
                if target == .outline {
                    let width = NSMenuItem(title: "描边宽度",action: nil,keyEquivalent: "")
                    width.submenu = menu([0.5,1,2,4,6].map { value in ("\(value) px",style.text.outlineWidth == value,{ [weak self] in self?.style.text.outlineWidth = value; self?.applyStyle() }) })
                    root.items.last?.submenu?.addItem(width)
                }
            }
        }
        if let selected, case .shape(let kind, let box, let angle) = selected.geometry {
            root.addItem(CaptureMenuItem("旋转 15°") { [weak self] in var value = selected; value.geometry = .shape(kind,box: box,rotation: angle+Double.pi/12); self?.controller?.update(value) })
        }
        return root
    }
    private func chooseFontSize() {
        let alert = NSAlert(); alert.messageText = "字号"; alert.informativeText = "输入 1–512 之间的字号。"
        alert.addButton(withTitle: "应用"); alert.addButton(withTitle: "取消")
        let field = NSTextField(string: String(Int(style.text.fontSize)))
        field.frame = CGRect(x: 0,y: 0,width: 180,height: 24); field.setAccessibilityLabel("自定字号")
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn,let value = Double(field.stringValue),value.isFinite,(1...512).contains(value) else { return }
        style.text.fontSize = value; applyStyle()
    }
    private func useEffect(blur: Bool) {
        if var value = selected,case .effect(_,let mask) = value.geometry {
            value.geometry = .effect(blur ? .blur(blurStrength) : .pixelate(pixelStrength),mask)
            controller?.update(value)
        } else { tool = blur ? .blur : .pixelate }
    }
    private func adoptToolOptions(_ value: Annotation) {
        style = value.style
        style.rotation = nil
        switch value.geometry {
        case .shape(let kind,_,_): shape = kind
        case .stroke(_,let highlighter): self.highlighter = highlighter
        case .effect(let kind,let mask):
            switch kind { case .pixelate(let strength): pixelStrength = strength; case .blur(let strength): blurStrength = strength }
            if case .brush = mask { brushMask = true } else { brushMask = false }
        case .magnifier(_,_,let scale): magnification = scale
        default: break
        }
    }
    private func applyToolOptions() {
        guard var value = selected else { installToolbar(); return }
        switch value.geometry {
        case .stroke(let points,_): value.geometry = .stroke(points,highlighter: highlighter)
        case .effect(.pixelate,let mask): value.geometry = .effect(.pixelate(pixelStrength),mask)
        case .effect(.blur,let mask): value.geometry = .effect(.blur(blurStrength),mask)
        case .magnifier(let source,let lens,_): value.geometry = .magnifier(source: source,lens: lens,scale: magnification)
        default: return
        }
        controller?.update(value)
    }
    private func toolFor(_ geometry: AnnotationGeometry) -> Tool {
        switch geometry {
        case .shape: .shape; case .arrow: .arrow; case .text: .text; case .numbered: .number; case .remark: .remark
        case .highlight: .highlight; case .stroke: .pen; case .effect(.pixelate,_): .pixelate
        case .effect(.blur,_): .blur; case .magnifier: .magnifier
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds,from: .zero,operation: .sourceOver,fraction: 1,respectFlipped: true,hints: nil)
        NSColor.black.withAlphaComponent(0.38).setFill(); bounds.fill()
        let region = selection.width > 0 && selection.height > 0 ? selection : (!isEditing ? hoveredWindow : nil)
        if let region {
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: region).addClip()
            image.draw(in: bounds,from: .zero,operation: .sourceOver,fraction: 1,respectFlipped: true,hints: nil)
            if let editedImage, isEditing { editedImage.draw(in: selection,from: .zero,operation: .sourceOver,fraction: 1,respectFlipped: true,hints: nil) }
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.withAlphaComponent(0.9).setStroke(); let border = NSBezierPath(rect: region); border.lineWidth = 1; border.stroke()
            if isEditing { drawHandles(region) }
            drawSize(region)
        }
        if let selected {
            let rect = objectRect(selected.bounds)
            NSColor.controlAccentColor.setStroke(); let path = NSBezierPath(rect: rect); path.lineWidth = 1; path.stroke(); drawHandles(rect)
            if selected.canRotate {
                let point = rotationHandle(selected)
                NSColor.systemOrange.setStroke(); let stem = NSBezierPath()
                stem.move(to: CGPoint(x: rect.midX,y: rect.minY)); stem.line(to: point); stem.lineWidth = 1; stem.stroke()
                let knob = NSBezierPath(ovalIn: CGRect(x: point.x-5,y: point.y-5,width: 10,height: 10))
                NSColor.controlBackgroundColor.setFill(); knob.fill(); knob.stroke()
            }
            if case .arrow(let a,let b,let c) = selected.geometry {
                let line = NSBezierPath(); line.setLineDash([3,3],count: 2,phase: 0)
                line.move(to: objectRect(CGRect(origin: a,size: .zero)).origin); line.line(to: objectRect(CGRect(origin: c,size: .zero)).origin); line.line(to: objectRect(CGRect(origin: b,size: .zero)).origin); line.stroke()
                let p = objectRect(CGRect(origin: c,size: .zero)).origin
                NSColor.controlAccentColor.setFill(); NSBezierPath(ovalIn: CGRect(x: p.x-4,y: p.y-4,width: 8,height: 8)).fill()
            }
        }
        if case .draw? = gesture, isEditing, let value = draftAnnotation(), let context = NSGraphicsContext.current?.cgContext {
            context.saveGState(); context.clip(to: selection)
            context.translateBy(x: selection.minX,y: selection.minY); context.scaleBy(x: bounds.width/CGFloat(pixels.width),y: bounds.height/CGFloat(pixels.height))
            context.setStrokeColor(style.color.nsColor.cgColor); context.setLineWidth(style.lineWidth); context.setLineCap(.round)
            switch value.geometry {
            case .shape(let kind,let box,let angle): if let path = try? GeometryPaths.shape(kind,box: box,rotation: angle) { context.addPath(path); context.strokePath() }
            case .arrow(let a,let b,let c):
                if let paths = try? GeometryPaths.arrow(start: a,end: b,control: c,lineWidth: style.lineWidth,style: style.arrow) {
                    context.addPath(paths.shaft); context.strokePath(); context.setFillColor(style.color.nsColor.cgColor)
                    if let head = paths.endHead { context.addPath(head); context.fillPath() }
                }
            case .stroke(let points,_):
                if let path = try? GeometryPaths.stroke(points) { context.addPath(path); context.strokePath() }
            case .effect, .magnifier, .highlight: break
            default: context.stroke(value.geometry.bounds)
            }
            context.restoreGState()
        }
        if !isEditing {
            let text = "拖动选择区域   ·   点击选窗口   ·   Esc 取消"
            drawBadge(text,at: CGPoint(x: bounds.midX-160,y: bounds.maxY-64),width: 320)
            if hover.x >= 0, hover.y >= 0, gesture == nil { drawLoupe() }
        }
    }
    private func drawHandles(_ rect: CGRect) {
        for point in handles(rect) {
            let handle = NSBezierPath(roundedRect: CGRect(x: point.x-3,y: point.y-3,width: 6,height: 6),xRadius: 1.5,yRadius: 1.5)
            NSColor.white.setFill(); handle.fill(); NSColor.black.withAlphaComponent(0.3).setStroke(); handle.lineWidth = 0.5; handle.stroke()
        }
    }
    private func rotationHandle(_ value: Annotation) -> CGPoint {
        let rect = objectRect(value.bounds)
        return CGPoint(x: rect.midX,y: max(8,rect.minY-24))
    }
    private func drawSize(_ rect: CGRect) {
        let size = pixelRect(rect)
        drawBadge("\(Int(size.width.rounded())) × \(Int(size.height.rounded()))",at: CGPoint(x: max(8,rect.minX),y: max(8,rect.minY-28)),width: 110)
    }
    private func drawBadge(_ text: String,at point: CGPoint,width: CGFloat) {
        let box = CGRect(origin: point,size: CGSize(width: width,height: 23))
        NSColor(srgbRed: 0.08,green: 0.09,blue: 0.11,alpha: 0.93).setFill(); NSBezierPath(roundedRect: box,xRadius: 6,yRadius: 6).fill()
        let attrs: [NSAttributedString.Key:Any] = [.font:NSFont.monospacedDigitSystemFont(ofSize: 11,weight: .medium),.foregroundColor:NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: CGPoint(x: box.midX-size.width/2,y: box.midY-size.height/2),withAttributes: attrs)
    }
    private func hex(at p: CGPoint) -> String? {
        guard bounds.contains(p),let source else { return nil }
        let q = pixelRect(CGRect(origin: p,size: .zero)).origin
        guard let pixel = source.cropping(to: CGRect(x: floor(q.x),y: floor(q.y),width: 1,height: 1)),
              let color = NSBitmapImageRep(cgImage: pixel).colorAt(x: 0,y: 0)?.usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X",Int((color.redComponent*255).rounded()),Int((color.greenComponent*255).rounded()),Int((color.blueComponent*255).rounded()))
    }
    private func drawLoupe() {
        guard let source, bounds.contains(hover) else { return }
        let q = pixelRect(CGRect(origin: hover,size: .zero)).origin
        let crop = CGRect(x: max(0,min(floor(q.x)-5,CGFloat(pixels.width)-11)),y: max(0,min(floor(q.y)-5,CGFloat(pixels.height)-11)),width: CGFloat(min(11,pixels.width)),height: CGFloat(min(11,pixels.height)))
        guard let piece = source.cropping(to: crop) else { return }
        let box = CGRect(x: min(hover.x+20,bounds.maxX-125),y: min(hover.y+20,bounds.maxY-175),width: 112,height: 160)
        NSColor(srgbRed: 0.08,green: 0.09,blue: 0.11,alpha: 0.96).setFill(); NSBezierPath(roundedRect: box,xRadius: 10,yRadius: 10).fill()
        NSGraphicsContext.current?.imageInterpolation = .none
        let rect = CGRect(x: box.minX+7,y: box.minY+7,width: 98,height: 98)
        NSImage(cgImage: piece,size: .zero).draw(in: rect,from: .zero,operation: .sourceOver,fraction: 1,respectFlipped: true,hints: nil)
        let cell = CGSize(width: rect.width/crop.width,height: rect.height/crop.height)
        NSColor.controlAccentColor.setStroke(); let target = NSBezierPath(rect: CGRect(x: rect.minX+(floor(q.x)-crop.minX)*cell.width,y: rect.minY+(floor(q.y)-crop.minY)*cell.height,width: cell.width,height: cell.height)); target.lineWidth = 1; target.stroke()
        drawBadge("\(hex(at: hover) ?? "") · C",at: CGPoint(x: box.minX+1,y: box.minY+110),width: 110)
        drawBadge("X \(Int(q.x))  Y \(Int(q.y))",at: CGPoint(x: box.minX+1,y: box.minY+133),width: 110)
    }
}
