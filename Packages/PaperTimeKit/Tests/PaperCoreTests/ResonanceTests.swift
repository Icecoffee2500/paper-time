import Foundation
import Testing
@testable import PaperCore

@Suite("Resonance")
struct ResonanceTests {
    let synaptic = (id: "synaptic",
                    text: "Synaptic consolidation in the cortex. Excitatory synapses are strengthened and spines persist, which protects old memories against catastrophic forgetting.")
    let openVLA = (id: "openvla",
                   text: "OpenVLA turns a vision-language model into a robot policy: the action head detokenises text into discrete actions.")
    let shopping = (id: "shopping", text: "Buy milk, eggs and coffee before the shop closes.")
    let page = """
        We implement an algorithm similar to synaptic consolidation in artificial neural networks: \
        elastic weight consolidation slows learning on the weights important for old tasks, so that a \
        network can learn task B without catastrophic forgetting of task A.
        """

    @Test("A note about the same thing echoes; notes about other things stay quiet")
    func echoes() {
        let index = Resonance.Index(notes: [synaptic, openVLA, shopping])
        let matches = index.matches(for: page)
        #expect(matches.map(\.id) == ["synaptic"])
    }

    @Test("The shared words are named, the rare ones first, as the page writes them")
    func sharedWords() throws {
        let index = Resonance.Index(notes: [synaptic, openVLA, shopping])
        let match = try #require(index.matches(for: page).first)
        #expect(match.shared.contains("catastrophic forgetting"))
        #expect(match.shared.contains { $0.contains("consolidation") })
        // A word inside a shown pair is not shown again on its own.
        #expect(!match.shared.contains("forgetting"))
        #expect(!match.shared.contains("the"))
    }

    @Test("Plurals and participles meet their stems")
    func stems() {
        #expect(Resonance.stem("weights") == "weight")
        #expect(Resonance.stem("pretraining") == "pretrain")
        #expect(Resonance.stem("pretrained") == "pretrain")
        #expect(Resonance.stem("forgetting") == "forget")
        #expect(Resonance.stem("policies") == "policy")
        #expect(Resonance.stem("loss") == "loss")
    }

    @Test("A word on every page counts for little; a word on two pages for much")
    func background() {
        let everywhere = (id: "network", text: "Network layers.")
        let rare = (id: "spines", text: "Dendritic spines persist for months.")
        let pages = [
            "The network layers grow.", "Network layers shrink.", "Dendritic spines persist in the network layers.",
            "The network layers learn.", "More network layers.",
        ]
        let index = Resonance.Index(notes: [everywhere, rare], background: pages)
        let query = "Dendritic spines persist in the network layers."
        let matches = index.matches(for: query)
        #expect(matches.first?.id == "spines")
    }

    @Test("Notation and markup are not words")
    func markup() {
        let words = Resonance.words(in: "See [[202609061204|Discretising actions]] and $\\mathcal{L}_{rollout}$ at https://x.y/z #robotics `code`")
        // "at" goes too: two letters is not a word worth matching on.
        #expect(words == ["See", "Discretising", "actions", "and", "robotics"])
    }

    @Test("Excluded notes are not returned, and nothing is returned for nothing")
    func exclusions() {
        let index = Resonance.Index(notes: [synaptic, openVLA])
        #expect(index.matches(for: page, excluding: ["synaptic"]).isEmpty)
        #expect(index.matches(for: "   ").isEmpty)
        #expect(Resonance.Index(notes: []).matches(for: page).isEmpty)
    }

    @Test("Two shared words that every paper uses are no echo")
    func generic() {
        let bland = (id: "bland", text: "The proposed method shows results on the model with training data.")
        let index = Resonance.Index(notes: [bland])
        #expect(index.matches(for: "Our method shows results; the model uses training data.").isEmpty)
    }
}
