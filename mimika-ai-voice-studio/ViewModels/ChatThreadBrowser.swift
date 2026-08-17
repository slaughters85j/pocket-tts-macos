//
//  ChatThreadBrowser.swift
//  mimika-ai-voice-studio
//
//  Sidebar state for Solo / Ensemble threads. Disk I/O goes through
//  ChatThreadStore; this object only holds the visible catalog + selection.
//

import Foundation
import Observation

// MARK: - ChatThreadBrowser

@MainActor
@Observable
final class ChatThreadBrowser {
    var kind: ChatThreadKind = .solo {
        didSet {
            if oldValue != kind { reload() }
        }
    }
    var entries: [ChatThreadIndexEntry] = []
    var selectedID: UUID?
    var isCollapsed = false

    /// Drop late `applySaved` / `listAsync` results for threads the user deleted.
    private var suppressedIDs: Set<UUID> = []
    private var reloadToken = UUID()

    func reload() {
        let kind = self.kind
        let token = UUID()
        reloadToken = token
        Task { @MainActor [weak self] in
            let listed = await ChatThreadStore.listAsync(kind: kind)
            guard let self, self.reloadToken == token, self.kind == kind else { return }
            self.entries = listed.filter { !self.suppressedIDs.contains($0.id) }
            if let selectedID, !self.entries.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
            }
        }
    }

    func select(_ id: UUID?) {
        selectedID = id
    }

    /// Upsert the catalog row. Does **not** change selection — a late save of
    /// thread A must not steal a click that already moved to thread B.
    /// Timestamp-only writes skip the array write so the sidebar (and the
    /// Chair sitting in the same Chat HStack) is not invalidated every turn.
    func applySaved(_ record: ChatThreadRecord) {
        guard !suppressedIDs.contains(record.id) else { return }
        let entry = record.indexEntry
        if let i = entries.firstIndex(where: { $0.id == entry.id }) {
            if Self.sidebarVisibleFieldsMatch(entries[i], entry) { return }
            entries[i] = entry
        } else {
            entries.insert(entry, at: 0)
        }
    }

    private static func sidebarVisibleFieldsMatch(
        _ lhs: ChatThreadIndexEntry,
        _ rhs: ChatThreadIndexEntry
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.theme == rhs.theme
            && lhs.pinned == rhs.pinned
            && lhs.createdAt == rhs.createdAt
    }

    func togglePinned(_ entry: ChatThreadIndexEntry) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[i].pinned.toggle()
        ChatThreadStore.setPinned(id: entry.id, kind: entry.kind, pinned: entries[i].pinned)
        entries.sort { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned && !rhs.pinned }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    func delete(_ entry: ChatThreadIndexEntry) {
        let id = entry.id
        suppressedIDs.insert(id)
        entries.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
        ChatThreadStore.delete(id: id, kind: entry.kind)
    }

    /// Messages-style created date (8/7/26).
    static func createdDateLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "M/d/yy"
        return f.string(from: date)
    }
}
