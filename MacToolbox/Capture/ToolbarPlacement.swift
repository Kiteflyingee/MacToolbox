import CoreGraphics

public enum ToolbarPlacement {
    /// Converts desktop coordinates (bottom-left) to a flipped capture canvas.
    /// Only editor controls use this rectangle; the captured image keeps its full extent.
    public static func chromeBounds(captureFrame: CGRect, visibleScreenFrame: CGRect) -> CGRect {
        let visible = captureFrame.intersection(visibleScreenFrame)
        guard !visible.isNull, !visible.isEmpty else { return CGRect(origin: .zero,size: captureFrame.size) }
        return CGRect(x: visible.minX-captureFrame.minX,y: captureFrame.maxY-visible.maxY,
                      width: visible.width,height: visible.height)
    }

    public static func clamped(_ frame: CGRect,to bounds: CGRect,inset: CGFloat = 8) -> CGRect {
        let x = max(bounds.minX+inset,min(frame.minX,bounds.maxX-frame.width-inset))
        let y = max(bounds.minY+inset,min(frame.minY,bounds.maxY-frame.height-inset))
        return CGRect(origin: CGPoint(x: x,y: y),size: frame.size)
    }

    public static func toolbar(size: CGSize,selection: CGRect,bounds: CGRect) -> CGRect {
        let below = selection.maxY+10
        let above = selection.minY-size.height-10
        let y: CGFloat
        if below+size.height <= bounds.maxY-8 { y = below }
        else if above >= bounds.minY+8 { y = above }
        else { y = min(selection.maxY,bounds.maxY)-size.height-8 }
        return clamped(CGRect(x: selection.maxX-size.width,y: y,width: size.width,height: size.height),to: bounds)
    }

    public static func availablePanelHeight(toolbar: CGRect,bounds: CGRect) -> CGFloat {
        max(84,max(toolbar.minY-bounds.minY-12,bounds.maxY-toolbar.maxY-12))
    }

    public static func panel(size: CGSize,anchor: CGRect,toolbar: CGRect,bounds: CGRect) -> (frame: CGRect,below: Bool) {
        let below = bounds.maxY-toolbar.maxY-8 >= size.height
        let x = max(bounds.minX+8,min(anchor.midX-size.width/2,bounds.maxX-size.width-8))
        let y = below ? toolbar.maxY+5 : toolbar.minY-size.height-5
        return (CGRect(origin: CGPoint(x: x,y: max(bounds.minY+5,min(y,bounds.maxY-size.height-5))),size: size),below)
    }
}
