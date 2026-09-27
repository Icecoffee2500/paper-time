// Citation keys and BibTeX entries as the Mac makes them, for the other
// build to be checked against. The same folder has to export the same
// `.bib` on both desktops: a key minted one way here and another there is a
// changed `\cite` in somebody's paper.
//
// These cases go through the Mac's own `CitationKey` and `BibTeXWriter`:
//
//     Scripts/bibtex-fixtures.sh > Tests/BibliographyTests/Fixtures/bibtex-cases.json
//
// `src/test/bibtexParity.ts` (Portable) runs the same cases through
// `shared/citationKey.ts` and `shared/bibtex.ts` and wants the same answers.

import Foundation

@main
enum BibTeXFixtures {
    struct Case: Codable {
        var name: String
        var csl: CSLItem
        var identifiers: Identifiers
        var bibKey: String
        var fileName: String
    }

    struct KeyAnswer: Codable {
        var name: String
        var csl: CSLItem
        var fileName: String
        var key: String
    }

    struct EntryAnswer: Codable {
        var name: String
        var csl: CSLItem
        var identifiers: Identifiers
        var key: String
        var options: String
        var text: String
    }

    struct Assigned: Codable {
        var items: [AssignItem]
        var keys: [String]
    }

    struct AssignItem: Codable {
        var csl: CSLItem
        var preferred: String?
    }

    struct Out: Codable {
        var keys: [KeyAnswer]
        var entries: [EntryAnswer]
        var assigned: [Assigned]
    }

    static func item(_ json: String) -> CSLItem {
        try! JSONDecoder().decode(CSLItem.self, from: Data(json.utf8))
    }

    static func main() {
        let items: [(String, String, String)] = [
            ("journal", #"{"type":"article-journal","title":"Attention Is All You Need","author":[{"family":"Vaswani","given":"Ashish"},{"family":"Shazeer","given":"Noam"}],"issued":{"date-parts":[[2017,12]]},"container-title":"Advances in Neural Information Processing Systems","container-title-short":"NeurIPS","volume":"30","page":"5998-6008","DOI":"10.5555/3295222.3295349"}"#, "attention.pdf"),
            ("stop words", #"{"type":"paper-conference","title":"Learning to Learn by Gradient Descent by Gradient Descent","author":[{"family":"Andrychowicz","given":"Marcin"}],"issued":{"date-parts":[[2016]]},"container-title":"NIPS"}"#, "l2l.pdf"),
            ("accents and particles", #"{"type":"book","title":"Über die Wärme","author":[{"family":"Beethoven","given":"Ludwig","non-dropping-particle":"van"}],"issued":{"date-parts":[[1905]]},"publisher":"Müller & Söhne","publisher-place":"Wien","edition":"2"}"#, "waerme.pdf"),
            ("an institution", #"{"type":"report","title":"GPT-4 Technical Report","author":[{"literal":"OpenAI"}],"issued":{"date-parts":[[2023]]},"publisher":"OpenAI","number":"TR-1"}"#, "gpt4.pdf"),
            ("no author", #"{"type":"webpage","title":"The Annotated Transformer","URL":"https://nlp.seas.harvard.edu/annotated-transformer/"}"#, "annotated.pdf"),
            ("nothing at all", #"{"type":"other"}"#, "Some File (1).pdf"),
            ("subtitle", #"{"type":"article-journal","title":"Diffusion Policy:","subtitle":"Visuomotor Policy Learning via Action Diffusion","author":[{"family":"Chi","given":"Cheng"}],"issued":{"date-parts":[[2023]]}}"#, "dp.pdf"),
            ("a chapter", #"{"type":"chapter","title":"Kernel Methods","author":[{"family":"Smola","given":"Alex"}],"editor":[{"family":"Schölkopf","given":"Bernhard"}],"container-title":"Learning with Kernels","page":"1–42","issued":{"date-parts":[[2002]]},"collection-title":"Adaptive Computation"}"#, "kernels.pdf"),
            ("a thesis", #"{"type":"thesis","genre":"Master's thesis","title":"On Graphs","author":[{"family":"Kim","given":"Minsu"}],"publisher":"KAIST","issued":{"date-parts":[[2021]]}}"#, "thesis.pdf"),
            ("a preprint", #"{"type":"manuscript","title":"Diffusion Policy","author":[{"family":"Chen","given":"Yi"}],"issued":{"date-parts":[[2024,3]]},"note":"arXiv:2403.18293 [cs.RO]"}"#, "2403.18293v1.pdf"),
        ]
        let identifiers: [String: Identifiers] = [
            "a preprint": Identifiers(doi: "10.48550/arXiv.2403.18293", arxiv: "2403.18293"),
            "journal": Identifiers(doi: "10.5555/3295222.3295349"),
        ]
        var keys: [KeyAnswer] = []
        var entries: [EntryAnswer] = []
        let optionSets: [(String, BibTeXExportOptions)] = [
            ("default", BibTeXExportOptions()),
            ("plain", BibTeXExportOptions(preprintStyle: .arxivPreprintArticle, protectCase: false, abbreviateJournals: true, includeURL: false)),
        ]
        for (name, json, file) in items {
            let csl = item(json)
            let key = CitationKey.make(for: csl, fallback: file)
            keys.append(KeyAnswer(name: name, csl: csl, fileName: file, key: key))
            for (label, options) in optionSets {
                let ids = identifiers[name] ?? Identifiers()
                let entry = BibTeXWriter.entry(for: csl, key: key, identifiers: ids, options: options)
                entries.append(EntryAnswer(name: name, csl: csl, identifiers: ids, key: key, options: label, text: BibTeXWriter.write(entry)))
            }
        }
        let same = item(#"{"type":"article-journal","title":"Deep Nets","author":[{"family":"Smith"}],"issued":{"date-parts":[[2020]]}}"#)
        let groups: [[AssignItem]] = [
            [AssignItem(csl: same, preferred: nil), AssignItem(csl: same, preferred: nil), AssignItem(csl: same, preferred: nil)],
            [AssignItem(csl: same, preferred: nil), AssignItem(csl: same, preferred: "smith2020deep"), AssignItem(csl: same, preferred: "smith2020deep")],
            [AssignItem(csl: same, preferred: "Smith 2020: Deep!"), AssignItem(csl: item(#"{"type":"other"}"#), preferred: nil)],
        ]
        var assigned: [Assigned] = []
        for group in groups {
            let ids = group.map { _ in UUID() }
            let result = CitationKey.assignKeys(to: zip(ids, group).map { (id: $0.0, item: $0.1.csl, preferred: $0.1.preferred) })
            assigned.append(Assigned(items: group, keys: ids.map { result[$0] ?? "" }))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try! encoder.encode(Out(keys: keys, entries: entries, assigned: assigned))
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
