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

    func test_createListPinDelete_andRestartDoesNotOverwrite() async throws {
        let savedFirst = await ChatThreadStore.saveAsync(ChatThreadRecord(kind: .solo, title: "Hello there"))
        let first = try XCTUnwrap(savedFirst)
        var listed = await ChatThreadStore.listAsync(kind: .solo)
        XCTAssertEqual(listed.count, 1)
        XCTAssertFalse(ChatThreadBrowser.createdDateLabel(first.createdAt).isEmpty)

        // `setPinned` is fire-and-forget; the serial queue guarantees the next `listAsync` sees it.
        ChatThreadStore.setPinned(id: first.id, kind: .solo, pinned: true)
        listed = await ChatThreadStore.listAsync(kind: .solo)
        XCTAssertTrue(listed.first?.pinned == true)

        var live = first
        live.soloMessages = [ChatMessage(role: .user, content: "Keep this")]
        _ = await ChatThreadStore.saveAsync(live)

        // Restart = new record, same title family, old file untouched.
        let savedRestart = await ChatThreadStore.saveAsync(ChatThreadRecord(kind: .solo, title: "Hello there"))
        let restarted = try XCTUnwrap(savedRestart)
        XCTAssertNotEqual(restarted.id, first.id)
        let kept = await ChatThreadStore.loadAsync(id: first.id, kind: .solo)
        XCTAssertEqual(kept?.soloMessages.first?.content, "Keep this")

        ChatThreadStore.delete(id: first.id, kind: .solo)
        let gone = await ChatThreadStore.loadAsync(id: first.id, kind: .solo)
        XCTAssertNil(gone)
        listed = await ChatThreadStore.listAsync(kind: .solo)
        XCTAssertEqual(listed.map(\.id), [restarted.id])
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
        var record = ChatThreadRecord(kind: .solo, title: "Async")
        record.soloMessages = [ChatMessage(role: .user, content: "hi")]
        _ = await ChatThreadStore.saveAsync(record)

        let listed = await ChatThreadStore.listAsync(kind: .solo)
        XCTAssertEqual(listed.map(\.id), [record.id])

        let loaded = await ChatThreadStore.loadAsync(id: record.id, kind: .solo)
        XCTAssertEqual(loaded?.soloMessages.first?.content, "hi")
    }

    func test_saveAsyncAfterDeleteDoesNotResurrect() async {
        var record = ChatThreadRecord(kind: .solo, title: "Doomed")
        record.soloMessages = [ChatMessage(role: .user, content: "keep")]
        _ = await ChatThreadStore.saveAsync(record)
        ChatThreadStore.delete(id: record.id, kind: .solo)

        let saved = await ChatThreadStore.saveAsync(record)
        XCTAssertNil(saved, "tombstone must drop a write queued after delete")
        let loaded = await ChatThreadStore.loadAsync(id: record.id, kind: .solo)
        XCTAssertNil(loaded)
        let listed = await ChatThreadStore.listAsync(kind: .solo)
        XCTAssertTrue(listed.isEmpty)
    }

    // MARK: - Tolerant decoding

    /// Writes raw JSON straight into the store's directory, bypassing the encoder, so these tests exercise
    /// the real decode path a hand-edited or partially-written file would take.
    private func writeRaw(_ json: String, to relativePath: String) throws {
        let url = ChatThreadStore.rootDirectory().appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try XCTUnwrap(json.data(using: .utf8)).write(to: url)
    }

    /// One unusable row must cost that row alone. Before tolerant decoding the array threw, the store
    /// reported an EMPTY index, and the next save wrote that emptiness over every thread the user had.
    func test_oneBadIndexRowDoesNotDestroyTheCatalog() async throws {
        let good = UUID()
        try writeRaw(
            """
            {"entries":[
              {"id":"\(good.uuidString)","kind":"solo","title":"Survivor","theme":"",
               "createdAt":"2026-08-01T00:00:00Z","updatedAt":"2026-08-01T00:00:00Z","pinned":false},
              {"id":"\(UUID().uuidString)","title":"No kind, unaddressable",
               "createdAt":"2026-08-01T00:00:00Z","updatedAt":"2026-08-01T00:00:00Z","pinned":false}
            ]}
            """,
            to: "index.json"
        )

        let listed = await ChatThreadStore.listAsync(kind: .solo)
        XCTAssertEqual(listed.map(\.id), [good], "a single bad row must not empty the catalog")
    }

    /// A row written by an older build lacks the newer keys entirely.
    func test_indexRowMissingNewerKeysStillDecodes() async throws {
        let id = UUID()
        try writeRaw(
            """
            {"entries":[{"id":"\(id.uuidString)","kind":"solo","title":"Old build",
             "createdAt":"2026-08-01T00:00:00Z","updatedAt":"2026-08-01T00:00:00Z"}]}
            """,
            to: "index.json"
        )

        let listed = await ChatThreadStore.listAsync(kind: .solo)
        XCTAssertEqual(listed.map(\.id), [id])
        XCTAssertFalse(listed[0].pinned, "absent pinned must default, not throw")
        XCTAssertNil(listed[0].titleIsCustom)
        XCTAssertEqual(listed[0].theme, "")
    }

    /// Same guarantee for a thread file: a truncated record loads with defaults rather than reading as a
    /// missing thread the sidebar would then evict.
    func test_threadRecordMissingKeysLoadsWithDefaults() async throws {
        let id = UUID()
        try writeRaw(
            """
            {"id":"\(id.uuidString)","kind":"solo","title":"Truncated"}
            """,
            to: "solo/\(id.uuidString).json"
        )

        let loaded = await ChatThreadStore.loadAsync(id: id, kind: .solo)
        XCTAssertEqual(loaded?.id, id)
        XCTAssertEqual(loaded?.title, "Truncated")
        XCTAssertEqual(loaded?.soloMessages.count, 0)
        XCTAssertNil(loaded?.ensemble)
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
