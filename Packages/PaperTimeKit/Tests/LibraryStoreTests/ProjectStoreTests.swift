import Foundation
import PaperCore
import Testing
@testable import LibraryStore

/// A project is a file beside the plans, read and written the same way (1.1).
@Suite("Projects")
struct ProjectStoreTests {
    @Test("A project comes back as it was written, and edits keep what another device wrote")
    func roundTrip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "papertime-projects-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        let due = try #require(PlanDay(year: 2027, month: 1, day: 29))
        // A whole second: the file keeps dates to the second, as the plans do.
        var project = Project(name: "ICML 투고", goal: "지속 언러닝", deadline: due, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        project.milestones = [Project.Milestone(title: "실험 끝", day: try #require(PlanDay(year: 2026, month: 12, day: 20)))]
        project.todos = [Project.Todo(title: "기준선"), Project.Todo(title: "초고", due: due)]
        try await store.saveProject(project)
        let read = await store.loadProjects()
        #expect(read == [project])
        // An edit against the file: another device's step is kept.
        _ = try await store.updateProject(project.id) { $0.todos.append(Project.Todo(title: "그림")) }
        let edited = try await store.updateProject(project.id) { $0.move($0.todos[0].id, to: .done) }
        #expect(Set(edited?.todos.map(\.title) ?? []) == ["기준선", "초고", "그림"])
        #expect(edited?.todos(in: .done).map(\.title) == ["기준선"])
        #expect(abs((edited?.progress ?? 0) - 1.0 / 3.0) < 0.001)
        #expect(project.daysLeft(today: try #require(PlanDay(year: 2026, month: 11, day: 18))) == 72)
        try await store.deleteProject(project.id, toTrash: false)
        #expect(await store.loadProjects().isEmpty)
    }

    @Test("A step moves between states, before another or to the end")
    func moving() {
        var project = Project(name: "P", todos: [Project.Todo(title: "a"), Project.Todo(title: "b"), Project.Todo(title: "c", state: .doing)])
        let a = project.todos[0].id, c = project.todos[2].id
        project.move(a, to: .doing)
        #expect(project.todos(in: .doing).map(\.title) == ["c", "a"])
        project.move(a, to: .doing, before: c)
        #expect(project.todos(in: .doing).map(\.title) == ["a", "c"])
        project.add(papers: [UUID(), UUID()])
        let first = project.papers[0]
        project.add(papers: [first])
        #expect(project.papers.count == 2)
    }
}
