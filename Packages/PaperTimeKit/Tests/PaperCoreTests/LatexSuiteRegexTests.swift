import Foundation
import Testing
@testable import PaperCore

/// The regex triggers are JavaScript regular expressions rewritten into a
/// dialect ICU reads the same way. `latex-suite-regex.json` records what the
/// *original* JavaScript pattern matched on a corpus aimed at the places the
/// two engines part ways; the TypeScript port asserts the same file.
extension LatexSuiteTests {
    @Suite("Regex dialect")
    struct Regex {
        struct Fixture: Decodable {
            struct Case: Decodable {
                var id: Int
                /// [corpus index, match index, capture 1, capture 2, …]
                var matches: [[Value]]
            }

            /// A match index, or a capture's `[from, to]` (UTF-16), or null.
            enum Value: Decodable, Equatable, CustomStringConvertible {
                case int(Int)
                case range(Int, Int)
                case null

                init(from decoder: Decoder) throws {
                    let c = try decoder.singleValueContainer()
                    if c.decodeNil() {
                        self = .null
                    } else if let i = try? c.decode(Int.self) {
                        self = .int(i)
                    } else {
                        let pair = try c.decode([Int].self)
                        self = .range(pair[0], pair[1])
                    }
                }

                init(_ r: Range<Int>?) { self = r.map { .range($0.lowerBound, $0.upperBound) } ?? .null }

                var description: String {
                    switch self {
                    case let .int(i): return "\(i)"
                    case let .range(a, b): return "[\(a),\(b)]"
                    case .null: return "null"
                    }
                }
            }

            var corpus: [String]
            var cases: [Case]
        }

        static let fixture: Fixture = {
            // swiftlint:disable:next force_try
            try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: LatexSuiteFixtures.url("latex-suite-regex")))
        }()

        struct Pattern {
            var id: Int
            var regex: NSRegularExpression
            var shape: LSPatternShape
            var groupNames: [String?]
        }

        static let patterns: [Pattern] = LSLibrary.shared.snippets.compactMap { snippet in
            guard case let .regex(regex, shape, names) = snippet.trigger else { return nil }
            return Pattern(id: snippet.id, regex: regex, shape: shape, groupNames: names)
        }

        /// What the fixture says JavaScript matched on `text`, in the fixture's shape.
        static func expected(_ id: Int, _ index: Int) -> [Fixture.Value]? {
            guard let c = fixture.cases.first(where: { $0.id == id }) else { return nil }
            return c.matches.first { $0.first == .int(index) }.map { Array($0.dropFirst()) }
        }

        static func shape(_ m: LSRegexInput.Match?, shift: Int = 0) -> [Fixture.Value]? {
            guard let m else { return nil }
            return [.int(m.index - shift)] + m.groupRanges.map { Fixture.Value($0.map { ($0.lowerBound - shift)..<($0.upperBound - shift) }) }
        }

        /// ICU's answer on the whole text, the surrogates shown as U+FFFD.
        static func whole(_ regex: NSRegularExpression, _ units: LSUnits) -> [Fixture.Value]? {
            var shown = units
            for k in shown.indices where shown[k] & 0xF800 == 0xD800 { shown[k] = 0xFFFD }
            guard let m = regex.firstMatch(in: shown.string, range: NSRange(location: 0, length: units.count)) else { return nil }
            return [.int(m.range.location)] + (1..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? .null : .range(r.location, r.location + r.length)
            }
        }

        @Test("Every regex trigger compiles, and the fixture has each one")
        func compiles() {
            #expect(Self.patterns.count == 49)
            #expect(Set(Self.patterns.map(\.id)) == Set(Self.fixture.cases.map(\.id)))
        }

        /// The dialect itself: ICU on the whole text gives JavaScript's match.
        @Test("ICU reads every rewritten pattern the way JavaScript read the original", arguments: patterns.map(\.id))
        func dialect(_ id: Int) throws {
            let pattern = try #require(Self.patterns.first { $0.id == id })
            for (index, text) in Self.fixture.corpus.enumerated() {
                // The engine shows ICU each surrogate as U+FFFD; the rest of
                // the dialect needs nothing else.
                let got = Self.whole(pattern.regex, LS.units(text))
                #expect(got == Self.expected(id, index), "snippet \(id) on \(text.debugDescription)")
            }
        }

        /// What the engine actually runs: a window before the caret instead of
        /// the whole prefix, and patterns skipped when they cannot end with the
        /// key. Both must give the whole-prefix answer — typed as a key, and
        /// already in the text (Tab).
        @Test("The engine's windowed match agrees with the whole-prefix match", arguments: patterns.map(\.id))
        func window(_ id: Int) throws {
            let pattern = try #require(Self.patterns.first { $0.id == id })
            for (index, text) in Self.fixture.corpus.enumerated() {
                let units = LS.units(text)
                let want = Self.expected(id, index)
                let onTab = LSRegexInput(doc: units, to: units.count, key: [])
                #expect(Self.shape(onTab.match(pattern.regex, shape: pattern.shape, groupNames: pattern.groupNames)) == want,
                        "snippet \(id), Tab after \(text.debugDescription)")
                guard let last = units.last else { continue }
                let typed = LSRegexInput(doc: Array(units.dropLast()), to: units.count - 1, key: [last])
                #expect(Self.shape(typed.match(pattern.regex, shape: pattern.shape, groupNames: pattern.groupNames)) == want,
                        "snippet \(id), typing the last key of \(text.debugDescription)")
            }
        }

        /// The same corpus after a long note: the window must answer what
        /// matching the whole prefix answers, however much text is in front.
        @Test("A long note in front changes nothing the window sees", arguments: ["", "\n\n", "x", "\n  ", " "])
        func longPrefix(_ joint: String) {
            let prefix = LS.units(String(repeating: "Some prose with $x^2$ and \\alpha in it. ", count: 60) + joint)
            for pattern in Self.patterns {
                for text in Self.fixture.corpus {
                    let units = prefix + LS.units(text)
                    let want = Self.whole(pattern.regex, units)
                    let input = LSRegexInput(doc: units, to: units.count, key: [])
                    let got = Self.shape(input.match(pattern.regex, shape: pattern.shape, groupNames: pattern.groupNames))
                    #expect(got == want, "snippet \(pattern.id) after a long note and \(joint.debugDescription): \(text.debugDescription)")
                }
            }
        }

        @Test("Pattern shapes: lengths and last characters")
        func shapes() {
            let greek = LSPatternShape(pattern: "(?:([^\\\\])((?:alpha|beta|pi)))(?![\\s\\S])")
            #expect(greek.maxLength == 6)
            #expect(greek.last?.contains(97) == true) // a
            #expect(greek.last?.contains(105) == true) // i
            #expect(greek.last?.contains(120) == false) // x
            let letters = LSPatternShape(pattern: "(?:\\\\[A-Za-z]{2,})(?![\\s\\S])")
            #expect(letters.maxLength == nil)
            #expect(letters.last?.contains(113) == true) // q
            #expect(letters.last?.contains(50) == false) // 2
            let optional = LSPatternShape(pattern: "(?:(n?)e)(?![\\s\\S])")
            #expect(optional.maxLength == 2)
            #expect(optional.last?.contains(101) == true)
            #expect(optional.last?.contains(110) == false)
            // Something the reader does not know is answered conservatively.
            let unknown = LSPatternShape(pattern: "(?:a\\pLx)")
            #expect(unknown.maxLength == nil)
            #expect(unknown.last == .all)
            let nullable = LSPatternShape(pattern: "(?:a*)(?![\\s\\S])")
            #expect(nullable.last == nil)
        }
    }
}
