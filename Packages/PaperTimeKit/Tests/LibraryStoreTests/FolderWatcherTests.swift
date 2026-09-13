import Foundation
import Testing
@testable import LibraryStore

/// A library folder that only notices new files when the app is relaunched
/// would not really be a folder.
@Suite("Folder watching")
struct FolderWatcherTests {
    @Test("A file appearing in the folder reaches the callback")
    func firesOnNewFile() async throws {
        let root = try FlatLayoutTests.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let signal = AsyncStream<Void>.makeStream()
        let watcher = FolderWatcher(url: root, quietPeriod: .milliseconds(50)) {
            signal.continuation.yield()
        }
        watcher.start()
        defer { watcher.stop() }

        // Give the source a moment to arm before touching the folder.
        try await Task.sleep(for: .milliseconds(200))
        try Data("hello".utf8).write(to: root.appending(path: "arrived.pdf"))

        let heard = await withTimeout(seconds: 5) {
            var iterator = signal.stream.makeAsyncIterator()
            return await iterator.next() != nil
        }
        #expect(heard == true)
    }

    @Test("Bursts of changes are reported once")
    func coalesces() async throws {
        let root = try FlatLayoutTests.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let counter = Counter()
        let watcher = FolderWatcher(url: root, quietPeriod: .milliseconds(150)) {
            Task { await counter.increment() }
        }
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(200))

        for index in 0..<8 {
            try Data("x".utf8).write(to: root.appending(path: "file\(index).pdf"))
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(600))

        let calls = await counter.value
        #expect(calls >= 1)
        #expect(calls <= 3)
    }

    /// The store's cheap check is what the watcher's callback runs, so it has
    /// to agree with the authoritative one.
    @Test("Unclaimed documents match what a full scan would report")
    func unclaimedAgreesWithFullScan() async throws {
        let root = try FlatLayoutTests.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try FlatLayoutTests.writePDF(named: "known.pdf", in: root)
        let store = LibraryStore(root: root)
        try await store.bootstrap()
        _ = try await store.importDocument(at: root.appending(path: "known.pdf"))

        try FlatLayoutTests.writePDF(named: "dropped-in.pdf", in: root)
        let claimed: Set<String> = ["known.pdf"]

        let cheap = await store.unclaimedDocumentURLs(claiming: claimed)
        let full = await store.looseDocumentURLs()
        #expect(cheap.map(\.lastPathComponent) == ["dropped-in.pdf"])
        #expect(cheap.map(\.lastPathComponent) == full.map(\.lastPathComponent))
        #expect(await store.documentsAreMissing(among: claimed) == false)
        #expect(await store.documentsAreMissing(among: ["gone.pdf"]) == true)
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private func withTimeout(
    seconds: Double,
    _ work: @escaping @Sendable () async -> Bool
) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask { await work() }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
}
