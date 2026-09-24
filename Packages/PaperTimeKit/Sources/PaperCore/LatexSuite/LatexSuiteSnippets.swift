import Foundation

// MARK: - The bundled data

/// `LatexSuiteSnippets.json`, as both builds read it. The file is generated
/// from Latex Suite's own sources by `Scripts/latex-suite-data.mjs`; see its
/// `header.format` for what each field means.
struct LSData: Decodable {
    struct Header: Decodable {
        var version: String
        var copyright: String
        var credit: String
        var licenceText: String
    }

    struct MacroArea: Decodable, Equatable {
        var name: String
        var arguments: [Int]?
    }

    struct Snippet: Decodable {
        var id: Int
        var kind: String
        var trigger: String?
        var pattern: String?
        var key: String?
        var replacement: String?
        var function: String?
        var options: String
        var priority: Int
        var description: String?
        var excludedMacros: [MacroArea]?
        var groupNames: [String?]?
    }

    struct Settings: Decodable {
        var snippetsEnabled: Bool
        var removeSnippetWhitespace: Bool
        var autoDeleteDollar: Bool
        var autofractionEnabled: Bool
        var autofractionSymbol: String
        var autofractionBreakingChars: String
        var autofractionExcludedEnvs: [[String]]
        var matrixShortcutsEnabled: Bool
        var matrixShortcutsEnvNames: [String]
        var matrixShortcutsMacroNames: [String]
        var taboutEnabled: Bool
        var taboutExitEquationOnlyOnEOL: Bool
        var taboutClosingSymbols: [String]
        var autoEnlargeBrackets: Bool
        var autoEnlargeBracketsSpace: Bool
        var autoEnlargeBracketsTriggers: [String]
        var wordDelimiters: String
        var forceMathLanguages: [String]

        enum CodingKeys: String, CodingKey {
            case snippetsEnabled, removeSnippetWhitespace, autofractionEnabled, autofractionSymbol,
                 autofractionBreakingChars, autofractionExcludedEnvs, matrixShortcutsEnabled, matrixShortcutsEnvNames,
                 matrixShortcutsMacroNames, taboutEnabled, taboutExitEquationOnlyOnEOL, taboutClosingSymbols,
                 autoEnlargeBrackets, autoEnlargeBracketsSpace, autoEnlargeBracketsTriggers, wordDelimiters,
                 forceMathLanguages
            case autoDeleteDollar = "autoDelete$"
        }
    }

    var header: Header
    var settings: Settings
    var variables: [String: String]
    var snippets: [Snippet]
    var macros: [String]
    var symbolCommands: [String]
    var environmentClasses: [String: [String]]
}

/// The compiled defaults, loaded once.
/// Immutable once built; NSRegularExpression is safe to match from any thread.
final class LSLibrary: @unchecked Sendable {
    let snippets: [LSSnippet]
    /// The same, split the way the keymap asks for them (latex_suite.ts): the
    /// automatic ones on every key, the rest on Tab, the visual ones on theirs.
    let automatic: [LSSnippet]
    let onTab: [LSSnippet]
    let visual: [UInt16: [LSSnippet]]
    let header: LSData.Header
    let settings: LSData.Settings
    /// Every prefix of every name in ALL_MACROS (backslash included): the two
    /// priority-3 defaults ask whether the typed macro *starts* some macro.
    let macroPrefixes: Set<LSUnits>
    let greek: Set<String>
    let symbols: Set<String>
    /// Environment name → its token class (latex_tokens.ts): names in the
    /// same class close each other, any other name only a generic one.
    let environmentClasses: [String: String]

    static let shared: LSLibrary = {
        guard let url = Bundle.module.url(forResource: "LatexSuiteSnippets", withExtension: "json") else {
            fatalError("LatexSuiteSnippets.json is missing from the PaperCore bundle")
        }
        do {
            return try LSLibrary(data: Data(contentsOf: url))
        } catch {
            fatalError("LatexSuiteSnippets.json does not load: \(error)")
        }
    }()

    init(data: Data) throws {
        let raw = try JSONDecoder().decode(LSData.self, from: data)
        header = raw.header
        settings = raw.settings
        snippets = try raw.snippets.map(LSSnippet.init)
        automatic = snippets.filter(\.automatic)
        onTab = snippets.filter { !$0.automatic && !$0.isVisual }
        var visual: [UInt16: [LSSnippet]] = [:]
        for snippet in snippets {
            if case let .visual(key) = snippet.trigger { visual[key, default: []].append(snippet) }
        }
        self.visual = visual
        var prefixes = Set<LSUnits>()
        for name in raw.macros {
            let units = LS.units(name)
            for n in 1...units.count { prefixes.insert(Array(units[0..<n])) }
        }
        macroPrefixes = prefixes
        let greekPattern = raw.variables["${GREEK}"] ?? ""
        greek = Set(greekPattern.dropFirst(3).dropLast().split(separator: "|").map(String.init))
        symbols = Set(raw.symbolCommands)
        var classes: [String: String] = [:]
        for (kind, names) in raw.environmentClasses { for name in names { classes[name] = kind } }
        environmentClasses = classes
    }
}

// MARK: - Snippets

/// `Mode` (options.ts): where a snippet may run, or where the caret is.
struct LSMode: Equatable {
    enum CodeBlock: Equatable {
        case no
        case any
        case language(String)
    }

    var text = false
    var inlineMath = false
    var blockMath = false
    var codeMath = false
    var codeBlock: CodeBlock = .no
    var code = false
    var textEnv = false
    var snippetlessEnv = false

    var inMath: Bool { inlineMath || blockMath || codeMath }
    var strictlyInMath: Bool { inMath && !textEnv }

    /// `Mode.fromSource`: the option letters; none at all means "everywhere"
    /// the old way, which is every flag set (and therefore *not* plain math —
    /// `textEnv` is set too).
    init(options: String) {
        for c in options {
            switch c {
            case "m": inlineMath = true; blockMath = true
            case "n": inlineMath = true
            case "M": blockMath = true
            case "t": text = true
            case "T": textEnv = true
            case "c": codeBlock = .any
            case "C": code = true
            default: break
            }
        }
        if textEnv && !(blockMath || inlineMath) {
            blockMath = true
            inlineMath = true
        }
        if !(text || inlineMath || blockMath || codeMath || codeBlock != .no || textEnv || code) {
            text = true
            inlineMath = true
            blockMath = true
            codeMath = true
            codeBlock = .any
            code = true
            textEnv = true
            snippetlessEnv = true
        }
    }

    init() {}

    /// `Options.snippetShouldRunInMode`: `self` is the snippet's, `context` the caret's.
    func runs(in context: LSMode, ignoringSnippetlessEnv: Bool = false) -> Bool {
        if context.snippetlessEnv && !ignoringSnippetlessEnv { return false }
        if (inlineMath && context.inlineMath) || (blockMath && context.blockMath) ||
            ((inlineMath || blockMath) && context.codeMath) {
            if context.textEnv == textEnv { return true }
        }
        if text && context.text { return true }
        if case let .language(name) = context.codeBlock {
            if codeBlock == .any || codeBlock == .language(name) { return true }
        }
        if code && context.code { return true }
        return false
    }
}

struct LSSnippet {
    enum Trigger {
        case string(LSUnits)
        case regex(NSRegularExpression, shape: LSPatternShape, groupNames: [String?])
        case visual(UInt16)
    }

    enum Replacement {
        case template(LSUnits)
        case function(LSFunction)
    }

    let id: Int
    let trigger: Trigger
    let replacement: Replacement
    let mode: LSMode
    let automatic: Bool
    let onWordBoundary: Bool
    let undoKey: Bool
    let priority: Int
    let excludedMacros: [LSData.MacroArea]

    var isVisual: Bool { if case .visual = trigger { return true } else { return false } }

    init(_ raw: LSData.Snippet) throws {
        id = raw.id
        mode = LSMode(options: raw.options)
        onWordBoundary = raw.options.contains("w")
        undoKey = !raw.options.contains("U")
        priority = raw.priority
        excludedMacros = raw.excludedMacros ?? []
        switch raw.kind {
        case "regex":
            let pattern = raw.pattern ?? ""
            trigger = .regex(try NSRegularExpression(pattern: pattern, options: []),
                             shape: LSPatternShape(pattern: pattern), groupNames: raw.groupNames ?? [])
            automatic = raw.options.contains("A")
        case "visual":
            trigger = .visual(LS.units(raw.key ?? " ")[0])
            automatic = false
        default:
            trigger = .string(LS.units(raw.trigger ?? ""))
            automatic = raw.options.contains("A")
        }
        if let name = raw.function {
            guard let function = LSFunction(rawValue: name) else {
                throw CocoaError(.coderInvalidValue, userInfo: [NSDebugDescriptionErrorKey: "unknown function \(name)"])
            }
            replacement = .function(function)
        } else {
            replacement = .template(LS.units(raw.replacement ?? ""))
        }
    }

    /// `isWithinExcludedScope` (snippets.ts): environments are walked past, a
    /// nested math scope ends the walk, a listed macro excludes.
    func isExcluded(by scopes: [LSLatex.Scope]) -> Bool {
        guard !excludedMacros.isEmpty else { return false }
        for scope in scopes {
            switch scope.kind {
            case .environment: continue
            case .math: return false
            case .command:
                if LSContext.matches(scope, excludedMacros) { return true }
            }
        }
        return false
    }
}

// MARK: - Replacements

struct LSTabstopSpec {
    var index: [Int]
    var from: Int
    var to: Int
}

/// What a replacement expands to: the text, and its tabstops relative to it.
struct LSInsert {
    var text: LSUnits
    var tabstops: [LSTabstopSpec]
}

enum LSReplacement {
    private static let visualMarker = LS.units("${VISUAL}")

    /// `SnippetStringNode.parseSnippet`: `[[n]]` captures (regex snippets
    /// only — `captures` is nil otherwise), then `$n` / `${n:text}` tabstops.
    static func expand(_ template: LSUnits, captures: [LSUnits]? = nil, visual: LSUnits? = nil) -> LSInsert {
        var text = template
        if let captures { text = expandCaptures(text, captures) }
        if let visual { text = replaceAll(text, visualMarker, visual) }
        return expandTabstops(text)
    }

    static func expandCaptures(_ text: LSUnits, _ captures: [LSUnits]) -> LSUnits {
        var out = LSUnits()
        var i = 0
        while i < text.count {
            if text[i] == 91, i + 1 < text.count, text[i + 1] == 91 {
                var j = i + 2
                while j < text.count, LS.isDigit(Int(text[j])) { j += 1 }
                if j > i + 2, j + 1 < text.count, text[j] == 93, text[j + 1] == 93,
                   let index = Int(text.slice(i + 2, j).string), index < captures.count {
                    out += captures[index]
                    i = j + 2
                    continue
                }
            }
            out.append(text[i])
            i += 1
        }
        return out
    }

    static func replaceAll(_ text: LSUnits, _ needle: LSUnits, _ with: LSUnits) -> LSUnits {
        var out = LSUnits()
        var i = 0
        while i < text.count {
            if text.hasPrefix(needle, at: i) {
                out += with
                i += needle.count
            } else {
                out.append(text[i])
                i += 1
            }
        }
        return out
    }

    /// `/\$(\d)|\$\{(\d+):([^}]*)\}/g`: `$N` takes one digit; there is no escape.
    static func expandTabstops(_ text: LSUnits) -> LSInsert {
        var out = LSUnits()
        var tabstops: [LSTabstopSpec] = []
        var i = 0
        while i < text.count {
            if text[i] == 36 {
                if i + 1 < text.count, LS.isDigit(Int(text[i + 1])) {
                    tabstops.append(LSTabstopSpec(index: [Int(text[i + 1]) - 48], from: out.count, to: out.count))
                    i += 2
                    continue
                }
                if i + 1 < text.count, text[i + 1] == 123 {
                    var j = i + 2
                    while j < text.count, LS.isDigit(Int(text[j])) { j += 1 }
                    if j > i + 2, j < text.count, text[j] == 58 {
                        var k = j + 1
                        while k < text.count, text[k] != 125 { k += 1 }
                        if k < text.count {
                            let placeholder = text.slice(j + 1, k)
                            let index = Int(text.slice(i + 2, j).string) ?? 0
                            tabstops.append(LSTabstopSpec(index: [index], from: out.count, to: out.count + placeholder.count))
                            out += placeholder
                            i = k + 1
                            continue
                        }
                    }
                }
            }
            out.append(text[i])
            i += 1
        }
        return LSInsert(text: out, tabstops: tabstops)
    }

    /// `trimWhitespace` (run_snippets.ts): inline math loses trailing space.
    static func trimmed(_ insert: LSInsert) -> LSInsert {
        let text = insert.text.trimmingEnd()
        return LSInsert(text: text, tabstops: insert.tabstops.map {
            LSTabstopSpec(index: $0.index, from: Swift.min($0.from, text.count), to: Swift.min($0.to, text.count))
        })
    }
}

// MARK: - The five function replacements

/// The defaults whose replacement is JavaScript, ported by hand. The
/// generator fingerprints each body and refuses to run when one changes, so
/// these cannot silently fall behind the plugin.
enum LSFunction: String {
    case autoSubscriptOrSpace, disableWhileTypingMacro, spaceAfterMacro, identityMatrix, displayMathInList

    /// The replacement for a match, or nil for "does not apply, keep trying"
    /// (the JavaScript `false`). `groups` are the capture groups (index 0 is
    /// the first group), `named` the named ones.
    func callAsFunction(_ match: LSUnits, _ groups: [LSUnits?], _ named: [String: LSUnits], library: LSLibrary) -> LSUnits? {
        switch self {
        case .autoSubscriptOrSpace:
            let isMacro = groups[0] == LS.units("\\")
            let digit = groups[2] ?? []
            let name = groups[1] ?? []
            if !isMacro { return name + LS.units("_{") + digit + LS.units("}") }
            if library.greek.contains(name.string) { return LS.units("\\") + name + LS.units("_{") + digit + LS.units("}") }
            return LS.units("\\") + name + LS.units(" ") + digit
        case .disableWhileTypingMacro:
            return library.macroPrefixes.contains(match) ? match : nil
        case .spaceAfterMacro:
            if library.macroPrefixes.contains(match) { return nil }
            let trigger = Array(match.dropFirst())
            return LS.units("\\") + Array(trigger.dropLast()) + LS.units(" ") + [trigger.last!]
        case .identityMatrix:
            let n = Int((groups[0] ?? []).string) ?? 0
            let rows = (0..<n).map { j in (0..<n).map { i in i == j ? "1" : "0" }.joined(separator: " & ") }
            return LS.units("\\begin{pmatrix}\n" + rows.joined(separator: " \\\\\n") + "\n\\end{pmatrix}")
        case .displayMathInList:
            let lookbehind = named["positive_lookbehind"] ?? []
            let marker = named["marker"] ?? []
            let whitespace = named["whitespace"] ?? []
            let text = named["text"] ?? []
            let firstLine = marker + whitespace + text
            let indent = LSUnits(repeating: 32, count: marker.count) + whitespace
            let nl: LSUnits = [10]
            return lookbehind + firstLine + nl + indent + LS.units("$$") + nl + indent + LS.units("$0") + nl + indent + LS.units("$$")
        }
    }
}
