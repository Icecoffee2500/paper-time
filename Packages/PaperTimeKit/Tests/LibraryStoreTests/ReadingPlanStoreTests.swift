import Foundation
import PaperCore
import Testing
@testable import LibraryStore

/// The plan files, the days and the materials, as the folder keeps them.
@Suite("Reading plans on disk")
struct ReadingPlanStoreTests {
    static func makeLibrary() throws -> (LibraryStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "papertime-plans-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (LibraryStore(root: root), root)
    }

    /// iCloud Drive flags the files inside `.papertime` as hidden. A listing
    /// that skipped hidden files found no plans at all on an iCloud library,
    /// and every plan vanished at the next read (2026-11-16).
    @Test("A plan whose file is flagged hidden is still read")
    func hiddenFlag() async throws {
        let (store, root) = try Self.makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        var plan = ReadingPlan(name: "JEPA")
        plan.add([UUID(), UUID()])
        try await store.savePlan(plan)
        var url = LibraryLayout.planURL(id: plan.id, inLibrary: root)
        var values = URLResourceValues()
        values.isHidden = true
        try url.setResourceValues(values)
        #expect(try url.resourceValues(forKeys: [.isHiddenKey]).isHidden == true)

        let read = await store.loadPlans()
        #expect(read.map(\.id) == [plan.id])
        #expect(read.first?.entries.count == 2)
    }

    @Test("Dot files beside the plans are left out")
    func dotFiles() async throws {
        let (store, root) = try Self.makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = ReadingPlan(name: "A")
        try await store.savePlan(plan)
        let directory = LibraryLayout.plansDirectoryURL(inLibrary: root)
        try Data("{".utf8).write(to: directory.appending(path: ".DS_Store"))
        try Data("{}".utf8).write(to: directory.appending(path: ".tmp.json"))
        #expect(await store.loadPlans().map(\.id) == [plan.id])
    }

    @Test("Edits apply to the file as it is now")
    func editsReadFirst() async throws {
        let (store, root) = try Self.makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let one = UUID(), two = UUID()
        var plan = ReadingPlan(name: "A")
        plan.add([one])
        try await store.savePlan(plan)
        // Another device adds a paper to the file.
        var elsewhere = plan
        elsewhere.add([two])
        try FileOperations.encodeAndWrite(elsewhere, to: LibraryLayout.planURL(id: plan.id, inLibrary: root))
        // This one, still holding the old copy, renames it.
        let saved = try await store.updatePlan(plan.id) { $0.name = "B" }
        #expect(saved?.name == "B")
        #expect(saved?.entries.map(\.paper) == [one, two])
    }

    @Test("A day and materials are read back; none is no file")
    func dayAndMaterials() async throws {
        let (store, root) = try Self.makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = PaperFolder(url: root.appending(path: "papers/one", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        #expect(await store.loadSchedule(folder) == nil)
        #expect(await store.loadLinks(folder).isEmpty)

        try await store.saveSchedule(PlanDay("2026-11-20"), in: folder)
        #expect(await store.loadSchedule(folder) == PlanDay("2026-11-20"))
        try await store.saveSchedule(nil, in: folder)
        #expect(!FileManager.default.fileExists(atPath: folder.scheduleURL.path(percentEncoded: false)))

        let link = PaperMaterial(kind: .code, url: "https://github.com/a/b")
        try await store.updateLinks(in: folder) { $0.append(link) }
        // Dates are written to the second, so the id and the address are what
        // must come back.
        let read = await store.loadLinks(folder)
        #expect(read.map(\.id) == [link.id] && read.first?.url == link.url && read.first?.kind == .code)
        try await store.updateLinks(in: folder) { $0.removeAll() }
        #expect(!FileManager.default.fileExists(atPath: folder.linksURL.path(percentEncoded: false)))
    }
}
