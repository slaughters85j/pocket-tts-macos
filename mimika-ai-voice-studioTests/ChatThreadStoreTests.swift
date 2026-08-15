//
//  ChatThreadStoreTests.swift
//  mimika-ai-voice-studioTests
//

import XCTest
@testable import mimika_ai_voice_studio

@MainActor
final class ChatThreadStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-threads-tests-\(UUID().uuidString)", isDirectory: true)
        ChatThreadStore.directoryOverride = url
    }

    override func tearDown() {
        if let url = ChatThreadStore.directoryOverride {
            try? FileManager.default.removeItem(at: url)
        }
        ChatThreadStore.directoryOverride = nil
        super.tearDown()
    }

    func test_createListPinDelete_andRestartDoesNotOverwrite() {
        let first = ChatThreadStore.create(kind: .solo, title: "Hello there")
        XCTAssertEqual(ChatThreadStore.list(kind: .solo).count, 1)
        XCTAssertFalse(ChatThreadStore.createdDateLabelIsEmpty(first.createdAt))

        ChatThreadStore.setPinned(id: first.id, kind: .solo, pinned: true)
        XCTAssertTrue(ChatThreadStore.list(kind: .solo).first?.pinned == true)

        var live = first
        live.soloMessages = [ChatMessage(role: .user, content: "Keep this")]
        _ = ChatThreadStore.save(live)

        // Restart = new record, same title family, old file untouched.
        let restarted = ChatThreadStore.create(kind: .solo, title: "Hello there")
        XCTAssertNotEqual(restarted.id, first.id)
        XCTAssertEqual(ChatThreadStore.load(id: first.id, kind: .solo)?.soloMessages.first?.content, "Keep this")

        ChatThreadStore.delete(id: first.id, kind: .solo)
        XCTAssertNil(ChatThreadStore.load(id: first.id, kind: .solo))
        XCTAssertEqual(ChatThreadStore.list(kind: .solo).map(\.id), [restarted.id])
    }

    func test_cleanedTheme_stripsQuotesAndNewlines() {
        XCTAssertEqual(
            ChatThreadStore.cleanedTheme("\"Planning a rooftop party\"\nextra"),
            "Planning a rooftop party"
        )
    }

    func test_createdDateLabel_isMessagesStyle() {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 8
        comps.day = 7
        let date = Calendar(identifier: .gregorian).date(from: comps)!
        XCTAssertEqual(ChatThreadBrowser.createdDateLabel(date), "8/7/26")
    }
}

private extension ChatThreadStore {
    static func createdDateLabelIsEmpty(_ date: Date) -> Bool {
        ChatThreadBrowser.createdDateLabel(date).isEmpty
    }
}
