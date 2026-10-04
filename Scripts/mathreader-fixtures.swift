import Foundation
import PDFKit

/// Writes what the Mac's MathReader makes of real pages, and what it read
/// them from, for Portable's port (`Portable/src/shared/mathReader/`):
///
///     Scripts/mathreader-fixtures.sh [bench-dir]
///
/// `tables` dumps TeXGlyphNames' tables, the letters of the Mathematical
/// Alphanumeric Symbols as the Mac reads them, and the two byte encodings a
/// font may declare; `cases <cases.json>` dumps, for each (pdf, page, rect),
/// the page's glyphs and rules as the scanner read them, the two things
/// MathReader asks PDFKit (the selection's line boxes, and the page's
/// characters near them), what the paper's other first pages say about where
/// it keeps its variables, and the pieces, the structured Markdown and the
/// one-line LaTeX. The PDFs stay outside the repository; what is written is
/// only what was read off them.
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
        // Every code point the Mac reads as a styled letter, with the letter
        // and the style — the Letterlike Symbols as much as the block itself,
        // asked of the function rather than copied out of its tables.
        var alphanumeric: [String: [String]] = [:]
        for value in UInt32(0)...UInt32(0x10FFFF) {
            if let (base, style) = TeXGlyphNames.mathAlphanumeric(value) {
                alphanumeric[String(value)] = [base, "\(style)"]
            }
        }
        return [
            "byName": TeXGlyphNames.byName,
            "msam": TeXGlyphNames.msam,
            "msbm": TeXGlyphNames.msbm,
            "txsyc": TeXGlyphNames.txsyc,
            "unicodeCommands": TeXGlyphNames.unicodeCommands,
            "mathAlphanumeric": alphanumeric,
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

    /// One character as PDFKit read it (`MathReader.PageCharacter`).
    struct Box {
        var index: Int
        var rect: CGRect
        var character: Character
    }

    /// Every character of a page PDFKit gives a box for, in page coordinates
    /// — what `MathReader.characters(of:)` asks for.
    static func characters(of page: PDFPage) -> [Box] {
        let text = Array(page.string ?? "")
        let offset = page.bounds(for: .cropBox).origin
        var result: [Box] = []
        for index in text.indices {
            let bounds = page.characterBounds(at: index)
            guard !bounds.isEmpty else { continue }
            result.append(Box(index: index, rect: bounds.offsetBy(dx: offset.x, dy: offset.y), character: text[index]))
        }
        return result
    }

    /// `MathReader.characterLookup(for:)`, which is private: while a page is
    /// read, a glyph that spells nothing borrows from that page's text — the
    /// glyphs of the paper's other pages as much as its own, when they are
    /// asked where the paper keeps its variables.
    static func characterLookup(_ characters: [Box]) -> (PDFContentScanner.Glyph) -> String? {
        let boxes = characters.filter { !$0.character.isWhitespace }
        return { glyph in
            var best: (character: Character, area: CGFloat)?
            for box in boxes {
                let overlap = box.rect.intersection(glyph.rect)
                guard !overlap.isNull else { continue }
                let area = overlap.width * overlap.height
                guard area > glyph.rect.width * glyph.rect.height * 0.3 else { continue }
                if best == nil || area > best!.area { best = (box.character, area) }
            }
            guard let match = best else { return nil }
            if MathTranscriber.isMathFont(glyph), match.character.isLetter || match.character.isNumber {
                return nil
            }
            return String(match.character)
        }
    }

    @MainActor
    static func cases(from file: String) -> [[String: Any]] {
        let data = try! Data(contentsOf: URL(fileURLWithPath: file))
        let list = try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        var out: [[String: Any]] = []
        for item in list {
            let path = item["pdf"] as! String
            let number = item["page"] as! Int
            let name = item["name"] as? String ?? "\((path as NSString).lastPathComponent) p\(number)"
            guard let document = PDFDocument(url: URL(fileURLWithPath: path)),
                  let page = document.page(at: number - 1), let reference = page.pageRef
            else {
                FileHandle.standardError.write("!! cannot read \(name)\n".data(using: .utf8)!)
                continue
            }
            let box = page.bounds(for: .cropBox)
            let asked = (item["rect"] as? [Double]).map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) } ?? box
            guard let selection = page.selection(for: asked) else { continue }
            // The whole page, for the lasso, is the page's size at the origin —
            // `asked` is the cropBox with its own origin when no rect was given.
            let lassoAsked = item["rect"] != nil ? asked : CGRect(origin: .zero, size: box.size)

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
            let every = characters(of: page)
            let characters: [[Any]] = every.filter { $0.rect.intersects(reach) }.map {
                [$0.index, Double($0.rect.minX), Double($0.rect.minY), Double($0.rect.width), Double($0.rect.height),
                 String($0.character)]
            }

            // What the paper's other first pages say about where it keeps its
            // variables (`MathReader.variablesInTextItalic(for:scanned:)`),
            // read as the Mac reads them: while this page is being read, with
            // this page's text to borrow from. The port is given the two
            // answers and works the rest out from the page itself.
            MathTranscriber.fallback = characterLookup(every)
            var ownLetters = false, evidence = false
            let current = document.index(for: page)
            for index in 0..<min(document.pageCount, 10) where index != current {
                guard let other = document.page(at: index), let ref = other.pageRef else { continue }
                let seen = MathReader.italicEvidence(PDFContentScanner.scan(page: ref).glyphs)
                ownLetters = ownLetters || seen.ownLetters
                evidence = evidence || seen.evidence
            }
            let here = MathReader.italicEvidence(scanned.glyphs)
            MathTranscriber.fallback = nil
            let italic = !here.ownLetters && !ownLetters && (here.evidence || evidence)

            // Whatever a formula on the page is read with is the page's
            // answer — held against the replay above.
            var observed = Set<Bool>()
            MathTranscriber.observer = { _, _, _ in observed.insert(MathTranscriber.variablesInTextItalic) }
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
            let skipped = MathReader.skippedFormulas
            MathTranscriber.observer = nil
            if !observed.isEmpty, observed != [italic] {
                FileHandle.standardError.write("!! \(name): read with italic variables \(observed), replayed \(italic)\n".data(using: .utf8)!)
            }
            var source: [String: Any] = ["page": number]
            if let bench = item["bench"] as? String {
                source["bench"] = bench
            } else {
                source["corpus"] = (path as NSString).lastPathComponent
            }
            out.append([
                "name": name,
                "source": source,
                "cropBox": rect(box),
                "fonts": fonts, "glyphs": glyphs, "rules": rules,
                "lineBoxes": lineBoxes.map(rect),
                // The formula lasso: the rectangle asked for, in PDFKit's page
                // coordinates, and what the reader snaps it to (`extentRead`).
                "lassoRect": rect(lassoAsked),
                "lassoExtent": MathReader.extentRead(on: page, rect: lassoAsked).map(rect) ?? NSNull(),
                "pageText": String(text),
                "characters": characters,
                "selectionString": selection.string ?? "",
                "italicElsewhere": [ownLetters, evidence],
                "pieces": pieces,
                "skipped": skipped,
                "structured": MathReader.structured(from: selection),
                "latex": MathReader.latex(from: selection),
            ])
        }
        return out
    }
}
