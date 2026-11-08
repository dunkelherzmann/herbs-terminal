import CGtk
import CHerb
import Foundation

/// The app's look: the macOS window's unified toolbar, its square-ish toolbar buttons and the tab strip, drawn with
/// libadwaita's light and dark colors.
@MainActor
enum Styles {
    static let css = """
    .session-toolbar { min-height: 38px; padding: 0 4px; background: alpha(@headerbar_bg_color, 0.97); }
    .session-toolbar .glyph { min-width: 30px; min-height: 28px; padding: 0; border-radius: 5px;
        background: alpha(currentColor, 0.065); box-shadow: none; }
    .session-toolbar .glyph:hover { background: alpha(currentColor, 0.12); }
    .session-toolbar .glyph:active { background: alpha(currentColor, 0.18); }
    .session-toolbar .glyph.active, .session-toolbar .glyph:checked { background: alpha(@accent_bg_color, 0.18); color: @accent_color; }
    .session-toolbar .glyph image { -gtk-icon-size: 16px; }
    /* The Main Menu is a plain glyph, as on the Mac: its inner button is 30 × 28 with no background at rest. */
    .session-toolbar menubutton.glyph { background: none; min-height: 0; min-width: 0; }
    .session-toolbar menubutton.glyph > button { min-width: 30px; min-height: 28px; padding: 0; border-radius: 5px;
        background: none; box-shadow: none; }
    .session-toolbar menubutton.glyph > button:hover { background: alpha(currentColor, 0.12); }
    .session-toolbar menubutton.glyph > button:active, .session-toolbar menubutton.glyph > button:checked { background: alpha(currentColor, 0.18); }
    .session-title { font-size: 12px; font-weight: 600; }
    .session-subtitle { font-size: 10px; opacity: 0.6; }
    .tab-strip { padding: 3px 6px; background: alpha(@headerbar_bg_color, 0.97); border-bottom: 1px solid alpha(currentColor, 0.1); }
    .tab-chip { padding: 2px 6px; border-radius: 4px; }
    .tab-chip.selected { background: alpha(@accent_bg_color, 0.18); }
    .tab-chip.selected .tab-title { font-weight: 600; }
    .tab-chip button { min-height: 20px; min-width: 20px; padding: 0 2px; }
    .tab-title { font-size: 13px; }
    .terminal-pad { padding: 6px 0 0 8px; }
    .pane-divider-start { border-left: 1px solid alpha(currentColor, 0.15); }
    .pane-divider-top { border-top: 1px solid alpha(currentColor, 0.15); }
    .focused-pane { box-shadow: inset 0 0 0 1.5px alpha(@accent_color, 0.8); }
    .size-badge { font-family: monospace; font-size: 18px; font-weight: 600; padding: 8px 14px; border-radius: 8px;
        background: alpha(@window_bg_color, 0.85); box-shadow: 0 1px 4px alpha(black, 0.2); }
    .bell-flash { background: alpha(white, 0); transition: background 180ms ease-out; }
    .bell-flash.flash-on { background: alpha(white, 0.25); transition: none; }
    .bell-flash.flash-on-slow { background: alpha(white, 0.25); transition: none; }
    .find-bar { margin: 8px 12px; padding: 4px; border-radius: 8px; background: @popover_bg_color;
        box-shadow: 0 1px 5px alpha(black, 0.25); }
    .banner-warn { background: alpha(#e5a50a, 0.14); padding: 6px 10px; font-size: 12px; }
    .banner-admin { background: alpha(#e01b24, 0.15); padding: 5px 10px; font-size: 12px; font-weight: 600; }
    .multiexec-bar { background: alpha(#ff7800, 0.14); padding: 6px 10px; }
    .multiexec-cell { border: 1px solid alpha(currentColor, 0.3); border-radius: 3px; }
    .multiexec-cell.included { border-color: alpha(#ff7800, 0.55); }
    .multiexec-cell.focused { border: 2px solid @accent_color; }
    .multiexec-caption { padding: 3px 8px; font-size: 11px; background: alpha(@headerbar_bg_color, 0.97); }
    .location-bar { padding: 8px; }
    .location-bar button.flat { min-width: 26px; min-height: 26px; padding: 2px; }
    .path-segment { padding: 2px 6px; border-radius: 4px; background: alpha(currentColor, 0.06); min-height: 0; }
    .path-segment.current { font-weight: 600; }
    .places { background: alpha(@sidebar_bg_color, 1); }
    .places row { padding: 4px 8px; }
    .places .section { font-size: 11px; font-weight: 700; opacity: 0.55; padding: 10px 12px 4px 12px; }
    .file-size { font-size: 11px; opacity: 0.6; }
    .hidden-file { opacity: 0.6; }
    .transfers { padding: 8px; background: alpha(@headerbar_bg_color, 0.97); font-size: 11px; }
    .error-text { color: @error_color; }
    .editor-status { font-size: 11px; opacity: 0.7; font-feature-settings: "tnum"; }
    .editor-bar { padding: 3px 10px; }
    .heading-text { font-weight: 700; font-size: 15px; }
    .theme-swatch { font-family: monospace; padding: 1px 6px; border-radius: 4px; min-width: 22px; }
    .monospace-text { font-family: monospace; }
    .result-output { font-family: monospace; font-size: 11px; padding: 6px; border-radius: 4px; background: alpha(currentColor, 0.05); }
    .login-header { font-size: 11px; font-weight: 600; opacity: 0.6; padding: 5px 16px; }
    .toolbar-strip { padding: 6px 8px; background: alpha(@headerbar_bg_color, 0.97); }
    """

    static func install() {
        loadCSS(css)
        let theme = gtk_icon_theme_get_for_display(gdk_display_get_default())
        // Development builds name the folder with the app's icons in HERBS_ICON_PATH.
        let development = ProcessInfo.processInfo.environment["HERBS_ICON_PATH"] ?? ""
        for path in [development, "/app/share/icons"] where !path.isEmpty && FileManager.default.fileExists(atPath: path) {
            gtk_icon_theme_add_search_path(theme, path)
        }
    }

    private static var backgroundProviders: [ObjectIdentifier: OpaquePointer] = [:]

    /// A widget's own background color, as an inline style.
    static func setBackground(_ widget: Widget, _ color: RGB) {
        setStyle(widget, "background-color: \(color.css);")
    }

    /// `points` are the Mac's points (one screen pixel each before scaling), so CSS gets them as px, not pt.
    static func setFont(_ widget: Widget, family: String, points: Double) {
        setStyle(widget, "font-family: \"\(family)\"; font-size: \(points)px;")
    }

    /// CSS declarations for one widget.
    static func setStyle(_ widget: Widget, _ declarations: String) {
        let name = "w-\(UInt(bitPattern: widget))"
        gtk_widget_add_css_class(widget, name)
        let key = ObjectIdentifier(widget as AnyObject)
        let provider: OpaquePointer
        if let existing = backgroundProviders[key] {
            provider = existing
        } else {
            provider = c(gtk_css_provider_new())
            gtk_style_context_add_provider_for_display(gdk_display_get_default(), c(provider), UInt32(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 1))
            backgroundProviders[key] = provider
        }
        gtk_css_provider_load_from_string(c(provider), ".\(name) { \(declarations) }")
    }
}

/// System, Light or Dark, and whether the window currently draws dark.
@MainActor
enum Appearance {
    static var isDark: Bool { adw_style_manager_get_dark(adw_style_manager_get_default()) != 0 }
    static var animationsEnabled: Bool {
        herb_get_bool(raw(gtk_settings_get_default()), "gtk-enable-animations") != 0
    }

    static func apply(_ choice: String) {
        let scheme: AdwColorScheme = switch choice {
        case "Light": ADW_COLOR_SCHEME_FORCE_LIGHT
        case "Dark": ADW_COLOR_SCHEME_FORCE_DARK
        default: ADW_COLOR_SCHEME_DEFAULT
        }
        adw_style_manager_set_color_scheme(adw_style_manager_get_default(), scheme)
    }
}
