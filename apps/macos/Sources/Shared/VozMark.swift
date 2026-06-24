import AppKit

/// The voz brand mark, loaded from the bundled official SVGs (`Sources/Shared/Resources`, traced from
/// `brand/source/`). macOS 13+ renders SVG natively via `NSImage`, so we ship the real artwork instead
/// of re-tracing bezier geometry by hand:
///   • `menuBarTemplate` — the monochrome glyph as a *template* image (the bar tints it black on a light
///     bar, white on a dark one), the macOS-correct treatment for a status item.
///   • `coloredMark` — the full blue gradient mark, for on-brand surfaces like the Insights header.
///
/// Both are drawn fit-and-centered into a fresh canvas so optical balance is identical regardless of the
/// source viewBox. If a resource ever fails to load, we fall back to an SF Symbol so the bar is never blank.
public enum VozMark {
    /// The monochrome V glyph sized for the menu bar (square, ~18pt), rendered as a template.
    public static func menuBarTemplate(height: CGFloat = 18) -> NSImage {
        let img = fitted(named: "voz_glyph", into: NSSize(width: height, height: height), inset: 0.06)
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "voz") ?? NSImage()
        img.isTemplate = true
        img.accessibilityDescription = "voz"
        return img
    }

    /// The full-color brand mark (blue gradient), for dark on-brand surfaces. Not a template.
    public static func coloredMark(height: CGFloat = 22) -> NSImage {
        let img = fitted(named: "voz_icon", into: NSSize(width: height, height: height), inset: 0.0)
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "voz") ?? NSImage()
        img.accessibilityDescription = "voz"
        return img
    }

    // MARK: plumbing

    /// Load a bundled SVG by name (no extension) as a vector `NSImage`.
    private static func loadSVG(_ name: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Resources")
            ?? Bundle.module.url(forResource: name, withExtension: "svg") else { return nil }
        return NSImage(contentsOf: url)
    }

    /// Draw `name` fit-and-centered into a fresh `size` canvas, preserving aspect ratio with `inset` padding.
    private static func fitted(named name: String, into size: NSSize, inset: CGFloat) -> NSImage? {
        guard let src = loadSVG(name) else { return nil }
        let out = NSImage(size: size)
        out.lockFocus()
        let box = NSRect(origin: .zero, size: size).insetBy(dx: size.width * inset, dy: size.height * inset)
        let s = min(box.width / src.size.width, box.height / src.size.height)
        let w = src.size.width * s, h = src.size.height * s
        let dst = NSRect(x: box.minX + (box.width - w) / 2, y: box.minY + (box.height - h) / 2, width: w, height: h)
        src.draw(in: dst, from: .zero, operation: .sourceOver, fraction: 1)
        out.unlockFocus()
        return out
    }
}
