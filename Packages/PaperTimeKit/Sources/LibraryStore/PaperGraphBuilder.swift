import Foundation
import PaperCore

/// Why two papers in a library belong together.
///
/// Four reasons, and they are not equal. One paper naming another is the
/// literature's own connection; a note of yours linking two is a connection
/// only you have; a shared author is a fact about people; filing two papers in
/// the same place is a judgement you already made. Keeping them apart is what
/// makes the graph worth reading rather than a hairball.
public enum PaperLink: String, CaseIterable, Sendable, Hashable, Codable {
    case cites, note, author, filed

    public var label: String {
        switch self {
        case .cites: "Cites"
        case .note: "Notes"
        case .author: "Author"
        case .filed: "Filed together"
        }
    }

    /// How hard this kind of connection pulls two papers together.
    public var weight: Double {
        switch self {
        case .cites: 1.0
        case .note: 0.85
        case .author: 0.55
        case .filed: 0.3
        }
    }
}

public struct PaperConnection: Hashable, Sendable {
    public var a: UUID
    public var b: UUID
    public var kinds: Set<PaperLink>
    /// What the two have in common, in words, for the panel beside the graph.
    public var reason: String

    public var weight: Double { kinds.map(\.weight).reduce(0, +) }
}

/// Works out the connections between papers.
///
/// Everything here is a pure function of what is already known — the metadata,
/// the collections, the notes, and the citations found by reading the PDFs —
/// so the graph can be tested without a library on disk.
public enum PaperGraphBuilder {
    public static func connections(
        papers: [LoadedPaper],
        citations: [UUID: Set<UUID>],
        collections: CollectionSet,
        notes: [Zettel]
    ) -> [PaperConnection] {
        var kinds: [Pair: Set<PaperLink>] = [:]
        var reasons: [Pair: [String]] = [:]

        func join(_ a: UUID, _ b: UUID, _ kind: PaperLink, _ reason: String) {
            guard a != b else { return }
            let pair = Pair(a, b)
            kinds[pair, default: []].insert(kind)
            var found = reasons[pair] ?? []
            if found.count < 4, !found.contains(reason) {
                found.append(reason)
                reasons[pair] = found
            }
        }

        // What the papers themselves say.
        for (source, targets) in citations {
            for target in targets { join(source, target, .cites, "cites") }
        }

        // Who wrote them. A name on half the shelf says less about any two
        // papers than a name on two, so the crowd is left out.
        var byAuthor: [String: [(id: UUID, name: String)]] = [:]
        for paper in papers where paper.meta.parentID == nil {
            for author in paper.meta.csl.author {
                guard let key = authorKey(author) else { continue }
                byAuthor[key, default: []].append((paper.id, author.displayName))
            }
        }
        let crowd = max(12, papers.count / 4)
        for group in byAuthor.values where group.count > 1 && group.count <= crowd {
            for (offset, first) in group.enumerated() {
                for second in group.dropFirst(offset + 1) {
                    join(first.id, second.id, .author, first.name)
                }
            }
        }

        // What you filed together.
        for collection in collections.collections {
            let members = papers.filter { $0.meta.collectionIDs.contains(collection.id) }
            guard members.count > 1, members.count <= 40 else { continue }
            for (offset, first) in members.enumerated() {
                for second in members.dropFirst(offset + 1) {
                    join(first.id, second.id, .filed, collection.name)
                }
            }
        }
        var byTag: [UUID: [UUID]] = [:]
        for paper in papers where paper.meta.parentID == nil {
            for tag in paper.meta.tagIDs { byTag[tag, default: []].append(paper.id) }
        }
        for group in byTag.values where group.count > 1 && group.count <= 40 {
            for (offset, first) in group.enumerated() {
                for second in group.dropFirst(offset + 1) {
                    join(first, second, .filed, "same tag")
                }
            }
        }

        // What you wrote. A note about one paper linking to a note about
        // another is a connection nothing else in the library knows about.
        let byID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for note in notes {
            guard let from = note.paperID else { continue }
            for target in note.links {
                guard let other = byID[target], let to = other.paperID else { continue }
                join(from, to, .note, note.displayTitle)
            }
        }

        return kinds.map { pair, kinds in
            PaperConnection(
                a: pair.a, b: pair.b, kinds: kinds,
                reason: (reasons[pair] ?? []).joined(separator: ", ")
            )
        }
    }

    public static func degrees(of connections: [PaperConnection]) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        for connection in connections {
            result[connection.a, default: 0] += 1
            result[connection.b, default: 0] += 1
        }
        return result
    }

    /// Surname plus the initial of the first given name, folded and lowered —
    /// enough to join up the ways one person's name gets written, and not so
    /// loose that two people collide.
    public static func authorKey(_ name: CSLName) -> String? {
        guard let surname = name.sortingSurname?
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !surname.isEmpty
        else { return nil }
        let initial = name.given?
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .first
            .map(String.init) ?? ""
        return "\(surname.lowercased())|\(initial.lowercased())"
    }

    /// Order-free, so A–B and B–A are one connection.
    private struct Pair: Hashable {
        let a: UUID
        let b: UUID
        init(_ first: UUID, _ second: UUID) {
            if first.uuidString < second.uuidString {
                a = first; b = second
            } else {
                a = second; b = first
            }
        }
    }
}
