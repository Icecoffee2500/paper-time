import CryptoKit
import Foundation

/// The bytes an incremental update appends: the objects, a cross-reference
/// section of the same kind as the file's newest one, and a trailer pointing
/// back at the section before it.
enum Appendix {
    /// An object's new version, either as a value to serialise or as text
    /// already in the file's own words (a page with one entry spliced).
    enum Body {
        case object(PDFObj)
        case raw([UInt8])
    }

    /// An object this update frees, and the generation its free entry says —
    /// one more than the generation it was in use under.
    struct Freed {
        var num: Int
        var gen: Int
    }

    static func bytes(
        for file: PDFFile,
        objects: [(PDFRef, Body)],
        freed: [Freed],
        firstFree: Int
    ) -> (bytes: [UInt8], kind: PDFFile.SectionKind) {
        var body: [UInt8] = []
        let base = file.count
        if let last = file.bytes.last, last != 0x0A, last != 0x0D { body.append(0x0A) }
        var offsets: [(PDFRef, Int)] = []
        for (ref, content) in objects.sorted(by: { $0.0 < $1.0 }) {
            offsets.append((ref, base + body.count))
            body += Array("\(ref.num) \(ref.gen) obj\n".utf8)
            switch content {
            case let .object(obj):
                Serializer.write(file.security.map { $0.encrypting(obj, as: ref) } ?? obj, into: &body)
            case let .raw(text):
                // In the file's own words — and, in an encrypted file, its own
                // ciphertext, which stays good because the object keeps its
                // number and generation.
                body += text
            }
            body += Array("\nendobj\n".utf8)
        }

        // The trailer says everything the previous one said but /Prev, and
        // the second half of /ID changes because the file did.
        var trailer = PDFDict()
        for (k, v) in file.trailer.pairs where !PDFFile.sectionKeys.contains(k) && k != "Size" {
            trailer.pairs.append((k, v))
        }
        if case let .array(id)? = file.trailer["ID"], id.count == 2 {
            var hasher = Insecure.MD5()
            hasher.update(data: Data(id[0].stringBytes ?? []))
            hasher.update(data: Data(body))
            trailer["ID"] = .array([id[0], .string(Array(hasher.finalize()), hex: true)])
        }

        // The free list: object 0 heads it, each freed number points at the
        // next, the last back at 0 (ISO 32000-1 §7.5.4).
        let freedSorted = freed.sorted { $0.num < $1.num }
        var nextFree: [Int: Int] = [:]
        for (i, f) in freedSorted.enumerated() {
            nextFree[f.num] = i + 1 < freedSorted.count ? freedSorted[i + 1].num : 0
        }
        let head = freedSorted.first?.num ?? 0

        enum Row { case used(off: Int, gen: Int), free(next: Int, gen: Int) }
        var rows: [(num: Int, row: Row)] = [(0, .free(next: head, gen: 65535))]
        rows += offsets.map { ($0.0.num, .used(off: $0.1, gen: $0.0.gen)) }
        rows += freedSorted.map { ($0.num, .free(next: nextFree[$0.num] ?? 0, gen: min($0.gen, 65535))) }

        let useStream = file.sections.first?.kind == .stream
        if !useStream {
            let byNumber = Dictionary(rows.map { ($0.num, $0.row) }, uniquingKeysWith: { first, _ in first })
            let xrefOffset = base + body.count
            var size = max(file.size, firstFree)
            for r in rows { size = max(size, r.num + 1) }
            body += Array("xref\n".utf8)
            for group in consecutive(rows.map(\.num)) {
                body += Array("\(group.lowerBound) \(group.count)\n".utf8)
                for n in group {
                    guard let row = byNumber[n] else { continue }
                    switch row {
                    case let .used(off, gen): body += Array(String(format: "%010d %05d n\r\n", off, gen).utf8)
                    case let .free(next, gen): body += Array(String(format: "%010d %05d f\r\n", next, gen).utf8)
                    }
                }
            }
            var t = PDFDict([("Size", .int(size))])
            t.pairs += trailer.pairs
            t.pairs.append(("Prev", .int(file.startxref)))
            body += Array("trailer\n".utf8)
            Serializer.writeDict(t, into: &body)
            body += Array("\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8)
            return (body, .table)
        }

        // A cross-reference stream, which lists itself.
        let xrefNum = max(file.size, firstFree, (rows.map(\.num).max() ?? 0) + 1)
        let xrefOffset = base + body.count
        rows.append((xrefNum, .used(off: xrefOffset, gen: 0)))
        let byNumber = Dictionary(rows.map { ($0.num, $0.row) }, uniquingKeysWith: { first, _ in first })
        let widest = rows.map { r -> Int in
            switch r.row {
            case let .used(off, _): off
            case let .free(next, _): next
            }
        }.max() ?? 0
        var w2 = 1
        while w2 < 8, (1 << (8 * w2)) <= widest { w2 += 1 }
        var data: [UInt8] = []
        var index: [PDFObj] = []
        for group in consecutive(rows.map(\.num)) {
            index += [.int(group.lowerBound), .int(group.count)]
            for n in group {
                guard let row = byNumber[n] else { continue }
                let (type, f2, f3): (UInt8, Int, Int)
                switch row {
                case let .used(off, gen): (type, f2, f3) = (1, off, gen)
                case let .free(next, gen): (type, f2, f3) = (0, next, gen)
                }
                data.append(type)
                for s in stride(from: 8 * (w2 - 1), through: 0, by: -8) { data.append(UInt8((f2 >> s) & 0xFF)) }
                data.append(UInt8((f3 >> 8) & 0xFF)); data.append(UInt8(f3 & 0xFF))
            }
        }
        var d = PDFDict([
            ("Type", .name("XRef")),
            ("Size", .int(xrefNum + 1)),
            ("W", .array([.int(1), .int(w2), .int(2)])),
            ("Index", .array(index)),
            ("Prev", .int(file.startxref)),
            ("Filter", .name("FlateDecode")),
        ])
        d.pairs += trailer.pairs
        body += Array("\(xrefNum) 0 obj\n".utf8)
        Serializer.write(.stream(d, Filters.deflate(data)), into: &body)
        body += Array("\nendobj\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8)
        return (body, .stream)
    }

    /// Runs of consecutive numbers, one subsection each.
    static func consecutive(_ numbers: [Int]) -> [ClosedRange<Int>] {
        var groups: [ClosedRange<Int>] = []
        for n in numbers.sorted() {
            if let last = groups.last, last.upperBound + 1 == n {
                groups[groups.count - 1] = last.lowerBound...n
            } else if groups.last?.contains(n) != true {
                groups.append(n...n)
            }
        }
        return groups
    }
}
