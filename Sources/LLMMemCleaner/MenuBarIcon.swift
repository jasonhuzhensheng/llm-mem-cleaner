import AppKit

/// Draws an outlined RAM-chip glyph (body + pins) in the menu bar's text color, with `text`
/// inside in the same color, turning red only once usage passes 95%.
/// Colors resolve at draw time, so the chip follows light/dark menu bars.
func memoryChipImage(text: String, usedFraction: Double) -> NSImage {
    let numberColor: NSColor = usedFraction > 0.95 ? .systemRed : .labelColor

    let str = text as NSString
    let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .heavy)
    let textSize = str.size(withAttributes: [.font: font])

    let pinHeight: CGFloat = 2.5
    let bodyHeight: CGFloat = 13
    let width = max(ceil(textSize.width) + 9, 18)
    let size = NSSize(width: width, height: bodyHeight + pinHeight * 2)

    let image = NSImage(size: size, flipped: false) { rect in
        NSColor.labelColor.setFill()
        NSColor.labelColor.setStroke()

        // Pins: evenly spaced ticks above and below the body.
        let pinWidth: CGFloat = 1.5
        let pinCount = max(3, Int((width - 4) / 4))
        let spacing = (width - 4) / CGFloat(pinCount)
        for i in 0..<pinCount {
            let x = 2 + spacing * (CGFloat(i) + 0.5) - pinWidth / 2
            NSRect(x: x, y: 0, width: pinWidth, height: pinHeight + 0.5).fill()
            NSRect(x: x, y: rect.height - pinHeight - 0.5, width: pinWidth, height: pinHeight + 0.5).fill()
        }

        let body = NSRect(x: 0, y: pinHeight, width: rect.width, height: bodyHeight).insetBy(dx: 0.6, dy: 0.6)
        let outline = NSBezierPath(roundedRect: body, xRadius: 2.5, yRadius: 2.5)
        outline.lineWidth = 1.2
        outline.stroke()

        str.draw(at: NSPoint(x: (rect.width - textSize.width) / 2,
                             y: body.midY - textSize.height / 2),
                 withAttributes: [.font: font, .foregroundColor: numberColor])
        return true
    }
    image.isTemplate = false
    return image
}
