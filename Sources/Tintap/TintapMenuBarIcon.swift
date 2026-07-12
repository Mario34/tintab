import AppKit

enum TintapMenuBarIcon {
    static func makeTemplateImage() -> NSImage {
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
           let bundledImage = NSImage(contentsOf: url) {
            bundledImage.size = NSSize(width: 18, height: 18)
            // The supplied artwork is intentionally two-tone. Treating it as
            // a template would flatten the gray tiles and black glyphs.
            bundledImage.isTemplate = false
            return bundledImage
        }

        // Keep a generated fallback for `swift run`, where the app bundle's
        // packaged Resources directory is not present.
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        let upper = NSBezierPath(roundedRect: NSRect(x: 2.4, y: 9.2, width: 7.0, height: 5.0), xRadius: 2.1, yRadius: 2.1)
        NSColor.black.setFill()
        upper.fill()

        let lower = NSBezierPath(roundedRect: NSRect(x: 8.6, y: 3.8, width: 7.0, height: 5.0), xRadius: 2.1, yRadius: 2.1)
        NSColor.black.setFill()
        lower.fill()

        let connector = NSBezierPath()
        connector.lineWidth = 1.8
        connector.lineCapStyle = .round
        connector.lineJoinStyle = .round
        connector.move(to: NSPoint(x: 8.0, y: 10.5))
        connector.curve(to: NSPoint(x: 10.8, y: 8.0), controlPoint1: NSPoint(x: 9.0, y: 9.9), controlPoint2: NSPoint(x: 9.8, y: 9.0))
        NSColor.black.setStroke()
        connector.stroke()

        let arrow = NSBezierPath()
        arrow.lineWidth = 1.8
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        arrow.move(to: NSPoint(x: 10.0, y: 9.2))
        arrow.line(to: NSPoint(x: 10.9, y: 8.0))
        arrow.line(to: NSPoint(x: 12.4, y: 8.4))
        NSColor.black.setStroke()
        arrow.stroke()

        let leftGlyph = NSBezierPath()
        leftGlyph.lineWidth = 1.2
        leftGlyph.lineCapStyle = .round
        leftGlyph.move(to: NSPoint(x: 4.4, y: 11.5))
        leftGlyph.line(to: NSPoint(x: 5.8, y: 13.0))
        leftGlyph.line(to: NSPoint(x: 7.2, y: 11.5))
        NSColor.white.setStroke()
        leftGlyph.stroke()

        let rightGlyph = NSBezierPath()
        rightGlyph.lineWidth = 1.1
        rightGlyph.lineCapStyle = .round
        rightGlyph.move(to: NSPoint(x: 10.4, y: 6.9))
        rightGlyph.line(to: NSPoint(x: 13.6, y: 6.9))
        rightGlyph.move(to: NSPoint(x: 11.0, y: 5.7))
        rightGlyph.line(to: NSPoint(x: 13.0, y: 5.7))
        NSColor.white.setStroke()
        rightGlyph.stroke()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
