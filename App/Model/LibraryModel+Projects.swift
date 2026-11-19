import Foundation
import LibraryStore
import PaperCore

/// The slip-box's projects (1.1): read beside the plans, one file each, and
/// edited against the file as it is now.
extension LibraryModel {
    public func project(_ id: UUID) -> Project? { projects.first { $0.id == id } }

    /// The projects still being worked on, for the sidebar.
    public var activeProjects: [Project] { projects.filter { $0.status != .done } }

    /// Every projects folder of every library folder, read again.
    func loadProjects() async {
        var found: [Project] = []
        var roots: [UUID: URL] = [:]
        for source in allStores {
            for project in await source.loadProjects() where roots[project.id] == nil {
                found.append(project)
                roots[project.id] = source.root
            }
        }
        projectRoots = roots
        let sorted = found.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        if sorted != projects { projects = sorted }
        if case let .projects(id?) = scope, project(id) == nil { scope = .projects(nil) }
    }

    private func projectStore(_ id: UUID) -> LibraryStore {
        let root = projectRoots[id]
        return allStores.first { $0.root == root } ?? store
    }

    /// A new project, in the first library folder, open.
    @discardableResult
    public func createProject(named name: String) async -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let project = Project(name: trimmed)
        do {
            try await store.saveProject(project)
        } catch {
            return nil
        }
        projectRoots[project.id] = store.root
        projects.append(project)
        return project.id
    }

    /// Edits a project: on screen straight away, then against its file.
    public func editProject(_ id: UUID, _ change: @escaping @Sendable (inout Project) -> Void) async {
        if let index = projects.firstIndex(where: { $0.id == id }) {
            var local = projects[index]
            change(&local)
            if local != projects[index] { projects[index] = local }
        }
        guard let saved = try? await projectStore(id).updateProject(id, change) else { return }
        if let index = projects.firstIndex(where: { $0.id == id }), projects[index] != saved { projects[index] = saved }
    }

    public func deleteProject(_ id: UUID) async {
        try? await projectStore(id).deleteProject(id, toTrash: Boot.setting("PAPERTIME_LIBRARY") == nil)
        projects.removeAll { $0.id == id }
        projectRoots[id] = nil
        if scope == .projects(id) { scope = .projects(nil) }
    }

    /// Papers dropped on a project, or on one of its steps.
    public func addToProject(_ id: UUID, papers ids: [UUID], todo: UUID? = nil) async {
        await editProject(id) { project in
            project.add(papers: ids)
            if let todo, let index = project.todos.firstIndex(where: { $0.id == todo }) {
                for paper in ids where !project.todos[index].papers.contains(paper) {
                    project.todos[index].papers.append(paper)
                }
            }
        }
    }
}

extension LibraryModel {
    /// `--papertime-project-sample=1`: a project with milestones, steps and
    /// materials, made in a probe's library only — never one somebody reads in.
    func sampleProject() async {
        guard Boot.setting("PAPERTIME_LIBRARY") != nil, projects.isEmpty else { return }
        guard let id = await createProject(named: L("ICML 투고 — 지속 언러닝", "ICML submission — continual unlearning")) else { return }
        let today = self.today
        let firstPapers = papers.filter { $0.meta.parentID == nil && $0.meta.shelfKind == .paper }.prefix(3).map(\.id)
        let book = papers.first { $0.meta.shelfKind == .book }?.id
        let note = notes.knowledge.first?.id
        await editProject(id) { project in
            project.goal = L("이어지는 삭제 요청에서도 정확도를 지키는 언러닝 방법을 논문으로", "An unlearning method that keeps accuracy across a stream of deletions, written up")
            project.deadline = today.adding(days: 72)
            project.milestones = [
                Project.Milestone(title: L("관련 연구 정리", "Related work"), day: today.adding(days: -10), done: true),
                Project.Milestone(title: L("실험 끝", "Experiments done"), day: today.adding(days: 20)),
                Project.Milestone(title: L("초고", "First draft"), day: today.adding(days: 50)),
            ]
            project.todos = [
                Project.Todo(title: L("기준선 셋 재현", "Reproduce three baselines"), state: .done, start: today.adding(days: -18), due: today.adding(days: -4)),
                Project.Todo(title: L("평가 축 정하기", "Settle the evaluation axes"), state: .done, start: today.adding(days: -14), due: today.adding(days: -8)),
                Project.Todo(title: L("연속 삭제 실험 — CIFAR-100", "Sequential deletion — CIFAR-100"), state: .doing, start: today.adding(days: -3),
                             due: today.adding(days: 4), papers: Array(firstPapers.prefix(1))),
                Project.Todo(title: L("이론 부분 증명 다듬기", "Tighten the proofs"), start: today.adding(days: 8), due: today.adding(days: 18),
                             papers: book.map { [$0] } ?? []),
                Project.Todo(title: L("그림 1 · 2 그리기", "Figures 1 and 2"), start: today.adding(days: 22), due: today.adding(days: 32)),
                Project.Todo(title: L("초고 쓰기", "Write the draft"), start: today.adding(days: 34), due: today.adding(days: 53)),
            ]
            project.add(papers: Array(firstPapers) + (book.map { [$0] } ?? []))
            if let note { project.add(notes: [note]) }
            project.plans = []
        }
        scope = .projects(id)
    }
}
