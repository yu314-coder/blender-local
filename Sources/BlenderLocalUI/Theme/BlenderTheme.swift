import SwiftUI

/// Blender's default dark theme.
///
/// Every value here was extracted from Blender's own source of truth,
/// `release/datafiles/userdef/userdef_default_theme.c`, so the interface
/// matches the desktop application rather than approximating it.
/// Do not hand-tune these — re-extract if Blender changes.
public enum BTheme {

    // MARK: Editor backgrounds (.space_*.back)

    /// `.space_view3d.back` — the 3D viewport.
    public static let viewport      = Color(hex: 0x3D3D3D)
    /// `.space_properties.back`
    public static let properties    = Color(hex: 0x303030)
    /// `.space_outliner.back`
    public static let outliner      = Color(hex: 0x282828)
    /// `.space_text.back` — the text editor.
    public static let textEditor    = Color(hex: 0x232323)
    /// `.space_console.back`
    public static let console       = Color(hex: 0x1D1D1D)
    /// `.space_info.back`
    public static let info          = Color(hex: 0x1D1D1D)
    /// `.space_topbar.back`.
    ///
    /// The theme file says 0x181818, but Blender renders 0x171717 — the header
    /// colours carry an alpha (0xB3) that composites against the editor
    /// beneath. These are the values sampled from a screenshot of Blender
    /// itself, because matching what it looks like beats matching what its
    /// theme file says.
    public static let topbar        = Color(hex: 0x171717)
    /// Workspace tab fills, measured the same way.
    public static let tabActive     = Color(hex: 0x2F2F2F)
    public static let tabInactive   = Color(hex: 0x1C1C1C)
    /// Datablock name fields in the topbar.
    public static let fieldTopbar   = Color(hex: 0x1C1C1C)
    /// `.space_statusbar.back`
    public static let statusbar     = Color(hex: 0x303030)

    // MARK: Headers (.space_*.header — alpha 0xB3 in Blender, opaque here
    // because our editors do not overlap)

    /// 0x303030 at 0xB3 over the editor background renders as 0x272727.
    public static let header        = Color(hex: 0x272727)
    public static let headerOutliner = Color(hex: 0x282828)
    public static let headerTopbar  = Color(hex: 0x181818)

    // MARK: Widgets (.tui.wcol_*)

    /// `wcol_regular.inner` / `wcol_tool.inner`
    public static let widget        = Color(hex: 0x545454)
    /// `wcol_*.outline`
    public static let outline       = Color(hex: 0x3D3D3D)
    /// `wcol_text.inner` — text fields and number sliders.
    public static let field         = Color(hex: 0x1D1D1D)
    /// `wcol_menu_back.inner` — dropdowns and popovers.
    public static let menuBack      = Color(hex: 0x181818)

    // MARK: Text

    /// `wcol_*.text` — standard label text.
    public static let text          = Color(hex: 0xE6E6E6)
    /// `.space_view3d.title`
    public static let title         = Color(hex: 0xEEEEEE)
    public static let textDim       = Color(hex: 0xE6E6E6).opacity(0.55)

    // MARK: Accents

    /// `.tui.select` — Blender's selection orange.
    public static let select        = Color(hex: 0xED5700)
    /// `.tui.active` — active (last-selected) object.
    public static let active        = Color(hex: 0xFFA028)
    /// Tracebacks and failed runs. The console's error red, named here so the
    /// top bar, the console and the editor's error card agree on it.
    public static let error         = Color(hex: 0xFF6B5E)
    /// `.tui.editor_outline` — the hairline between editors.
    public static let editorOutline = Color(white: 1.0, opacity: 0x15 / 255.0)
    /// `.space_view3d.grid`
    public static let grid          = Color(hex: 0x545454).opacity(0x80 / 255.0)

    // MARK: Axis colors (Blender's standard X/Y/Z)

    public static let axisX = Color(hex: 0xE5486A)
    public static let axisY = Color(hex: 0x7BC629)
    public static let axisZ = Color(hex: 0x2F83E3)

    // MARK: Metrics
    //
    // Blender's headers are 26px at 1.0 UI scale. On a touch screen that is
    // below the 44pt comfortable-target guidance, so chrome is scaled up while
    // keeping Blender's proportions.

    public enum Metric {
        public static let headerHeight: CGFloat   = 34
        public static let topbarHeight: CGFloat   = 38
        public static let statusHeight: CGFloat   = 24
        public static let rowHeight: CGFloat      = 26
        public static let corner: CGFloat         = 4      // Blender widget radius
        public static let sidebarWidth: CGFloat   = 240
        public static let hairline: CGFloat       = 1
    }

    public enum Font {
        /// Blender ships DejaVu Sans; the closest always-present iOS face at
        /// these sizes is the system font at a slightly tightened size.
        public static func ui(_ size: CGFloat = 12, weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            .system(size: size, weight: weight)
        }
        public static func mono(_ size: CGFloat = 12) -> SwiftUI.Font {
            .system(size: size, design: .monospaced)
        }
    }
}

extension Color {
    /// 0xRRGGBB, matching the literals in Blender's theme source.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >>  8) & 0xFF) / 255.0,
            blue:  Double( hex        & 0xFF) / 255.0,
            opacity: 1.0
        )
    }
}
