import Foundation
import PaperCore

/// Resolves a DOI straight to CSL-JSON through DOI content negotiation.
///
/// This is the highest-quality path available: the registrar returns the record
/// it holds, so there is nothing to match and nothing to guess.
public struct DOIClient: Sendable {
    private let network: NetworkService

    public init(network: NetworkService) {
        self.network = network
    }

    public func fetch(doi: String) async throws -> CSLItem {
        guard let normalised = Identifiers.normalizeDOI(doi),
              let url = URL(string: "https://doi.org/\(normalised)")
        else { throw NetworkService.Failure.notFound }

        let data = try await network.get(url, accept: "application/vnd.citationstyles.csl+json")
        do {
            var item = try JSONDecoder().decode(CSLItem.self, from: data)
            item.doi = normalised
            return item
        } catch {
            throw NetworkService.Failure.malformedResponse
        }
    }

    /// A formatted citation in any CSL style the DOI resolver knows, used by
    /// the citation-style guide.
    public func formattedCitation(doi: String, style: String, locale: String = "en-US") async throws -> String {
        guard let normalised = Identifiers.normalizeDOI(doi),
              let url = URL(string: "https://doi.org/\(normalised)")
        else { throw NetworkService.Failure.notFound }

        let data = try await network.get(
            url,
            accept: "text/x-bibliography; style=\(style); locale=\(locale)"
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw NetworkService.Failure.malformedResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Title-based lookup against Crossref.
public struct CrossrefClient: Sendable {
    private let network: NetworkService

    public init(network: NetworkService) {
        self.network = network
    }

    public func work(doi: String) async throws -> CSLItem {
        guard let normalised = Identifiers.normalizeDOI(doi),
              let encoded = normalised.addingPercentEncoding(
                  withAllowedCharacters: .urlPathAllowed
              ),
              let url = URL(string: "https://api.crossref.org/works/\(encoded)")
        else { throw NetworkService.Failure.notFound }

        let response = try await network.getJSON(CrossrefWorkResponse.self, from: url)
        return response.message.asCSLItem()
    }

    /// `query.bibliographic` is Crossref's own citation-matching field: it
    /// accepts a whole reference string rather than requiring separate title,
    /// author and year parameters.
    public func search(
        bibliographic: String,
        author: String? = nil,
        rows: Int = 5
    ) async throws -> [CSLItem] {
        var components = URLComponents(string: "https://api.crossref.org/works")
        var items = [
            URLQueryItem(name: "query.bibliographic", value: bibliographic),
            URLQueryItem(name: "rows", value: String(rows)),
            // "language" is deliberately excluded: Crossref's `/works` search
            // route rejects it with a validation-failure response (HTTP 400,
            // `message` becomes a bare array of error objects instead of the
            // usual `{ items }` object) — which silently decoded into
            // zero-content `CrossrefWork`s and made every title search come
            // back empty. Confirmed live against the Crossref API.
            URLQueryItem(name: "select", value: [
                "DOI", "title", "subtitle", "author", "issued", "container-title",
                "short-container-title", "type", "page", "volume", "issue",
                "publisher", "ISSN", "ISBN", "URL", "event",
            ].joined(separator: ",")),
        ]
        if let author, !author.isEmpty {
            items.append(URLQueryItem(name: "query.author", value: author))
        }
        components?.queryItems = items
        guard let url = components?.url else { throw NetworkService.Failure.notFound }

        let response = try await network.getJSON(CrossrefWorkListResponse.self, from: url)
        return (response.message.items ?? []).map { $0.asCSLItem() }
    }
}

/// Title-based lookup against OpenAlex.
///
/// Kept alongside Crossref because OpenAlex indexes conference papers and
/// preprints that were never assigned a DOI — which, in a machine-learning
/// library, is most of them.
public struct OpenAlexClient: Sendable {
    private let network: NetworkService
    private let contactEmail: String?

    public init(network: NetworkService, contactEmail: String? = nil) {
        self.network = network
        self.contactEmail = contactEmail
    }

    public func search(title: String, rows: Int = 5) async throws -> [CSLItem] {
        var components = URLComponents(string: "https://api.openalex.org/works")
        var items = [
            // `title.search` scores against titles only, which is what we want:
            // a full-text search matches papers that merely cite this one.
            URLQueryItem(name: "filter", value: "title.search:\(sanitise(title))"),
            URLQueryItem(name: "per-page", value: String(rows)),
        ]
        if let contactEmail { items.append(URLQueryItem(name: "mailto", value: contactEmail)) }
        components?.queryItems = items
        guard let url = components?.url else { throw NetworkService.Failure.notFound }

        let response = try await network.getJSON(OpenAlexWorkList.self, from: url)
        return (response.results ?? []).map { $0.asCSLItem() }
    }

    public func work(doi: String) async throws -> CSLItem {
        guard let normalised = Identifiers.normalizeDOI(doi),
              let url = URL(string: "https://api.openalex.org/works/https://doi.org/\(normalised)")
        else { throw NetworkService.Failure.notFound }
        let work = try await network.getJSON(OpenAlexWork.self, from: url)
        return work.asCSLItem()
    }

    /// OpenAlex filters treat commas and pipes as separators.
    private func sanitise(_ title: String) -> String {
        title
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "|", with: " ")
            .replacingOccurrences(of: ":", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
    }
}

/// arXiv's Atom API.
public struct ArxivClient: Sendable {
    private let network: NetworkService

    public init(network: NetworkService) {
        self.network = network
    }

    public func entry(id: String) async throws -> ArxivEntry {
        guard let normalised = Identifiers.normalizeArxiv(id),
              let url = URL(string: "https://export.arxiv.org/api/query?id_list=\(normalised)")
        else { throw NetworkService.Failure.notFound }

        let data = try await network.get(url, accept: "application/atom+xml")
        let entries = try ArxivFeedParser.parse(data)
        guard let first = entries.first else { throw NetworkService.Failure.notFound }
        return first
    }

    public func search(title: String, rows: Int = 5) async throws -> [ArxivEntry] {
        let quoted = title
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: ":", with: " ")
        var components = URLComponents(string: "https://export.arxiv.org/api/query")
        components?.queryItems = [
            URLQueryItem(name: "search_query", value: "ti:\"\(quoted)\""),
            URLQueryItem(name: "max_results", value: String(rows)),
        ]
        guard let url = components?.url else { throw NetworkService.Failure.notFound }
        let data = try await network.get(url, accept: "application/atom+xml")
        return try ArxivFeedParser.parse(data)
    }
}
