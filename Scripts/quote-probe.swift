import Foundation
import PDFKit

/// Reads a piece of a real paper the way ⌘L reads it, and prints the Markdown
/// that would land in the note.
///
///     swiftc -O App/Model/MathReader.swift App/Model/MathTranscriber.swift \
///       App/Model/PDFContentScanner.swift App/Model/TeXGlyphNames.swift \
///       Scripts/quote-probe.swift -o /tmp/quote
///     /tmp/quote paper.pdf 3            # the whole of page 3
///     /tmp/quote paper.pdf 3 100 300 400 300
///
/// A selection lives three panes deep in the app and cannot be made from a
/// script, so this is how "does the quotation keep the page's shape?" gets
/// answered without a window.
@main
struct QuoteProbe {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 2,
              let document = PDFDocument(url: URL(fileURLWithPath: arguments[0])),
              let number = Int(arguments[1]),
              let page = document.page(at: number - 1)
        else {
            print("usage: quote-probe <pdf> <page> [x y w h]")
            exit(2)
        }
        let box = page.bounds(for: .cropBox)
        let rect: CGRect
        if arguments.count >= 6, let values = Optional(arguments[2...5].compactMap(Double.init)),
           values.count == 4 {
            rect = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        } else {
            rect = box
        }
        guard let selection = page.selection(for: rect) else {
            print("nothing selected")
            exit(3)
        }
        print("— \(selection.string?.count ?? 0) characters selected on page \(number)\n")
        if arguments.contains("--pieces") {
            // What the page was read as, before it became Markdown: one line
            // per thing, with what it was set in.
            for piece in MathReader.pieces(from: selection) {
                print(String(format: "%-10@ %.2f× %6.1f…%-6.1f %@",
                             "\(piece.kind)" as NSString, piece.scale,
                             piece.left, piece.right,
                             String(piece.marked.prefix(70)) as NSString))
            }
            return
        }
        for line in MathReader.structured(from: selection) {
            print(line.isEmpty ? "·" : line)
        }
    }
}
