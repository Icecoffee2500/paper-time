// The `meta.json` the Mac writes for a PDF it has just taken in, before any
// lookup, with its dates and identity pinned — for the other build to write
// byte for byte (`src/test/bibtexParity.ts`). A record that differs by one
// key is a whole-file change to every sync client, and a conflict when both
// machines touch it.
//
//     Scripts/fresh-meta-fixture.sh > Tests/LibraryStoreTests/Fixtures/fresh-meta.json

import Foundation

@main
enum FreshMeta {
    static func main() {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        var meta = PaperMeta(
            id: UUID(uuidString: "3F2504E0-4F89-41D3-9A0C-0305E82C3301")!,
            confidence: .unparsed,
            provenance: Provenance(source: .heuristic, fetchedAt: at, detail: "awaiting resolution"),
            file: PaperMeta.FileInfo(
                relativePath: "week 1/Attention Is All You Need.pdf",
                byteSize: 2_215_244,
                pageCount: 15,
                importDigest: "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
                originalName: "Attention Is All You Need.pdf"
            ),
            addedAt: at,
            updatedAt: at,
            updatedBy: "Mac-TEST"
        )
        meta.csl.id = ""
        FileHandle.standardOutput.write(try! JSONCoding.encoder.encode(meta))
    }
}
