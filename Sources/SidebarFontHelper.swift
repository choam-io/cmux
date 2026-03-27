import AppKit

/// Builds a system font with a Nerd Font as cascade fallback,
/// so Private Use Area characters (workmux icons, etc.) render
/// in the sidebar instead of showing as boxes.
enum SidebarFontHelper {

    /// Cache the resolved font to avoid re-creating descriptors on every cell draw.
    private static var cachedFont: NSFont?
    private static var cachedSize: CGFloat = 0
    private static var cachedWeight: NSFont.Weight = .semibold

    static func sidebarTitleFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        // Return cached font if parameters haven't changed
        if let cached = cachedFont,
           cachedSize == size,
           cachedWeight == weight {
            return cached
        }

        let font = buildFont(size: size, weight: weight)
        cachedFont = font
        cachedSize = size
        cachedWeight = weight
        return font
    }

    private static func buildFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let systemFont = NSFont.systemFont(ofSize: size, weight: weight)

        // Try the user's configured terminal font first
        let config = GhosttyConfig.load()
        if config.fontFamily != "Menlo",
           let termFont = NSFont(name: config.fontFamily, size: size),
           fontHasPUAGlyphs(termFont) {
            return fontWithCascade(systemFont, fallback: termFont, size: size)
        }

        // No config or config font lacks PUA -- scan for an installed Nerd Font.
        // Check common NF families in preference order.
        let candidates = [
            "JetBrainsMono Nerd Font",
            "JetBrainsMono NF",
            "Hack Nerd Font",
            "FiraCode Nerd Font",
            "MonaspiceAr Nerd Font",
            "Maple Mono NF",
            "Symbols Nerd Font Mono",
        ]

        for name in candidates {
            if let nf = NSFont(name: name, size: size),
               fontHasPUAGlyphs(nf) {
                return fontWithCascade(systemFont, fallback: nf, size: size)
            }
        }

        return systemFont
    }

    private static func fontWithCascade(_ base: NSFont, fallback: NSFont, size: CGFloat) -> NSFont {
        let descriptor = base.fontDescriptor.addingAttributes([
            .cascadeList: [fallback.fontDescriptor]
        ])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// Quick check: does this font contain glyphs in the Nerd Font PUA range?
    private static func fontHasPUAGlyphs(_ font: NSFont) -> Bool {
        let ctFont = font as CTFont
        // U+E0A0 is Powerline branch symbol, present in all Nerd Fonts
        var glyph: CGGlyph = 0
        var codePoint: UniChar = 0xE0A0
        return CTFontGetGlyphsForCharacters(ctFont, &codePoint, &glyph, 1) && glyph != 0
    }
}
