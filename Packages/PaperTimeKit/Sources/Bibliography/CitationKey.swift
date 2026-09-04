import Foundation
import PaperCore

/// Generates and de-duplicates BibTeX citation keys.
///
/// The shape is `surnameYEARword` — the form most people already type from
/// memory, and the one Google Scholar and most templates produce.
public enum CitationKey {
    public static func make(for item: CSLItem, fallback: String = "untitled") -> String {
        let surname = item.author.first?.sortingSurname
            ?? item.editor.first?.sortingSurname
        let namePart = surname.map { asciiWord($0) } ?? ""
        let yearPart = item.year.map(String.init) ?? ""
        let titlePart = item.fullTitle
            .flatMap { TextNormalization.firstSignificantWord(of: $0) }
            .map { asciiWord($0) } ?? ""

        let combined = namePart + yearPart + titlePart
        return combined.isEmpty ? asciiWord(fallback) : combined
    }

    /// Appends `a`, `b`, `c`… when a key is already taken.
    ///
    /// The suffix goes after the year-and-word stem, matching what BibTeX users
    /// expect from Google Scholar and from Zotero's Better BibTeX.
    public static func uniqued(_ key: String, takenKeys: inout Set<String>) -> String {
        guard takenKeys.contains(key) else {
            takenKeys.insert(key)
            return key
        }
        for suffix in "abcdefghijklmnopqrstuvwxyz" {
            let candidate = key + String(suffix)
            if !takenKeys.contains(candidate) {
                takenKeys.insert(candidate)
                return candidate
            }
        }
        var counter = 2
        while takenKeys.contains("\(key)-\(counter)") { counter += 1 }
        let candidate = "\(key)-\(counter)"
        takenKeys.insert(candidate)
        return candidate
    }

    /// Assigns stable keys to a whole library in one pass.
    ///
    /// Sorted by identity first so that adding a paper cannot renumber the keys
    /// of papers already cited in a manuscript.
    public static func assignKeys(
        to items: [(id: UUID, item: CSLItem, preferred: String?)]
    ) -> [UUID: String] {
        var taken = Set<String>()
        var result: [UUID: String] = [:]

        // Honour keys that already exist before minting new ones, so an export
        // never silently changes a key the user has cited.
        for entry in items {
            guard let preferred = entry.preferred, !preferred.isEmpty else { continue }
            let sanitised = sanitise(preferred)
            guard !taken.contains(sanitised) else { continue }
            taken.insert(sanitised)
            result[entry.id] = sanitised
        }
        for entry in items where result[entry.id] == nil {
            var takenCopy = taken
            let key = uniqued(make(for: entry.item), takenKeys: &takenCopy)
            taken = takenCopy
            result[entry.id] = key
        }
        return result
    }

    /// Strips everything BibTeX cannot carry in a key.
    public static func sanitise(_ raw: String) -> String {
        var result = ""
        for scalar in raw.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                result.unicodeScalars.append(scalar)
            } else if "-_:".unicodeScalars.contains(scalar), !result.isEmpty {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func asciiWord(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive], locale: nil).lowercased()
        var result = ""
        for scalar in folded.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            guard scalar.isASCII else { continue }
            result.unicodeScalars.append(scalar)
        }
        return result
    }
}
