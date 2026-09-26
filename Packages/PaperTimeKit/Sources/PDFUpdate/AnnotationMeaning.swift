import CoreGraphics
import Foundation

/// What a reader shows of an annotation — the view compaction compares.
///
/// A compaction rebuilds the marks of a paper from the app's state and asks
/// whether the rebuilt file shows the same marks as the file it replaces.
/// "The same" cannot mean the same dictionaries: the marks may have been
/// written by the Portable build, and PDFKit spells every one of them
/// differently — a highlight of three lines is one annotation there and
/// three here, an ink stroke is resampled on its way through PencilKit, the
/// keys and their order, the appearance stream, `/DA`, `/Border`, `/T`, the
/// dates and the flags are each writer's own. None of that is the mark. So
/// an annotation of ours is reduced to what the reader draws and lists:
///
/// - a text markup: its kind, its identifier, where it lies (every
///   quadrilateral, to a tenth of a point — one mark whatever it was cut
///   into), its colour to 1/255, and the reader's comment;
/// - a note: its kind, identifier, box, colour and comment;
/// - a pen stroke: its colour, its width to a tenth of a point, and its
///   path — two paths agree when neither strays more than half a point from
///   the other, which is what resampling leaves of a line;
/// - a shape or card of the sketch layer: its identifier, which part it is,
///   what annotation stands for it, and the `/PTSketch` payload both
///   readers draw from, compared as JSON rather than as text.
///
/// An annotation that is not ours is compared as `Canonical.form` — every
/// key it has — because nothing of ours may have changed it.
enum AnnotationMeaning {
    /// How far one pen path may stray from the other and still be the same
    /// stroke. The Mac samples a stroke every 1.5 canvas points along the
    /// curve PencilKit fits through the points it was given; the Portable
    /// build writes the points it has. Measured on the fixture, the two
    /// stay within 0.1 pt of each other; half a point is the same line to
    /// any reader at any zoom.
    static let strokeTolerance: CGFloat = 0.5

    struct Markup: Equatable {
        var subtype: String
        var id: String
        /// Every quadrilateral as `minX minY maxX maxY`, tenths, sorted.
        var boxes: [String]
        var colour: [Int]
        /// `/PTComment`: what the reader wrote, when the writer said so.
        var comment: String?
        /// `/Contents`: the comment again, or the quotation.
        var contents: String

        /// The same mark: same kind and identifier, the same lines in the
        /// same colour, and the same words from the reader. When neither
        /// side has `/PTComment`, `/Contents` is the quotation each writer
        /// took from the page, which is not the mark — the words are under
        /// it; when either side has one, it is compared with what the other
        /// side shows, which is `/Contents` when it has no key of its own
        /// (a comment written before there was a key).
        func agrees(with other: Markup) -> Bool {
            guard subtype == other.subtype, id == other.id, boxes == other.boxes, colour == other.colour else { return false }
            guard comment != nil || other.comment != nil else { return true }
            return (comment ?? contents).trimmed == (other.comment ?? other.contents).trimmed
        }
    }

    struct Ink {
        var colour: [Int]
        var width: Double
        var paths: [[CGPoint]]

        func agrees(with other: Ink) -> Bool {
            guard colour == other.colour, abs(width - other.width) < 0.05, paths.count == other.paths.count else { return false }
            var unmatched = other.paths
            for path in paths {
                guard let k = unmatched.firstIndex(where: { Self.close(path, $0) }) else { return false }
                unmatched.remove(at: k)
            }
            return true
        }

        /// Whether no point of either polyline lies further than
        /// `strokeTolerance` from the other polyline.
        static func close(_ a: [CGPoint], _ b: [CGPoint]) -> Bool {
            guard !a.isEmpty, !b.isEmpty else { return a.isEmpty == b.isEmpty }
            return stray(a, from: b) <= strokeTolerance && stray(b, from: a) <= strokeTolerance
        }

        /// The furthest any point of `points` lies from the polyline `line`.
        static func stray(_ points: [CGPoint], from line: [CGPoint]) -> CGFloat {
            var worst: CGFloat = 0
            for p in points {
                var best = CGFloat.infinity
                if line.count == 1 { best = hypot(p.x - line[0].x, p.y - line[0].y) }
                var k = 0
                while k + 1 < line.count {
                    best = min(best, distance(from: p, toSegment: line[k], line[k + 1]))
                    if best == 0 { break }
                    k += 1
                }
                worst = max(worst, best)
                if worst > strokeTolerance { return worst }
            }
            return worst
        }

        static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = b.x - a.x, dy = b.y - a.y
            let l2 = dx * dx + dy * dy
            let t = l2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
            let q = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
            return hypot(p.x - q.x, p.y - q.y)
        }
    }

    enum Mark {
        case markup(Markup)
        case ink(Ink)
        /// A sketch part, reduced to one line of text.
        case sketch(String)
        /// Somebody else's annotation, every key of it.
        case foreign([UInt8])

        func agrees(with other: Mark) -> Bool {
            switch (self, other) {
            case let (.markup(a), .markup(b)): a.agrees(with: b)
            case let (.ink(a), .ink(b)): a.agrees(with: b)
            case let (.sketch(a), .sketch(b)): a == b
            case let (.foreign(a), .foreign(b)): a == b
            default: false
            }
        }

        /// A word for the difference report.
        var label: String {
            switch self {
            case let .markup(m): "\(m.subtype) \(m.id.prefix(8))"
            case let .ink(i): "Ink \(i.paths.first?.count ?? 0) pt"
            case let .sketch(s): "sketch " + s.prefix(24)
            case let .foreign(f): "foreign " + String(decoding: f.prefix(40), as: UTF8.self)
            }
        }
    }

    static let markupSubtypes: Set<String> = ["Highlight", "Underline", "StrikeOut", "Squiggly", "Text"]

    /// Every mark on every page, ours reduced to their meaning and the
    /// markups merged by identifier, everybody else's as it is. Popups are
    /// left out because PDFKit makes them as it sees fit.
    static func pages(of file: PDFFile) throws -> [[Mark]] {
        var pages: [[Mark]] = []
        for info in try file.pages() {
            var marks: [Mark] = []
            var markups: [String: Markup] = [:]
            var order: [String] = []
            for element in (try file.resolve(info.dict["Annots"])).array ?? [] {
                guard let d = (try? file.resolve(element))?.dict, d["Subtype"] != nil || d["Rect"] != nil else { continue }
                let subtype = d["Subtype"]?.name ?? ""
                if subtype == "Popup" { continue }
                let title = text(d["T"], in: file)
                if markupSubtypes.contains(subtype), let id = text(d["PTMarkupID"], in: file), !id.isEmpty {
                    let mark = markup(d, subtype: subtype, id: id, in: file)
                    let key = subtype + "|" + id
                    if var existing = markups[key] {
                        existing.boxes = (existing.boxes + mark.boxes).sorted()
                        markups[key] = existing
                    } else {
                        markups[key] = mark
                        order.append(key)
                    }
                } else if d["PTSketchID"] != nil || title == "Paper Time Sketch" {
                    marks.append(.sketch(sketch(d, subtype: subtype, in: file)))
                } else if subtype == "Ink", d["PTInk"] != nil || title == "Paper Time" {
                    marks.append(.ink(ink(d, in: file)))
                } else {
                    marks.append(.foreign(Canonical.form(element, in: file)))
                }
            }
            for key in order { marks.append(.markup(markups[key]!)) }
            pages.append(marks)
        }
        return pages
    }

    /// What `candidate` shows differently from `current`, page by page, or
    /// nil when every page shows the same marks.
    static func difference(current: [[Mark]], candidate: [[Mark]]) -> String? {
        guard current.count == candidate.count else { return "\(candidate.count) pages instead of \(current.count)" }
        for (index, (a, b)) in zip(current, candidate).enumerated() {
            var unmatched = b
            var onlyCurrent: [Mark] = []
            for mark in a {
                if let k = unmatched.firstIndex(where: { mark.agrees(with: $0) }) {
                    unmatched.remove(at: k)
                } else {
                    onlyCurrent.append(mark)
                }
            }
            guard onlyCurrent.isEmpty, unmatched.isEmpty else {
                let lost = onlyCurrent.map(\.label).joined(separator: ", ")
                let extra = unmatched.map(\.label).joined(separator: ", ")
                return "page \(index): \(onlyCurrent.count) mark(s) only in the current file [\(lost)], \(unmatched.count) only in the candidate [\(extra)]"
            }
        }
        return nil
    }

    // MARK: Reading one annotation

    static func markup(_ d: PDFDict, subtype: String, id: String, in file: PDFFile) -> Markup {
        var boxes: [String] = []
        let quads = numbers(d["QuadPoints"], in: file)
        if subtype != "Text", quads.count >= 8 {
            var k = 0
            while k + 7 < quads.count {
                let xs = [quads[k], quads[k + 2], quads[k + 4], quads[k + 6]]
                let ys = [quads[k + 1], quads[k + 3], quads[k + 5], quads[k + 7]]
                boxes.append(box(xs.min()!, ys.min()!, xs.max()!, ys.max()!))
                k += 8
            }
        } else {
            let r = numbers(d["Rect"], in: file)
            if r.count == 4 { boxes.append(box(min(r[0], r[2]), min(r[1], r[3]), max(r[0], r[2]), max(r[1], r[3]))) }
        }
        return Markup(
            subtype: subtype, id: id, boxes: boxes.sorted(), colour: colour(d["C"], in: file),
            comment: text(d["PTComment"], in: file), contents: text(d["Contents"], in: file) ?? ""
        )
    }

    static func ink(_ d: PDFDict, in file: PDFFile) -> Ink {
        var paths: [[CGPoint]] = []
        for path in (try? file.resolve(d["InkList"]))?.array ?? [] {
            let values = numbers(path, in: file)
            var points: [CGPoint] = []
            var k = 0
            while k + 1 < values.count {
                points.append(CGPoint(x: values[k], y: values[k + 1]))
                k += 2
            }
            paths.append(points)
        }
        return Ink(colour: colour(d["C"], in: file), width: (lineWidth(d, in: file) * 10).rounded() / 10, paths: paths)
    }

    static func sketch(_ d: PDFDict, subtype: String, in file: PDFFile) -> String {
        var line = "\(subtype) \(text(d["PTSketchID"], in: file) ?? "") \(text(d["PTSketchPart"], in: file) ?? "primary")"
        if let payload = text(d["PTSketch"], in: file), !payload.isEmpty {
            line += " " + canonicalJSON(payload)
        }
        if let contents = text(d["Contents"], in: file) { line += " «\(contents.trimmed)»" }
        return line
    }

    /// A base64 JSON payload as sorted-key JSON, so that two writers'
    /// spellings of the same element read the same; the text itself when
    /// it is not JSON.
    static func canonicalJSON(_ payload: String) -> String {
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return payload }
        return String(decoding: out, as: UTF8.self)
    }

    static func lineWidth(_ d: PDFDict, in file: PDFFile) -> Double {
        if let bs = (try? file.resolve(d["BS"]))?.dict, let w = (try? file.resolve(bs["W"]))?.number { return w }
        let border = numbers(d["Border"], in: file)
        if border.count >= 3 { return border[2] }
        return 1
    }

    static func box(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> String {
        [x0, y0, x1, y1].map { String(format: "%.1f", ($0 * 10).rounded() / 10) }.joined(separator: " ")
    }

    static func colour(_ o: PDFObj?, in file: PDFFile) -> [Int] {
        numbers(o, in: file).map { Int(($0 * 255).rounded()) }
    }

    static func numbers(_ o: PDFObj?, in file: PDFFile) -> [Double] {
        ((try? file.resolve(o))?.array ?? []).compactMap { (try? file.resolve($0))?.number }
    }

    static func text(_ o: PDFObj?, in file: PDFFile) -> String? {
        guard let o, let resolved = try? file.resolve(o) else { return nil }
        if let t = resolved.text { return t }
        return resolved.name
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
