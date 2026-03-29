import AppKit
import SwiftUI

/// Builds a system font with a Nerd Font as cascade fallback,
/// so Private Use Area characters (workmux icons, etc.) render
/// correctly instead of showing as boxes.
///
/// Used anywhere workspace/surface names may contain nerdfont glyphs:
/// sidebar, command palette, titlebar, rename flow, etc.
enum NerdFontHelper {

    /// Cache resolved fonts keyed by (size, weight) to avoid
    /// re-creating descriptors on every draw.
    private struct CacheKey: Hashable {
        let size: CGFloat
        let weight: NSFont.Weight

        // NSFont.Weight isn't Hashable by default -- hash on rawValue.
        func hash(into hasher: inout Hasher) {
            hasher.combine(size)
            hasher.combine(weight.rawValue)
        }

        static func == (lhs: CacheKey, rhs: CacheKey) -> Bool {
            lhs.size == rhs.size && lhs.weight.rawValue == rhs.weight.rawValue
        }
    }

    private static var cache: [CacheKey: NSFont] = [:]

    // MARK: - Public API

    /// Returns an NSFont (AppKit) with nerdfont cascade fallback.
    static func font(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let key = CacheKey(size: size, weight: weight)
        if let cached = cache[key] {
            return cached
        }
        let font = buildFont(size: size, weight: weight)
        cache[key] = font
        return font
    }

    /// Returns a SwiftUI Font with nerdfont cascade fallback.
    static func swiftUIFont(size: CGFloat, weight: NSFont.Weight) -> Font {
        Font(font(size: size, weight: weight))
    }

    // MARK: - Backwards compatibility

    /// Legacy name kept so existing sidebar call sites don't need renaming
    /// in the same commit. Remove once all callers migrate.
    static func sidebarTitleFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        font(size: size, weight: weight)
    }

    // MARK: - Internals

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
