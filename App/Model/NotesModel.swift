import Foundation
import LibraryStore
import PaperCore
import Observation

/// The slip-box: every note in the library, and what points at what.
///
/// Notes are kept together rather than under the paper they came from, which
/// is the whole idea of a Zettelkasten — a note earns its place by what it
/// links to, not by which folder it sits in. The paper a note was written
/// against is remembered on the note itself, so the reader can still ask "what
/// did I write about this one".
@MainActor
@Observable
public final class NotesModel {
    private let store: LibraryStore

    public private(set) var notes: [Zettel] = []
    public private(set) var byID: [String: Zettel] = [:]
    /// For each note, the notes that point at it.
    public private(set) var backlinks: [String: [String]] = [:]
    public private(set) var tagCounts: [String: Int] = [:]

    /// What the slip-box browser is showing.
    public var query = ""
    public var selectedTag: String?
    public var openNoteID: String?
    /// "Take me to this note" — set by a link inside a note, cleared by
    /// whichever view is in a position to show it.
    public var requestedNoteID: String?

    @ObservationIgnored private var saveTasks: [String: Task<Void, Never>] = [:]

    public init(store: LibraryStore) {
        self.store = store
    }

    // MARK: - Reading

    public func load() async {
        let loaded = await store.loadNotes()
        apply(loaded)
    }

    public func note(_ id: String) -> Zettel? { byID[id] }

    /// The notes written while reading one paper, newest first.
    public func notes(forPaper paperID: UUID) -> [Zettel] {
        notes.filter { $0.paperID == paperID }
    }

    /// What the browser shows: the box, narrowed by the search field and the
    /// chosen tag.
    public var visible: [Zettel] {
        var result = notes
        if let selectedTag {
            result = result.filter { $0.tags.contains(selectedTag) }
        }
        let terms = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !terms.isEmpty else { return result }
        return result.filter { note in
            note.displayTitle.lowercased().contains(terms)
                || note.body.lowercased().contains(terms)
                || note.id.contains(terms)
        }
    }

    public var tags: [(tag: String, count: Int)] {
        tagCounts
            .map { (tag: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.tag < $1.tag : $0.count > $1.count }
    }

    /// The notes pointing at this one, newest first.
    public func linkedFrom(_ id: String) -> [Zettel] {
        (backlinks[id] ?? []).compactMap { byID[$0] }.sorted { $0.modified > $1.modified }
    }

    /// The notes this one points at, in the order they are mentioned.
    public func linksOut(of id: String) -> [Zettel] {
        (byID[id]?.links ?? []).compactMap { byID[$0] }
    }

    /// Notes whose title or identifier matches what is being typed after `[[`.
    public func suggestions(matching text: String, excluding id: String?) -> [Zettel] {
        let terms = text.trimmingCharacters(in: .whitespaces).lowercased()
        let candidates = notes.filter { $0.id != id }
        guard !terms.isEmpty else { return Array(candidates.prefix(8)) }
        return candidates
            .filter { $0.displayTitle.lowercased().contains(terms) || $0.id.contains(terms) }
            .prefix(8)
            .map(\.self)
    }

    // MARK: - Writing

    public func create(paperID: UUID?) -> Zettel {
        let note = Zettel(id: Zettel.makeID(avoiding: Set(byID.keys)), paperID: paperID)
        var updated = notes
        updated.insert(note, at: 0)
        apply(updated)
        return note
    }

    /// Keeps a note, a moment after the typing stops.
    public func update(_ note: Zettel) {
        var edited = note
        edited.modified = .now
        var updated = notes
        if let index = updated.firstIndex(where: { $0.id == note.id }) {
            updated[index] = edited
        } else {
            updated.insert(edited, at: 0)
        }
        apply(updated)

        saveTasks[note.id]?.cancel()
        saveTasks[note.id] = Task { [store] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            try? await store.saveNote(edited)
        }
    }

    /// Writes a note out now, without waiting for the pause in typing.
    public func flush(_ note: Zettel) async {
        saveTasks[note.id]?.cancel()
        saveTasks[note.id] = nil
        try? await store.saveNote(note)
    }

    public func delete(_ id: String) {
        saveTasks[id]?.cancel()
        saveTasks[id] = nil
        apply(notes.filter { $0.id != id })
        if openNoteID == id { openNoteID = nil }
        Task { [store] in try? await store.deleteNote(id) }
    }

    // MARK: - Indexes

    private func apply(_ loaded: [Zettel]) {
        // In the order they were written, and staying there: a list that
        // re-sorted itself by the last edit moved the note you had just
        // touched to the top and everything else down a row, so nothing was
        // ever where it had been.
        notes = loaded.sorted { $0.created == $1.created ? $0.id < $1.id : $0.created < $1.created }
        byID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var links: [String: [String]] = [:]
        var counts: [String: Int] = [:]
        for note in notes {
            for target in note.links where target != note.id {
                links[target, default: []].append(note.id)
            }
            for tag in note.tags {
                counts[tag, default: 0] += 1
            }
        }
        backlinks = links
        tagCounts = counts
    }
}
