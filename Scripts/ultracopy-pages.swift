import Foundation
import PDFKit

/// Reads every page of real papers the way ⌘L reads a selection — one
/// column at a time — and prints each displayed formula, so two builds of the
/// reader can be compared page by page.
///
///     swiftc -O App/Model/MathReader.swift App/Model/MathTranscriber.swift \
///       App/Model/PDFContentScanner.swift App/Model/TeXGlyphNames.swift \
///       Scripts/probe-localized.swift Scripts/ultracopy-pages.swift -o /tmp/pages-new
///     /tmp/pages-new ~/Documents/Bookends/Attachments/*.pdf > new.txt
///
/// Build the same file against an earlier commit's four model files
/// (`git show <tag>:App/Model/MathReader.swift` and so on) for the other side,
/// and diff. The bench holds the reader to single formulas; this is where a
/// change shows what it does to whole pages — two lines of an aligned formula
/// read as one, a sum's limits joining the next line, a table read as a
/// matrix. Nothing it prints says right or wrong: read the lines that changed.
///
/// A person selects inside one column, and PDFKit turns a drag into a run of
/// the text in reading order — a rectangle over a two-column page is both
/// columns, line by line. So each column is the run from the first to the last
/// character that stands in it; a page whose glyphs leave its middle empty
/// has two. The margins, where arXiv stamps its number, are left out.
@main
struct UltracopyPages {
    @MainActor
    static func main() {
        for path in CommandLine.arguments.dropFirst() {
            guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else { continue }
            let name = (path as NSString).lastPathComponent
            for index in 0..<min(document.pageCount, 30) {
                guard let page = document.page(at: index), let reference = page.pageRef else { continue }
                let box = page.bounds(for: .cropBox)
                let glyphs = PDFContentScanner.scan(page: reference).glyphs
                let middle = box.midX
                let crossing = glyphs.filter { $0.rect.minX < middle - 2 && $0.rect.maxX > middle + 2 }.count
                let inner = box.insetBy(dx: 45, dy: 30)
                let columns: [(String, CGRect)] = !glyphs.isEmpty && crossing * 60 < glyphs.count
                    ? [("L", CGRect(x: inner.minX, y: inner.minY, width: middle - inner.minX, height: inner.height)),
                       ("R", CGRect(x: middle, y: inner.minY, width: inner.maxX - middle, height: inner.height))]
                    : [("", inner)]
                for (label, rect) in columns {
                    var first = Int.max, last = -1
                    for character in 0..<page.numberOfCharacters {
                        let bounds = page.characterBounds(at: character)
                        guard bounds.width > 0, rect.contains(CGPoint(x: bounds.midX, y: bounds.midY)) else { continue }
                        first = min(first, character)
                        last = max(last, character)
                    }
                    guard last >= first,
                          let selection = page.selection(for: NSRange(location: first, length: last - first + 1))
                    else { continue }
                    for line in MathReader.structured(from: selection)
                    where line.hasPrefix("$$") || line.hasPrefix("\\begin{") {
                        print("\(name)\tp\(index + 1)\(label)\t\(line)")
                    }
                }
            }
        }
    }
}
