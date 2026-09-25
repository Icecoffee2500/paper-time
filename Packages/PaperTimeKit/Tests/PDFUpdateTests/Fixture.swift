import CryptoKit
import Foundation
@testable import PDFUpdate

/// Small PDFs built byte by byte, in every shape the writer has to read: the
/// kinds of cross-reference section, object streams, the ways a page can hold
/// its annotations, the ciphers of the standard security handler — and the
/// damaged files it has to refuse. Built at test time rather than committed,
/// so what each one is stays readable here.
///
/// Every fixture has two pages of Helvetica text; page 0 carries a highlight
/// and its popup made by "another app", page 1 a link.
struct Fixture: CustomStringConvertible {
    enum XRef: String { case table, tableFromOne, stream, streamPredictor, hybrid }
    enum Annots: String { case none, direct, indirect, shared, withNull, directDict, widget, duplicateKey }
    enum Cipher: String { case rc4_40, rc4_128, aes128, aes256 }

    struct Encryption {
        var cipher: Cipher
        var userPassword = ""
        var ownerPassword = "owner"
        /// Everything allowed.
        var permissions: Int32 = -4
    }

    var name: String
    var xref: XRef = .table
    var pagesInObjectStream = false
    var linearizedShape = false
    var annots: Annots = .direct
    var rotateInherited = false
    var docMDP: Int?
    var encryption: Encryption?
    var tail = ""
    var finalNewline = true
    var carriageReturns = false
    var startxrefShift = 0

    var description: String { name }

    static let id0: [UInt8] = Array("PaperTimeFixture".utf8)

    // Object numbers.
    static let catalog = 1, pages = 2, page0 = 3, contents0 = 4, page1 = 5, contents1 = 6, font = 7, info = 8
    static let highlight = 9, popup = 10, link = 11, annotsArray = 12, widget = 13, signature = 14, encrypt = 15

    // MARK: The objects

    func objects() -> [Int: PDFObj] {
        var o: [Int: PDFObj] = [:]
        func ref(_ n: Int) -> PDFObj { .ref(PDFRef(n, 0)) }
        func string(_ s: String) -> PDFObj { .string(Array(s.utf8), hex: false) }
        func rect(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> PDFObj { .array([.real("\(a)"), .real("\(b)"), .real("\(c)"), .real("\(d)")]) }

        var catalog = PDFDict([("Type", .name("Catalog")), ("Pages", ref(Self.pages))])
        if annots == .widget { catalog["AcroForm"] = .dict(PDFDict([("Fields", .array([ref(Self.widget)]))])) }
        if docMDP != nil { catalog["Perms"] = .dict(PDFDict([("DocMDP", ref(Self.signature))])) }
        o[Self.catalog] = .dict(catalog)

        var pages = PDFDict([("Type", .name("Pages")), ("Kids", .array([ref(Self.page0), ref(Self.page1)])), ("Count", .int(2))])
        if rotateInherited { pages["Rotate"] = .int(90) }
        o[Self.pages] = .dict(pages)

        func page(_ contents: Int) -> PDFDict {
            PDFDict([
                ("Type", .name("Page")), ("Parent", ref(Self.pages)),
                ("MediaBox", .array([.int(0), .int(0), .int(612), .int(792)])),
                ("Resources", .dict(PDFDict([("Font", .dict(PDFDict([("F1", ref(Self.font))])))]))),
                ("Contents", ref(contents)),
            ])
        }
        var p0 = page(Self.contents0)
        var p1 = page(Self.contents1)
        let foreign: [PDFObj] = [ref(Self.highlight), ref(Self.popup)]
        switch annots {
        case .none: break
        case .direct: p0["Annots"] = .array(foreign)
        case .indirect:
            p0["Annots"] = ref(Self.annotsArray)
            o[Self.annotsArray] = .array(foreign)
        case .shared:
            p0["Annots"] = ref(Self.annotsArray)
            p1["Annots"] = ref(Self.annotsArray)
            o[Self.annotsArray] = .array(foreign)
        case .withNull: p0["Annots"] = .array([ref(Self.highlight), .null, ref(Self.popup)])
        case .directDict:
            let square = PDFDict([("Type", .name("Annot")), ("Subtype", .name("Square")), ("Rect", rect(300, 300, 360, 340)),
                                  ("C", .array([.int(0), .int(0), .int(1)])), ("F", .int(4))])
            p0["Annots"] = .array([.dict(square)] + foreign)
        case .widget: p0["Annots"] = .array(foreign + [ref(Self.widget)])
        case .duplicateKey:
            p0.pairs.append(("Annots", .array(foreign)))
            p0.pairs.append(("Annots", .array([ref(Self.popup), ref(Self.highlight)])))
        }
        if annots != .none, annots != .shared { p1["Annots"] = .array([ref(Self.link)]) }
        o[Self.page0] = .dict(p0)
        o[Self.page1] = .dict(p1)

        func content(_ n: Int) -> PDFObj {
            let text = "BT /F1 18 Tf 72 700 Td (office difference efficient, page \(n)) Tj 0 -30 Td (a second line of words to read) Tj ET"
            return .stream(PDFDict(), Array(text.utf8))
        }
        o[Self.contents0] = content(0)
        o[Self.contents1] = content(1)
        o[Self.font] = .dict(PDFDict([("Type", .name("Font")), ("Subtype", .name("Type1")), ("BaseFont", .name("Helvetica")), ("Encoding", .name("WinAnsiEncoding"))]))
        o[Self.info] = .dict(PDFDict([("Producer", string("Paper Time test fixture"))]))

        o[Self.highlight] = .dict(PDFDict([
            ("Type", .name("Annot")), ("Subtype", .name("Highlight")), ("Rect", rect(72, 696, 200, 716)),
            ("QuadPoints", .array([72, 716, 200, 716, 72, 696, 200, 696].map { .int($0) })),
            ("C", .array([.int(1), .int(1), .int(0)])), ("Contents", string("office")), ("T", string("Someone Else")),
            ("P", ref(Self.page0)), ("Popup", ref(Self.popup)), ("F", .int(4)),
        ]))
        o[Self.popup] = .dict(PDFDict([
            ("Type", .name("Annot")), ("Subtype", .name("Popup")), ("Rect", rect(220, 600, 400, 700)),
            ("Parent", ref(Self.highlight)), ("F", .int(28)),
        ]))
        o[Self.link] = .dict(PDFDict([
            ("Type", .name("Annot")), ("Subtype", .name("Link")), ("Rect", rect(72, 690, 300, 720)),
            ("Border", .array([.int(0), .int(0), .int(0)])),
            ("A", .dict(PDFDict([("S", .name("URI")), ("URI", string("https://example.org/paper"))]))),
        ]))
        if annots == .widget {
            o[Self.widget] = .dict(PDFDict([
                ("Type", .name("Annot")), ("Subtype", .name("Widget")), ("FT", .name("Tx")), ("T", string("field")),
                ("V", string("a value")), ("Rect", rect(72, 500, 272, 520)), ("P", ref(Self.page0)), ("F", .int(4)),
            ]))
        }
        if let p = docMDP {
            let params = PDFDict([("Type", .name("TransformParams")), ("P", .int(p)), ("V", .name("1.2"))])
            let reference = PDFDict([("Type", .name("SigRef")), ("TransformMethod", .name("DocMDP")), ("TransformParams", .dict(params))])
            o[Self.signature] = .dict(PDFDict([
                ("Type", .name("Sig")), ("Filter", .name("Adobe.PPKLite")), ("SubFilter", .name("adbe.pkcs7.detached")),
                ("Reference", .array([.dict(reference)])), ("Contents", .string([0], hex: true)),
                ("ByteRange", .array([.int(0), .int(0), .int(0), .int(0)])),
            ]))
        }
        return o
    }

    // MARK: Encryption

    static let padding = StandardSecurity.padding

    static func pad(_ password: String) -> [UInt8] { Array((Array(password.utf8) + padding).prefix(32)) }

    /// The /Encrypt dictionary for a cipher and passwords, and the handler
    /// that encrypts with it — found by the writer's own key derivation,
    /// which is how the dictionary is checked to be right.
    static func security(_ e: Encryption) throws -> (PDFDict, StandardSecurity) {
        let p = e.permissions
        var d = PDFDict([("Filter", .name("Standard"))])
        switch e.cipher {
        case .rc4_40, .rc4_128, .aes128:
            let r = e.cipher == .rc4_40 ? 2 : (e.cipher == .rc4_128 ? 3 : 4)
            let n = r == 2 ? 5 : 16
            // Algorithm 3: O from the owner password.
            var h = Array(Insecure.MD5.hash(data: pad(e.ownerPassword)))
            if r >= 3 { for _ in 0..<50 { h = Array(Insecure.MD5.hash(data: h)) } }
            let ownerKey = Array(h.prefix(n))
            var o = StandardSecurity.rc4(ownerKey, pad(e.userPassword))
            if r >= 3 { for i in 1...19 { o = StandardSecurity.rc4(ownerKey.map { $0 ^ UInt8(i) }, o) } }
            // Algorithm 2: the file key.
            var input = pad(e.userPassword) + o + withUnsafeBytes(of: p.littleEndian, Array.init) + id0
            var key = Array(Insecure.MD5.hash(data: input))
            if r >= 3 { for _ in 0..<50 { key = Array(Insecure.MD5.hash(data: key.prefix(n))) } }
            key = Array(key.prefix(n))
            input.removeAll()
            // Algorithms 4 and 5: U.
            var u: [UInt8]
            if r == 2 {
                u = StandardSecurity.rc4(key, padding)
            } else {
                u = StandardSecurity.rc4(key, Array(Insecure.MD5.hash(data: padding + id0)))
                for i in 1...19 { u = StandardSecurity.rc4(key.map { $0 ^ UInt8(i) }, u) }
                u += [UInt8](repeating: 0, count: 16)
            }
            d.pairs += [("V", .int(r == 2 ? 1 : (r == 3 ? 2 : 4))), ("R", .int(r)), ("Length", .int(n * 8)),
                        ("O", .string(o, hex: true)), ("U", .string(u, hex: true)), ("P", .int(Int(p)))]
            if r == 4 {
                let cf = PDFDict([("StdCF", .dict(PDFDict([("CFM", .name("AESV2")), ("Length", .int(16)), ("AuthEvent", .name("DocOpen"))])))])
                d.pairs += [("CF", .dict(cf)), ("StmF", .name("StdCF")), ("StrF", .name("StdCF"))]
            }
        case .aes256:
            let fileKey = (0..<32).map { UInt8(($0 * 37 + 11) & 0xFF) }
            let pw = Array(e.userPassword.utf8), opw = Array(e.ownerPassword.utf8)
            let vs: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8], ks: [UInt8] = [9, 10, 11, 12, 13, 14, 15, 16]
            let u = StandardSecurity.hash2B(pw, salt: vs, extra: []) + vs + ks
            let ue = StandardSecurity.aes(decrypt: false, key: StandardSecurity.hash2B(pw, salt: ks, extra: []), iv: [UInt8](repeating: 0, count: 16), fileKey, padding: false)!
            let ovs: [UInt8] = [17, 18, 19, 20, 21, 22, 23, 24], oks: [UInt8] = [25, 26, 27, 28, 29, 30, 31, 32]
            let o = StandardSecurity.hash2B(opw, salt: ovs, extra: u) + ovs + oks
            let oe = StandardSecurity.aes(decrypt: false, key: StandardSecurity.hash2B(opw, salt: oks, extra: u), iv: [UInt8](repeating: 0, count: 16), fileKey, padding: false)!
            // Algorithm 10: /Perms, one block, which CBC with a zero IV is.
            let block = withUnsafeBytes(of: p.littleEndian, Array.init) + [0xFF, 0xFF, 0xFF, 0xFF] + Array("Tadb".utf8) + [0, 0, 0, 0]
            let perms = StandardSecurity.aes(decrypt: false, key: fileKey, iv: [UInt8](repeating: 0, count: 16), block, padding: false)!
            let cf = PDFDict([("StdCF", .dict(PDFDict([("CFM", .name("AESV3")), ("Length", .int(32)), ("AuthEvent", .name("DocOpen"))])))])
            d.pairs += [("V", .int(5)), ("R", .int(6)), ("Length", .int(256)), ("CF", .dict(cf)), ("StmF", .name("StdCF")), ("StrF", .name("StdCF")),
                        ("O", .string(o, hex: true)), ("U", .string(u, hex: true)), ("OE", .string(oe, hex: true)), ("UE", .string(ue, hex: true)),
                        ("P", .int(Int(p))), ("Perms", .string(perms, hex: true))]
        }
        let security = try StandardSecurity(encrypt: d, id0: id0, password: Array(e.userPassword.utf8))
        return (d, security)
    }

    // MARK: The file

    func data() throws -> Data {
        var objects = objects()
        var security: StandardSecurity?
        if let encryption {
            let (dict, s) = try Self.security(encryption)
            objects[Self.encrypt] = .dict(dict)
            security = s
        }
        let compressible: Set<Int> = pagesInObjectStream
            ? Set([Self.pages, Self.page0, Self.page1, Self.font, Self.highlight, Self.popup, Self.link, Self.annotsArray, Self.widget]).intersection(objects.keys)
            : []
        let highest = objects.keys.max() ?? 0
        let objStmNum = highest + 1
        let xrefStmNum = highest + (compressible.isEmpty ? 1 : 2)
        let size = (xref == .stream || xref == .streamPredictor || xref == .hybrid) ? xrefStmNum + 1 : (compressible.isEmpty ? highest + 1 : objStmNum + 1)

        var out = Array("%PDF-1.7\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
        // A linearised file's last startxref points at a small section near
        // the start, whose /Prev points at the main one at the end. The
        // shape of that chain is what matters here, so a table of the first
        // three objects stands in for the first-page section.
        var linearPlaceholder: Range<Int>?
        if linearizedShape {
            let start = out.count
            out += Array("xref\n1 3\n".utf8) + [UInt8](repeating: 0x30, count: 60)
            out += Array("trailer\n<< /Size \(size) /Root 1 0 R /Prev 0000000000 >>\nstartxref\n0\n%%EOF\n".utf8)
            linearPlaceholder = start..<out.count
        }

        var offsets: [Int: Int] = [:]
        func emit(_ num: Int, _ obj: PDFObj) {
            offsets[num] = out.count
            out += Array("\(num) 0 obj\n".utf8)
            let written = (num == Self.encrypt) ? obj : (security.map { $0.encrypting(obj, as: PDFRef(num, 0)) } ?? obj)
            Serializer.write(written, into: &out)
            out += Array("\nendobj\n".utf8)
        }
        for num in objects.keys.sorted() where !compressible.contains(num) { emit(num, objects[num]!) }

        var compressedIndex: [Int: Int] = [:]
        if !compressible.isEmpty {
            var header: [UInt8] = [], body: [UInt8] = []
            for (i, num) in compressible.sorted().enumerated() {
                header += Array("\(num) \(body.count) ".utf8)
                Serializer.write(objects[num]!, into: &body)
                body += Array("\n".utf8)
                compressedIndex[num] = i
            }
            let data = header + body
            let dict = PDFDict([("Type", .name("ObjStm")), ("N", .int(compressible.count)), ("First", .int(header.count)), ("Filter", .name("FlateDecode"))])
            emit(objStmNum, .stream(dict, Filters.deflate(data)))
        }

        var trailer = PDFDict([("Size", .int(size)), ("Root", .ref(PDFRef(Self.catalog, 0))), ("Info", .ref(PDFRef(Self.info, 0)))])
        trailer["ID"] = .array([.string(Self.id0, hex: true), .string(Self.id0, hex: true)])
        if security != nil { trailer["Encrypt"] = .ref(PDFRef(Self.encrypt, 0)) }

        func streamRows(_ include: (Int) -> Bool, own: Int?, at ownOffset: Int) -> [UInt8] {
            var rows: [UInt8] = []
            // /W [1 3 2]: one byte of type, three of offset or stream number,
            // two of generation or index.
            for num in 0..<size {
                guard include(num) else { continue }
                if num == 0 { rows += [0, 0, 0, 0, 0xFF, 0xFF]; continue }
                if let i = compressedIndex[num] {
                    rows += [2, UInt8(objStmNum >> 16 & 0xFF), UInt8(objStmNum >> 8 & 0xFF), UInt8(objStmNum & 0xFF),
                             UInt8(i >> 8 & 0xFF), UInt8(i & 0xFF)]
                    continue
                }
                let off = num == own ? ownOffset : (offsets[num] ?? 0)
                let type: UInt8 = offsets[num] != nil || num == own ? 1 : 0
                rows += [type, UInt8(off >> 16 & 0xFF), UInt8(off >> 8 & 0xFF), UInt8(off & 0xFF), 0, 0]
            }
            return rows
        }

        var xrefOffset = out.count
        switch xref {
        case .table, .tableFromOne:
            precondition(compressible.isEmpty, "a table cannot say where compressed objects are")
            out += Array((xref == .tableFromOne ? "xref\n1 \(size)\n" : "xref\n0 \(size)\n").utf8)
            out += Array("0000000000 65535 f \n".utf8)
            for num in 1..<size {
                if let off = offsets[num] { out += Array(String(format: "%010d 00000 n \n", off).utf8) } else { out += Array("0000000000 00000 f \n".utf8) }
            }
            out += Array("trailer\n".utf8)
            Serializer.writeDict(trailer, into: &out)
        case .stream, .streamPredictor:
            let rows = streamRows({ _ in true }, own: xrefStmNum, at: xrefOffset).chunked(6)
            var data: [UInt8] = []
            var previous = [UInt8](repeating: 0, count: 6)
            for row in rows {
                if xref == .streamPredictor {
                    data.append(2) // PNG "Up"
                    for k in 0..<6 { data.append(row[k] &- previous[k]) }
                    previous = row
                } else {
                    data += row
                }
            }
            var dict = trailer
            dict.pairs = [("Type", .name("XRef")), ("W", .array([.int(1), .int(3), .int(2)])), ("Index", .array([.int(0), .int(size)])), ("Filter", .name("FlateDecode"))] + dict.pairs
            if xref == .streamPredictor { dict["DecodeParms"] = .dict(PDFDict([("Predictor", .int(12)), ("Columns", .int(6))])) }
            offsets[xrefStmNum] = xrefOffset
            out += Array("\(xrefStmNum) 0 obj\n".utf8)
            Serializer.write(.stream(dict, Filters.deflate(data)), into: &out)
            out += Array("\nendobj\n".utf8)
        case .hybrid:
            // The stream says where the compressed objects are; the table says
            // everything else and calls those free.
            let stmOffset = out.count
            let rows = streamRows({ compressedIndex[$0] != nil }, own: nil, at: 0)
            var dict = PDFDict([("Type", .name("XRef")), ("Size", .int(size)), ("W", .array([.int(1), .int(3), .int(2)])),
                                ("Index", .array(compressible.sorted().flatMap { [PDFObj.int($0), .int(1)] })), ("Filter", .name("FlateDecode"))])
            dict["Root"] = .ref(PDFRef(Self.catalog, 0))
            offsets[xrefStmNum] = stmOffset
            out += Array("\(xrefStmNum) 0 obj\n".utf8)
            Serializer.write(.stream(dict, Filters.deflate(rows)), into: &out)
            out += Array("\nendobj\n".utf8)
            xrefOffset = out.count
            out += Array("xref\n0 \(size)\n0000000000 65535 f \n".utf8)
            for num in 1..<size {
                if let off = offsets[num] { out += Array(String(format: "%010d 00000 n \n", off).utf8) } else { out += Array("0000000000 00000 f \n".utf8) }
            }
            var t = trailer
            t["XRefStm"] = .int(stmOffset)
            out += Array("trailer\n".utf8)
            Serializer.writeDict(t, into: &out)
        }
        var lastStartxref = xrefOffset
        if let placeholder = linearPlaceholder {
            var section = Array("xref\n1 3\n".utf8)
            for num in 1...3 { section += Array(String(format: "%010d 00000 n \n", offsets[num]!).utf8) }
            section += Array("trailer\n<< /Size \(size) /Root 1 0 R /Prev \(String(format: "%010d", xrefOffset)) >>\nstartxref\n0\n%%EOF\n".utf8)
            precondition(section.count == placeholder.count)
            out.replaceSubrange(placeholder, with: section)
            lastStartxref = placeholder.lowerBound
        }
        out += Array("\nstartxref\n\(lastStartxref + startxrefShift)\n%%EOF".utf8)
        if finalNewline { out += Array("\n".utf8) }
        out += Array(tail.utf8)
        if carriageReturns {
            // Line ends of CR alone, as old Mac writers made them — outside the
            // streams, whose bytes are counted.
            out = Array(String(decoding: out, as: UTF8.self).replacingOccurrences(of: "\nendobj\n", with: "\rendobj\r")
                .replacingOccurrences(of: "%%EOF\n", with: "%%EOF\r").utf8)
        }
        return Data(out)
    }
}

extension Array {
    func chunked(_ n: Int) -> [[Element]] {
        stride(from: 0, to: count, by: n).map { Array(self[$0..<Swift.min($0 + n, count)]) }
    }
}
