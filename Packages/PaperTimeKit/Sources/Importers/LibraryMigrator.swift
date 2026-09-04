import Bibliography
import Foundation
import LibraryStore
import PaperCore

/// Brings an existing reference library into Paper Time.
///
/// The route in is a BibTeX or RIS export plus the folder of PDFs it refers
/// to, because that is what every reference manager can produce and because
/// neither Bookends nor Zotero exposes its database in a form another app may
/// safely read.
///
/// Imported records are marked `needsReview`, never `verified`. The reason is
/// the reason this app exists: the records in the old library are exactly the
/// ones the user found unreliable, so they are treated as a strong hint for the
/// resolver rather than as fact.
public enum LibraryMigrator {
    public struct MatchedRecord: Sendable, Identifiable {
        public var id: UUID = UUID()
        public var record: BibTeXImporter.ImportedRecord
        public var documentURL: URL?
        /// How the PDF was matched, shown in the migration review list.
        public var matchReason: String
    }

    public struct Plan: Sendable {
        public var matched: [MatchedRecord] = []
        /// Records whose PDF could not be found. Still worth importing as
        /// bibliography-only entries.
        public var withoutDocuments: [BibTeXImporter.ImportedRecord] = []
        /// PDFs in the folder that no record mentions.
        public var orphanedDocuments: [URL] = []
        public var warnings: [String] = []

        public var totalRecords: Int { matched.count + withoutDocuments.count }
    }

    public enum Failure: LocalizedError {
        case unreadableBibliography(URL)
        case unsupportedFormat(String)

        public var errorDescription: String? {
            switch self {
            case let .unreadableBibliography(url):
                "Could not read \(url.lastPathComponent)."
            case let .unsupportedFormat(ext):
                "Paper Time can import .bib and .ris files, not .\(ext)."
            }
        }
    }

    /// Works out what would be imported, without changing anything.
    public static func plan(bibliographyAt url: URL, attachmentsFolder: URL?) throws -> Plan {
        guard let text = try? String(contentsOf: url, encoding: .utf8)
            ?? String(contentsOf: url, encoding: .isoLatin1)
        else { throw Failure.unreadableBibliography(url) }

        let parsed: (records: [BibTeXImporter.ImportedRecord], warnings: [String])
        switch url.pathExtension.lowercased() {
        case "bib", "bibtex":
            parsed = BibTeXImporter.records(from: text)
        case "ris", "txt":
            parsed = RISImporter.records(from: text)
        default:
            throw Failure.unsupportedFormat(url.pathExtension)
        }

        var plan = Plan(warnings: parsed.warnings)
        let available = attachmentsFolder.map(pdfFiles(in:)) ?? []
        var unclaimed = Set(available)

        for record in parsed.records {
            if let match = matchDocument(for: record, among: available, unclaimed: unclaimed) {
                unclaimed.remove(match.url)
                plan.matched.append(
                    MatchedRecord(
                        record: record,
                        documentURL: match.url,
                        matchReason: match.reason
                    )
                )
            } else {
                plan.withoutDocuments.append(record)
            }
        }
        plan.orphanedDocuments = available.filter { unclaimed.contains($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return plan
    }

    /// Copies matched PDFs into the library and writes their records.
    ///
    /// Returns the papers created, so the caller can queue them for metadata
    /// resolution straight away.
    public static func apply(
        _ plan: Plan,
        to store: LibraryStore,
        includeRecordsWithoutDocuments: Bool = false
    ) async -> (imported: [LoadedPaper], failures: [String]) {
        var imported: [LoadedPaper] = []
        var failures: [String] = []

        for entry in plan.matched {
            guard let url = entry.documentURL else { continue }
            do {
                let outcome = try await store.importDocument(at: url)
                guard case let .imported(paper) = outcome else { continue }
                var meta = paper.meta
                meta.csl = entry.record.csl
                meta.identifiers = entry.record.identifiers
                meta.bibKey = entry.record.bibKey
                meta.csl.id = entry.record.bibKey
                meta.confidence = .needsReview
                meta.provenance = Provenance(
                    source: .importedBibTeX,
                    detail: "imported from your previous library"
                )
                let saved = try await store.save(meta: meta, in: paper.folder)
                imported.append(LoadedPaper(folder: paper.folder, meta: saved, state: paper.state))
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (imported, failures)
    }

    // MARK: - Matching

    struct DocumentMatch {
        var url: URL
        var reason: String
    }

    static func matchDocument(
        for record: BibTeXImporter.ImportedRecord,
        among files: [URL],
        unclaimed: Set<URL>
    ) -> DocumentMatch? {
        // A `file` field written by the old manager is the only exact evidence
        // available, so it is tried before any name similarity.
        for hint in record.fileHints {
            let name = (hint as NSString).lastPathComponent
            guard !name.isEmpty else { continue }
            if let match = files.first(where: {
                unclaimed.contains($0) && $0.lastPathComponent == name
            }) {
                return DocumentMatch(url: match, reason: "matched by the record's file path")
            }
        }

        guard let title = record.csl.fullTitle, title.count > 8 else { return nil }
        let foldedTitle = TextNormalization.foldedTitle(title)

        var best: (url: URL, score: Double)?
        for file in files where unclaimed.contains(file) {
            let stem = (file.lastPathComponent as NSString).deletingPathExtension
            let score = StringSimilarity.jaroWinkler(
                foldedTitle,
                TextNormalization.foldedTitle(stem)
            )
            if score > (best?.score ?? 0) { best = (file, score) }
        }
        // A high bar on purpose: attaching the wrong PDF to a record is worse
        // than leaving it unattached, because it is invisible afterwards.
        guard let best, best.score >= 0.88 else { return nil }
        return DocumentMatch(
            url: best.url,
            reason: "matched by title, \(Int((best.score * 100).rounded()))% similar to the file name"
        )
    }

    static func pdfFiles(in folder: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var found: [URL] = []
        while let item = enumerator?.nextObject() as? URL {
            if item.pathExtension.lowercased() == "pdf" { found.append(item) }
        }
        return found.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
