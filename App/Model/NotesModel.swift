import Foundation
import LibraryStore
import PaperCore
import Observation

/// The slip-box: every note in the library, and what points at what.
///
/// Inside one folder the notes are kept together rather than under the paper
/// they came from, which is the whole idea of a Zettelkasten — a note earns
/// its place by what it links to, not by which folder it sits in. The paper a
/// note was written against is remembered on the note itself, so the reader
/// can still ask "what did I write about this one".
///
/// Across folders it is the other way round: a note is written into the
/// folder of the paper it is about, because everything a folder's papers
/// carry belongs in that folder. Carry the folder to another machine and the
/// notes come with it; disconnect it here and they go quietly with it, which
/// is what disconnecting a folder means. A note about no paper — a loose
/// thought, a map, a draft — has no folder to belong to, so it lives in the
/// app's own box instead of in whichever folder happened to be first. The
/// boxes are read together, so the box the reader sees is still one box.
///
/// The reader can choose where that box is — a folder in a cloud drive, say,
/// so the notes that are about no paper follow them between machines the way
/// the rest do. The app's own folder is then the place a note goes when the
/// chosen one cannot be reached, and whatever is found in it is carried into
/// the chosen one the next time it is there (`catchUp`). A note is never in
/// neither, and never written over by one of the same name.
@MainActor
@Observable
public final class NotesModel {
    /// Where a note about no paper goes: the folder the reader chose for
    /// them, or the app's own when there is none, or none that can be reached.
    private(set) var loose: LooseNotes
    /// The app's own folder. Always the same one — the box when nothing was
    /// chosen, and the place a note falls back to when the chosen folder is
    /// away.
    @ObservationIgnored private let appFolder: LooseNotes
    /// Folders a move left notes in, because a note of the same name was
    /// already where they were going. Read after everything else, so they are
    /// found — and so a note that is already showing keeps the file it was
    /// read from rather than turning into the other one (see `reload`).
    @ObservationIgnored private var leftBehind: [LooseNotes] = []
    /// Set when a note could not be written into the chosen folder and went
    /// into the app's own instead — the disk was unplugged while it was open.
    public private(set) var chosenFolderWentAway = false
    /// Every box, read together — the loose box and one per folder.
    @ObservationIgnored private var boxes: [any SlipBox] = []
    /// The library's folders, as last told. Kept so the loose box can be
    /// swapped without asking the library for them again.
    @ObservationIgnored private var folders: [LibraryStore] = []
    /// Which box each note came from, so it goes back to the same one.
    @ObservationIgnored private var boxByNote: [String: URL] = [:]
    /// Names that more than one box holds a note under. Nothing is moved
    /// between boxes under such a name: moving one would write over the other.
    @ObservationIgnored private var sharedNames: Set<String> = []
    /// Notes changed here and not yet written. A reading of the boxes that
    /// arrives in between is older than they are, and the note being typed
    /// into keeps what was typed.
    @ObservationIgnored private var unwritten: [String: Zettel] = [:]
    /// Deletions asked for while the loose notes were being carried
    /// elsewhere. The file may already have gone ahead of the request.
    @ObservationIgnored private var deletedDuringMove: Set<String> = []
    /// The carrying of the loose notes to another folder, while it lasts.
    /// Everything that writes waits for it: halfway through, some of the
    /// notes are in each place.
    @ObservationIgnored private var relocation: Task<(moved: Int, kept: Int), Never>?
    /// How many times the loose notes have been carried elsewhere. A reading
    /// of the boxes that was under way when they went is a reading of where
    /// they used to be, and is read again rather than believed.
    @ObservationIgnored private var relocations = 0
    /// The folder a paper is in, asked of the library.
    @ObservationIgnored private var folderOfPaper: (UUID) -> LibraryStore? = { _ in nil }

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

    /// `chosen` is the folder the reader picked for the notes about no paper,
    /// already known to be there; nil keeps them in `appFolder`. Decided
    /// before anything is read, so the first reading is of the right box.
    public init(appFolder: LooseNotes, chosen: LooseNotes? = nil) {
        self.appFolder = appFolder
        self.loose = chosen ?? appFolder
        self.boxes = [chosen ?? appFolder]
    }

    /// Told by the library which folders are open, and how to find the one a
    /// paper is in. A weak closure rather than a back-reference: the library
    /// owns this.
    func read(
        folders: [LibraryStore],
        of folderOfPaper: @escaping (UUID) -> LibraryStore?
    ) {
        self.folders = folders
        self.folderOfPaper = folderOfPaper
        rebuildBoxes()
    }

    /// The loose box first, so a note it already holds stays its own; what a
    /// move left behind last, so it never wins a name from anyone.
    private func rebuildBoxes() {
        let kept = leftBehind.filter { $0.boxID != loose.boxID }
        boxes = [loose] + folders + kept
    }

    /// Where a note is written: the box it was read from, else the folder of
    /// the paper it is about, else the app's own box.
    private func box(for note: Zettel) -> any SlipBox {
        if let id = boxByNote[note.id], let found = boxes.first(where: { $0.boxID == id }) {
            return found
        }
        if let paperID = note.paperID, let found = folderOfPaper(paperID) { return found }
        return loose
    }

    // MARK: - Reading

    public func load() async {
        // Not in the middle of carrying the loose notes elsewhere: a reading
        // then finds some of them in each place, and the ones it misses drop
        // out from under whoever has them open.
        if let relocation { _ = await relocation.value }
        await reload()
    }

    private func reload() async {
        let generation = relocations
        var loaded: [String: Zettel] = [:]
        var order: [String] = []
        var homes: [String: URL] = [:]
        var shared = Set<String>()
        // Every box at once. Most of them are folders in a cloud drive, and
        // asking one after another meant waiting for each in turn to answer
        // what is usually "nothing new".
        //
        // The list as it was when the reading began, and paired with what
        // came back against that list: a write that fell back into the app's
        // folder adds a box while the others are still answering.
        let reading = boxes
        let read = await Trace.time("notes: read \(reading.count) box(es)") {
            await withTaskGroup(of: (Int, [Zettel]).self) { group in
                for (position, box) in reading.enumerated() {
                    group.addTask { (position, await box.loadNotes()) }
                }
                var found = [[Zettel]](repeating: [], count: reading.count)
                for await (position, notes) in group { found[position] = notes }
                return found
            }
        }
        // The notes moved while they were being read: some of what came back
        // is in a folder that no longer holds it, and taking that as the
        // truth sends the next edit back into the folder they left.
        guard generation == relocations else { return await load() }
        // In the order the boxes are kept, so which box owns a note that is
        // in two of them does not depend on which answered first.
        for (box, notes) in zip(reading, read) {
            for note in notes {
                // Two boxes cannot both own a note. One keeps it and the
                // other copy is left alone rather than deleted — nobody's
                // writing is thrown away to tidy an index.
                if let home = homes[note.id], let other = loaded[note.id] {
                    shared.insert(note.id)
                    // The one already showing keeps showing. Two notes of one
                    // name are two notes, and turning the one somebody has
                    // open into the other is how the other gets written over:
                    // the editor keeps what it was showing and writes it back
                    // under that name when it closes.
                    let owner = boxByNote[note.id]
                    let ownerHasIt = owner == home || owner == box.boxID
                    let takesIt = ownerHasIt
                        ? owner == box.boxID && home != box.boxID
                        // Showing for the first time: the newer of the two.
                        // Mostly that is a note changed in the app's folder
                        // while the chosen one was away, and it is the
                        // version the reader wrote last.
                        : note.modified > other.modified
                    if takesIt {
                        homes[note.id] = box.boxID
                        loaded[note.id] = note
                    }
                    continue
                }
                homes[note.id] = box.boxID
                loaded[note.id] = note
                order.append(note.id)
            }
        }
        // What was typed and has not reached the disk yet is newer than what
        // the disk says, and a note that has never been written is not on it
        // at all — read back, it would vanish from under the hand typing it.
        for (id, mine) in unwritten {
            if loaded[id] == nil {
                order.append(id)
                homes[id] = boxByNote[id] ?? box(for: mine).boxID
            }
            loaded[id] = mine
        }
        boxByNote = homes
        sharedNames = shared
        let notes = order.compactMap { loaded[$0] }
        Trace.time("notes: index \(notes.count)") { apply(notes) }
        await Trace.time("notes: settle") { await settle() }
    }

    /// Puts each note in the box it belongs to: the folder of the paper it is
    /// about, or the app's own box when it is about no paper.
    ///
    /// A library that was one folder kept every note in that folder. A note
    /// with a paper moves only while both folders are open — a note moved
    /// into a folder that is away is a note nobody can see. A note with no
    /// paper has nowhere to be away, so it moves whenever it is found.
    private func settle() async {
        let generation = relocations
        for note in notes {
            // The loose notes went somewhere else in the meantime, and what
            // this pass knew about where each note is went with them.
            guard generation == relocations else { return }
            // Another box has a note by this name, and moving this one there
            // would write over it.
            guard !sharedNames.contains(note.id), unwritten[note.id] == nil else { continue }
            guard let id = boxByNote[note.id],
                  let source = boxes.first(where: { $0.boxID == id })
            else { continue }
            let target: any SlipBox
            if let paperID = note.paperID {
                guard let folder = folderOfPaper(paperID) else { continue }
                target = folder
            } else {
                target = loose
            }
            guard target.boxID != source.boxID else { continue }
            guard (try? await target.saveNote(note)) != nil else { continue }
            try? await source.deleteNote(note.id)
            boxByNote[note.id] = target.boxID
        }
    }

    /// Where the app keeps the notes about no paper, and which they are.
    /// For `--papertime-folders=1`, and for anyone who wants to open them.
    public var looseBox: URL { loose.directory }
    /// Whether that is a folder the reader chose rather than the app's own.
    public var looseBoxIsChosen: Bool { loose.isChosen }
    /// The app's own folder, which is where they are when nothing is chosen.
    public var appFolderURL: URL { appFolder.directory }

    public func looseNoteIDs() async -> [String] {
        await loose.loadNotes().map(\.id)
    }

    /// Names more than one box holds a note under, and which box the one
    /// showing was read from. For `--papertime-folders=1`: a note that is
    /// two notes is the case every rule about moving them exists for.
    public var notesInTwoBoxes: [(id: String, shownFrom: URL)] {
        sharedNames.sorted().compactMap { id in boxByNote[id].map { (id, $0) } }
    }

    /// The notes still in the app's own folder while another is the box:
    /// the ones a note of the same name kept out of the chosen folder, and
    /// the ones written while it was away and not yet carried across.
    public func appFolderNoteIDs() async -> [String] {
        guard loose.boxID != appFolder.boxID else { return [] }
        return await appFolder.noteIDs()
    }

    // MARK: - Where the loose notes live

    /// Carries the notes about no paper into another folder and reads them
    /// from there.
    ///
    /// Whatever is waiting to be written goes out first, into the box it was
    /// meant for, so the move takes it along; anything typed while the files
    /// are on their way waits and is written after, into wherever its note
    /// ended up. A name already taken in the new folder is not written over —
    /// that note stays where it was (`LooseNotes.move(into:)`), is still read
    /// from there, and, if it is the one open, stays the one open. Notes keep
    /// their names, so a note open in the editor is still open afterwards.
    ///
    /// Going to a chosen folder also brings along what is in the app's own —
    /// notes that fell back there while the old choice was away. Going back
    /// to the app's own folder is the same move the other way.
    @discardableResult
    public func relocate(to box: LooseNotes) async -> (moved: Int, kept: Int) {
        await exclusively { [self] in
            guard box.boxID.standardizedFileURL != loose.boxID.standardizedFileURL else { return (0, 0) }
            let old = loose
            let first = await carry(from: old, into: box)
            loose = box
            // The move and the catching up count as one: to the reader it is
            // one press, and the notes that stay behind stay behind for the
            // same reason — a name that was taken.
            var second = (moved: 0, kept: 0)
            if box.boxID != appFolder.boxID, old.boxID != appFolder.boxID {
                second = await carry(from: appFolder, into: box)
            }
            chosenFolderWentAway = false
            rebuildBoxes()
            await reload()
            return (first.moved + second.moved, first.kept + second.kept)
        }
    }

    /// The way back: the notes about no paper return to the app's own folder.
    @discardableResult
    public func returnToAppFolder() async -> (moved: Int, kept: Int) {
        await relocate(to: appFolder)
    }

    /// Carries into the chosen folder whatever is in the app's own: the
    /// notes written while the chosen one could not be reached.
    ///
    /// Asked once, before the notes are first read, when the chosen folder is
    /// there again. The ones that cannot go — a note of the same name is
    /// already there — stay in the app's folder and are read from it, so
    /// nothing drops out of sight; the settings say how many there are.
    @discardableResult
    public func catchUp() async -> (moved: Int, kept: Int) {
        guard loose.boxID != appFolder.boxID else { return (0, 0) }
        let result = await appFolder.move(into: loose)
        if result.kept > 0, !leftBehind.contains(where: { $0.boxID == appFolder.boxID }) {
            leftBehind.append(appFolder)
            rebuildBoxes()
        }
        return result
    }

    /// After a note fell back into the app's folder because the chosen one
    /// went away: whether the chosen one is back, and if it is, the notes
    /// that fell back carried across. Nil while it is still away.
    public func comeBack() async -> (moved: Int, kept: Int)? {
        guard loose.isChosen, loose.isReachable else { return nil }
        return await exclusively { [self] in
            let result = await carry(from: appFolder, into: loose)
            chosenFolderWentAway = false
            rebuildBoxes()
            await reload()
            return result
        }
    }

    /// Runs one move of the loose notes with every write held back until it
    /// is over.
    ///
    /// One at a time: two panels answered close together would otherwise
    /// carry the same files in two directions.
    private func exclusively(
        _ work: @escaping @MainActor () async -> (moved: Int, kept: Int)
    ) async -> (moved: Int, kept: Int) {
        while let running = relocation { _ = await running.value }
        relocations += 1
        let task = Task { @MainActor in await work() }
        relocation = task
        let result = await task.value
        relocation = nil
        return result
    }

    /// Moves the files of one box into another, and brings the index along.
    ///
    /// Whatever is waiting to be written goes out first, into the box it was
    /// meant for, so the move takes it with it.
    private func carry(from old: LooseNotes, into box: LooseNotes) async -> (moved: Int, kept: Int) {
        deletedDuringMove = []
        await writeOutstanding()
        let result = await old.move(into: box)
        // What went across is the new box's now; what a taken name kept
        // back is still the old one's, and stays that way for the rest of
        // this run, so the note somebody has open is still the same note.
        let stillThere = Set(await old.noteIDs())
        for (id, home) in boxByNote where home == old.boxID && !stillThere.contains(id) {
            boxByNote[id] = box.boxID
        }
        leftBehind.removeAll { $0.boxID == box.boxID || $0.boxID == old.boxID }
        if !stillThere.isEmpty { leftBehind.append(old) }
        // A note deleted while its file was on the way: the request went to
        // the box it was in, and the file had already left it. Not when the
        // old box still has it — then the one in the new box is the other
        // note of that name, and the request will find its own in the old.
        for id in deletedDuringMove where !stillThere.contains(id) {
            try? await box.deleteNote(id)
        }
        deletedDuringMove = []
        return result
    }

    /// Writes out everything that is waiting for the pause in typing, and
    /// anything an earlier write could not put down.
    ///
    /// The waiting writes are called off rather than waited for. One that
    /// woke up a moment ago is waiting for this move to finish, and waiting
    /// for it here would be the move waiting for itself.
    private func writeOutstanding() async {
        let pending = saveTasks
        saveTasks = [:]
        for task in pending.values { task.cancel() }
        for id in Set(pending.keys).union(unwritten.keys) {
            guard let note = unwritten[id] ?? byID[id] else { continue }
            await write(note, waiting: false)
        }
    }

    /// Writes one note into the box it belongs to.
    ///
    /// Into the app's own folder when the chosen one refuses it — an
    /// unplugged disk, a drive signed out of while the app was open. The note
    /// is kept either way, and the next time the chosen folder is there it
    /// is carried across (`catchUp`). A note that already lived in the chosen
    /// folder and was changed while it was away comes back as a second note
    /// of the same name; that one stays in the app's folder, is not written
    /// over, and is counted in the settings rather than guessed at.
    private func write(_ note: Zettel, waiting: Bool = true) async {
        if waiting, let relocation {
            _ = await relocation.value
            // Called off while it waited: the move wrote this note out
            // itself, or a newer edit is on its way behind this one.
            guard !Task.isCancelled else { return }
        }
        let home = box(for: note)
        do {
            try await home.saveNote(note)
        } catch {
            guard home.boxID == loose.boxID, loose.isChosen, !loose.isReachable else { return }
            guard (try? await appFolder.saveNote(note)) != nil else { return }
            boxByNote[note.id] = appFolder.boxID
            if !leftBehind.contains(where: { $0.boxID == appFolder.boxID }) {
                leftBehind.append(appFolder)
                rebuildBoxes()
            }
            chosenFolderWentAway = true
        }
        // An empty note stays on the list of the unwritten: writing it took
        // its file away, or there never was one, and the note is still in
        // somebody's hands until they close it.
        if let waiting = unwritten[note.id], waiting.sameWords(as: note), !note.isEmpty {
            unwritten[note.id] = nil
        }
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
            let index = Trace.time("resonance: build the index") {
                Resonance.Index(
                    notes: notes.filter { !$0.isEmpty }.map { (id: $0.id, text: $0.title + "\n" + $0.body) },
                    background: background
                )
            }
            resonanceIndex = (index, background)
            changedSinceIndex = []
        }
        guard let index = resonanceIndex?.index, !index.isEmpty else { return [] }
        return Trace.time("resonance: match a page") {
            index.matches(for: text, limit: limit, excluding: excluding)
                .compactMap { match in byID[match.id].map { (note: $0, shared: match.shared) } }
        }
    }

    // MARK: - Atlas

    /// The maps: notes that arrange other notes.
    public var maps: [Zettel] { notes.filter { $0.kind == .map } }
    /// The drafts: writing on its way out of the box.
    public var drafts: [Zettel] { notes.filter { $0.kind == .draft } }

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

    /// Puts a note on a map — or into a draft — under its last heading.
    public func add(_ id: String, toMap mapID: String) {
        guard var map = byID[mapID], let note = byID[id], map.kind != .note,
              !map.outline.contains(where: { $0.entries.contains { $0.id == id } })
        else { return }
        let separator = map.body.isEmpty || map.body.hasSuffix("\n") ? "" : "\n"
        map.body += separator + "- " + note.linkMarkdown + "\n"
        update(map)
    }

    // MARK: - Writing

    public func create(paperID: UUID?, kind: Zettel.Kind = .note) -> Zettel {
        let note = Zettel(id: Zettel.makeID(avoiding: Set(byID.keys)), kind: kind, paperID: paperID)
        boxByNote[note.id] = box(for: note).boxID
        // Not on the disk until somebody types into it, and a reading of the
        // boxes in the meantime must not take it away from them.
        unwritten[note.id] = note
        var updated = notes
        updated.insert(note, at: 0)
        apply(updated)
        return note
    }

    /// Keeps a note, a moment after the typing stops.
    /// One note, changed.
    ///
    /// Typing a letter into a note calls this, so it is on the path of every
    /// keystroke. It used to hand the whole box back to `apply`, which sorted
    /// every note, rebuilt the identifier map, and walked every note's links
    /// and tags — all of it to say that one note's body now has one more
    /// character in it. The list's order is by when a note was *written*,
    /// which an edit does not change, so the note can be put back where it
    /// was; and the links and the tags are only walked again when the links
    /// or the tags are what changed.
    public func update(_ note: Zettel) {
        var edited = note
        edited.modified = .now
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            let before = notes[index]
            notes[index] = edited
            byID[edited.id] = edited
            if before.title != edited.title || before.body != edited.body {
                changedSinceIndex.insert(edited.id)
            }
            if before.links != edited.links || before.tags != edited.tags {
                rebuildConnections()
            }
            revision += 1
        } else {
            apply(notes + [edited])
        }

        saveTasks[note.id]?.cancel()
        unwritten[note.id] = edited
        // Which box it goes to is asked when it is written, not now: the
        // loose notes may be in another folder by then.
        saveTasks[note.id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            await self.write(edited)
        }
    }

    /// Writes a note out now, without waiting for the pause in typing.
    public func flush(_ note: Zettel) async {
        saveTasks[note.id]?.cancel()
        saveTasks[note.id] = nil
        await write(note)
        // The editor lets go of a note by flushing it, and an empty note let
        // go of is a note nobody wrote: the next reading may drop it, as it
        // always has.
        if note.isEmpty { unwritten[note.id] = nil }
    }

    public func delete(_ id: String) {
        saveTasks[id]?.cancel()
        saveTasks[id] = nil
        unwritten[id] = nil
        let home = byID[id].map(box(for:)) ?? loose
        if relocation != nil, home.boxID == loose.boxID { deletedDuringMove.insert(id) }
        apply(notes.filter { $0.id != id })
        boxByNote[id] = nil
        if openNoteID == id { openNoteID = nil }
        Task { [weak self] in
            if let relocation = self?.relocation { _ = await relocation.value }
            try? await home.deleteNote(id)
        }
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

        rebuildConnections()
    }

    /// Who links to whom, and how many notes wear each tag.
    private func rebuildConnections() {
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

private extension Zettel {
    /// Whether two versions of a note say the same thing. The time it was
    /// last touched is left out: it is the moment of the edit, not the edit.
    func sameWords(as other: Zettel) -> Bool {
        title == other.title && body == other.body && kind == other.kind && paperID == other.paperID
    }
}
