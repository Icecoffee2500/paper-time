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
    /// The notes weighed for resonance, built when first asked. Weighed
    /// against these pages, if any.
    @ObservationIgnored private var resonanceIndex: (index: Resonance.Index, background: [String])?
    /// Notes changed since the index was built. The index is rebuilt only
    /// when one of them is asked about: the note being typed into is always
    /// left out of its own echoes, so typing does not rebuild anything.
    @ObservationIgnored private var changedSinceIndex = Set<String>()
    /// Bumped whenever the notes change, so a view reading along can ask again.
    public private(set) var revision = 0

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

    // MARK: - Resonance

    /// The notes that echo a text — a page being read, or another note —
    /// with the words they share. `background` is what the words' rarity is
    /// judged against: the pages of the paper being read.
    public func resonance(
        with text: String, background: [String] = [], excluding: Set<String> = [], limit: Int = 5
    ) -> [(note: Zettel, shared: [String])] {
        if resonanceIndex == nil || resonanceIndex?.background != background
            || !changedSinceIndex.isSubset(of: excluding) {
            let index = Resonance.Index(
                notes: notes.filter { !$0.isEmpty }.map { (id: $0.id, text: $0.title + "\n" + $0.body) },
                background: background
            )
            resonanceIndex = (index, background)
            changedSinceIndex = []
        }
        guard let index = resonanceIndex?.index, !index.isEmpty else { return [] }
        return index.matches(for: text, limit: limit, excluding: excluding)
            .compactMap { match in byID[match.id].map { (note: $0, shared: match.shared) } }
    }

    // MARK: - Atlas

    /// The maps: notes that arrange other notes.
    public var maps: [Zettel] { notes.filter { $0.kind == .map } }

    /// Whether a note has a map to live on.
    public func maps(holding id: String) -> [Zettel] {
        maps.filter { $0.outline.contains { $0.entries.contains { $0.id == id } } }
    }

    /// Where the squeeze is: notes with no map that hang together, five or
    /// more. Found once per change to the notes.
    public var suggestions: [Atlas.Suggestion] {
        if let cached = suggestionCache, cached.revision == revision { return cached.found }
        let found = Atlas.squeeze(notes: notes, maps: maps)
        suggestionCache = (revision, found)
        return found
    }
    @ObservationIgnored private var suggestionCache: (revision: Int, found: [Atlas.Suggestion])?

    /// Makes the map a suggestion asked for, as a first draft to be taken
    /// over: a title from the shared words, the notes under their papers.
    public func createMap(from suggestion: Atlas.Suggestion, paperTitle: (UUID) -> String?) -> Zettel {
        let made = Atlas.draft(for: suggestion, notes: notes, paperTitle: paperTitle)
        var map = Zettel(id: Zettel.makeID(avoiding: Set(byID.keys)), kind: .map, title: made.title, body: made.body)
        map.modified = .now
        update(map)
        return map
    }

    /// Puts a note on a map, under its last heading.
    public func add(_ id: String, toMap mapID: String) {
        guard var map = byID[mapID], let note = byID[id], map.kind == .map,
              !map.outline.contains(where: { $0.entries.contains { $0.id == id } })
        else { return }
        let separator = map.body.isEmpty || map.body.hasSuffix("\n") ? "" : "\n"
        map.body += separator + "- " + note.linkMarkdown + "\n"
        update(map)
    }

    // MARK: - Writing

    public func create(paperID: UUID?, kind: Zettel.Kind = .note) -> Zettel {
        let note = Zettel(id: Zettel.makeID(avoiding: Set(byID.keys)), kind: kind, paperID: paperID)
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
        // Which notes the index no longer describes.
        var seen = Set<String>()
        for note in loaded {
            seen.insert(note.id)
            if let known = byID[note.id], known.title == note.title, known.body == note.body { continue }
            changedSinceIndex.insert(note.id)
        }
        for gone in byID.keys where !seen.contains(gone) { changedSinceIndex.insert(gone) }
        revision += 1
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
