import AppKit
import Foundation
import InkEngine
import PDFKit
import PDFReader
import PDFUpdate
import PencilKit

// papertime-pdfcheck — what the incremental writer does to real papers,
// checked from outside the app. Works on a copy; never on the file it is
// given.
//
//   papertime-pdfcheck protocol <paper.pdf> <outdir> [--control]
//       Four saves through DocumentSession.write, as the app makes them:
//       one of every kind of mark; one highlight more; a removal; the same
//       again, which must write nothing. After each: the earlier bytes are a
//       prefix, the text of every page is what it was, the marks read back.
//       --control also asks PDFKit to write the untouched paper out itself,
//       and counts the pages whose text that changes.
//
//   papertime-pdfcheck growth <paper.pdf> <outdir> <scenario> [saves]
//       Saves in a row, the whole journal every time: typing | handwriting |
//       heavyink | highlights | recolor | comment | shapes.
//
//   papertime-pdfcheck text <a.pdf> <b.pdf>
//       Whether PDFKit reads the same text on every page of both.

// PencilKit saves its replica state under the current application's
// preferences, and a tool without a bundle identifier has none: the first
// drawing with a stroke in it traps in CoreFoundation. The tool's own,
// throwaway identifier — never the app's.
if CFBundleGetIdentifier(CFBundleGetMainBundle()) == nil, let info = CFBundleGetInfoDictionary(CFBundleGetMainBundle()) {
    CFDictionarySetValue(
        unsafeDowncast(info, to: CFMutableDictionary.self),
        Unmanaged.passUnretained(kCFBundleIdentifierKey).toOpaque(),
        Unmanaged.passUnretained("local.papertime.pdfcheck" as CFString).toOpaque()
    )
}

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("usage: papertime-pdfcheck protocol|growth|text …")
    exit(2)
}

// MARK: - Text

struct TextLayer {
    var pages: [String]
    var counts: [String: Int]

    init(_ document: PDFDocument) {
        pages = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
        let all = pages.joined(separator: "\n")
        var c: [String: Int] = [:]
        c["ligatures"] = all.unicodeScalars.filter { (0xFB00...0xFB06).contains($0.value) }.count
        for needle in ["ff", "fi", "different", "!"] { c[needle] = all.components(separatedBy: needle).count - 1 }
        c["chars"] = all.count
        counts = c
    }

    func differingPages(from other: TextLayer) -> [Int] {
        guard pages.count == other.pages.count else { return [-1] }
        return pages.indices.filter { pages[$0] != other.pages[$0] }
    }

    var summary: String {
        "lig=\(counts["ligatures"] ?? 0) ff=\(counts["ff"] ?? 0) different=\(counts["different"] ?? 0) !=\(counts["!"] ?? 0)"
    }
}

if arguments[1] == "text" {
    guard arguments.count >= 4, let a = PDFDocument(url: URL(fileURLWithPath: arguments[2])),
          let b = PDFDocument(url: URL(fileURLWithPath: arguments[3]))
    else { print("text: cannot open"); exit(1) }
    let ta = TextLayer(a), tb = TextLayer(b)
    let differing = tb.differingPages(from: ta)
    print("pages=\(a.pageCount)/\(b.pageCount) differing=\(differing.count) first=\(differing.prefix(5)) a[\(ta.summary)] b[\(tb.summary)]")
    exit(differing.isEmpty ? 0 : 1)
}

let source = URL(fileURLWithPath: arguments[2])
let outDir = URL(fileURLWithPath: arguments[3])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let original = try Data(contentsOf: source)
guard let doc0 = PDFDocument(data: original) else { print("PDFKit cannot open \(source.lastPathComponent)"); exit(1) }
let text0 = TextLayer(doc0)
let textPages = (0..<doc0.pageCount).filter { (doc0.page(at: $0)?.string?.count ?? 0) >= 400 }
let p = textPages.first ?? 0
let q = textPages.count > 1 ? textPages[1] : (textPages.isEmpty ? min(1, doc0.pageCount - 1) : p)

// The same identifiers every run, so two runs of one file write the same marks.
let seed = UInt8(truncatingIfNeeded: source.lastPathComponent.utf8.reduce(0) { ($0 &* 31) &+ Int($1) } % 200)
@MainActor func fixedUUID(_ n: Int) -> UUID {
    UUID(uuid: (0x50, 0x54, 0x43, 0x4B, UInt8(n >> 8 & 0xFF), seed, 0x40, UInt8(n & 0xFF), 0x80, 0, 0, 0, 0, 0, 0, 1))
}
let fixedDate = Date(timeIntervalSinceReferenceDate: 811_000_000.25)

@MainActor func markup(_ kind: MarkupDescriptor.Kind, on index: Int, from fraction: Double, length: Int, color: MarkupColor, id: UUID, comment: String = "") -> MarkupDescriptor {
    let page = doc0.page(at: index)!
    let ns = (page.string ?? "") as NSString
    let start = min(ns.length - 1, max(0, Int(Double(ns.length) * fraction)))
    let len = min(length, ns.length - start)
    var rects: [CGRect] = []
    var quoted = ""
    if ns.length > 0, len > 0, let sel = page.selection(for: NSRange(location: start, length: len)),
       let d = TextMarkupWriter.descriptor(for: sel, kind: kind, color: color, in: doc0).first(where: { $0.pageIndex == index }) {
        rects = d.rects
        quoted = d.quotedText
    }
    if rects.filter({ $0.width > 0.5 && $0.height > 0.5 }).isEmpty {
        let box = page.bounds(for: .cropBox)
        rects = [CGRect(x: box.minX + 72, y: box.minY + box.height * fraction, width: 200, height: 12)]
    }
    return MarkupDescriptor(id: id, kind: kind, pageIndex: index, rects: rects, color: color, quotedText: quoted, comment: comment, createdAt: fixedDate)
}

let crop = doc0.page(at: p)!.bounds(for: .cropBox)
let geometry = PageGeometry(page: doc0.page(at: p)!)
let size = geometry.displaySize
@MainActor func pkStroke(_ points: [CGPoint], ink: PKInk, width: CGFloat) -> PKStroke {
    let controls = points.enumerated().map { i, pt in
        PKStrokePoint(location: pt, timeOffset: Double(i) * 0.01, size: CGSize(width: width, height: width),
                      opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
    }
    return PKStroke(ink: ink, path: PKStrokePath(controlPoints: controls, creationDate: fixedDate))
}
@MainActor func pt(_ fx: Double, _ fy: Double) -> CGPoint { CGPoint(x: crop.minX + crop.width * fx, y: crop.minY + crop.height * fy) }
@MainActor func sketchJSON(_ e: [SketchElement]) -> Data {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .prettyPrinted]
    return try! enc.encode(e)
}

@MainActor func save(_ url: URL, additions: [MarkupDescriptor], removals: [UUID], ink: [Int: Data], sketches: [Int: Data]) -> (DocumentSession.WriteOutcome?, String?, Double) {
    let t0 = Date()
    let r = DocumentSession.write(to: url, additions: additions, removals: removals, ink: ink, sketches: sketches)
    let ms = Date().timeIntervalSince(t0) * 1000
    switch r {
    case let .success(o): return (o, nil, ms)
    case let .failure(e): return (nil, "\(e)", ms)
    }
}

let work = outDir.appendingPathComponent("work.pdf")
try? FileManager.default.removeItem(at: work)
try original.write(to: work)

// MARK: - Growth

if arguments[1] == "growth" {
    guard arguments.count >= 5 else { print("growth <pdf> <outdir> <scenario> [saves]"); exit(2) }
    let scenario = arguments[4]
    let saves = arguments.count > 5 ? Int(arguments[5]) ?? 40 : 40
    @MainActor func stroke(_ k: Int) -> PKStroke {
        let row = Double(k % 40) / 40, col = Double((k / 40) % 2)
        let y0 = Double(size.height) * (0.1 + 0.8 * row), x0 = Double(size.width) * (0.1 + 0.4 * col)
        return pkStroke((0..<40).map { i in CGPoint(x: x0 + Double(i) * 5, y: y0 + sin(Double(i + k) / 3) * 6) },
                        ink: PKInk(.pen, color: NSColor(srgbRed: 0.1, green: 0.2, blue: 0.7, alpha: 1)), width: 2)
    }
    @MainActor func highlight(_ k: Int, color: MarkupColor = .yellow, comment: String = "") -> MarkupDescriptor {
        let index = textPages.isEmpty ? 0 : textPages[k % textPages.count]
        let len = (doc0.page(at: index)?.string as NSString?)?.length ?? 0
        let fraction = len > 0 ? min(0.9, Double((k / max(1, textPages.count)) * 70 + 100) / Double(len)) : 0.1
        return markup(.highlight, on: index, from: fraction, length: 50, color: color, id: fixedUUID(1000 + k), comment: comment)
    }
    let words = "Incremental updates keep the original bytes and append only what changed so the fonts are never written again 한국어 메모도 함께 적어 두고 the text layer stays as the author made it".split(separator: " ").map(String.init)
    var journal: [MarkupDescriptor] = []
    var ink: [Int: Data] = [:]
    var sketch: [Int: Data] = [:]
    var sizes: [Int] = [], times: [Double] = []
    for k in 1...saves {
        switch scenario {
        case "typing":
            let card = SketchElement(id: fixedUUID(1), kind: .text, points: [pt(0.1, 0.5), pt(0.5, 0.6)],
                                     style: SketchStyle(stroke: SketchColor(0.1, 0.1, 0.1), fill: SketchColor(0.9, 0.95, 1), border: true),
                                     text: words.prefix(min(k, words.count)).joined(separator: " ") + (k > words.count ? " \(k)" : ""),
                                     createdAt: fixedDate, textSizing: .autoHeight)
            sketch[p] = sketchJSON([card])
        case "heavyink": ink[p] = PKDrawing(strokes: (0..<(399 + k)).map(stroke)).dataRepresentation()
        case "handwriting": ink[p] = PKDrawing(strokes: (0..<k).map(stroke)).dataRepresentation()
        case "highlights": journal.append(highlight(k))
        case "recolor":
            if journal.isEmpty { journal = (0..<20).map { highlight($0) } }
            journal[0].color = k % 2 == 0 ? .yellow : .green
        case "comment":
            if journal.isEmpty { journal = [highlight(0, comment: "c")] }
            journal[0].comment = "note " + String(repeating: "x", count: k)
        case "shapes":
            let shapes = (0..<10).map { i -> SketchElement in
                let dx = i == (k % 10) ? Double(k) * 0.002 : 0
                return SketchElement(id: fixedUUID(100 + i), kind: .rectangle,
                                     points: [pt(0.1 + dx, 0.05 + 0.08 * Double(i)), pt(0.3 + dx, 0.1 + 0.08 * Double(i))],
                                     style: SketchStyle(stroke: SketchColor(0.8, 0.1, 0.1), width: 2), text: i == 0 ? "label" : "", createdAt: fixedDate)
            }
            sketch[p] = sketchJSON(shapes)
        default: print("unknown scenario \(scenario)"); exit(2)
        }
        let (outcome, error, ms) = save(work, additions: journal, removals: [], ink: ink, sketches: sketch)
        guard let outcome else { print("FAIL save \(k): \(error ?? "?")"); exit(1) }
        switch outcome {
        case let .appended(bytes): sizes.append(bytes)
        case .unchanged: sizes.append(0)
        case let .keptInApp(r): print("FAIL save \(k): kept in app: \(r)"); exit(1)
        }
        times.append(ms)
    }
    let final = try Data(contentsOf: work)
    let reread = PDFDocument(data: final)!
    let textSame = TextLayer(reread).differingPages(from: text0).isEmpty
    @MainActor func quantile(_ a: [Double], _ f: Double) -> Double { a.sorted()[min(a.count - 1, Int(Double(a.count - 1) * f))] }
    print("""
    \(source.lastPathComponent.prefix(28)) \(scenario) saves=\(saves) pages=\(doc0.pageCount) original=\(original.count)
      per save B: first=\(sizes.first!) median=\(Int(quantile(sizes.map(Double.init), 0.5))) p90=\(Int(quantile(sizes.map(Double.init), 0.9))) last=\(sizes.last!)
      per save ms: first=\(Int(times.first!)) median=\(Int(quantile(times, 0.5))) max=\(Int(times.max()!)) last=\(Int(times.last!))
      total appended=\(final.count - original.count) prefix=\(final.prefix(original.count) == original) textSame=\(textSame)
    """)
    exit(0)
}

// MARK: - Protocol

guard arguments[1] == "protocol" else { print("unknown command \(arguments[1])"); exit(2) }

let highlight = markup(.highlight, on: p, from: 0.25, length: 90, color: .yellow, id: fixedUUID(1))
let underline = markup(.underline, on: p, from: 0.45, length: 60, color: .green, id: fixedUUID(2))
let strike = markup(.strikethrough, on: p, from: 0.60, length: 40, color: .pink, id: fixedUUID(3))
let noteD = MarkupDescriptor(id: fixedUUID(4), kind: .note, pageIndex: p, rects: [highlight.rects[0]], color: .blue, comment: "A note, 메모", createdAt: fixedDate)
let commented = markup(.highlight, on: p, from: 0.70, length: 30, color: .blue, id: fixedUUID(6), comment: "worth a look — 다시 보기")
let highlight2 = markup(.highlight, on: q, from: 0.5, length: 50, color: .purple, id: fixedUUID(5))

let penStroke = pkStroke((0..<30).map { i in CGPoint(x: size.width * 0.2 + Double(i) * 6, y: size.height * 0.3 + sin(Double(i) / 3) * 12) },
                         ink: PKInk(.pen, color: NSColor(srgbRed: 0.1, green: 0.2, blue: 0.7, alpha: 1)), width: 2)
let markerStroke = pkStroke((0..<20).map { i in CGPoint(x: size.width * 0.2 + Double(i) * 9, y: size.height * 0.36) },
                            ink: PKInk(.marker, color: NSColor(srgbRed: 1, green: 0.8, blue: 0.1, alpha: 1)), width: 10)
let drawing2 = PKDrawing(strokes: [penStroke, markerStroke])
let drawing1 = PKDrawing(strokes: [penStroke])

let groupID = fixedUUID(20)
let sketchAll: [SketchElement] = [
    SketchElement(id: fixedUUID(10), kind: .rectangle, points: [pt(0.10, 0.10), pt(0.30, 0.18)],
                  style: SketchStyle(stroke: SketchColor(0.8, 0.1, 0.1), fill: SketchColor(1, 0.9, 0.2, alpha: 0.4), width: 2), text: "Box label", createdAt: fixedDate),
    SketchElement(id: fixedUUID(11), kind: .ellipse, points: [pt(0.35, 0.10), pt(0.50, 0.18)],
                  style: SketchStyle(stroke: SketchColor(0.1, 0.5, 0.1), width: 1.5, dash: .dashed), createdAt: fixedDate, parent: groupID),
    SketchElement(id: fixedUUID(12), kind: .line, points: [pt(0.55, 0.10), pt(0.70, 0.18)],
                  style: SketchStyle(stroke: SketchColor(0, 0, 0), width: 1, startHead: .none, endHead: .none), createdAt: fixedDate, parent: groupID),
    SketchElement(id: fixedUUID(13), kind: .arrow, points: [pt(0.10, 0.22), pt(0.30, 0.26)],
                  style: SketchStyle(stroke: SketchColor(0.2, 0.2, 0.8), width: 2, startHead: .dot, endHead: .arrow), createdAt: fixedDate),
    SketchElement(id: fixedUUID(14), kind: .arrow, points: [pt(0.35, 0.22), pt(0.55, 0.26)], bend: CGPoint(x: 0, y: 25),
                  style: SketchStyle(stroke: SketchColor(0.6, 0.2, 0.6), width: 2, endHead: .triangle), createdAt: fixedDate),
    SketchElement(id: fixedUUID(15), kind: .arrow, points: [pt(0.60, 0.22), pt(0.80, 0.26)],
                  style: SketchStyle(stroke: SketchColor(0.3, 0.3, 0.3), width: 2, endHead: .bar), createdAt: fixedDate),
    SketchElement(id: fixedUUID(16), kind: .text, points: [pt(0.10, 0.30), pt(0.40, 0.36)],
                  style: SketchStyle(stroke: SketchColor(0.1, 0.1, 0.1), fill: SketchColor(0.9, 0.95, 1), border: true), text: "Card $x^2$ 카드 — office ffi", createdAt: fixedDate, textSizing: .autoHeight),
    SketchElement(id: fixedUUID(17), kind: .frame, points: [pt(0.60, 0.30), pt(0.90, 0.40)],
                  style: SketchStyle(stroke: SketchColor(0.4, 0.4, 0.4), fill: SketchColor(0.95, 0.95, 0.95), width: 1), createdAt: fixedDate, name: "Frame 1"),
    SketchElement(id: groupID, kind: .group, points: [pt(0.35, 0.10), pt(0.70, 0.18)], createdAt: fixedDate),
]
let sketchAfterRemoval = sketchAll.filter { $0.id != fixedUUID(10) }

struct Step {
    var name: String
    var additions: [MarkupDescriptor]
    var removals: [UUID]
    var drawing: PKDrawing
    var sketch: [SketchElement]
}
let steps = [
    Step(name: "add-all", additions: [highlight, underline, strike, noteD, commented], removals: [], drawing: drawing2, sketch: sketchAll),
    Step(name: "add-one", additions: [highlight, underline, strike, noteD, commented, highlight2], removals: [], drawing: drawing2, sketch: sketchAll),
    Step(name: "remove", additions: [underline, strike, noteD, highlight2], removals: [highlight.id, commented.id], drawing: drawing1, sketch: sketchAfterRemoval),
    Step(name: "no-op", additions: [underline, strike, noteD, highlight2], removals: [highlight.id, commented.id], drawing: drawing1, sketch: sketchAfterRemoval),
]

var failures: [String] = []
@MainActor func fail(_ s: String) { failures.append(s) }

@MainActor func foreignCounts(_ d: PDFDocument) -> [Int] {
    (0..<d.pageCount).map { i in
        d.page(at: i)!.annotations.filter {
            $0.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/PTMarkupID")) == nil && !InkConverter.isOwned($0) && !SketchWriter.isOwned($0) && $0.type != "Popup"
        }.count
    }
}
let baselineForeign = foreignCounts(doc0)
let originalPopups = doc0.page(at: p)!.annotations.filter { $0.type == "Popup" }.count

@MainActor func check(_ doc: PDFDocument, _ step: Step) {
    let label = step.name
    for m in step.additions {
        guard let page = doc.page(at: m.pageIndex) else { fail("\(label): no page"); continue }
        if !TextMarkupWriter.isAlreadyWritten(m, on: page) { fail("\(label): \(m.kind) \(m.id.uuidString.prefix(8)) not in the file as written") }
    }
    for gone in step.removals {
        for i in 0..<doc.pageCount where doc.page(at: i)!.annotations.contains(where: { TextMarkupWriter.identifier(of: $0) == gone }) {
            fail("\(label): removed mark still on page \(i)")
        }
    }
    let page = doc.page(at: p)!
    if !InkConverter.isAlreadyWritten(step.drawing, on: page) { fail("\(label): ink not as drawn") }
    if InkConverter.drawing(fromOwnedInkOn: page).strokes.count != step.drawing.strokes.count { fail("\(label): ink reads back wrong") }
    if !SketchWriter.isAlreadyWritten(step.sketch, on: page) { fail("\(label): sketch not as drawn") }
    if Set(SketchWriter.elements(fromOwnedOn: page)) != Set(step.sketch) { fail("\(label): sketch reads back wrong") }
    if foreignCounts(doc) != baselineForeign { fail("\(label): another app's annotations changed") }
    // One popup for our note, beside whatever popups the page had: PDFKit
    // makes a new one for every note it writes, and they used to pile up.
    let popups = page.annotations.filter { $0.type == "Popup" }.count - originalPopups
    if popups > 1 { fail("\(label): \(popups) popups of ours on the marked page") }
}

var cells: [String] = []
var previous = original
var previousModified = try FileManager.default.attributesOfItem(atPath: work.path)[.modificationDate] as? Date
for (n, step) in steps.enumerated() {
    let (outcome, error, ms) = save(work, additions: step.additions, removals: step.removals,
                                    ink: [p: step.drawing.dataRepresentation()], sketches: [p: sketchJSON(step.sketch)])
    guard let outcome else { fail("\(step.name): \(error ?? "?")"); break }
    let saved = try Data(contentsOf: work)
    let modified = try FileManager.default.attributesOfItem(atPath: work.path)[.modificationDate] as? Date
    switch outcome {
    case let .keptInApp(r): fail("\(step.name): kept in app: \(r)"); cells.append("kept")
    case .unchanged: cells.append("0/\(Int(ms))")
    case let .appended(bytes): cells.append("\(bytes)/\(Int(ms))")
    }
    if case .keptInApp = outcome { break }
    if !(saved.count >= previous.count && saved.prefix(previous.count) == previous) { fail("\(step.name): earlier bytes changed") }
    if n == 3 {
        if saved != previous { fail("no-op changed the file") }
        if modified != previousModified { fail("no-op touched the file") }
        if outcome != .unchanged { fail("no-op said \(outcome)") }
    }
    if let f = try? PDFFile(data: saved) {
        if f.repaired { fail("\(step.name): our reader had to repair the result") }
    } else { fail("\(step.name): our reader cannot read the result") }
    guard let doc = PDFDocument(data: saved) else { fail("\(step.name): PDFKit cannot open the result"); break }
    if doc.pageCount != doc0.pageCount { fail("\(step.name): \(doc.pageCount) pages") }
    let differing = TextLayer(doc).differingPages(from: text0)
    if !differing.isEmpty { fail("\(step.name): text differs on \(differing.count) pages") }
    check(doc, step)
    try saved.write(to: outDir.appendingPathComponent("save\(n + 1).pdf"))
    previous = saved
    previousModified = modified
}

var control = ""
if arguments.contains("--control") {
    let t0 = Date()
    if let rewritten = PDFDocument(data: original)?.dataRepresentation(), let d = PDFDocument(data: rewritten) {
        let t = TextLayer(d)
        control = " | PDFKit's own rewrite: \(t.differingPages(from: text0).count) pages changed, \(t.summary), \(rewritten.count - original.count) B, \(Int(Date().timeIntervalSince(t0) * 1000)) ms"
    }
}
let kind = (try? PDFFile(data: original))?.sections.first?.kind.rawValue ?? "?"
print("\(failures.isEmpty ? "OK  " : "FAIL") \(source.lastPathComponent.prefix(30)) | \(doc0.pageCount) pp | \(kind) | \(text0.summary) | B/ms \(cells.joined(separator: " "))\(control)")
for f in failures { print("   - \(f)") }
exit(failures.isEmpty ? 0 : 1)
