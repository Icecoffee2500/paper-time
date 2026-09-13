import CoreGraphics
import Foundation
import PaperCore
import Testing
@testable import LibraryStore

/// Turning something off has to stick.
///
/// The first version compared the file on disk against the value being written
/// rather than against the value the caller started from, so every save looked
/// like a conflict and ran the merge. The merge rules could only add — a
/// favourite either side had set stayed set, a paper once Read stayed Read — so
/// unfavouriting and un-reading silently did nothing.
@Suite("State persistence")
struct StatePersistenceTests {
    static func makeLibrary() throws -> (LibraryStore, PaperFolder, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "papertime-state-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let folder = PaperFolder(
            url: root.appending(path: "papers/one", directoryHint: .isDirectory)
        )
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        return (LibraryStore(root: root), folder, root)
    }

    @Test("A favourite can be turned back off")
    func unfavouriting() async throws {
        let (store, folder, root) = try Self.makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        var state = PaperState()
        state.isFavorite = true
        let saved = try await store.save(state: state, in: folder, baseline: nil)
        #expect(saved.isFavorite)

        var cleared = saved
        cleared.isFavorite = false
        let afterClearing = try await store.save(state: cleared, in: folder, baseline: saved)
        #expect(!afterClearing.isFavorite)

        let reloaded = try await store.loadState(folder)
        #expect(!reloaded.isFavorite)
    }

    @Test("A paper can move back from Read to Unread")
    func unreading() async throws {
        let (store, folder, root) = try Self.makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        var state = PaperState()
        state.readingStatus = .read
        let saved = try await store.save(state: state, in: folder, baseline: nil)

        var back = saved
        back.readingStatus = .unread
        let afterChange = try await store.save(state: back, in: folder, baseline: saved)
        #expect(afterChange.readingStatus == .unread)
        #expect(try await store.loadState(folder).readingStatus == .unread)
    }

    @Test("A cleared note stays cleared")
    func clearingANote() async throws {
        let (store, folder, root) = try Self.makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        var state = PaperState()
        state.summaryNote = "worth re-reading"
        let saved = try await store.save(state: state, in: folder, baseline: nil)

        var cleared = saved
        cleared.summaryNote = ""
        let afterClearing = try await store.save(state: cleared, in: folder, baseline: saved)
        #expect(afterClearing.summaryNote.isEmpty)
    }

    @Test("A concurrent write from another device is still merged, newest wins")
    func concurrentWriteIsMerged() async throws {
        let (store, folder, root) = try Self.makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let baseline = try await store.save(state: PaperState(), in: folder, baseline: nil)

        // Another device writes the file while this one holds the baseline.
        var elsewhere = baseline
        elsewhere.summaryNote = "written on the iPad"
        elsewhere.updatedAt = .now.addingTimeInterval(60)
        elsewhere.updatedBy = "iPad-TEST"
        try FileOperations.encodeAndWrite(elsewhere, to: folder.stateURL)

        var mine = baseline
        mine.rating = 4
        let result = try await store.save(state: mine, in: folder, baseline: baseline)

        // The other device's write is newer, so it wins the record outright.
        #expect(result.summaryNote == "written on the iPad")
    }

    @Test("A tag removed on this device is not resurrected")
    func removingATag() async throws {
        let (store, folder, root) = try Self.makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let tag = UUID()
        var meta = PaperMeta()
        meta.tagIDs = [tag]
        let saved = try await store.save(meta: meta, in: folder, baseline: nil)
        #expect(saved.tagIDs == [tag])

        var withoutTag = saved
        withoutTag.tagIDs = []
        let afterRemoval = try await store.save(meta: withoutTag, in: folder, baseline: saved)
        #expect(afterRemoval.tagIDs.isEmpty)
        #expect(try await store.loadMeta(folder).tagIDs.isEmpty)
    }

    @Test("A hand-edited record still beats an automatic one on a real conflict")
    func manualStillWins() async throws {
        let (store, folder, root) = try Self.makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        var mine = PaperMeta()
        mine.confidence = .manual
        mine.csl.title = "What I typed"
        let baseline = PaperMeta()

        var elsewhere = PaperMeta()
        elsewhere.confidence = .verified
        elsewhere.csl.title = "What a registrar said"
        elsewhere.updatedAt = .now.addingTimeInterval(60)
        try FileOperations.encodeAndWrite(elsewhere, to: folder.metadataURL)

        let result = try await store.save(meta: mine, in: folder, baseline: baseline)
        #expect(result.csl.title == "What I typed")
    }
}
