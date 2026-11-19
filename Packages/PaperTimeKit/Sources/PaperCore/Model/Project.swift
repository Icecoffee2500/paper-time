import Foundation

/// A piece of work planned backwards from when it is due — a paper to submit,
/// an exam to sit — with the steps to get there and what it draws on (1.1,
/// the slip-box's 프로젝트).
///
/// Kept beside the reading plans, one file each in the library folder's
/// `.papertime/projects/`, so it travels with the papers it uses and both
/// builds read the same file. Planned the way Linear and Things plan: a
/// target date and milestones first, the steps under them, seen as a board
/// or along a timeline.
public struct Project: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// One line on what it is for.
    public var goal: String
    /// When it is due — a submission deadline, an exam.
    public var deadline: PlanDay?
    public var status: Status
    public var milestones: [Milestone]
    public var todos: [Todo]
    /// The papers it draws on.
    public var papers: [UUID]
    /// The notes it draws on, by identifier.
    public var notes: [String]
    /// The reading plans it reads through.
    public var plans: [UUID]
    public var createdAt: Date

    public enum Status: String, Codable, Hashable, Sendable, CaseIterable {
        case active, paused, done
    }

    /// A point on the way, on a day.
    public struct Milestone: Codable, Hashable, Sendable, Identifiable {
        public var id: UUID
        public var title: String
        public var day: PlanDay
        public var done: Bool

        public init(id: UUID = UUID(), title: String, day: PlanDay, done: Bool = false) {
            self.id = id
            self.title = title
            self.day = day
            self.done = done
        }
    }

    /// One step: to do, under way, or done — and what it needs.
    public struct Todo: Codable, Hashable, Sendable, Identifiable {
        public var id: UUID
        public var title: String
        public var state: State
        /// When it starts and when it is due, for the timeline.
        public var start: PlanDay?
        public var due: PlanDay?
        public var papers: [UUID]
        public var notes: [String]
        public var memo: String

        public enum State: String, Codable, Hashable, Sendable, CaseIterable {
            case todo, doing, done
        }

        public init(id: UUID = UUID(), title: String, state: State = .todo, start: PlanDay? = nil, due: PlanDay? = nil,
                    papers: [UUID] = [], notes: [String] = [], memo: String = "") {
            self.id = id
            self.title = title
            self.state = state
            self.start = start
            self.due = due
            self.papers = papers
            self.notes = notes
            self.memo = memo
        }
    }

    public init(id: UUID = UUID(), name: String, goal: String = "", deadline: PlanDay? = nil, status: Status = .active,
                milestones: [Milestone] = [], todos: [Todo] = [], papers: [UUID] = [], notes: [String] = [],
                plans: [UUID] = [], createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.goal = goal
        self.deadline = deadline
        self.status = status
        self.milestones = milestones
        self.todos = todos
        self.papers = papers
        self.notes = notes
        self.plans = plans
        self.createdAt = createdAt
    }

    /// How far through: the steps done of all of them — 0 with none.
    public var progress: Double {
        guard !todos.isEmpty else { return status == .done ? 1 : 0 }
        return Double(todos.filter { $0.state == .done }.count) / Double(todos.count)
    }

    /// The days left to the deadline: 0 on the day, below 0 past it.
    public func daysLeft(today: PlanDay) -> Int? {
        deadline.map { today.days(until: $0) }
    }

    /// The steps in one state, in the order kept.
    public func todos(in state: Todo.State) -> [Todo] { todos.filter { $0.state == state } }

    /// Puts a step in a state, before another step there or at its end.
    public mutating func move(_ id: UUID, to state: Todo.State, before other: UUID? = nil) {
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        var todo = todos.remove(at: index)
        todo.state = state
        if let other, let at = todos.firstIndex(where: { $0.id == other }) {
            todos.insert(todo, at: at)
        } else if let last = todos.lastIndex(where: { $0.state == state }) {
            todos.insert(todo, at: last + 1)
        } else {
            todos.append(todo)
        }
    }

    /// Papers it does not draw on yet, drawn on now.
    public mutating func add(papers ids: [UUID]) {
        for id in ids where !papers.contains(id) { papers.append(id) }
    }

    public mutating func add(notes ids: [String]) {
        for id in ids where !notes.contains(id) { notes.append(id) }
    }

    /// The milestones in the order of their days.
    public var milestonesByDay: [Milestone] { milestones.sorted { $0.day < $1.day } }
}

public extension PlanDay {
    /// Whole days from this day to another — negative when it is earlier.
    func days(until other: PlanDay) -> Int { other.ordinal - ordinal }
}
