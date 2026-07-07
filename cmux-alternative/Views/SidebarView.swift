import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: TerminalSessionStore
    @State private var expandedFolders = Set<TerminalFolder.ID>()
    @State private var folderBeingRenamed: TerminalFolder?
    @State private var draftFolderTitle = ""
    @State private var sessionBeingRenamed: TerminalSession?
    @State private var draftSessionTitle = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    pinnedZone
                    zoneDivider
                    ephemeralZone
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            expandedFolders.formUnion(store.pinnedFolders.map(\.id))
        }
        .onChange(of: store.pinnedFolders.map(\.id)) { _, folderIDs in
            expandedFolders.formUnion(folderIDs)
        }
        .sheet(item: $folderBeingRenamed) { folder in
            RenameSheet(kind: "Folder", title: $draftFolderTitle) {
                folderBeingRenamed = nil
            } onSave: {
                store.rename(folder, to: draftFolderTitle)
                folderBeingRenamed = nil
            }
        }
        .sheet(item: $sessionBeingRenamed) { session in
            RenameSheet(kind: "Tab", title: $draftSessionTitle) {
                sessionBeingRenamed = nil
            } onSave: {
                store.rename(session, to: draftSessionTitle)
                sessionBeingRenamed = nil
            }
        }
    }

    // MARK: - Pinned zone (persistent, above the divider)

    private var pinnedZone: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Pinned")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.38))
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 4)

            if store.pinnedSessions.isEmpty && store.pinnedFolders.isEmpty {
                Text("Drag tabs here to keep them")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.28))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
            }

            ForEach(store.pinnedSessions) { session in
                sessionRow(session)
            }

            ForEach(store.pinnedFolders) { folder in
                folderSection(folder)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            store.pin(sessionIDs(from: items))
            return true
        }
    }

    private var zoneDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.1))
            .frame(height: 1)
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
    }

    // MARK: - Ephemeral zone (throwaway tabs, below the divider)

    private var ephemeralZone: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(store.ephemeralSessions) { session in
                sessionRow(session)
            }

            Button {
                store.createSession()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 14)
                    Text("New Tab")
                        .font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white.opacity(0.45))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 120)
        }
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            store.unpin(sessionIDs(from: items))
            return true
        }
    }

    // MARK: - Rows

    private func folderSection(_ folder: TerminalFolder) -> some View {
        DisclosureGroup(isExpanded: binding(for: folder.id)) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(folder.sessions) { session in
                    sessionRow(session)
                }
            }
            .padding(.top, 2)
            .padding(.leading, 14)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 16)
                Text(folder.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .contextMenu {
                Button("Rename Folder", systemImage: "pencil") {
                    draftFolderTitle = folder.title
                    folderBeingRenamed = folder
                }
                Button("Delete Folder", systemImage: "trash") {
                    store.deleteFolder(folder.id)
                }
            }
            .dropDestination(for: String.self) { items, _ in
                store.move(sessionIDs(from: items), toFolder: folder.id)
                return true
            }
        }
        .tint(.white.opacity(0.4))
    }

    private func sessionRow(_ session: TerminalSession) -> some View {
        let isSelected = store.selection == session.id
        let isMultiSelected = store.multiSelection.contains(session.id)

        return HStack(spacing: 8) {
            Circle()
                .fill(session.accent.color.opacity(isSelected ? 0.95 : 0.55))
                .frame(width: 7, height: 7)
            Text(session.title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(.white.opacity(isSelected ? 0.95 : 0.62))
                .lineLimit(1)
            Spacer(minLength: 0)
            if session.status == .attention {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(
                    isSelected
                        ? Color.white.opacity(0.14)
                        : (isMultiSelected ? Color.white.opacity(0.07) : Color.clear)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            handleTap(session)
        }
        .draggable(dragPayload(for: session))
        .contextMenu {
            contextMenu(for: session)
        }
    }

    @ViewBuilder
    private func contextMenu(for session: TerminalSession) -> some View {
        let targets = contextTargets(for: session)
        let plural = targets.count > 1 ? " \(targets.count) Tabs" : " Tab"

        Button("New Folder with\(plural)", systemImage: "folder.badge.plus") {
            store.createFolder(with: targets)
        }

        if !store.pinnedFolders.isEmpty {
            Menu("Move to Folder") {
                ForEach(store.pinnedFolders) { folder in
                    Button(folder.title) {
                        store.move(targets, toFolder: folder.id)
                    }
                }
            }
        }

        if targets.contains(where: { !store.isPinned($0) }) {
            Button("Pin\(plural)", systemImage: "pin") {
                store.pin(targets)
            }
        }
        if targets.contains(where: { store.isPinned($0) }) {
            Button("Unpin\(plural)", systemImage: "pin.slash") {
                store.unpin(targets)
            }
        }

        if targets.count == 1 {
            Button("Rename", systemImage: "pencil") {
                draftSessionTitle = session.title
                sessionBeingRenamed = session
            }
        }

        Divider()

        Button("Close\(plural)", systemImage: "xmark") {
            store.close(sessionIDs: targets)
        }
    }

    // MARK: - Selection handling

    private func handleTap(_ session: TerminalSession) {
        let flags = NSEvent.modifierFlags

        if flags.contains(.command) {
            if store.multiSelection.contains(session.id) {
                store.multiSelection.remove(session.id)
            } else {
                store.multiSelection.insert(session.id)
            }
            store.selection = session.id
        } else if flags.contains(.shift), let anchor = store.selection {
            let order = visibleOrder()
            if let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: session.id) {
                store.multiSelection.formUnion(order[min(from, to)...max(from, to)])
            }
        } else {
            store.selection = session.id
            store.multiSelection = [session.id]
        }
    }

    private func contextTargets(for session: TerminalSession) -> Set<TerminalSession.ID> {
        store.multiSelection.count > 1 && store.multiSelection.contains(session.id)
            ? store.multiSelection
            : [session.id]
    }

    private func visibleOrder() -> [TerminalSession.ID] {
        var order = store.pinnedSessions.map(\.id)
        for folder in store.pinnedFolders where expandedFolders.contains(folder.id) {
            order += folder.sessions.map(\.id)
        }
        order += store.ephemeralSessions.map(\.id)
        return order
    }

    // MARK: - Drag & drop

    private func dragPayload(for session: TerminalSession) -> String {
        let ids = contextTargets(for: session)
        return ids.map(\.uuidString).joined(separator: ",")
    }

    private func sessionIDs(from items: [String]) -> Set<TerminalSession.ID> {
        Set(items.flatMap { $0.split(separator: ",") }.compactMap { UUID(uuidString: String($0)) })
    }

    private func binding(for folderID: TerminalFolder.ID) -> Binding<Bool> {
        Binding {
            expandedFolders.contains(folderID)
        } set: { isExpanded in
            if isExpanded {
                expandedFolders.insert(folderID)
            } else {
                expandedFolders.remove(folderID)
            }
        }
    }
}

private struct RenameSheet: View {
    let kind: String
    @Binding var title: String
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename \(kind)")
                .font(.headline)

            TextField("\(kind) name", text: $title)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}

#Preview {
    SidebarView(store: .preview)
        .frame(width: 264, height: 600)
        .background(.black)
}
