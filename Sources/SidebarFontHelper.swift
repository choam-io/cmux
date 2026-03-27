import AppKit

/// Builds a system font with the user's terminal font as a cascade fallback,
/// so Private Use Area characters (Nerd Font icons) render in the sidebar
/// instead of showing as boxes.
enum SidebarFontHelper {

    /// Cache the resolved font to avoid re-creating descriptors on every cell draw.
    private static var cachedFont: NSFont?
    private static var cachedSize: CGFloat = 0
    private static var cachedWeight: NSFont.Weight = .semibold
    private static var cachedTerminalFamily: String = ""

    static func sidebarTitleFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let config = GhosttyConfig.load()
        let terminalFamily = config.fontFamily

        // Return cached font if parameters haven't changed
        if let cached = cachedFont,
           cachedSize == size,
           cachedWeight == weight,
           cachedTerminalFamily == terminalFamily {
            return cached
        }

        let font = buildFont(size: size, weight: weight, terminalFamily: terminalFamily)
        cachedFont = font
        cachedSize = size
        cachedWeight = weight
        cachedTerminalFamily = terminalFamily
        return font
    }

    private static func buildFont(size: CGFloat, weight: NSFont.Weight, terminalFamily: String) -> NSFont {
        // Start with the system font
        let systemFont = NSFont.systemFont(ofSize: size, weight: weight)

        // Try to load the terminal font for cascade fallback
        guard let terminalFont = NSFont(name: terminalFamily, size: size) else {
            return systemFont
        }

        // Create a new font descriptor with the terminal font as a cascade fallback.
        // macOS will use the system font for normal glyphs and fall back to the
        // terminal font for characters not in SF Pro (like PUA/Nerd Font icons).
        let descriptor = systemFont.fontDescriptor.addingAttributes([
            .cascadeList: [terminalFont.fontDescriptor]
        ])

        return NSFont(descriptor: descriptor, size: size) ?? systemFont
    }
}
