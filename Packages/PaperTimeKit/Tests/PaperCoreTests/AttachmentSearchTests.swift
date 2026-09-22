import Foundation
import Testing
@testable import PaperCore

@Suite("Finding the paper to attach to")
struct AttachmentSearchTests {
    private func candidate(_ title: String, file: String = "") -> AttachmentSearch.Candidate {
        AttachmentSearch.Candidate(
            id: UUID(),
            title: title,
            fileName: file.isEmpty ? title + ".pdf" : file
        )
    }

    private var library: [AttachmentSearch.Candidate] {
        [
            candidate("Efficient Test-Time Adaptation of Vision-Language Models",
                      file: "Karmanov_Efficient_Test-Time_Adaptation_CVPR_2024.pdf"),
            candidate("Attention Is All You Need", file: "1706.03762v7.pdf"),
            candidate("Deep Residual Learning for Image Recognition"),
            candidate("강화학습의 수학적 기초", file: "rl-foundations.pdf"),
            candidate("Zero-Shot Text-to-Image Generation"),
        ]
    }

    @Test("Nothing typed lists every paper in title order")
    func unqueried() {
        let ranked = AttachmentSearch.ranked(library, matching: "")
        #expect(ranked.count == library.count)
        // Ordered the way the reader's language orders names, not by code
        // point — the order the old submenu had, kept.
        let titles = ranked.map(\.title)
        #expect(titles == titles.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    @Test("A phrase from the middle of a title finds it")
    func middleOfTitle() {
        // The whole point: the old submenu was alphabetical and cut at thirty,
        // so a paper whose title starts with E was reachable only by scrolling
        // past everything before it.
        let ranked = AttachmentSearch.ranked(library, matching: "vision-language")
        #expect(ranked.first?.title == "Efficient Test-Time Adaptation of Vision-Language Models")
    }

    @Test("The file name is a name for the paper too")
    func byFileName() {
        // Nothing in that title says "Karmanov", and it is what the reader
        // downloaded and what they will type.
        let ranked = AttachmentSearch.ranked(library, matching: "karmanov")
        #expect(ranked.first?.title == "Efficient Test-Time Adaptation of Vision-Language Models")

        let byNumber = AttachmentSearch.ranked(library, matching: "1706.03762")
        #expect(byNumber.first?.title == "Attention Is All You Need")
    }

    @Test("A word prefix is enough")
    func prefixes() {
        #expect(AttachmentSearch.ranked(library, matching: "adapt").first?.title
            == "Efficient Test-Time Adaptation of Vision-Language Models")
        #expect(AttachmentSearch.ranked(library, matching: "resid").first?.title
            == "Deep Residual Learning for Image Recognition")
    }

    @Test("Korean finds its noun through the particle")
    func korean() {
        // "강화학습" is written "강화학습의" in the title; a search that only
        // matched whole words would miss it.
        let ranked = AttachmentSearch.ranked(library, matching: "강화학습")
        #expect(ranked.first?.title == "강화학습의 수학적 기초")
    }

    @Test("Every word beats most of them")
    func coverage() {
        let ranked = AttachmentSearch.ranked(library, matching: "image recognition")
        #expect(ranked.first?.title == "Deep Residual Learning for Image Recognition")
        // "Zero-Shot Text-to-Image Generation" holds one of the two words, so
        // it is in the list and it is not first.
        #expect(ranked.count >= 2)
        #expect(ranked[1].title == "Zero-Shot Text-to-Image Generation")
    }

    @Test("A paper that answers nothing is not offered")
    func excluded() {
        let ranked = AttachmentSearch.ranked(library, matching: "photosynthesis")
        #expect(ranked.isEmpty)
    }

    @Test("A typo still finds the paper")
    func typo() {
        // No word of "attention is all you ned" matches by prefix, so this is
        // the whole-title fallback rather than the word ladder.
        let ranked = AttachmentSearch.ranked(library, matching: "attentoin is all you ned")
        #expect(ranked.first?.title == "Attention Is All You Need")
    }

    @Test("The supplement's parent is offered before anything is typed")
    func suggestion() {
        let shelf = library
        let parent = shelf.first { $0.title == "Attention Is All You Need" }
        let child = AttachmentSearch.Candidate(
            id: UUID(),
            title: "",
            fileName: "Attention Is All You Need supplementary.pdf"
        )
        #expect(AttachmentSearch.suggestion(for: child, among: shelf) == parent?.id)
    }

    @Test("A paper that is not a supplement is offered no parent")
    func onlySupplements() {
        // Two titles that begin with the same words score high enough to be
        // called a match, and a heading that says "looks like the one" over
        // the wrong paper is worse than no heading at all.
        let child = AttachmentSearch.Candidate(
            id: UUID(),
            title: "Scene-Graph ViT: End-to-End Open-Vocabulary Visual Relationship Detection",
            fileName: "scene_graph_vit.pdf"
        )
        let shelf = library + [candidate("Scene Graph Generation by Iterative Message Passing")]
        #expect(AttachmentSearch.suggestion(for: child, among: shelf) == nil)
    }

    @Test("Nothing is suggested when nothing stands out")
    func noSuggestion() {
        let child = AttachmentSearch.Candidate(
            id: UUID(), title: "", fileName: "scan-2026-04-11.pdf"
        )
        #expect(AttachmentSearch.suggestion(for: child, among: library) == nil)
    }
}
