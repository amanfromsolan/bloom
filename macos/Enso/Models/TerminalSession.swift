import AppKit
import Foundation
import SwiftUI

/// One swipeable sidebar page: its own pinned/ephemeral tabs and folders.
struct SidebarSpace: Identifiable, Hashable, Codable {
    enum Icon: Hashable, Codable {
        case dot
        case symbol(String)
        case emoji(String)
    }

    let id: UUID
    var name: String
    var icon: Icon
    var pinnedFolders: [TerminalFolder]
    var pinnedSessions: [TerminalSession]
    var ephemeralSessions: [TerminalSession]
    var lastSelection: TerminalSession.ID?

    init(
        id: UUID = UUID(),
        name: String,
        icon: Icon = .dot,
        pinnedFolders: [TerminalFolder] = [],
        pinnedSessions: [TerminalSession] = [],
        ephemeralSessions: [TerminalSession] = [],
        lastSelection: TerminalSession.ID? = nil
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.pinnedFolders = pinnedFolders
        self.pinnedSessions = pinnedSessions
        self.ephemeralSessions = ephemeralSessions
        self.lastSelection = lastSelection
    }

    var sessions: [TerminalSession] {
        pinnedSessions + pinnedFolders.flatMap(\.sessions) + ephemeralSessions
    }
}

struct TerminalFolder: Identifiable, Hashable, Codable {
    let id: UUID
    var title: String
    var sessions: [TerminalSession]
    /// Last-known cwd of the folder's most recently active tab. A folder is,
    /// in practice, a project: this keeps the association alive after the
    /// last tab is gone so a new tab can start back in the project directory.
    /// Optional, so state files written before this field decode as nil.
    var lastWorkingDirectory: String?

    init(
        id: UUID = UUID(),
        title: String,
        sessions: [TerminalSession] = [],
        lastWorkingDirectory: String? = nil
    ) {
        self.id = id
        self.title = title
        self.sessions = sessions
        self.lastWorkingDirectory = lastWorkingDirectory
    }
}

struct TerminalSession: Identifiable, Hashable, Codable {
    enum Status: String, CaseIterable, Codable {
        case running = "Running"
        case idle = "Idle"
        case attention = "Needs Attention"
    }

    /// Who last named the tab; higher origins are never overwritten by
    /// lower ones (user > auto > shell).
    enum TitleOrigin: String, Codable {
        /// Live shell-integration title; keeps updating as commands run.
        case shell
        /// One-shot LLM auto-name; freezes the title against shell updates.
        case auto
        /// Manual rename; nothing may touch it again.
        case user
    }

    let id: UUID
    var title: String
    var titleOrigin: TitleOrigin
    var workingDirectory: String
    var branch: String?
    var status: Status
    var accent: SessionAccent
    var lastActivity: Date
    /// Live foreground-process detection; session-only, resets to a plain
    /// shell on relaunch, so it is not persisted.
    var runningProcess: TabProcess?

    private enum CodingKeys: String, CodingKey {
        case id, title, titleOrigin, workingDirectory, branch, status, accent, lastActivity
    }

    init(
        id: UUID = UUID(),
        title: String,
        titleOrigin: TitleOrigin = .shell,
        workingDirectory: String,
        branch: String? = nil,
        status: Status = .running,
        accent: SessionAccent = .blue,
        lastActivity: Date = .now
    ) {
        self.id = id
        self.title = title
        self.titleOrigin = titleOrigin
        self.workingDirectory = workingDirectory
        self.branch = branch
        self.status = status
        self.accent = accent
        self.lastActivity = lastActivity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        // Absent in pre-auto-naming state files.
        titleOrigin = try container.decodeIfPresent(TitleOrigin.self, forKey: .titleOrigin) ?? .shell
        workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        status = try container.decode(Status.self, forKey: .status)
        accent = try container.decode(SessionAccent.self, forKey: .accent)
        lastActivity = try container.decode(Date.self, forKey: .lastActivity)
        runningProcess = nil
    }
}

enum SessionAccent: String, CaseIterable, Hashable, Codable {
    case blue
    case green
    case orange
    case pink
    case violet

    /// Jewel tones tuned for the dark frosted sidebar, plus deeper variants for
    /// the light sidebar. The pale dark-mode tones have almost no contrast on a
    /// light background, so light mode resolves to saturated, darker versions.
    var color: Color {
        let pair = hexPair
        return Color(nsColor: Theme.dynamic(
            dark: NSColor(hex: pair.dark),
            light: NSColor(hex: pair.light)
        ))
    }

    private var hexPair: (dark: UInt32, light: UInt32) {
        switch self {
        case .blue: (0x6FA8FF, 0x2F6FE0)
        case .green: (0x5BD9A9, 0x12A176)
        case .orange: (0xFFB454, 0xD97D0F)
        case .pink: (0xFF7EB6, 0xDE3F86)
        case .violet: (0xB18CFF, 0x7B4DE0)
        }
    }

    static func cycling(index: Int) -> SessionAccent {
        let accents = Self.allCases
        return accents[index % accents.count]
    }
}
