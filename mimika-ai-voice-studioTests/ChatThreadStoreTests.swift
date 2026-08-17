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
        XCTAssertFalse(ChatThreadBrowser.createdDateLabel(first.createdAt).isEmpty)

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

    func test_listAndLoadAsync_roundTrip() async {
        var record = ChatThreadStore.create(kind: .solo, title: "Async")
        record.soloMessages = [ChatMessage(role: .user, content: "hi")]
        _ = ChatThreadStore.save(record)

        let listed = await ChatThreadStore.listAsync(kind: .solo)
        XCTAssertEqual(listed.map(\.id), [record.id])

        let loaded = await ChatThreadStore.loadAsync(id: record.id, kind: .solo)
        XCTAssertEqual(loaded?.soloMessages.first?.content, "hi")
    }

    func test_saveAsyncAfterDeleteDoesNotResurrect() async {
        var record = ChatThreadStore.create(kind: .solo, title: "Doomed")
        record.soloMessages = [ChatMessage(role: .user, content: "keep")]
        ChatThreadStore.delete(id: record.id, kind: .solo)

        let saved = await ChatThreadStore.saveAsync(record)
        XCTAssertNil(saved, "tombstone must drop a write queued after delete")
        XCTAssertNil(ChatThreadStore.load(id: record.id, kind: .solo))
        XCTAssertTrue(ChatThreadStore.list(kind: .solo).isEmpty)
    }

    func test_browserApplySavedDoesNotResurrectDeleted() {
        let browser = ChatThreadBrowser()
        var record = ChatThreadRecord(kind: .solo, title: "Ghost")
        record.soloMessages = [ChatMessage(role: .user, content: "x")]
        browser.applySaved(record)
        XCTAssertEqual(browser.entries.map(\.id), [record.id])

        let entry = browser.entries[0]
        browser.delete(entry)
        XCTAssertTrue(browser.entries.isEmpty)

        browser.applySaved(record)
        XCTAssertTrue(browser.entries.isEmpty, "late save must not put a deleted row back")
    }

    func test_applySavedDoesNotStealSelection() {
        let browser = ChatThreadBrowser()
        let first = ChatThreadRecord(kind: .solo, title: "First")
        let second = ChatThreadRecord(kind: .solo, title: "Second")
        browser.applySaved(first)
        browser.select(first.id)
        browser.applySaved(second)
        browser.select(second.id)

        browser.applySaved(first)
        XCTAssertEqual(browser.selectedID, second.id, "flush of the previous thread must not steal the click")
    }

    /// With no `directoryOverride`, a test run must still never resolve to the
    /// user's real Application Support store.
    ///
    /// Regression: most Chat/Ensemble view-model tests never set the override, so
    /// sending a turn wrote fixture threads ("look", "go", "restore me") into the
    /// live sidebar. The interlock in `rootDirectory()` is what stops that, and it
    /// has to hold for tests that don't know it exists.
    func test_rootDirectoryNeverResolvesToLiveStoreUnderTests() {
        let saved = ChatThreadStore.directoryOverride
        ChatThreadStore.directoryOverride = nil
        defer { ChatThreadStore.directoryOverride = saved }

        let root = ChatThreadStore.rootDirectory().standardizedFileURL.path
        let live = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("pocket-tts-macos", isDirectory: true)
            .appendingPathComponent("chat-threads", isDirectory: true)
            .standardizedFileURL.path

        XCTAssertNotEqual(root, live, "unoverridden test writes must not hit the live store")
        XCTAssertTrue(
            root.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path),
            "expected a temp sandbox, got \(root)"
        )
    }
}
