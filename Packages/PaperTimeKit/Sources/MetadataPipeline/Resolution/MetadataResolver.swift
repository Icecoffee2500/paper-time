import Foundation
import PaperCore

/// What the pipeline concluded about one document.
public struct ResolutionResult: Sendable {
    public var csl: CSLItem
    public var identifiers: Identifiers
    public var confidence: MetadataConfidence
    public var provenance: Provenance
    public var candidates: [MetadataCandidate]
    public var assessment: MatchAssessment?
    /// Set when the attempt failed for a reason that will pass, so the caller
    /// can leave the paper queued instead of marking it unresolvable.
    public var transientFailure: (any Error)?

    public init(
        csl: CSLItem,
        identifiers: Identifiers,
        confidence: MetadataConfidence,
        provenance: Provenance,
        candidates: [MetadataCandidate] = [],
        assessment: MatchAssessment? = nil,
        transientFailure: (any Error)? = nil
    ) {
        self.csl = csl
        self.identifiers = identifiers
        self.confidence = confidence
        self.provenance = provenance
        self.candidates = candidates
        self.assessment = assessment
        self.transientFailure = transientFailure
    }
}

/// Resolves a PDF to a bibliographic record.
///
/// The order is fixed by how much each step can be trusted:
/// an identifier printed on the paper, then the paper's own embedded title
/// confirmed against a registrar, then typography, and only then a guess the
/// user is asked to confirm. Nothing below "confirmed" is stored as fact.
public actor MetadataResolver {
    private let doiClient: DOIClient
    private let crossref: CrossrefClient
    private let openAlex: OpenAlexClient
    private let arxiv: ArxivClient
    private let headerExtractor: any HeaderExtracting

    public init(
        network: NetworkService,
        contactEmail: String? = nil,
        headerExtractor: any HeaderExtracting = HeuristicHeaderExtractor()
    ) {
        self.doiClient = DOIClient(network: network)
        self.crossref = CrossrefClient(network: network)
        self.openAlex = OpenAlexClient(network: network, contactEmail: contactEmail)
        self.arxiv = ArxivClient(network: network)
        self.headerExtractor = headerExtractor
    }

    public func resolve(
        signals: DocumentSignals,
        originalFileName: String
    ) async -> ResolutionResult {
        let headers = await headerExtractor.extract(from: signals)
        let bestHeader = headers.first
        // Where the paper says it was published, if it says so on its first
        // page — the only witness for the venues that mint no DOI.
        let stamp = VenueStamp.find(in: signals.firstPageLines.joined(separator: "\n"))

        var found = IdentifierScanner.scan(signals.openingText)
        if found.arxiv == nil {
            found.arxiv = IdentifierScanner.arxivID(fromFileName: originalFileName)
        }

        // Each strategy is tried in order of trustworthiness, but a strategy
        // that fails to *confirm* does not end the search: a rate-limited
        // registrar or a preprint server having a bad minute must not leave a
        // paper unresolved when a title lookup would have answered it.
        var fallback: ResolutionResult?

        if let doi = found.doi {
            let result = await resolveByDOI(doi, header: bestHeader, headers: headers)
            if let result, result.confidence == .verified { return finish(await published(result, stamp: stamp)) }
            fallback = fallback ?? result
        }
        if let arxivID = found.arxiv {
            let result = await resolveByArxiv(arxivID, header: bestHeader, headers: headers)
            if let result, result.confidence == .verified { return finish(await published(result, stamp: stamp)) }
            fallback = fallback ?? result
        }

        let byTitle = await resolveByTitle(headers: headers, signals: signals)
        if byTitle.confidence == .verified { return finish(await published(byTitle, stamp: stamp)) }

        // Prefer whichever attempt produced a record with real fields.
        guard let fallback else { return finish(await published(byTitle, stamp: stamp)) }
        return finish(await published(
            fallback.csl.hasMinimumFields && !byTitle.csl.hasMinimumFields ? fallback : byTitle,
            stamp: stamp
        ))
    }

    /// Looks again at a record that is only a preprint — or names no venue —
    /// for where the paper was published, and on the arXiv identifier of a
    /// record it already holds. What `MetadataQueue` runs on the library's
    /// preprints from time to time, since a paper is accepted long after it
    /// is posted.
    public func published(
        _ csl: CSLItem,
        identifiers: Identifiers,
        firstPage: String
    ) async -> (csl: CSLItem, identifiers: Identifiers, provenance: Provenance)? {
        let before = ResolutionResult(
            csl: csl, identifiers: identifiers, confidence: .verified,
            provenance: Provenance(source: .arxiv)
        )
        let after = await published(before, stamp: VenueStamp.find(in: firstPage))
        guard after.csl != csl || after.identifiers != identifiers else { return nil }
        let cleaned = finish(after)
        return (cleaned.csl, cleaned.identifiers, cleaned.provenance)
    }

    /// The published version of a preprint, when there is one.
    ///
    /// arXiv's record of a paper stays a preprint for ever, and so did ours:
    /// a paper at CVPR 2024 was filed as «arXiv» because its PDF printed an
    /// arXiv identifier (2026-11-16, «어딘가에 accept이 되고 publish가 된
    /// 논문은 그걸로 가져오면 좋겠어»). OpenAlex keeps the preprint and the
    /// paper as one work, so asking it about the arXiv DOI answers with the
    /// published DOI, whose record Crossref then gives in full. A venue with
    /// no DOI — NeurIPS, ICLR, ICML — is known only from the paper's own
    /// first page (`VenueStamp`). The published record must be the same paper
    /// — the same title and first author — or it is not taken.
    func published(_ result: ResolutionResult, stamp: VenueStamp?) async -> ResolutionResult {
        guard result.confidence != .unparsed else { return result }
        let preprint = Self.isPreprint(result)
        let venueless = (result.csl.containerTitle ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        guard preprint || venueless else { return result }

        if preprint, let base = Self.arxivBase(of: result) {
            if let work = try? await openAlex.rawWork(doi: "10.48550/arXiv.\(base)"),
               let raw = work.doi, let doi = Identifiers.normalizeDOI(raw), !Self.isArxivDOI(doi) {
                var record: CSLItem? = try? await crossref.work(doi: doi)
                if record == nil { record = try? await doiClient.fetch(doi: doi) }
                if var record, Self.samePaper(record, result.csl) {
                    record.doi = doi
                    var identifiers = result.identifiers
                    identifiers.doi = doi
                    if identifiers.arxiv == nil { identifiers.arxiv = base }
                    var made = result
                    made.csl = record
                    made.identifiers = identifiers
                    made.provenance = Provenance(source: .crossref, detail: "published version of arXiv \(base)")
                    return made
                }
            }
        }
        if let stamp {
            var made = result
            made.csl = stamp.applied(to: result.csl)
            made.provenance.detail = [result.provenance.detail, "venue printed on the paper: \(stamp.short)"]
                .compactMap { $0 }.joined(separator: "; ")
            return made
        }
        return result
    }

    /// A record of a preprint: arXiv's own, by its DOI, its type or its
    /// container.
    static func isPreprint(_ result: ResolutionResult) -> Bool {
        if let doi = result.identifiers.doi ?? result.csl.doi, isArxivDOI(doi) { return true }
        if result.csl.type == .manuscript { return true }
        return result.csl.containerTitle?.localizedCaseInsensitiveContains("arxiv") == true
    }

    static func isArxivDOI(_ doi: String) -> Bool {
        doi.lowercased().hasPrefix("10.48550/arxiv.")
    }

    /// The arXiv number a record stands for, without its version.
    static func arxivBase(of result: ResolutionResult) -> String? {
        if let arxiv = result.identifiers.arxiv, let base = Identifiers(arxiv: arxiv).arxivBaseID { return base }
        for raw in [result.identifiers.doi, result.csl.doi].compactMap({ $0 }) where isArxivDOI(raw) {
            let tail = String(raw.dropFirst("10.48550/arxiv.".count))
            if let base = Identifiers(arxiv: tail).arxivBaseID { return base }
        }
        return nil
    }

    /// The same paper twice: titles alike, and the same first author when
    /// both name one.
    static func samePaper(_ published: CSLItem, _ preprint: CSLItem) -> Bool {
        guard let left = published.fullTitle, let right = preprint.fullTitle,
              StringSimilarity.titleSimilarity(left, right) >= 0.9
        else { return false }
        guard let one = published.author.first?.sortingSurname, let two = preprint.author.first?.sortingSurname
        else { return true }
        let a = TextNormalization.foldedTitle(one), b = TextNormalization.foldedTitle(two)
        guard !a.isEmpty, !b.isEmpty else { return true }
        return a == b || a.contains(b) || b.contains(a) || StringSimilarity.jaroWinkler(a, b) >= 0.92
    }

    // MARK: - Identifier paths

    private func resolveByDOI(
        _ doi: String,
        header: ExtractedHeader?,
        headers: [ExtractedHeader]
    ) async -> ResolutionResult? {
        guard let item = try? await doiClient.fetch(doi: doi) else { return nil }
        let assessment = MetadataVerifier.assess(
            candidate: item,
            against: header,
            identifierCameFromDocument: true
        )
        let identifiers = Identifiers(doi: doi)
        return ResolutionResult(
            csl: item,
            identifiers: identifiers,
            confidence: assessment.verdict,
            provenance: Provenance(
                source: .doiContentNegotiation,
                detail: "doi.org content negotiation"
            ),
            candidates: assessment.verdict == .verified
                ? []
                : [candidate(item, identifiers, .doiContentNegotiation, assessment)],
            assessment: assessment
        )
    }

    private func resolveByArxiv(
        _ arxivID: String,
        header: ExtractedHeader?,
        headers: [ExtractedHeader]
    ) async -> ResolutionResult? {
        var item: CSLItem?
        var identifiers = Identifiers(arxiv: arxivID)
        var source = Provenance.Source.arxiv
        var detail = "arXiv \(arxivID)"

        // arXiv mints a DataCite DOI for every submission, so the record can be
        // fetched through the same content-negotiation path as any other DOI.
        // Preferring it matters in practice: arXiv's own API allows one request
        // every three seconds and refuses the rest, while doi.org does not.
        let base = Identifiers(arxiv: arxivID).arxivBaseID ?? arxivID
        if let preprintDOI = Identifiers.normalizeDOI("10.48550/arXiv.\(base)"),
           var fetched = try? await doiClient.fetch(doi: preprintDOI) {
            // DataCite labels preprints as plain articles; BibTeX needs to know
            // this is unpublished so it emits eprint fields.
            if fetched.type == .other || fetched.type == .articleJournal {
                fetched.type = .manuscript
            }
            fetched.note = "arXiv:\(arxivID)"
            // DataCite records arXiv's publisher as "arXiv (Cornell University)",
            // which reads as a journal name everywhere it is shown.
            if fetched.containerTitle?.localizedCaseInsensitiveContains("arxiv") == true {
                fetched.containerTitle = "arXiv"
            }
            if fetched.publisher?.localizedCaseInsensitiveContains("arxiv") == true {
                fetched.publisher = "arXiv"
            }
            item = fetched
            identifiers.doi = preprintDOI
            source = .doiContentNegotiation
            detail = "arXiv DOI \(preprintDOI)"
        }

        if item == nil {
            guard let entry = try? await arxiv.entry(id: arxivID) else { return nil }
            item = entry.asCSLItem()
            // A preprint that was later published should cite the published
            // version; arXiv reports its DOI once that happens.
            if let publishedDOI = entry.doi,
               let normalised = Identifiers.normalizeDOI(publishedDOI),
               let published = try? await doiClient.fetch(doi: normalised) {
                item = published
                identifiers.doi = normalised
                source = .doiContentNegotiation
            }
        }

        guard let resolved = item else { return nil }
        let assessment = MetadataVerifier.assess(
            candidate: resolved,
            against: header,
            identifierCameFromDocument: true
        )
        return ResolutionResult(
            csl: resolved,
            identifiers: identifiers,
            confidence: assessment.verdict,
            provenance: Provenance(source: source, detail: detail),
            candidates: assessment.verdict == .verified
                ? []
                : [candidate(resolved, identifiers, source, assessment)],
            assessment: assessment
        )
    }

    // MARK: - Title path

    private func resolveByTitle(
        headers: [ExtractedHeader],
        signals: DocumentSignals
    ) async -> ResolutionResult {
        guard let primary = headers.first else {
            return ResolutionResult(
                csl: CSLItem(),
                identifiers: Identifiers(),
                confidence: .unparsed,
                provenance: Provenance(
                    source: .heuristic,
                    detail: signals.hasTextLayer
                        ? "no title could be identified"
                        : "no text layer; needs text recognition"
                )
            )
        }

        /// A registrar result, kept next to the guess that produced it.
        ///
        /// Scoring a result against a *different* guess is meaningless, and it
        /// used to happen whenever the best guess's lookup failed and a weaker
        /// one's succeeded: unrelated papers were then reported as "title match
        /// 63%" against a title they had never been compared to.
        struct Found {
            var item: CSLItem
            var identifiers: Identifiers
            var source: Provenance.Source
            var header: ExtractedHeader

            init(
                _ item: CSLItem,
                _ identifiers: Identifiers,
                _ source: Provenance.Source,
                _ header: ExtractedHeader
            ) {
                self.item = item
                self.identifiers = identifiers
                self.source = source
                self.header = header
            }
        }

        var pool: [Found] = []
        var transientByHeader: [Int: any Error] = [:]

        // Only the two strongest guesses are searched: every extra query costs
        // a second of rate limit and adds noise to the ranking.
        for (index, header) in headers.prefix(2).enumerated() {
            let authorHint = header.authors.first?.sortingSurname
            do {
                let matches = try await crossref.search(
                    bibliographic: header.title,
                    author: authorHint
                )
                pool += matches.map {
                    Found($0, Identifiers(doi: $0.doi), .crossref, header)
                }
            } catch let error as NetworkService.Failure where error.isTransient {
                transientByHeader[index] = error
            } catch {}

            do {
                let matches = try await openAlex.search(title: header.title)
                pool += matches.map {
                    Found($0, Identifiers(doi: $0.doi, pmid: $0.pmid), .openAlex, header)
                }
            } catch let error as NetworkService.Failure where error.isTransient {
                transientByHeader[index] = transientByHeader[index] ?? error
            } catch {}

            let confirmed = pool.contains { found in
                MetadataVerifier.assess(
                    candidate: found.item,
                    against: found.header,
                    identifierCameFromDocument: false
                ).verdict == .verified
            }
            if confirmed { break }
        }

        let assessed = pool
            .map { found in
                (
                    found: found,
                    assessment: MetadataVerifier.assess(
                        candidate: found.item,
                        against: found.header,
                        identifierCameFromDocument: false
                    )
                )
            }
            .sorted { MetadataVerifier.rank($0.assessment) > MetadataVerifier.rank($1.assessment) }

        if let best = assessed.first, best.assessment.verdict == .verified {
            // OpenAlex's own record of a work is thin — a chapter's book is
            // its series, a conference paper has no pages — and the work's
            // DOI has a full one at Crossref.
            if best.found.source == .openAlex, let raw = best.found.identifiers.doi,
               let doi = Identifiers.normalizeDOI(raw), !Self.isArxivDOI(doi),
               var full = try? await crossref.work(doi: doi), Self.samePaper(full, best.found.item) {
                full.doi = doi
                return ResolutionResult(
                    csl: full,
                    identifiers: best.found.identifiers,
                    confidence: .verified,
                    provenance: Provenance(source: .crossref, detail: "title match"),
                    assessment: best.assessment
                )
            }
            return ResolutionResult(
                csl: best.found.item,
                identifiers: best.found.identifiers,
                confidence: .verified,
                provenance: Provenance(source: best.found.source, detail: "title match"),
                assessment: best.assessment
            )
        }

        // Anything this far from the title is noise, not a candidate. Offering
        // four unrelated papers to confirm is worse than offering none.
        let plausible = assessed.filter {
            $0.assessment.titleSimilarity >= MetadataVerifier.candidateFloor
        }

        // A lookup that failed for the strongest guess is the honest
        // explanation, and it means the paper should be retried later rather
        // than treated as unmatchable.
        let primaryFailure = transientByHeader[0]
        let detail: String = if plausible.isEmpty, let primaryFailure {
            "could not reach the metadata services: \(primaryFailure.localizedDescription)"
        } else if plausible.isEmpty {
            "no registrar match for the extracted title"
        } else {
            "extracted from the document; a match needs confirming"
        }

        return ResolutionResult(
            csl: fallbackItem(from: primary),
            identifiers: Identifiers(),
            confidence: .needsReview,
            provenance: Provenance(source: primary.source, detail: detail),
            candidates: plausible.prefix(4).map {
                candidate($0.found.item, $0.found.identifiers, $0.found.source, $0.assessment)
            },
            assessment: plausible.first?.assessment,
            transientFailure: plausible.isEmpty ? primaryFailure : nil
        )
    }

    // MARK: - Helpers

    /// Every record leaves the resolver cleaned, whichever path produced it.
    private func finish(_ result: ResolutionResult) -> ResolutionResult {
        var cleaned = result
        cleaned.csl = RecordSanitizer.sanitized(result.csl)
        cleaned.candidates = result.candidates.map { candidate in
            var copy = candidate
            copy.csl = RecordSanitizer.sanitized(candidate.csl)
            return copy
        }
        return cleaned
    }

    private func candidate(
        _ item: CSLItem,
        _ identifiers: Identifiers,
        _ source: Provenance.Source,
        _ assessment: MatchAssessment
    ) -> MetadataCandidate {
        MetadataCandidate(
            csl: item,
            identifiers: identifiers,
            provenance: Provenance(source: source),
            score: assessment.score,
            matchExplanation: assessment.explanation
        )
    }

    /// Builds a usable record out of what the document itself said, so a paper
    /// that cannot be matched still shows a real title in the library.
    private func fallbackItem(from header: ExtractedHeader?) -> CSLItem {
        guard let header else { return CSLItem() }
        var item = CSLItem()
        item.title = header.title
        item.author = header.authors
        if let year = header.year { item.issued = CSLDate(year: year) }
        if let venue = header.venueHint {
            item.containerTitle = venue
            let lowered = venue.lowercased()
            let conferenceMarkers = ["conference", "proceedings", "workshop", "symposium"]
            item.type = conferenceMarkers.contains(where: lowered.contains)
                ? .paperConference
                : .articleJournal
        } else {
            item.type = .other
        }
        return item
    }
}
