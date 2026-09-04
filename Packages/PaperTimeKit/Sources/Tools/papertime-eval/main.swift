import Bibliography
import Foundation
import MetadataPipeline
import PDFKit
import PaperCore

// A developer tool that runs the real metadata pipeline over a folder of PDFs
// and reports how it did. Accuracy is a feature of this app, so it needs to be
// measurable rather than asserted.
//
//   swift run papertime-eval <folder> [--online] [--email you@example.com]

// Swift block-buffers stdout when it is not a terminal, so a run redirected to
// a log file shows nothing at all until it exits — which is exactly when the
// progress would have been useful. Line buffering costs nothing here.
setvbuf(stdout, nil, _IOLBF, 0)

struct Row {
    var fileName: String
    var doi: String?
    var arxiv: String?
    var embeddedTitle: String?
    var extractedTitle: String?
    var extractedSource: String?
    var resolvedTitle: String?
    var resolvedVenue: String?
    var resolvedYear: Int?
    var confidence: String
    var provenance: String
    var explanation: String
    var bibKey: String?
    var disagreement: Double?
}

func pdfURLs(in root: URL) -> [URL] {
    let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    )
    var found: [URL] = []
    while let item = enumerator?.nextObject() as? URL {
        if item.pathExtension.lowercased() == "pdf" { found.append(item) }
    }
    return found.sorted { $0.lastPathComponent < $1.lastPathComponent }
}

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    print("usage: papertime-eval <folder> [--online] [--email you@example.com]")
    exit(1)
}
let root = URL(fileURLWithPath: arguments[1])
let online = arguments.contains("--online")
let email = arguments.firstIndex(of: "--email").flatMap { index -> String? in
    index + 1 < arguments.count ? arguments[index + 1] : nil
}

let files = pdfURLs(in: root)
print("Scanning \(files.count) PDFs in \(root.path)")
print(online ? "Mode: online (queries doi.org, Crossref, OpenAlex, arXiv)" : "Mode: offline")

let onDevice = OnDeviceHeaderExtractor()
print("On-device model: \(onDevice.availability.message)")

let extractor = CompositeHeaderExtractor([onDevice, HeuristicHeaderExtractor()])
let network = NetworkService(contactEmail: email)
let resolver = MetadataResolver(
    network: network,
    contactEmail: email,
    headerExtractor: extractor
)

var rows: [Row] = []
for (index, url) in files.enumerated() {
    guard let signals = DocumentSignalsExtractor.extract(fromFileAt: url) else {
        print("[\(index + 1)/\(files.count)] \(url.lastPathComponent): unreadable")
        continue
    }
    let identifiers = IdentifierScanner.scan(signals.openingText)
    let headers = await extractor.extract(from: signals)

    var row = Row(
        fileName: url.lastPathComponent,
        doi: identifiers.doi,
        arxiv: identifiers.arxiv ?? IdentifierScanner.arxivID(fromFileName: url.lastPathComponent),
        embeddedTitle: signals.embeddedTitle,
        extractedTitle: headers.first?.title,
        extractedSource: headers.first?.source.rawValue,
        confidence: "not attempted",
        provenance: "",
        explanation: ""
    )

    if online {
        let result = await resolver.resolve(
            signals: signals,
            originalFileName: url.lastPathComponent
        )
        row.resolvedTitle = result.csl.fullTitle
        row.resolvedVenue = result.csl.containerTitle
        row.resolvedYear = result.csl.year
        row.confidence = result.confidence.rawValue
        row.provenance = "\(result.provenance.source.rawValue): \(result.provenance.detail ?? "")"
        row.explanation = result.assessment?.explanation ?? ""
        row.bibKey = CitationKey.make(for: result.csl)
        if let resolved = result.csl.fullTitle, let embedded = signals.embeddedTitle {
            row.disagreement = StringSimilarity.titleSimilarity(resolved, embedded)
        }
    }
    rows.append(row)
    let label = online ? row.confidence : (row.extractedTitle == nil ? "no title" : "title found")
    print("[\(index + 1)/\(files.count)] \(url.lastPathComponent) — \(label)")
}

// MARK: - Report

print("\n================ SUMMARY ================")
print("PDFs                       : \(rows.count)")
print("DOI printed in document    : \(rows.filter { $0.doi != nil }.count)")
print("arXiv ID found             : \(rows.filter { $0.arxiv != nil }.count)")
print("Embedded PDF title usable  : \(rows.filter { $0.embeddedTitle != nil }.count)")
print("Title extracted offline    : \(rows.filter { $0.extractedTitle != nil }.count)")

let bySource = Dictionary(grouping: rows.compactMap(\.extractedSource), by: { $0 })
for (source, entries) in bySource.sorted(by: { $0.value.count > $1.value.count }) {
    print("  via \(source): \(entries.count)")
}

if online {
    let verified = rows.filter { $0.confidence == "verified" }.count
    let review = rows.filter { $0.confidence == "needsReview" }.count
    let unparsed = rows.filter { $0.confidence == "unparsed" }.count
    print("Verified automatically     : \(verified) (\(verified * 100 / max(rows.count, 1))%)")
    print("Needs review               : \(review)")
    print("Unresolved                 : \(unparsed)")

    let suspicious = rows.filter { ($0.disagreement ?? 1) < 0.75 }
    print("Resolved title disagrees with embedded title: \(suspicious.count)")
    for row in suspicious {
        print("  ! \(row.fileName)")
        print("      embedded : \(row.embeddedTitle ?? "-")")
        print("      resolved : \(row.resolvedTitle ?? "-")")
        print("      \(row.explanation)")
    }
}

// Machine-readable output for regression comparison between runs.
var report: [[String: String]] = []
for row in rows {
    report.append([
        "file": row.fileName,
        "doi": row.doi ?? "",
        "arxiv": row.arxiv ?? "",
        "embeddedTitle": row.embeddedTitle ?? "",
        "extractedTitle": row.extractedTitle ?? "",
        "extractedSource": row.extractedSource ?? "",
        "resolvedTitle": row.resolvedTitle ?? "",
        "resolvedVenue": row.resolvedVenue ?? "",
        "resolvedYear": row.resolvedYear.map(String.init) ?? "",
        "confidence": row.confidence,
        "provenance": row.provenance,
        "explanation": row.explanation,
        "bibKey": row.bibKey ?? "",
    ])
}
let outputURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appending(path: online ? "eval-online.json" : "eval-offline.json")
if let data = try? JSONSerialization.data(
    withJSONObject: report,
    options: [.prettyPrinted, .sortedKeys]
) {
    try? data.write(to: outputURL)
    print("\nWrote \(outputURL.lastPathComponent)")
}
