import AppKit
import Combine
import SwiftUI

/// Enso's terminal-theme layer on top of the user's own Ghostty config.
///
/// The user's ghostty config files are never touched. Enso keeps its choice in
/// its own places instead:
///   - UserDefaults for the durable preference (an all-spaces theme plus
///     per-space overrides, and the "recent themes" list), and
///   - a small override config file under Application Support that is loaded
///     *after* the user's config whenever a `ghostty_config_t` is built, so
///     Enso's keys win while everything else (fonts, keybinds, ...) stays the
///     user's. Besides `theme` it restates the theme's own `background` and
///     `foreground`, because ghostty lets an explicitly set color in the
///     user's config outrank a theme's — restating them makes ordinary
///     last-key-wins precedence apply the theme's colors anyway. It also
///     pins `background-opacity = 1` (theme or not), so the terminal's
///     rendered background exactly matches the chrome painted with it.
///
/// Live application is real: changing the theme rebuilds the config and pushes
/// it through `ghostty_app_update_config` / `ghostty_surface_update_config`
/// (see GhosttyRuntime.reloadConfig), which recolors running terminals
/// immediately — the same mechanism Ghostty itself uses for config reload.
@MainActor
final class TerminalThemeManager: ObservableObject {
    static let shared = TerminalThemeManager()

    enum Scope {
        case thisSpace(SidebarSpace.ID)
        case allSpaces
    }

    static let allSpacesDefaultsKey = "terminalThemeAllSpaces"
    static let bySpaceDefaultsKey = "terminalThemeBySpace"
    static let recentsDefaultsKey = "terminalThemeRecents"
    /// The last theme name pushed live (preview or commit). Persisted so the
    /// chrome background can seed itself at launch without re-parsing the
    /// on-disk override file — that file is still the source of truth for the
    /// running config (GhosttyRuntime.loadConfig reads it), this key only
    /// mirrors the applied *name* for the UI.
    static let appliedDefaultsKey = "terminalThemeApplied"

    /// Every bundled Ghostty theme name (Enso ships Ghostty's theme set under
    /// Resources/ghostty/themes, the location libghostty resolves `theme`
    /// names from), sorted for the "All Themes" section.
    let themes: [String]

    /// Recently applied themes, most recent first. Seeded with a few
    /// well-known ones so the picker's "Recent" section reads believably
    /// before the user has committed anything.
    @Published private(set) var recentThemeNames: [String]

    /// True while `recentThemeNames` is still the well-known seed (the durable
    /// key is absent). The picker titles the section "Suggested" rather than
    /// "Recent" until the first real commit writes the key and flips this.
    private(set) var recentsAreSeeded: Bool

    /// Bumped on every live apply (preview or commit) so chrome observing the
    /// manager re-renders. The applied *name* mirror; the applied *background*
    /// is `themeBackground` below.
    @Published private(set) var appliedThemeName: String?

    /// The running terminal's background color, republished from
    /// GhosttyRuntime whenever it (re)loads config. Chrome that blends with
    /// the terminal (the header strip, the palette shadows) observes this
    /// directly instead of reaching into the runtime and relying on the
    /// re-render ordering to have refreshed the runtime's copy first.
    @Published private(set) var themeBackground: Color

    /// True between the palette starting a live preview and either a commit
    /// or a cancel. While previewing, space switches don't reapply.
    private(set) var isPreviewing = false

    private weak var store: TerminalSessionStore?
    private var previewWorkItem: DispatchWorkItem?

    private init() {
        themes = Self.enumerateBundledThemes()
        let storedRecents = UserDefaults.standard.stringArray(forKey: Self.recentsDefaultsKey)
        recentsAreSeeded = storedRecents == nil
        recentThemeNames = storedRecents
            ?? ["Catppuccin Mocha", "TokyoNight", "Nord", "Gruvbox Dark"]
        // Seed the applied name from the durable mirror. The running config
        // was built from the override file at startup (GhosttyRuntime.loadConfig
        // loads it), and this key was written alongside it on the last apply.
        appliedThemeName = UserDefaults.standard.string(forKey: Self.appliedDefaultsKey)
        // Seed from the runtime's initial config read (its default until
        // ensureStarted runs); attach() and every reload republish the real one.
        themeBackground = GhosttyRuntime.shared.themeBackground
    }

    /// Called once from the root view. Reconciles the on-disk override (which
    /// tracks the *applied* theme, possibly a stale preview from a crash) with
    /// the committed preference for the active space.
    func attach(to store: TerminalSessionStore) {
        self.store = store
        // Seed from the runtime's startup read (config is built by then), then
        // the reloadConfig below republishes it after the override is applied.
        themeBackground = GhosttyRuntime.shared.themeBackground
        // Unconditional write + reload, bypassing apply()'s no-change guard:
        // the override file must exist even with no theme picked (it pins
        // background-opacity), and one written by an older build may lack
        // that key.
        let name = effectiveThemeName(forSpace: store.activeSpaceID)
        setAppliedName(name)
        Self.writeOverrideFile(themeName: name)
        GhosttyRuntime.shared.reloadConfig()
    }

    // MARK: - Preference

    /// The committed theme for a space: its own override, else the all-spaces
    /// choice, else nil (the user's ghostty config as-is).
    func effectiveThemeName(forSpace spaceID: SidebarSpace.ID) -> String? {
        themeBySpace[spaceID.uuidString] ?? allSpacesTheme
    }

    private var allSpacesTheme: String? {
        UserDefaults.standard.string(forKey: Self.allSpacesDefaultsKey)
    }

    private var themeBySpace: [String: String] {
        UserDefaults.standard.dictionary(forKey: Self.bySpaceDefaultsKey) as? [String: String] ?? [:]
    }

    /// Whether Enso holds any committed theme preference (an all-spaces choice
    /// or any per-space override). Drives the picker's "Use My Ghostty Config"
    /// reset row, which is pointless when there's nothing to reset.
    var hasThemePreference: Bool {
        allSpacesTheme != nil || !themeBySpace.isEmpty
    }

    // MARK: - Live preview / commit

    /// Recolors the running terminals to `name` without persisting anything;
    /// `nil` previews the user's own ghostty config (the "Use My Ghostty
    /// Config" row). Debounced a beat so held arrow keys don't rebuild the
    /// config per row.
    func preview(_ name: String?) {
        isPreviewing = true
        previewWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.apply(name)
        }
        previewWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    /// Reverts an uncommitted preview to the committed theme.
    func cancelPreview() {
        previewWorkItem?.cancel()
        previewWorkItem = nil
        guard isPreviewing else { return }
        isPreviewing = false
        let spaceID = store?.activeSpaceID
        apply(spaceID.flatMap { effectiveThemeName(forSpace: $0) } ?? allSpacesTheme)
    }

    /// Persists the choice into Enso's own config (UserDefaults) and leaves
    /// the previewed colors applied.
    func commit(_ name: String, scope: Scope) {
        previewWorkItem?.cancel()
        previewWorkItem = nil
        isPreviewing = false

        let defaults = UserDefaults.standard
        switch scope {
        case .allSpaces:
            defaults.set(name, forKey: Self.allSpacesDefaultsKey)
            // "All Spaces" means all: older per-space overrides give way.
            defaults.removeObject(forKey: Self.bySpaceDefaultsKey)
        case .thisSpace(let spaceID):
            var map = themeBySpace
            map[spaceID.uuidString] = name
            defaults.set(map, forKey: Self.bySpaceDefaultsKey)
        }

        var recents = recentThemeNames.filter { $0 != name }
        recents.insert(name, at: 0)
        recentThemeNames = Array(recents.prefix(5))
        defaults.set(recentThemeNames, forKey: Self.recentsDefaultsKey)
        // The recents list is now the user's own; the picker stops calling the
        // section "Suggested".
        recentsAreSeeded = false

        apply(name)
    }

    /// "Use My Ghostty Config": clears every Enso theme preference (all-spaces
    /// and per-space) so the user's own ghostty config shows through, and
    /// applies it live. The override file is still written by `apply(nil)` —
    /// it pins background-opacity even with no theme.
    func clearThemePreference() {
        previewWorkItem?.cancel()
        previewWorkItem = nil
        isPreviewing = false
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.allSpacesDefaultsKey)
        defaults.removeObject(forKey: Self.bySpaceDefaultsKey)
        apply(nil)
    }

    /// Per-space themes follow the active space; called from the store on
    /// space switches.
    func activeSpaceDidChange(_ spaceID: SidebarSpace.ID) {
        guard !isPreviewing else { return }
        apply(effectiveThemeName(forSpace: spaceID))
    }

    /// Rewrites the override layer and pushes a rebuilt config to the running
    /// app and every live surface. `nil` drops the override so the user's own
    /// ghostty config shows through unmodified.
    private func apply(_ name: String?) {
        guard name != appliedThemeName else { return }
        setAppliedName(name)
        Self.writeOverrideFile(themeName: name)
        GhosttyRuntime.shared.reloadConfig()
    }

    /// Publishes the applied name and mirrors it into UserDefaults so the next
    /// launch can seed `appliedThemeName` without parsing the override file.
    private func setAppliedName(_ name: String?) {
        appliedThemeName = name
        let defaults = UserDefaults.standard
        if let name {
            defaults.set(name, forKey: Self.appliedDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.appliedDefaultsKey)
        }
    }

    /// Republished by GhosttyRuntime after it (re)loads config, carrying the
    /// freshly resolved terminal background so observing chrome repaints in
    /// step with the terminal recolor.
    func updateThemeBackground(_ color: Color) {
        themeBackground = color
    }

    /// Called from the store when a space is deleted: drops that space's
    /// per-space theme override so the entry doesn't linger in storage. Kept
    /// here (rather than the store reaching into UserDefaults) so all
    /// per-space theme state stays owned by the manager.
    func spaceWasDeleted(_ spaceID: SidebarSpace.ID) {
        var map = themeBySpace
        guard map.removeValue(forKey: spaceID.uuidString) != nil else { return }
        UserDefaults.standard.set(map, forKey: Self.bySpaceDefaultsKey)
    }

    /// On quit: if a preview is still in flight, rewrite the override file back
    /// to the committed theme so the next launch's first paint isn't the
    /// abandoned preview (ensureStarted builds the startup config from this
    /// file before the manager attaches and reconciles).
    func reconcileOverrideOnTermination() {
        guard isPreviewing else { return }
        previewWorkItem?.cancel()
        previewWorkItem = nil
        isPreviewing = false
        let spaceID = store?.activeSpaceID
        let committed = spaceID.flatMap { effectiveThemeName(forSpace: $0) } ?? allSpacesTheme
        Self.writeOverrideFile(themeName: committed)
        setAppliedName(committed)
    }

    // MARK: - Enso's ghostty override file

    /// Enso-owned config fragment, loaded after the user's ghostty config
    /// whenever a ghostty_config_t is built. Never the user's own config file.
    nonisolated static var overrideFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Enso", isDirectory: true)
            .appendingPathComponent("ghostty-overrides.conf", isDirectory: false)
    }

    private static func writeOverrideFile(themeName: String?) {
        let url = overrideFileURL
        // Always written (theme or not): Enso needs the terminal fully
        // opaque. The header strip is a flat fill of the theme background,
        // and a user background-opacity < 1 shifts the rendered terminal a
        // shade off that fill — visibly so on light themes. Translucency
        // bought nothing here anyway: the surface sits on an opaque
        // same-color container, never the desktop.
        var lines = ["background-opacity = 1"]
        if let themeName {
            // Ghostty treats an explicit `background`/`foreground` in the
            // user's config as outranking any theme's colors, regardless of
            // where the `theme` key loads. Restating the theme's own values
            // here turns that into plain last-key-wins precedence, so this
            // file (loaded last) actually recolors the terminal even when
            // the user pins those keys.
            lines.append("theme = \(themeName)")
            let colors = themeColors(named: themeName)
            if let background = colors.backgroundHex {
                lines.append("background = \(background)")
            }
            if let foreground = colors.foregroundHex {
                lines.append("foreground = \(foreground)")
            }
        }
        let contents = """
        # Managed by Enso. This is Enso's own layer over your Ghostty config;
        # your ~/.config/ghostty files are never modified.
        \(lines.joined(separator: "\n"))

        """
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("TerminalThemeManager: failed to write override file: %@", "\(error)")
        }
    }

    // MARK: - Theme catalog

    private nonisolated static var themesDirectoryURL: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("ghostty", isDirectory: true)
            .appendingPathComponent("themes", isDirectory: true)
    }

    private static func enumerateBundledThemes() -> [String] {
        guard
            let directory = themesDirectoryURL,
            let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
            !names.isEmpty
        else {
            // Previews / stripped bundles: a believable well-known subset.
            return [
                "Atom One Dark", "Ayu", "Catppuccin Mocha", "Dracula",
                "Everforest Dark Hard", "GitHub Dark", "Gruvbox Dark",
                "Kanagawa Wave", "Nord", "Rose Pine", "Solarized Dark Patched",
                "TokyoNight",
            ]
        }
        return names
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// One theme's parsed colors, read from its bundled file once and cached:
    /// `#rrggbb` hex strings for the override file, resolved `Color`s for the
    /// palette-row swatch, and an accent (ANSI palette-4, else foreground) for
    /// the fallback dot. One pass, one cache, feeding every call site below.
    private struct ThemeColors {
        var backgroundHex: String?
        var foregroundHex: String?
        var background: Color?
        var foreground: Color?
        /// palette-4 (ANSI blue) else foreground; nil when neither parses.
        var accent: Color?
    }

    private static var themeColorsCache: [String: ThemeColors] = [:]

    private static func themeColors(named name: String) -> ThemeColors {
        if let cached = themeColorsCache[name] { return cached }
        let colors = parseThemeColors(named: name)
        themeColorsCache[name] = colors
        return colors
    }

    private static func parseThemeColors(named name: String) -> ThemeColors {
        var colors = ThemeColors()
        guard
            let url = themesDirectoryURL?.appendingPathComponent(name),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return colors }

        var paletteBlueHex: String?
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "background" where colors.backgroundHex == nil:
                colors.backgroundHex = normalizedHex(parts[1])
            case "foreground" where colors.foregroundHex == nil:
                colors.foregroundHex = normalizedHex(parts[1])
            case "palette" where paletteBlueHex == nil:
                // "palette = 4=#89b4fa"
                let entry = parts[1].split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if entry.count == 2, entry[0] == "4" {
                    paletteBlueHex = normalizedHex(entry[1])
                }
            default:
                break
            }
        }

        colors.background = colors.backgroundHex.flatMap(color(fromHex:))
        colors.foreground = colors.foregroundHex.flatMap(color(fromHex:))
        colors.accent = (paletteBlueHex ?? colors.foregroundHex).flatMap(color(fromHex:))
        return colors
    }

    /// A representative color for a theme's row bullet: its ANSI blue
    /// (palette 4), falling back to its foreground, then a neutral ink.
    func accentColor(for name: String) -> Color {
        Self.themeColors(named: name).accent ?? Theme.ink.opacity(0.55)
    }

    /// A theme's background/foreground as `Color`s for the palette-row swatch,
    /// or nil when the file has neither parseable — the caller falls back to
    /// the accent dot.
    func swatchColors(for name: String) -> (background: Color, foreground: Color)? {
        let colors = Self.themeColors(named: name)
        guard let background = colors.background, let foreground = colors.foreground else {
            return nil
        }
        return (background, foreground)
    }

    /// Accepts `#1e1e2e`, `1e1e2e`, or either form in quotes; returns the
    /// canonical `#rrggbb` ghostty accepts, or nil for anything else.
    private static func normalizedHex(_ raw: String) -> String? {
        var hex = raw
        if hex.hasPrefix("\""), hex.hasSuffix("\""), hex.count >= 2 {
            hex = String(hex.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, UInt32(hex, radix: 16) != nil else { return nil }
        return "#" + hex.lowercased()
    }

    private static func color(fromHex string: String) -> Color? {
        var hex = string
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return Color(nsColor: NSColor(hex: value))
    }
}
