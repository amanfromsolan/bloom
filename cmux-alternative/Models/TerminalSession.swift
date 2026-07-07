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

    init(
        id: UUID = UUID(),
        title: String,
        sessions: [TerminalSession] = []
    ) {
        self.id = id
        self.title = title
        self.sessions = sessions
    }
}

struct TerminalSession: Identifiable, Hashable, Codable {
    enum Status: String, CaseIterable, Codable {
        case running = "Running"
        case idle = "Idle"
        case attention = "Needs Attention"
    }

    let id: UUID
    var title: String
    var workingDirectory: String
    var branch: String?
    var status: Status
    var accent: SessionAccent
    var lastActivity: Date

    init(
        id: UUID = UUID(),
        title: String,
        workingDirectory: String,
        branch: String? = nil,
        status: Status = .running,
        accent: SessionAccent = .blue,
        lastActivity: Date = .now
    ) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
        self.branch = branch
        self.status = status
        self.accent = accent
        self.lastActivity = lastActivity
    }
}

enum SessionAccent: String, CaseIterable, Hashable, Codable {
    case blue
    case green
    case orange
    case pink
    case violet

    var color: Color {
        switch self {
        case .blue:
            .blue
        case .green:
            .green
        case .orange:
            .orange
        case .pink:
            .pink
        case .violet:
            .purple
        }
    }

    static func cycling(index: Int) -> SessionAccent {
        let accents = Self.allCases
        return accents[index % accents.count]
    }
}
