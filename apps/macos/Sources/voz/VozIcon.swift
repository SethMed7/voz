import AppKit

/// The voz brand mark — the "V" sound-wave logo — drawn as a vector so it stays crisp at any
/// menu-bar size and renders as a *template* (the menu bar tints it black on a light bar, white
/// on a dark one). The geometry is traced from `brand/v-mark.svg`: a solid left down-stroke plus
/// five ascending equalizer bars that form the right arm.
enum VozIcon {
    /// A template image of the V mark, sized for the menu bar (square, ~18pt by default).
    static func menuBar(height: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: height, height: height), flipped: false) { rect in
            drawMark(in: rect)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "voz"
        return img
    }

    // Design space is 100×100, y-up: y = 0 is the bottom vertex, y = 100 the top of the tallest bar.
    private static let barCenterX: [CGFloat] = [59, 70, 80, 89, 97]
    private static let barTopY: [CGFloat]    = [68.8, 83.8, 90.5, 96.9, 100]
    private static let barBotY: [CGFloat]    = [0, 24.5, 40.1, 56.3, 69.4]
    private static let barWidth: CGFloat = 6

    private static func drawMark(in rect: NSRect) {
        // Fit the 100×100 design into rect with a little breathing room, keeping it centered.
        let box = rect.insetBy(dx: rect.width * 0.07, dy: rect.height * 0.07)
        let s = min(box.width, box.height) / 100.0
        let ox = box.minX + (box.width - 100 * s) / 2
        let oy = box.minY + (box.height - 100 * s) / 2
        func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x * s, y: oy + y * s) }

        NSColor.black.setFill()

        // Left arm: a solid triangle with a flat top, converging to the bottom vertex.
        let arm = NSBezierPath()
        arm.move(to: P(0, 92.4))
        arm.line(to: P(28.8, 92.4))
        arm.line(to: P(54.9, 0))
        arm.close()
        arm.fill()

        // Right arm: five ascending capsule bars — the sound-wave.
        for i in barCenterX.indices {
            let x = ox + (barCenterX[i] - barWidth / 2) * s
            let y = oy + barBotY[i] * s
            let h = (barTopY[i] - barBotY[i]) * s
            let r = barWidth / 2 * s
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barWidth * s, height: h),
                         xRadius: r, yRadius: r).fill()
        }
    }
}
