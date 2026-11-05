// The addresses the field accepts, answered by the Mac's `PaperAddress`,
// for `Tests/PaperCoreTests/Fixtures/paper-addresses.json` — which the
// Portable build's `shared/paperAddress.ts` is held to.
//
//   swiftc -O -enable-bare-slash-regex \
//     Packages/PaperTimeKit/Sources/PaperCore/Model/PaperAddress.swift \
//     Packages/PaperTimeKit/Sources/PaperCore/Model/Identifiers.swift \
//     Scripts/paper-address-fixture.swift -o /tmp/paper-address-fixture && /tmp/paper-address-fixture
import Foundation

let texts = [
    "2512.11732", "2512.11732v2", " arXiv:2512.11732 ", "arxiv:2512.11732v1", "cs/0101001", "hep-th/9901001v3",
    "https://arxiv.org/abs/2512.11732", "https://arxiv.org/abs/2512.11732v2", "http://arxiv.org/pdf/2512.11732",
    "https://arxiv.org/pdf/2512.11732v2.pdf", "https://www.arxiv.org/html/2512.11732v1", "https://export.arxiv.org/abs/cs/0101001",
    "https://arxiv.org/abs/math.AG/0601001", "<https://arxiv.org/abs/2512.11732>",
    "10.48550/arXiv.2512.11732", "https://doi.org/10.48550/arXiv.2512.11732",
    "10.1145/3292500.3330701", "doi:10.1145/3292500.3330701", "DOI: 10.1145/3292500.3330701",
    "https://doi.org/10.1109/CVPR52688.2022.01553", "http://dx.doi.org/10.1038/s41586-020-2649-2.",
    "https://doi.org/10.1002/(SICI)1097-0258(19980430)17:8<857::AID-SIM777>3.0.CO;2-E",
    "https://www.scopus.com/record/display.uri?eid=2-s2.0-85123456789&doi=10.1016%2fj.neunet.2021.01.001&origin=inward",
    "https://www.scopus.com/record/display.uri?eid=2-s2.0-85123456789&origin=inward",
    "https://link.springer.com/article/10.1007/s10462-023-10562-9",
    "https://onlinelibrary.wiley.com/doi/full/10.1002/advs.202300001",
    "https://onlinelibrary.wiley.com/doi/abs/10.1002/advs.202300001",
    "https://ieeexplore.ieee.org/document/9879595",
    "https://www.sciencedirect.com/science/article/pii/S0893608021000010",
    "https://openreview.net/pdf?id=abc123", "https://example.org/papers/lejepa.pdf", "example.org/papers/lejepa.pdf",
    "https://proceedings.neurips.cc/paper_files/paper/2023/file/abcd-Paper-Conference.pdf",
    "https://example.org/", "not an address", "two words here", "", "ftp://example.org/x.pdf", "10.12/short",
    "https://arxiv.org/abs/", "arXiv:", "https://doi.org/",
]

struct Case: Encodable {
    var text: String
    var kind: String?
    var value: String?
    var address: String?
    var pdf: String?
    var lookup: String?
    var file: String?
}

@main
struct Fixture {
    static func main() throws {
        var cases: [Case] = []
        for text in texts {
            var made = Case(text: text)
            if let address = PaperAddress.read(text) {
                switch address {
                case let .arxiv(id): made.kind = "arxiv"; made.value = id
                case let .doi(doi): made.kind = "doi"; made.value = doi
                case let .web(url): made.kind = "web"; made.value = url.absoluteString
                }
                made.address = address.text
                made.pdf = address.pdfURL?.absoluteString
                made.lookup = address.lookupURL?.absoluteString
                made.file = address.fileName
            }
            cases.append(made)
        }

        // OpenAlex answers, and the PDF addresses read out of them, best first.
        let answers: [String] = [
            #"{"id":"https://openalex.org/W1","open_access":{"oa_url":"https://arxiv.org/pdf/2512.11732"},"best_oa_location":{"pdf_url":"https://arxiv.org/pdf/2512.11732v2","landing_page_url":"https://arxiv.org/abs/2512.11732"},"primary_location":{"pdf_url":null,"landing_page_url":"https://doi.org/10.1/x"},"locations":[{"pdf_url":"https://arxiv.org/pdf/2512.11732v2"},{"pdf_url":"https://publisher.example/x.pdf"},{"pdf_url":null}]}"#,
            #"{"id":"https://openalex.org/W2","open_access":{"oa_url":null},"best_oa_location":null,"primary_location":{"pdf_url":null},"locations":[]}"#,
            #"{"id":"https://openalex.org/W3","open_access":{"oa_url":"https://europepmc.org/articles/PMC1/pdf"},"best_oa_location":null,"locations":[{"pdf_url":"ftp://nope/x.pdf"}]}"#,
            #"not json"#,
        ]
        struct Answer: Encodable { var json: String; var pdfs: [String] }
        let read = answers.map { Answer(json: $0, pdfs: PaperAddress.openAccessPDFs(inOpenAlex: Data($0.utf8)).map(\.absoluteString)) }

        // Publishers' files, guessed from the DOI's prefix (and OpenAlex's
        // landing page where the publisher names files its own way).
        let elsevier = #"{"id":"https://openalex.org/W4","primary_location":{"pdf_url":null,"landing_page_url":"https://www.sciencedirect.com/science/article/pii/S0893608021000010"},"locations":[{"landing_page_url":"https://linkinghub.elsevier.com/retrieve/pii/S0893608021000010"}]}"#
        let ieee = #"{"id":"https://openalex.org/W5","primary_location":{"landing_page_url":"https://ieeexplore.ieee.org/document/9879595/"},"best_oa_location":null,"locations":[{"landing_page_url":"https://doi.org/10.1109/cvpr52688.2022.01553"}]}"#
        let dois: [(String, String)] = [
            ("10.1145/3292500.3330701", answers[1]), ("10.5555/3295222.3295349", answers[1]),
            ("10.1007/s10462-023-10562-9", answers[1]), ("10.1002/advs.202300001", answers[1]),
            ("10.1038/s41586-020-2649-2", answers[1]), ("10.1021/acs.jpcc.0c00001", answers[1]),
            ("10.1126/science.abc1234", answers[1]), ("10.1073/pnas.2000000117", answers[1]),
            ("10.1080/01621459.2020.1000000", answers[1]), ("10.1137/19m1234567", answers[1]),
            ("10.1101/2020.01.01.000001", answers[1]),
            ("10.1016/j.neunet.2021.01.001", elsevier), ("10.1016/j.neunet.2021.01.001", answers[1]),
            ("10.1109/CVPR52688.2022.01553", ieee), ("10.1109/CVPR52688.2022.01553", answers[3]),
            ("10.1371/journal.pone.0000001", answers[1]), ("10.1145/", answers[1]), ("10.1145", answers[1]),
        ]
        struct Guess: Encodable { var doi: String; var json: String; var pdfs: [String] }
        let guesses = dois.map { Guess(doi: $0.0, json: $0.1, pdfs: PaperAddress.publisherPDFs(for: $0.0, inOpenAlex: Data($0.1.utf8)).map(\.absoluteString)) }

        struct Written: Encodable { var addresses: [Case]; var openAlex: [Answer]; var publishers: [Guess] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Written(addresses: cases, openAlex: read, publishers: guesses))
        let out = URL(fileURLWithPath: "Packages/PaperTimeKit/Tests/PaperCoreTests/Fixtures/paper-addresses.json")
        try data.write(to: out)
        print("wrote \(cases.count) addresses, \(read.count) answers, \(guesses.count) publisher guesses to \(out.path)")

    }
}
