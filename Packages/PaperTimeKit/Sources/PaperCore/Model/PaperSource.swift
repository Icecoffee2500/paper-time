import Foundation

/// `source.json` — where a paper that was added by address came from.
///
/// A sidecar beside `meta.json` rather than a key in it: the record's bytes
/// have to match the Portable build's to the byte, and a key one build does
/// not know is a cloud conflict on every record the other rewrites. The
/// record keeps the name, size, page count and digest the PDF would have as
/// a file; this says where the file can be had again. A paper whose PDF is
/// not in the folder but has one of these is opened from the address — on a
/// machine that keeps no PDF files (a company computer whose security agent
/// swallows them), and on a machine that merely has not got the file yet.
public struct PaperSource: Codable, Hashable, Sendable {
    /// What was typed, as `PaperAddress.text` writes it: `arXiv:…`, `doi:…`,
    /// or the address itself.
    public var address: String
    /// Where the PDF was fetched from — the address that answered with bytes.
    public var pdf: URL
    public var fetchedAt: Date

    public init(address: String, pdf: URL, fetchedAt: Date = .now) {
        self.address = address
        self.pdf = pdf
        self.fetchedAt = fetchedAt
    }
}
