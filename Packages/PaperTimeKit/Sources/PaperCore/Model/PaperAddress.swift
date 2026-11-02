import Foundation

/// What a reader typed into «Add Paper by Address…», read for what it names.
///
/// Three things come through that field: an arXiv paper (its identifier, or
/// any of the addresses arxiv.org gives one), a DOI (bare, with a `doi:`
/// prefix, as a doi.org address, or buried in a publisher's or Scopus's
/// address as a path or a `doi=` query), and a plain web address that may be
/// a PDF. A DOI is found before a plain address is kept, because a
/// publisher's page is a page and the DOI on it is what finds the PDF.
///
/// Pure: `read` sees only the text, and `openAccessPDF` only OpenAlex's
/// answer. The Portable build has the same reader (`shared/paperAddress.ts`)
/// and the two are held to one fixture (`paper-addresses.json`).
public enum PaperAddress: Equatable, Sendable {
    /// An arXiv identifier without a version — `2512.11732`, `cs/0101001`.
    case arxiv(String)
    /// A DOI, lower-cased, without a prefix — `10.1145/3292500.3330701`.
    case doi(String)
    /// An http(s) address that is neither.
    case web(URL)

    /// Reads a typed line. Nil when nothing in it names a paper.
    public static func read(_ text: String) -> PaperAddress? {
        var line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("<"), line.hasSuffix(">") { line = String(line.dropFirst().dropLast()) }
        // «DOI: 10.…» as a reference list writes it: the label and its
        // space come off. Otherwise an address has no spaces in it, and a
        // sentence pasted by mistake is not read for the DOI it may hold.
        if let match = line.firstMatch(of: /^(?i)(doi|arxiv)\s*:\s+/) { line = String(line[match.range.upperBound...]) }
        guard !line.isEmpty, !line.contains(where: \.isWhitespace) else { return nil }

        if let id = arxivIdentifier(in: line) { return .arxiv(id) }
        if let doi = doi(in: line) {
            // arXiv's own DOIs name the paper on arXiv.
            if let id = arxivIdentifier(in: doi) { return .arxiv(id) }
            return .doi(doi)
        }
        if let url = webAddress(line) { return .web(url) }
        return nil
    }

    /// The address as it is kept and shown: `arXiv:…`, `doi:…`, or the URL.
    public var text: String {
        switch self {
        case let .arxiv(id): "arXiv:\(id)"
        case let .doi(doi): "doi:\(doi)"
        case let .web(url): url.absoluteString
        }
    }

    /// Where the PDF is, when the address itself says so.
    public var pdfURL: URL? {
        switch self {
        case let .arxiv(id): URL(string: "https://arxiv.org/pdf/\(id)")
        case .doi: nil
        case let .web(url): url
        }
    }

    /// Where to ask which open-access copy a DOI has: OpenAlex, which folds
    /// in Unpaywall's locations and needs no key.
    public var lookupURL: URL? {
        guard case let .doi(doi) = self else { return nil }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))
        guard let escaped = doi.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://api.openalex.org/works/https://doi.org/\(escaped)?select=id,open_access,best_oa_location,primary_location,locations")
    }

    /// The name the PDF takes in the library.
    public var fileName: String {
        switch self {
        case let .arxiv(id): return "\(id.replacingOccurrences(of: "/", with: "_")).pdf"
        case let .doi(doi): return "\(Self.sanitisedFileName(doi)).pdf"
        case let .web(url):
            var last = url.lastPathComponent
            if last.lowercased().hasSuffix(".pdf") { last = String(last.dropLast(4)) }
            // `…/pdf?id=abc`: the page is named by its query, not its path.
            if ["pdf", "download", "view", "file", "fulltext", "content"].contains(last.lowercased()),
               let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.last?.value, !value.isEmpty {
                last = value
            }
            let name = Self.sanitisedFileName(last)
            return name.isEmpty || last == "/" ? "paper.pdf" : "\(name).pdf"
        }
    }

    /// The identifier the record starts with, so the lookup asks the
    /// registrar directly rather than reading the first page for it.
    public var identifiers: Identifiers {
        switch self {
        case let .arxiv(id): Identifiers(arxiv: id)
        case let .doi(doi): Identifiers(doi: doi)
        case .web: Identifiers()
        }
    }

    /// The PDF addresses OpenAlex's answer offers, best first: the location
    /// it calls best, then every other with a `pdf_url`, then `oa_url` when
    /// it looks like a file. Empty when the answer has none.
    public static func openAccessPDFs(inOpenAlex data: Data) -> [URL] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var found: [URL] = []
        func take(_ value: Any?) {
            guard let text = value as? String, let url = URL(string: text), ["http", "https"].contains(url.scheme ?? "") else { return }
            if !found.contains(url) { found.append(url) }
        }
        take((object["best_oa_location"] as? [String: Any])?["pdf_url"])
        take((object["primary_location"] as? [String: Any])?["pdf_url"])
        for location in object["locations"] as? [[String: Any]] ?? [] { take(location["pdf_url"]) }
        take((object["open_access"] as? [String: Any])?["oa_url"])
        return found
    }

    // MARK: - Reading

    // Lookbehinds are not in Swift's regex yet: the path these are run
    // on is already the identifier's own tail.
    // Computed rather than stored: a `Regex` is not Sendable, and a stored
    // static one is a shared mutable global to Swift 6.
    private static var newStyle: Regex<(Substring, Substring)> { /(\d{4}\.\d{4,5})(?:v\d+)?(?!\d)/ }
    private static var oldStyle: Regex<(Substring, Substring)> { /([a-z]+(?:-[a-z]+)?(?:\.[A-Z]{2})?\/\d{7})(?:v\d+)?(?!\d)/ }
    // `<` and `>` are in a SICI DOI; `?` and `#` end a URL's path.
    private static var doiPattern: Regex<Substring> { /10\.\d{4,9}\/[^\s"?#]+/ }

    static func arxivIdentifier(in line: String) -> String? {
        let lower = line.lowercased()
        if lower.hasPrefix("arxiv:") || lower.hasPrefix("arxiv.") || lower.hasPrefix("10.48550/arxiv.") {
            let rest = String(line[line.index(line.startIndex, offsetBy: lower.hasPrefix("10.48550/arxiv.") ? 15 : 6)...])
            return identifier(inArxivPath: rest)
        }
        if let url = URL(string: line), let host = url.host()?.lowercased(),
           host == "arxiv.org" || host.hasSuffix(".arxiv.org") {
            // /abs/ID, /pdf/ID, /pdf/ID.pdf, /pdfvN, /html/ID: the path's tail.
            var path = url.path()
            for prefix in ["/abs/", "/pdf/", "/html/", "/format/"] where path.hasPrefix(prefix) {
                path = String(path.dropFirst(prefix.count))
            }
            if path.lowercased().hasSuffix(".pdf") { path = String(path.dropLast(4)) }
            return identifier(inArxivPath: path)
        }
        // A bare identifier, and nothing else on the line.
        if let match = line.wholeMatch(of: /(\d{4}\.\d{4,5})(?:v\d+)?/) { return String(match.1) }
        if let match = line.wholeMatch(of: /([a-z]+(?:-[a-z]+)?(?:\.[A-Z]{2})?\/\d{7})(?:v\d+)?/) { return String(match.1) }
        return nil
    }

    private static func identifier(inArxivPath path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let match = trimmed.firstMatch(of: newStyle) { return String(match.1) }
        if let match = trimmed.firstMatch(of: oldStyle) { return String(match.1) }
        return nil
    }

    static func doi(in line: String) -> String? {
        var candidates: [String] = []
        let lower = line.lowercased()
        if lower.hasPrefix("doi:") { candidates.append(String(line.dropFirst(4))) }
        if let url = URL(string: line), let host = url.host()?.lowercased() {
            if host == "doi.org" || host == "dx.doi.org" || host.hasSuffix(".doi.org") {
                let path = String(url.path().dropFirst())
                candidates.append(path.removingPercentEncoding ?? path)
            }
            // Scopus and the like: `…?eid=…&doi=10.…`.
            for item in URLComponents(string: line)?.queryItems ?? [] where item.name.lowercased() == "doi" {
                if let value = item.value { candidates.append(value) }
            }
            if let decoded = url.path().removingPercentEncoding { candidates.append(decoded) }
        }
        candidates.append(line.removingPercentEncoding ?? line)
        for candidate in candidates {
            if let match = candidate.firstMatch(of: doiPattern) {
                return clean(String(match.0))
            }
        }
        return nil
    }

    /// A DOI as a registrar would take it: lower-cased, without the
    /// punctuation a sentence or a URL hangs on its end.
    private static func clean(_ doi: String) -> String {
        var value = doi
        while let last = value.last, ".,;:)]}'\"".contains(last) { value.removeLast() }
        // `…/abstract` and `…/pdf` are the page's, not the DOI's — only on
        // the known publisher suffixes, since a DOI may hold any characters.
        for tail in ["/abstract", "/full", "/pdf", "/epdf", "/summary", "/meta"] where value.lowercased().hasSuffix(tail) {
            value = String(value.dropLast(tail.count))
        }
        return value.lowercased()
    }

    private static func webAddress(_ line: String) -> URL? {
        if let url = URL(string: line), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host() != nil {
            return url
        }
        // `example.org/paper.pdf`: a host with a dot and no scheme.
        guard !line.contains("://"), let dot = line.firstIndex(of: "."), dot != line.startIndex,
              let url = URL(string: "https://\(line)"), let host = url.host(), host.contains("."),
              let tail = host.split(separator: ".").last, tail.count >= 2, tail.allSatisfy(\.isLetter) else { return nil }
        return url
    }

    private static func sanitisedFileName(_ text: String) -> String {
        var name = ""
        // What no desktop takes in a name: the Mac's two, and Windows's rest.
        for scalar in text.unicodeScalars {
            if "/:\\<>\"|?*%".unicodeScalars.contains(scalar) || scalar.value < 32 { name.append("_") } else { name.unicodeScalars.append(scalar) }
        }
        return String(name.prefix(120))
    }
}
