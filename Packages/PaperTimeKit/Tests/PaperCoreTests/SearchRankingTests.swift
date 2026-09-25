import Foundation
import Testing
@testable import PaperCore

/// The palette's scores, held to the scoring it did before the library was
/// folded ahead of time: `referenceScore` is that code, copied unchanged.
@Suite("Scoring a name against what is typed")
struct SearchRankingTests {
    /// The palette's `matchScore` as it stood, folding on every call.
    static func referenceScore(foldedQuery: String, foldedText: String) -> Double? {
        guard !foldedText.isEmpty else { return nil }

        if foldedText.hasPrefix(foldedQuery) { return 1.0 }
        if foldedText.split(separator: " ").contains(where: { $0.hasPrefix(foldedQuery) }) { return 0.9 }
        if foldedText.contains(foldedQuery) { return 0.75 }

        let similarity = StringSimilarity.jaroWinkler(foldedQuery, foldedText)
        return similarity > 0.82 ? similarity : nil
    }

    static let names: [String] = [
        "Towards Lifecycle Unlearning Commitment Management- Measuring Sample-level Approximate Unlearning Completeness",
        "Fast Machine Unlearning Without Retraining Through Selective Synaptic Dampening",
        "Elastic Weight Consolidation (EWC)- Nuts and Bolts", "LeJEPA", "I-JEPA", "V_JEPA_Latent_Video_Prediction",
        "Neural Motifs; Scene Graph Parsing with Global Context", "강화학습의 수학적 기초", "학습", "Almudévar",
        "OpenVLA; An Open-Source Vision-Language-Action Model", "Unlearning", "unlearn", "Map", "Draft", "Note",
        "PDF 더하기…", "Add PDFs…", "Export BibTeX…", "Resolve Missing Metadata", "Settings…", "tag", "vla",
        "Sliced Wasserstein distance for learning Gaussian mixture models", "Wasserstein GAN", "le", "L", "",
        "Note 12 about SGG on Visual Genome (VG) dataset [14] for VLM GLIP [19]. R and zR denote the re- call metric "
            + "in the base and novel relations. “Frozen Text” denotes only training the visual part of VLM",
    ]

    static let queries: [String] = [
        "unlearning", "unlernaing", "catastrophic forgetting", "forgetting catastrophic", "학습", "Almudévar",
        "almudevar", "Wasserstein", "wasserstien", "le", "l", "jepa", "LeJEP", "ewc", "nuts and bolts", "openvla",
        "vision language", "machine unlearnin", "fast machine", "u", "un", "unl", "unle", "unlea", "note", "map",
        "setting", "export", "bibtex", "motifs scene", "scene graph", "강화", "수학적 기초", "sgg on visual",
    ]

    @Test("Scores every name against every query exactly as before")
    func sameScores() {
        var compared = 0
        for name in Self.names {
            let text = SearchRanking.Folded(name)
            for raw in Self.queries {
                // Every prefix, the way the palette sees a query being typed.
                for count in 1...raw.count {
                    let query = SearchRanking.Folded(String(raw.prefix(count)))
                    guard !query.text.isEmpty else { continue }
                    let expected = Self.referenceScore(foldedQuery: query.text, foldedText: text.text)
                    #expect(SearchRanking.score(query, against: text) == expected, "\(query.text) / \(name)")
                    compared += 1
                }
            }
        }
        #expect(compared > 1000)
    }

    @Test("A near miss is never skipped where it could have counted")
    func nearMissBound() {
        // Strings of every pair of lengths up to 40, made as alike as they
        // can be: the longer one starts with the shorter one's letters.
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
        for short in 1...40 {
            for long in short...120 {
                let lhs = String((0..<short).map { alphabet[$0 % 26] })
                let rhs = String((0..<long).map { alphabet[$0 % 26] })
                let similarity = StringSimilarity.jaroWinkler(lhs, rhs)
                if similarity > SearchRanking.fuzzyThreshold {
                    #expect(SearchRanking.couldBeNearMiss(short, long), "\(short) vs \(long): \(similarity)")
                }
            }
        }
    }
}
