import Bibliography
import Foundation
import LibraryStore
import MetadataPipeline
import PaperCore

// Fills a Paper Time library folder from a directory of PDFs, using exactly the
// same import and resolution code the app runs. Used to set up a realistic
// library for manual testing without driving the document picker by hand.
//
//   swift run papertime-seed <library folder> <pdf folder> [--offline]

// Line-buffer so progress is visible when the output is redirected to a file.
setvbuf(stdout, nil, _IOLBF, 0)

let arguments = CommandLine.arguments
guard arguments.count > 2 else {
    print("usage: papertime-seed <library folder> <pdf folder> [--offline]")
    exit(1)
}

let libraryURL = URL(fileURLWithPath: arguments[1])
let sourceURL = URL(fileURLWithPath: arguments[2])
let offline = arguments.contains("--offline")

let store = LibraryStore(root: libraryURL)
let manifest = try await store.bootstrap()
print("Library: \(manifest.displayName) at \(libraryURL.path)")

let contents = (try? FileManager.default.contentsOfDirectory(
    at: sourceURL,
    includingPropertiesForKeys: nil,
    options: [.skipsHiddenFiles]
)) ?? []
let pdfs = contents
    .filter { $0.pathExtension.lowercased() == "pdf" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
print("Found \(pdfs.count) PDFs to import")

let resolver = MetadataResolver(
    network: NetworkService(),
    headerExtractor: CompositeHeaderExtractor([
        OnDeviceHeaderExtractor(),
        HeuristicHeaderExtractor(),
    ])
)

var existing: [String: PaperFolder] = [:]
for paper in (try await store.loadAll()).papers where !paper.meta.file.importDigest.isEmpty {
    existing[paper.meta.file.importDigest] = paper.folder
}

for url in pdfs {
    let outcome = try await store.importDocument(at: url, knownDigests: existing)
    guard case let .imported(paper) = outcome else {
        print("  skipped (already in library): \(url.lastPathComponent)")
        continue
    }
    existing[paper.meta.file.importDigest] = paper.folder

    guard !offline, let signals = DocumentSignalsExtractor.extract(fromFileAt: paper.documentURL)
    else {
        print("  imported: \(url.lastPathComponent)")
        continue
    }

    let result = await resolver.resolve(
        signals: signals,
        originalFileName: paper.meta.file.originalName
    )
    var meta = paper.meta
    meta.csl = result.csl
    meta.identifiers = result.identifiers
    meta.confidence = result.confidence
    meta.provenance = result.provenance
    meta.candidates = result.candidates
    meta.bibKey = CitationKey.make(for: result.csl, fallback: meta.file.originalName)
    meta.csl.id = meta.bibKey
    _ = try await store.save(meta: meta, in: paper.folder)

    print("  \(result.confidence.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)) \(meta.bibKey) — \(result.csl.fullTitle ?? url.lastPathComponent)")
}

let final = try await store.loadAll()
print("\nLibrary now holds \(final.papers.count) papers.")
