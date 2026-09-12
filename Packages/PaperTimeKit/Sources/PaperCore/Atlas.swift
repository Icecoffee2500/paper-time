import Foundation

/// Where the maps come from: the squeeze.
///
/// A map of content is not made in advance. It is made when a subject has
/// gathered enough notes that you feel the squeeze — Nick Milo's phrase —
/// and want them arranged. This finds that moment: notes not yet on any
/// map that hang together, by linking to one another or by sharing their
/// rarer words, five or more of them, and names the subject with the words
/// they share. The map itself is then a note like any other, `kind: map`,
/// links under headings, which the writer takes over from there.
public enum Atlas {
    public struct Suggestion: Identifiable, Hashable, Sendable {
        public var id: String { noteIDs.sorted().joined(separator: "+") }
        /// The words the notes have in common, strongest first.
        public let words: [String]
        public let noteIDs: [String]
    }

    /// Notes that hang together and have no map, in groups of `threshold`
    /// or more, largest first.
    public static func squeeze(
        notes: [Zettel], maps: [Zettel], threshold: Int = 5
    ) -> [Suggestion] {
        // Notes a map already holds are home.
        let housed = Set(maps.flatMap { $0.outline.flatMap { $0.entries.map(\.id) } })
        let loose = notes.filter { $0.kind == .note && !$0.isEmpty && !housed.contains($0.id) }
        guard loose.count >= threshold else { return [] }

        // Edges: a link either way, or an echo strong enough to stand.
        let index = Resonance.Index(notes: loose.map { (id: $0.id, text: $0.title + "\n" + $0.body) })
        var parent: [String: String] = [:]
        for note in loose { parent[note.id] = note.id }
        func root(_ id: String) -> String {
            var current = id
            while let up = parent[current], up != current { current = up }
            return current
        }
        func join(_ a: String, _ b: String) { parent[root(a)] = root(b) }
        var wordsBetween: [String: [String]] = [:]
        let ids = Set(loose.map(\.id))
        for note in loose {
            for target in note.links where ids.contains(target) { join(note.id, target) }
            for match in index.matches(for: note.title + "\n" + note.body, limit: 6, excluding: [note.id]) {
                join(note.id, match.id)
                wordsBetween[root(note.id), default: []].append(contentsOf: match.shared)
            }
        }

        var groups: [String: [String]] = [:]
        for note in loose { groups[root(note.id), default: []].append(note.id) }
        return groups.values
            .filter { $0.count >= threshold }
            .map { members in
                // The words most often shared inside the group name it.
                var counts: [String: Int] = [:]
                for member in members { for word in wordsBetween[root(member)] ?? [] { counts[word, default: 0] += 1 } }
                let words = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
                return Suggestion(words: Array(words.prefix(3)), noteIDs: members.sorted())
            }
            .sorted { $0.noteIDs.count > $1.noteIDs.count }
    }

    /// A first draft of the map: a title from the shared words, and under a
    /// heading per paper the notes as links with their opening words.
    public static func draft(
        for suggestion: Suggestion, notes: [Zettel], paperTitle: (UUID) -> String?
    ) -> (title: String, body: String) {
        let members = suggestion.noteIDs.compactMap { id in notes.first { $0.id == id } }
        let title = suggestion.words.prefix(2).map { $0.capitalized }.joined(separator: " · ")
        var groups: [(name: String, notes: [Zettel])] = []
        for note in members {
            let name = note.paperID.flatMap(paperTitle) ?? "Notes of my own"
            if let at = groups.firstIndex(where: { $0.name == name }) {
                groups[at].notes.append(note)
            } else {
                groups.append((name, [note]))
            }
        }
        var body = ""
        for group in groups {
            body += "## \(group.name)\n\n"
            for note in group.notes {
                let opening = note.previewBody.prefix(80).trimmingCharacters(in: .whitespaces)
                body += "- \(note.linkMarkdown)" + (opening.isEmpty ? "" : " — \(opening)") + "\n"
            }
            body += "\n"
        }
        return (title.isEmpty ? "Map" : title, body)
    }
}
