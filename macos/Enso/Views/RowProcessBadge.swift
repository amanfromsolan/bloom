import SwiftUI

/// Detected-process badge at chrome-row scale — the command palette and
/// Ctrl-Tab switcher twin of the sidebar's ProcessBadgeView, a notch bigger
/// to match their larger rows. Agents get their full-color mark, known
/// tools a neutral-ink SF Symbol, and anything else alive the running-blue
/// dot in the same geometry as the accent dot it stands in for.
struct RowProcessBadge: View {
    let process: TabProcess
    let isHighlighted: Bool

    var body: some View {
        switch process.badge {
        case .agent(let base):
            // 24 pt draws the 48-grid artwork: 24 pt @2x is 48 physical
            // pixels, so the marks land 1:1 on the Retina grid. The inner
            // frame is the visual size; the outer one is the layout
            // footprint, kept under the row title's line height so rows
            // stay exactly as tall as their dot-only neighbours — the art
            // overflows evenly into the row padding. Light/dark appearance
            // variants resolve from the app colorScheme (these rows sit on
            // app chrome, not the terminal background, so no luminance
            // override is needed here).
            Image("\(base)48")
                .resizable()
                .renderingMode(.original)
                .aspectRatio(contentMode: .fit)
                // Unhighlighted rows fade like the rows' other glyphs do.
                .opacity(isHighlighted ? 1 : 0.7)
                .frame(width: 24, height: 24)
                .frame(width: 16, height: 16)
        case .symbol(let name):
            // Neutral ink like the rows' other glyphs — tool badges are
            // status, not identity, so they don't take the tab accent.
            Image(systemName: name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text(isHighlighted ? 0.9 : 0.7))
        case .dot:
            // A live process without artwork: the idle terminal glyph in
            // running blue, so "something is running here" still reads.
            Image("TerminalIdle16")
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(Color.blue.opacity(isHighlighted ? 0.95 : 0.7))
                .frame(width: 22, height: 22)
        }
    }
}
