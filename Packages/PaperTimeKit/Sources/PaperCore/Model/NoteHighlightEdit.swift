import Foundation

/// ⌘⇧H and the colour dots on the selection bar: a highlight put round the
/// selected words, recoloured, or taken off — one replacement in the
/// Markdown, so one undo step. Portable's `toggleHighlightEdit`
/// (`shared/noteBlocks.ts`) is the same function, case for case.
///
/// A highlight is `==words==`, or `=={pink}words==` with one of the page's
/// five colour names; `==` with no name is the default colour. Pressing the
/// colour a highlight already has takes it off; pressing another changes it;
/// the marks may be inside the selection («==word==» selected whole) or just
/// outside it («word» selected inside its marks). With nothing selected, an
/// empty pair goes in and the caret between — or comes off, if the caret is
/// already between one.
public enum NoteHighlightEdit {
    public struct Edit: Equatable {
        /// What to replace, in UTF-16 offsets, and with what.
        public var range: NSRange
        public var insert: String
        /// Where the selection is afterwards.
        public var selection: NSRange
    }

    public static let names: [String] = ["yellow", "green", "blue", "pink", "purple"]

    /// The opening marks for a colour: `==`, or `=={name}`.
    public static func opening(_ color: String?) -> String {
        guard let color, !color.isEmpty else { return "==" }
        return "=={\(color)}"
    }

    /// A highlight's opening at the start of `text`, and the colour it names
    /// (nil for the default). Nil when `text` does not open one.
    static func openingAtStart(of text: NSString) -> (length: Int, color: String?)? {
        guard text.length >= 2, text.substring(to: 2) == "==" else { return nil }
        if text.length > 3, text.character(at: 2) == 0x7B,   // {
           let close = text.range(of: "}", range: NSRange(location: 3, length: text.length - 3)).location as Int?,
           close != NSNotFound {
            let name = text.substring(with: NSRange(location: 3, length: close - 3))
            if names.contains(name) { return (close + 1, name) }
        }
        return (2, nil)
    }

    /// `text` is `==…==` or `=={name}…==`, with something between.
    static func wrapped(_ text: NSString) -> (color: String?, inner: String)? {
        guard let open = openingAtStart(of: text), text.length >= open.length + 2,
              text.substring(from: text.length - 2) == "=="
        else { return nil }
        let inner = text.substring(with: NSRange(location: open.length, length: text.length - open.length - 2))
        guard !inner.isEmpty, !inner.hasSuffix("=") else { return nil }
        return (open.color, inner)
    }

    public static func toggle(in markdown: String, selection: NSRange, color: String?) -> Edit {
        let text = markdown as NSString
        let lo = max(0, min(selection.location, text.length))
        let hi = max(lo, min(NSMaxRange(selection), text.length))
        let open = opening(color)
        let openLength = (open as NSString).length
        if lo == hi {
            // Between an empty pair already: it comes off. Otherwise the pair
            // goes in, and the caret between.
            let candidates: [String?] = [color] + names.map { $0 as String? } + [nil]
            for name in candidates {
                let before = opening(name) as NSString
                guard lo >= before.length, lo + 2 <= text.length,
                      text.substring(with: NSRange(location: lo - before.length, length: before.length)) == before as String,
                      text.substring(with: NSRange(location: lo, length: 2)) == "=="
                else { continue }
                let range = NSRange(location: lo - before.length, length: before.length + 2)
                return Edit(range: range, insert: "", selection: NSRange(location: range.location, length: 0))
            }
            return Edit(range: NSRange(location: lo, length: 0), insert: open + "==",
                        selection: NSRange(location: lo + openLength, length: 0))
        }
        let selected = text.substring(with: NSRange(location: lo, length: hi - lo)) as NSString
        // The marks inside the selection: «==word==» selected whole.
        if let had = wrapped(selected) {
            return rewrap(had, at: NSRange(location: lo, length: hi - lo), to: color)
        }
        // The marks just outside it: «word» selected inside its marks.
        var start = lo
        while start > 0, text.character(at: start - 1) != 0x0A, lo - start < 12 { start -= 1 }
        for from in stride(from: lo - 2, through: start, by: -1) where from >= 0 {
            let candidate = text.substring(with: NSRange(location: from, length: min(hi + 2, text.length) - from)) as NSString
            guard let open = openingAtStart(of: candidate), from + open.length == lo,
                  hi + 2 <= text.length, text.substring(with: NSRange(location: hi, length: 2)) == "==",
                  let had = wrapped(candidate)
            else { continue }
            return rewrap(had, at: NSRange(location: from, length: hi + 2 - from), to: color)
        }
        return Edit(range: NSRange(location: lo, length: hi - lo), insert: open + (selected as String) + "==",
                    selection: NSRange(location: lo + openLength, length: hi - lo))
    }

    /// A highlight standing at `range`: taken off when `color` is the one it
    /// has, recoloured otherwise.
    private static func rewrap(_ had: (color: String?, inner: String), at range: NSRange, to color: String?) -> Edit {
        let inner = had.inner as NSString
        if had.color == color {
            return Edit(range: range, insert: had.inner, selection: NSRange(location: range.location, length: inner.length))
        }
        let open = opening(color)
        return Edit(range: range, insert: open + had.inner + "==",
                    selection: NSRange(location: range.location + (open as NSString).length, length: inner.length))
    }
}
