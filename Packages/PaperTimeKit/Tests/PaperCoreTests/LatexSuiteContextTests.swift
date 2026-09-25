import Foundation
import Testing
@testable import PaperCore

/// Where the caret is, position by position, against the plugin's own
/// `Context` (`latex-suite-context.json`): the mode flags, the equation's
/// bounds and the scope stack. The keystroke fixtures only see these through
/// what a snippet did; this sees them directly, at every offset of 820 notes.
extension LatexSuiteTests {
    @Suite("Context")
    struct Context {
        struct Fixture: Decodable {
            struct Header: Decodable {
                struct Divergent: Decodable {
                    var doc: Int
                    var reason: String
                }

                var divergent: [Divergent]
            }

            struct Doc: Decodable {
                var set: String
                var doc: String
                var runs: [Run]
                var equations: [Equation]?
            }

            struct Equation: Decodable {
                var caret: Int
                var pairs: [[Int]]

                init(from decoder: Decoder) throws {
                    var c = try decoder.unkeyedContainer()
                    caret = try c.decode(Int.self)
                    pairs = try c.decode([[Int]].self)
                }
            }

            struct Run: Decodable {
                var from: Int
                var to: Int
                var mode: String
                var bounds: [Int]?
                var stack: [String]

                init(from decoder: Decoder) throws {
                    var c = try decoder.unkeyedContainer()
                    from = try c.decode(Int.self)
                    to = try c.decode(Int.self)
                    mode = try c.decode(String.self)
                    bounds = try c.decodeIfPresent([Int].self)
                    stack = try c.decode([String].self)
                }
            }

            var header: Header
            var docs: [Doc]
        }

        static let fixture: Fixture = {
            // swiftlint:disable:next force_try
            try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: LatexSuiteFixtures.url("latex-suite-context")))
        }()

        /// The context at `pos`, written the fixture's way.
        static func describe(_ units: LSUnits, _ pos: Int) -> (mode: String, bounds: [Int]?, stack: [String]) {
            let ctx = LSContext(doc: units, selection: [pos..<pos], library: .shared, forceMathLanguages: ["math"])
            let m = ctx.mode
            var flags: [String] = []
            if m.text { flags.append("t") }
            if m.inlineMath { flags.append("n") }
            if m.blockMath { flags.append("M") }
            if m.codeMath { flags.append("k") }
            if case let .language(l) = m.codeBlock { flags.append("c=" + l) }
            if m.code { flags.append("C") }
            if m.textEnv { flags.append("T") }
            if m.snippetlessEnv { flags.append("S") }
            let bounds = ctx.equation.map { [$0.outerStart, $0.innerStart, $0.innerEnd, $0.outerEnd] }
            let stack = ctx.scopes(at: pos).map { s -> String in
                switch s.kind {
                case .math: return "math"
                case .environment: return "environment:" + s.name
                case .command: return "command:\(s.name):\(s.argumentIndex)"
                }
            }
            return (flags.joined(separator: ","), m.codeBlock == .no ? bounds : nil, stack)
        }

        @Test("Every caret position reads the way the plugin reads it", arguments: ["written", "random"])
        func positions(_ set: String) {
            let divergent = Set(Self.fixture.header.divergent.map(\.doc))
            var checked = 0
            for (index, doc) in Self.fixture.docs.enumerated() where doc.set == set && !divergent.contains(index) {
                let units = LS.units(doc.doc)
                for run in doc.runs {
                    for pos in run.from...run.to {
                        let got = Self.describe(units, pos)
                        checked += 1
                        let marked = (doc.doc as NSString).replacingCharacters(in: NSRange(location: pos, length: 0), with: "‸")
                        #expect(got.mode == run.mode && got.bounds == run.bounds && got.stack == run.stack,
                                "\(marked.debugDescription): got \(got), want \(run.mode) \(run.bounds ?? []) \(run.stack)")
                    }
                }
            }
            #expect(checked > (set == "written" ? 2_500 : 14_000))
        }

        /// The pairs auto-enlarge can rewrite, deduplicated: see the fixture's
        /// note on `equations` for why only these.
        static func rewritable(_ pairs: [[Int]], in units: LSUnits) -> Set<[Int]> {
            Set(pairs.filter { p in
                let open = units.slice(p[0], p[1]).string
                let close = units.slice(p[2], p[3]).string
                return !(open == "{" || open == "\\(" || open.hasPrefix("\\left") || close.hasPrefix("\\right"))
            })
        }

        @Test("Auto-enlarge sees the bracket pairs the plugin sees", arguments: ["written", "random"])
        func bracketPairs(_ set: String) {
            var checked = 0
            for doc in Self.fixture.docs where doc.set == set {
                let units = LS.units(doc.doc)
                for equation in doc.equations ?? [] {
                    let pos = equation.caret
                    let ctx = LSContext(doc: units, selection: [pos..<pos], library: .shared, forceMathLanguages: ["math"])
                    // The equation auto-enlarge picks (auto_enlarge_brackets.ts).
                    let bound = ctx.bounds.first { $0.tree != nil && $0.innerStart <= pos && $0.innerEnd >= pos }
                    let got = bound.flatMap { ctx.latex(for: $0) }?.pairs()
                        .map { [$0.open.lowerBound, $0.open.upperBound, $0.close.lowerBound, $0.close.upperBound] } ?? []
                    checked += 1
                    #expect(Self.rewritable(got, in: units) == Self.rewritable(equation.pairs, in: units),
                            "\(doc.doc.debugDescription) at \(pos)")
                }
            }
            #expect(checked > (set == "written" ? 150 : 90))
        }

        @Test("The one divergence is still the known one")
        func divergence() throws {
            // If this starts to agree, drop it from the fixture's `divergent`.
            let entry = try #require(Self.fixture.header.divergent.first)
            let doc = Self.fixture.docs[entry.doc]
            let units = LS.units(doc.doc)
            let disagreements = doc.runs.flatMap { run in
                (run.from...run.to).filter { pos in
                    let got = Self.describe(units, pos)
                    return !(got.mode == run.mode && got.bounds == run.bounds && got.stack == run.stack)
                }
            }
            #expect(!disagreements.isEmpty)
        }
    }
}
