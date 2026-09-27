import Foundation
import PDFKit

/// Writes what the Mac's MathReader makes of real pages, and what it read
/// them from, for Portable's port (`Portable/src/shared/mathReader/`):
///
///     Scripts/mathreader-fixtures.sh
///
/// `tables` dumps TeXGlyphNames' tables and the two byte encodings a font
/// may declare; `cases <cases.json>` dumps, for each (pdf, page, rect), the
/// page's glyphs and rules as the scanner read them, the two things MathReader
/// asks PDFKit (the selection's line boxes, and the page's characters near
/// them), and the pieces, the structured Markdown and the one-line LaTeX.
/// The PDFs stay outside the repository; what is written is only what was
/// read off them.
@main
struct MathReaderFixtures {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments.first {
        case "tables": printJSON(tables())
        case "cases": printJSON(cases(from: arguments[1]))
        default:
            FileHandle.standardError.write("usage: mathreader-fixtures tables | cases <cases.json>\n".data(using: .utf8)!)
            exit(2)
        }
    }

    static func printJSON(_ value: Any) {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    }

    static func stringKeys(_ table: [Int: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: table.map { (String($0.key), $0.value) })
    }

    static func tables() -> [String: Any] {
        var mac: [String: String] = [:], win: [String: String] = [:]
        for code in 0...255 {
            if let value = PDFContentScanner.decode(code, with: "MacRomanEncoding") { mac[String(code)] = value }
            if let value = PDFContentScanner.decode(code, with: "WinAnsiEncoding") { win[String(code)] = value }
        }
        return [
            "byName": TeXGlyphNames.byName,
            "mathItalic": stringKeys(TeXGlyphNames.mathItalic),
            "symbols": stringKeys(TeXGlyphNames.symbols),
            "blackboard": stringKeys(TeXGlyphNames.blackboard),
            "extensions": stringKeys(TeXGlyphNames.extensions),
            "roman": stringKeys(TeXGlyphNames.roman),
            "macRoman": mac,
            "winAnsi": win,
        ]
    }

    static func rect(_ r: CGRect) -> [Double] { [r.origin.x, r.origin.y, r.size.width, r.size.height].map(Double.init) }

    @MainActor
    static func cases(from file: String) -> [[String: Any]] {
        let data = try! Data(contentsOf: URL(fileURLWithPath: file))
        let list = try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        var out: [[String: Any]] = []
        for item in list {
            let path = item["pdf"] as! String
            let number = item["page"] as! Int
            guard let document = PDFDocument(url: URL(fileURLWithPath: path)),
                  let page = document.page(at: number - 1), let reference = page.pageRef
            else { continue }
            let box = page.bounds(for: .cropBox)
            let asked = (item["rect"] as? [Double]).map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) } ?? box
            guard let selection = page.selection(for: asked) else { continue }

            // The page as the scanner read it.
            let scanned = PDFContentScanner.scan(page: reference)
            var fonts: [String] = []
            var fontIndex: [String: Int] = [:]
            let glyphs: [[Any]] = scanned.glyphs.map { glyph in
                let key = "\(glyph.isSymbolic ? 1 : 0)\(glyph.fontName)"
                if fontIndex[key] == nil { fontIndex[key] = fonts.count; fonts.append(key) }
                return [glyph.code, fontIndex[key]!, glyph.unicode ?? NSNull(), glyph.glyphName ?? NSNull(),
                        Double(glyph.size), Double(glyph.origin.x), Double(glyph.origin.y), Double(glyph.width)]
            }
            let rules = scanned.rules.map { rect($0.rect) }

            // The selection's lines, as MathReader asks for them.
            let offset = box.origin
            var boxes: [CGRect] = []
            for line in selection.selectionsByLine() where line.pages.contains(page) {
                let r = line.bounds(for: page)
                guard !r.isEmpty else { continue }
                boxes.append(r)
            }
            if boxes.isEmpty {
                let r = selection.bounds(for: page)
                if !r.isEmpty { boxes = [r] }
            }
            let lineBoxes = boxes.map { CGRect(x: $0.minX + offset.x, y: $0.minY + offset.y, width: $0.width, height: $0.height).insetBy(dx: -1, dy: 0) }

            // The page's characters where the selection is, as PDFKit read them.
            let text = Array(page.string ?? "")
            let reach = lineBoxes.reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -40, dy: -40)
            var characters: [[Any]] = []
            for index in text.indices {
                let bounds = page.characterBounds(at: index)
                guard !bounds.isEmpty else { continue }
                let placed = bounds.offsetBy(dx: offset.x, dy: offset.y)
                guard placed.intersects(reach) else { continue }
                characters.append([index, Double(placed.minX), Double(placed.minY), Double(placed.width), Double(placed.height), String(text[index])])
            }

            let pieces = MathReader.pieces(from: selection).map { piece -> [String: Any] in
                let kind: String
                switch piece.kind {
                case .prose: kind = "prose"
                case .heading(let level): kind = "heading\(level)"
                case .display: kind = "display"
                case .inline: kind = "inline"
                }
                return ["kind": kind, "plain": piece.plain, "marked": piece.marked,
                        "left": Double(piece.left), "right": Double(piece.right),
                        "baseline": Double(piece.baseline), "page": piece.page, "scale": Double(piece.scale)]
            }
            out.append([
                "name": item["name"] as? String ?? "\((path as NSString).lastPathComponent) p\(number)",
                "cropBox": rect(box),
                "fonts": fonts, "glyphs": glyphs, "rules": rules,
                "lineBoxes": lineBoxes.map(rect),
                "pageText": String(text),
                "characters": characters,
                "selectionString": selection.string ?? "",
                "pieces": pieces,
                "structured": MathReader.structured(from: selection),
                "latex": MathReader.latex(from: selection),
            ])
        }
        return out
    }
}
