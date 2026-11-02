import Foundation
import PaperCore

/// Papers that come from an address rather than a file.
///
/// The one way out to the web for a paper's bytes: what «Add Paper by
/// Address…» fetches, and what opens a paper whose PDF is not in the folder
/// but has a `source.json` (`PaperSource`). The bytes of such papers are
/// held for the session, bounded, and fetched again when next opened. The
/// Portable build has the same (`main/paperSource.ts`).
public actor PaperFetcher {
    public static let shared = PaperFetcher()

    /// Why an address gave no paper. The app says each in its words.
    public enum Failure: String, Error, Sendable {
        case notAnAddress, noPDF, notFound, offline, tooLarge, failed
    }

    public struct Fetched: Sendable {
        public var data: Data
        /// The address the bytes came from, after redirects.
        public var pdf: URL
    }

    /// The most a paper may be: a scanned book is a few hundred megabytes,
    /// and anything past this is not a paper.
    public static let mostBytes = 400 * 1024 * 1024
    /// How much is held for the session before the oldest is let go.
    public static let mostHeld = 600 * 1024 * 1024

    /// `--papertime-fetch-base=<http://127.0.0.1:port>`: every address a
    /// probe would fetch goes to a server of its own, under the host's name
    /// — `https://arxiv.org/pdf/x` becomes `<base>/arxiv.org/pdf/x`.
    public nonisolated(unsafe) static var rewriteBase: URL?

    private var held: [UUID: Data] = [:]
    private var order: [UUID] = []
    private var size = 0
    private var pending: [UUID: Task<Data, Error>] = [:]

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 600
        configuration.httpAdditionalHeaders = ["User-Agent": "PaperTime/1.0"]
        return URLSession(configuration: configuration)
    }()

    // MARK: - Fetching

    private func request(_ url: URL, accept: String) async throws -> (Data, HTTPURLResponse) {
        var target = url
        // An address already at the base — one the probe stored — goes as it is.
        if let base = Self.rewriteBase, let host = url.host(), host != base.host() || url.port != base.port {
            var path = "\(host)\(url.path())"
            if let query = url.query() { path += "?\(query)" }
            target = base.appending(path: path)
        }
        var request = URLRequest(url: target)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.failed }
            return (data, http)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                 .networkConnectionLost, .internationalRoamingOff, .timedOut:
                throw Failure.offline
            default:
                throw Failure.failed
            }
        }
    }

    /// The PDF at an address, or why not. HTML in its place is `noPDF`: a
    /// publisher's page, a login wall, a company's stub.
    public func fetchPDF(at url: URL) async throws -> Fetched {
        let (data, http) = try await request(url, accept: "application/pdf,*/*;q=0.8")
        if http.statusCode == 404 || http.statusCode == 410 { throw Failure.notFound }
        guard (200...299).contains(http.statusCode) else { throw Failure.failed }
        guard data.count <= Self.mostBytes else { throw Failure.tooLarge }
        guard Self.looksLikePDF(data) else { throw Failure.noPDF }
        return Fetched(data: data, pdf: http.url ?? url)
    }

    /// The paper an address names. An arXiv address and a plain one are
    /// fetched as they are; a DOI is asked about at OpenAlex, and each
    /// open-access copy it knows of is tried in turn until one answers with
    /// a PDF.
    public func fetch(_ address: PaperAddress) async throws -> Fetched {
        if let direct = address.pdfURL { return try await fetchPDF(at: direct) }
        guard let lookup = address.lookupURL else { throw Failure.noPDF }
        let (data, http) = try await request(lookup, accept: "application/json")
        if http.statusCode == 404 { throw Failure.notFound }
        guard (200...299).contains(http.statusCode) else { throw Failure.failed }
        var last: Failure = .noPDF
        for candidate in PaperAddress.openAccessPDFs(inOpenAlex: data) {
            do {
                return try await fetchPDF(at: candidate)
            } catch let failure as Failure {
                if failure == .offline { throw failure }
                last = failure
            }
        }
        throw last == .notFound ? .noPDF : last
    }

    // MARK: - Holding

    /// A paper's bytes: its file when it has one, else from memory, else
    /// from its source — one fetch however many ask.
    public func bytes(for paper: LoadedPaper) async throws -> Data {
        if paper.hasFile { return try FileOperations.read(contentsOf: paper.documentURL) }
        if let data = held[paper.id] {
            touch(paper.id)
            return data
        }
        guard let source = paper.source else { throw FileOperations.Failure.documentMissing(paper.documentURL) }
        if let under = pending[paper.id] { return try await under.value }
        let id = paper.id
        let task = Task<Data, Error> { [self] in
            let fetched = try await fetchPDF(at: source.pdf)
            await put(fetched.data, for: id)
            return fetched.data
        }
        pending[id] = task
        defer { pending[id] = nil }
        return try await task.value
    }

    /// Bytes just fetched, kept so the reader opens them without a second fetch.
    public func put(_ data: Data, for id: UUID) {
        forget(id)
        held[id] = data
        order.append(id)
        size += data.count
        while size > Self.mostHeld, let oldest = order.first, oldest != id {
            forget(oldest)
        }
    }

    public func forget(_ id: UUID) {
        guard let old = held.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        size -= old.count
    }

    private func touch(_ id: UUID) {
        order.removeAll { $0 == id }
        order.append(id)
    }

    public var heldCount: Int { held.count }
    public var heldBytes: Int { size }

    /// `%PDF-` in the first kilobyte — not at byte 0, because a file with a
    /// banner glued to the front still opens (the Portable's `looksLikePDF`).
    nonisolated static func looksLikePDF(_ data: Data) -> Bool {
        let head = data.prefix(1024)
        return head.range(of: Data("%PDF-".utf8)) != nil
    }
}
