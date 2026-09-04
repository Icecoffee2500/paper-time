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
            if let result, result.confidence == .verified { return finish(result) }
            fallback = fallback ?? result
        }
        if let arxivID = found.arxiv {
            let result = await resolveByArxiv(arxivID, header: bestHeader, headers: headers)
            if let result, result.confidence == .verified { return finish(result) }
            fallback = fallback ?? result
        }

        let byTitle = await resolveByTitle(headers: headers, signals: signals)
        if byTitle.confidence == .verified { return finish(byTitle) }

        // Prefer whichever attempt produced a record with real fields.
        guard let fallback else { return finish(byTitle) }
        return finish(
            fallback.csl.hasMinimumFields && !byTitle.csl.hasMinimumFields ? fallback : byTitle
        )
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

        var pool: [(item: CSLItem, identifiers: Identifiers, source: Provenance.Source)] = []
        var transient: (any Error)?

        // Only the two strongest guesses are searched: every extra query costs
        // a second of rate limit and adds candidates that dilute the ranking.
        for header in headers.prefix(2) {
            let authorHint = header.authors.first?.sortingSurname
            do {
                let matches = try await crossref.search(
                    bibliographic: header.title,
                    author: authorHint
                )
                pool += matches.map {
                    ($0, Identifiers(doi: $0.doi), Provenance.Source.crossref)
                }
            } catch let error as NetworkService.Failure where error.isTransient {
                transient = error
            } catch {}

            do {
                let matches = try await openAlex.search(title: header.title)
                pool += matches.map {
                    ($0, Identifiers(doi: $0.doi, pmid: $0.pmid), Provenance.Source.openAlex)
                }
            } catch let error as NetworkService.Failure where error.isTransient {
                transient = error
            } catch {}

            if pool.contains(where: {
                MetadataVerifier.assess(
                    candidate: $0.item,
                    against: header,
                    identifierCameFromDocument: false
                ).verdict == .verified
            }) {
                break
            }
        }

        guard let best = MetadataVerifier.best(
            among: pool,
            header: primary,
            identifierCameFromDocument: false
        ) else {
            return ResolutionResult(
                csl: fallbackItem(from: primary),
                identifiers: Identifiers(),
                confidence: .needsReview,
                provenance: Provenance(
                    source: primary.source,
                    detail: transient == nil
                        ? "no registrar match for the extracted title"
                        : "could not reach the metadata services"
                ),
                transientFailure: transient
            )
        }

        // Prefer the registrar record when confirmed; otherwise keep what was
        // read from the paper and offer the registrar rows as candidates.
        let ranked = pool
            .map { entry in
                (
                    entry: entry,
                    assessment: MetadataVerifier.assess(
                        candidate: entry.item,
                        against: primary,
                        identifierCameFromDocument: false
                    )
                )
            }
            .sorted { $0.assessment.score > $1.assessment.score }
            .prefix(4)

        if best.assessment.verdict == .verified {
            return ResolutionResult(
                csl: best.item,
                identifiers: best.identifiers,
                confidence: .verified,
                provenance: Provenance(source: best.source, detail: "title match"),
                assessment: best.assessment
            )
        }

        return ResolutionResult(
            csl: fallbackItem(from: primary),
            identifiers: Identifiers(),
            confidence: .needsReview,
            provenance: Provenance(source: primary.source, detail: "extracted from the document"),
            candidates: ranked.map {
                candidate($0.entry.item, $0.entry.identifiers, $0.entry.source, $0.assessment)
            },
            assessment: best.assessment,
            transientFailure: transient
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
