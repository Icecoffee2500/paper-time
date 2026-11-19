@testable import MetadataPipeline
import PaperCore
import Testing

/// Where a paper was published, from its own first page, and the published
/// version of a preprint (2026-11-16: papers at CVPR, NeurIPS and ICLR were
/// all filed as «arXiv»).
@Suite("Venue stamps and published versions")
struct VenueStampTests {
    @Test("The final phrasings name the venue and its year")
    func finalPhrasings() {
        #expect(VenueStamp.find(in: "Published as a conference paper at ICLR 2024")?.short == "ICLR")
        #expect(VenueStamp.find(in: "37th Conference on Neural Information Processing Systems (NeurIPS 2023).")?.year == 2023)
        let icml = VenueStamp.find(in: "Proceedings of the 40 th International Conference on Machine Learning, Honolulu, Hawaii, USA. PMLR 202, 2023.")
        #expect(icml?.short == "ICML")
        #expect(icml?.volume == "202")
        #expect(icml?.collectionTitle == "Proceedings of Machine Learning Research")
        #expect(VenueStamp.find(in: "This CVPR paper is the Open Access version, provided by the Computer Vision Foundation.")?.short == "CVPR")
        #expect(VenueStamp.find(in: "The Thirty-Eighth AAAI Conference on Artificial Intelligence (AAAI-24)")?.year == 2024)
    }

    @Test("Submissions, preprints and workshops say nothing")
    func notPublished() {
        #expect(VenueStamp.find(in: "Under review as a conference paper at ICLR 2024") == nil)
        #expect(VenueStamp.find(in: "Submitted to 37th Conference on Neural Information Processing Systems (NeurIPS 2023).") == nil)
        #expect(VenueStamp.find(in: "37th Conference on Neural Information Processing Systems (NeurIPS 2023) Workshop on Foo.") == nil)
        #expect(VenueStamp.find(in: "Preliminary work. Under review by the International Conference on Machine Learning (ICML).") == nil)
        #expect(VenueStamp.find(in: "This CVPR workshop paper is the Open Access version, provided by the Computer Vision Foundation.") == nil)
        #expect(VenueStamp.find(in: "Preprint. Under review.") == nil)
    }

    @Test("A stamp turns a preprint into the paper at its venue, without arXiv's DOI")
    func applied() {
        var preprint = CSLItem()
        preprint.title = "SalUn"
        preprint.type = .manuscript
        preprint.containerTitle = "arXiv"
        preprint.doi = "10.48550/arxiv.2310.12508"
        let made = VenueStamp.find(in: "Published as a conference paper at ICLR 2024")!.applied(to: preprint)
        #expect(made.type == .paperConference)
        #expect(made.containerTitle == "International Conference on Learning Representations")
        #expect(made.year == 2024)
        #expect(made.doi == nil)
    }

    @Test("A preprint is arXiv's record by its DOI, its type or its container")
    func preprints() {
        func result(_ edit: (inout CSLItem, inout Identifiers) -> Void) -> ResolutionResult {
            var item = CSLItem()
            var ids = Identifiers()
            edit(&item, &ids)
            return ResolutionResult(csl: item, identifiers: ids, confidence: .verified, provenance: Provenance(source: .arxiv))
        }
        #expect(MetadataResolver.isPreprint(result { _, ids in ids.doi = "10.48550/arXiv.2403.18293" }))
        #expect(MetadataResolver.isPreprint(result { item, _ in item.type = .manuscript }))
        #expect(MetadataResolver.isPreprint(result { item, _ in item.containerTitle = "arXiv (Cornell University)" }))
        #expect(!MetadataResolver.isPreprint(result { item, _ in item.type = .paperConference; item.containerTitle = "CVPR" }))
        #expect(MetadataResolver.arxivBase(of: result { _, ids in ids.doi = "10.48550/arxiv.2403.18293" }) == "2403.18293")
        #expect(MetadataResolver.arxivBase(of: result { _, ids in ids.arxiv = "2403.18293v1" }) == "2403.18293")
    }

    @Test("A published record is taken only for the same paper")
    func samePaper() {
        var preprint = CSLItem()
        preprint.title = "Efficient Test-Time Adaptation of Vision-Language Models"
        preprint.author = [CSLName(family: "Karmanov", given: "Adilbek")]
        var published = preprint
        published.containerTitle = "2024 IEEE/CVF Conference on Computer Vision and Pattern Recognition (CVPR)"
        #expect(MetadataResolver.samePaper(published, preprint))
        published.author = [CSLName(family: "Somebody", given: "Else")]
        #expect(!MetadataResolver.samePaper(published, preprint))
        published.author = preprint.author
        published.title = "Auto-Encoding Variational Bayes"
        #expect(!MetadataResolver.samePaper(published, preprint))
    }
}
