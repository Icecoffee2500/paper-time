import Foundation

/// The Mac's own answers, for the port to be held to.
///
/// Portable searches the same library the Mac does, and "the same search"
/// has to mean the same folding: a query that finds "Almudévar" on one
/// desktop and not on the other is two apps. JavaScript has no
/// `String.folding(options:locale:)`, so rather than guess at what Foundation
/// does, this asks it — the real `PaperTextIndex.fold`, the real
/// `TextNormalization.foldedTitle`, the real `StringSimilarity` — and writes
/// the answers down. `generate-fold-table.mjs` compiles and runs it:
///
///     swiftc -O ../App/Model/PaperTextIndex.swift \
///         ../Packages/PaperTimeKit/Sources/PaperCore/Util/TextNormalization.swift \
///         tools/mac-fold.swift -o /tmp/mac-fold
///
/// Modes:
///   table            Foundation's fold of every scalar on its own, and which
///                    marks it drops after which kind of letter.
///   fold             stdin: a JSON array of strings; stdout: the real fold of
///                    each, with its map back to the original.
///   title            stdin: strings; stdout: `TextNormalization.foldedTitle`.
///   jw               stdin: pairs of strings; stdout: `jaroWinkler`.
///   pages <out> <pdf…>  every page's `PDFPage.string` and its fold, for a
///                    check over a real corpus (never committed).
@main
struct MacFold {
    static let full: String.CompareOptions = [.diacriticInsensitive, .caseInsensitive, .widthInsensitive]
    static let title: String.CompareOptions = [.diacriticInsensitive, .caseInsensitive]

    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else {
            FileHandle.standardError.write("usage: mac-fold table|fold|title|jw|pages\n".data(using: .utf8)!)
            exit(2)
        }
        switch arguments[1] {
        case "table": try table()
        case "fold":
            let inputs = try readStrings()
            let out: [[String: Any]] = inputs.map { input in
                let folded = PaperTextIndex.fold(input as NSString)
                return ["text": folded.text as String, "map": folded.map]
            }
            try write(out)
        case "title":
            try write(try readStrings().map { TextNormalization.foldedTitle($0) })
        case "jw":
            let data = FileHandle.standardInput.readDataToEndOfFile()
            let pairs = try JSONSerialization.jsonObject(with: data) as? [[String]] ?? []
            try write(pairs.map { StringSimilarity.jaroWinkler($0[0], $0[1]) })
        case "pages": try pages(Array(arguments.dropFirst(2)))
        default:
            FileHandle.standardError.write("unknown mode \(arguments[1])\n".data(using: .utf8)!)
            exit(2)
        }
    }

    static func readStrings() throws -> [String] {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return try JSONSerialization.jsonObject(with: data) as? [String] ?? []
    }

    static func write(_ value: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    }

    static func scalars(_ s: String) -> [UInt32] { s.unicodeScalars.map(\.value) }

    /// Every scalar's fold on its own, under both sets of options, and the
    /// marks Foundation drops after a letter it knows (Latin, Greek,
    /// Cyrillic and whatever folds into them) and after one it leaves alone.
    static func table() throws {
        var singles: [String: [[UInt32]]] = ["full": [], "title": []]
        var marks: [UInt32] = []
        var few: [UInt32] = []
        var classes: [[UInt32]] = []
        for value in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            // The order Foundation puts the marks it keeps in.
            let combining = UInt32(scalar.properties.canonicalCombiningClass.rawValue)
            if combining != 0 { classes.append([value, combining]) }
            let alone = String(Character(scalar))
            // Compared scalar by scalar. Swift's `==` on strings is canonical
            // equivalence, so a Greek question mark folded to a semicolon, or
            // U+0341 folded to U+0301, reads as "unchanged" — and the table
            // came out without every singleton decomposition in Unicode.
            for (name, options) in [("full", full), ("title", title)] {
                let folded = alone.folding(options: options, locale: nil)
                if scalars(folded) != [value] { singles[name]!.append([value] + scalars(folded)) }
            }
            // After "a" — a letter Foundation decomposes — and after "中",
            // which it leaves as it is.
            if scalars("a\(alone)".folding(options: full, locale: nil)) == [0x61] { marks.append(value) }
            if scalars("中\(alone)".folding(options: full, locale: nil)) == [0x4E2D] { few.append(value) }
        }
        try write([
            "full": singles["full"]!,
            "title": singles["title"]!,
            "stripAll": ranges(marks),
            "stripFew": ranges(few),
            "combining": classes,
        ])
    }

    static func ranges(_ values: [UInt32]) -> [[UInt32]] {
        var out: [[UInt32]] = []
        for value in values {
            if let last = out.last, last[1] == value - 1 { out[out.count - 1][1] = value } else { out.append([value, value]) }
        }
        return out
    }

    static func pages(_ arguments: [String]) throws {
        guard let destination = arguments.first else { exit(2) }
        var papers: [[String: Any]] = []
        for path in arguments.dropFirst() {
            let url = URL(fileURLWithPath: path)
            guard let document = PDFDocumentLoader.open(url) else { continue }
            var pages: [String] = []
            var folded: [String] = []
            for index in 0..<document.count {
                let text = document[index]
                pages.append(text)
                folded.append(PaperTextIndex.fold(text as NSString).text as String)
            }
            papers.append(["file": url.lastPathComponent, "pages": pages, "folded": folded])
        }
        let data = try JSONSerialization.data(withJSONObject: papers)
        try data.write(to: URL(fileURLWithPath: destination))
    }
}

import PDFKit

/// Reads a PDF the way `PaperTextIndex` does: `PDFPage.string`, page by page.
enum PDFDocumentLoader {
    static func open(_ url: URL) -> [String]? {
        guard let document = PDFDocument(url: url) else { return nil }
        return (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
    }
}
