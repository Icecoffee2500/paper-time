#if os(macOS)
import Foundation
import JavaScriptCore

/// The colours of a note's fenced code: the Portable build's highlighter
/// (`Portable/src/shared/codeHighlight.ts`, highlight.js inside it), run in
/// JavaScriptCore — so a block is coloured the same on a Mac and on a PC by
/// construction rather than by two highlighters agreeing.
///
/// The bundle is `App/Resources/CodeHighlight.js`
/// (`Scripts/code-highlight-bundle.sh`). As with `MathJaxEngine`, a context is
/// not safe on two threads, so everything goes through one queue; a block is
/// well under a millisecond and the note needs its colours before it is laid
/// out, so the answer is waited for.
final class CodeHighlighter: @unchecked Sendable {
    static let shared = CodeHighlighter()

    /// What a piece of code is, as far as its colour goes — the roles of
    /// `codeHighlight.ts`.
    enum Role: String, Sendable, CaseIterable {
        case keyword, string, number, comment, type, function, builtIn, meta, attribute
    }

    struct Run: Sendable, Equatable {
        /// UTF-16 offsets into the block's code.
        var range: NSRange
        var role: Role
    }

    private let queue = DispatchQueue(label: "com.imtaeheon.PaperTime.codehighlight", qos: .userInitiated)
    private var context: JSContext?
    private var highlight: JSValue?
    private var unavailable = false
    /// On the queue: the runs of code already coloured, by language and code.
    private var kept: [String: [Run]] = [:]

    /// Loads the highlighter off the main thread, so the first note with a
    /// block of code in it does not wait for it.
    func prewarm() {
        queue.async { _ = self.loaded() }
    }

    /// The coloured runs of a block's code; none when its language is not
    /// one that is coloured, or the bundle is not there.
    func runs(of code: String, language: String) -> [Run] {
        guard !language.isEmpty, !code.isEmpty else { return [] }
        return queue.sync {
            let key = language + "\u{0}" + code
            if let runs = kept[key] { return runs }
            guard loaded(), let highlight,
                  let answer = highlight.call(withArguments: [code, language])?.toString(), !answer.isEmpty,
                  let data = answer.data(using: .utf8),
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[Any]]
            else { return [] }
            let runs: [Run] = list.compactMap { item in
                guard item.count == 3,
                      let from = (item[0] as? NSNumber)?.intValue, let to = (item[1] as? NSNumber)?.intValue,
                      let role = (item[2] as? String).flatMap(Role.init(rawValue:)), to > from
                else { return nil }
                return Run(range: NSRange(location: from, length: to - from), role: role)
            }
            if kept.count > 300 { kept.removeAll() }
            kept[key] = runs
            return runs
        }
    }

    /// On the queue.
    private func loaded() -> Bool {
        if highlight != nil { return true }
        if unavailable { return false }
        guard let url = Bundle.main.url(forResource: "CodeHighlight", withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8),
              let made = JSContext()
        else {
            unavailable = true
            return false
        }
        var failure: String?
        made.exceptionHandler = { _, exception in failure = exception?.toString() }
        Trace.time("code: load the highlighter") {
            made.evaluateScript(script, withSourceURL: url)
        }
        let code = made.objectForKeyedSubscript("PaperTimeCode")
        guard failure == nil, let code, !code.isUndefined,
              let highlight = code.objectForKeyedSubscript("highlight"), !highlight.isUndefined
        else {
            FileHandle.standardError.write(Data("code: the highlighter did not load: \(failure ?? "no PaperTimeCode")\n".utf8))
            unavailable = true
            return false
        }
        made.exceptionHandler = { _, _ in }
        context = made
        self.highlight = highlight
        return true
    }
}
#endif
