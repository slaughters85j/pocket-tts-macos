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

    func reload() {
        entries = ChatThreadStore.list(kind: kind)
        if let selectedID, !entries.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
    }

    func select(_ id: UUID?) {
        selectedID = id
    }

    func applySaved(_ record: ChatThreadRecord) {
        selectedID = record.id
        reload()
    }

    func togglePinned(_ entry: ChatThreadIndexEntry) {
        ChatThreadStore.setPinned(id: entry.id, kind: entry.kind, pinned: !entry.pinned)
        reload()
    }

    func delete(_ entry: ChatThreadIndexEntry) {
        let id = entry.id
        ChatThreadStore.delete(id: id, kind: entry.kind)
        if selectedID == id { selectedID = nil }
        reload()
    }

    /// Messages-style created date (8/7/26).
    static func createdDateLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "M/d/yy"
        return f.string(from: date)
    }
}
