import Foundation
import Testing
@testable import PaperCore

@Suite("Provenance")
struct ProvenanceTests {
    /// The record the Windows and Linux build wrote until 0.8.2: a source and
    /// nothing else. It cost a whole library — `PaperMeta` would not decode,
    /// and a paper whose record will not decode is not a paper, so the Mac
    /// showed an empty shelf beside a folder full of PDFs.
    @Test("A record with only a source still names its paper")
    func missingFetchedAt() throws {
        let json = """
        {"schema":1,"id":"095886A4-5BB4-4A93-B764-43BE22CD41C1",
         "csl":{"id":"","type":"other","author":[],"editor":[]},
         "bibKey":"","confidence":"unparsed","identifiers":{},
         "provenance":{"source":"heuristic"},"candidates":[],
         "file":{"relativePath":"a.pdf","byteSize":1,"pageCount":1,
                 "importDigest":"d","originalName":"a.pdf"},
         "tagIDs":[],"collectionIDs":[],
         "addedAt":"2026-09-21T12:08:26Z","updatedAt":"2026-09-21T12:08:26Z",
         "updatedBy":"pc"}
        """
        let meta = try JSONCoding.decoder.decode(PaperMeta.self, from: Data(json.utf8))
        #expect(meta.file.relativePath == "a.pdf")
        #expect(meta.provenance.source == .heuristic)
    }

    @Test("What this build writes has the date in it")
    func writesFetchedAt() throws {
        let data = try JSONCoding.encoder.encode(Provenance(source: .heuristic))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("fetchedAt"))
    }
}
