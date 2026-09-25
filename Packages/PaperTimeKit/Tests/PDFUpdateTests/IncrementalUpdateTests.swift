import AppKit
import Foundation
import PDFKit
import Testing
@testable import PDFUpdate

/// The writer against every shape of file it has to read, with the checks
/// the app relies on after every save: the paper's bytes are still there,
/// byte for byte; PDFKit reads the marks back; the text of every page is what
/// it was; another app's annotations are the same objects in the same order;
/// the chain points back where it should; and a save that changes nothing
/// writes nothing.
@Suite("Incremental update")
struct IncrementalUpdateTests {
    static let fixedDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static let secret = "secret words — 비밀"

    // MARK: What the app's writers do, in miniature

    static func key(_ name: String) -> PDFAnnotationKey { PDFAnnotationKey(rawValue: "/\(name)") }

    static func ourHighlight() -> PDFAnnotation {
        let a = PDFAnnotation(bounds: CGRect(x: 72, y: 666, width: 200, height: 18), forType: .highlight, withProperties: nil)
        a.color = NSColor(srgbRed: 1, green: 0.84, blue: 0.25, alpha: 1)
        a.contents = "a second line"
        a.setValue("M-1", forAnnotationKey: key("PTMarkupID"))
        a.modificationDate = fixedDate
        return a
    }

    static func ourNote() -> PDFAnnotation {
        let a = PDFAnnotation(bounds: CGRect(x: 40, y: 700, width: 20, height: 20), forType: .text, withProperties: nil)
        a.color = NSColor(srgbRed: 0.42, green: 0.71, blue: 0.98, alpha: 1)
        a.contents = secret
        a.setValue("N-1", forAnnotationKey: key("PTMarkupID"))
        a.setValue(secret, forAnnotationKey: key("PTComment"))
        a.modificationDate = fixedDate
        return a
    }

    static func ourSquare() -> PDFAnnotation {
        let a = PDFAnnotation(bounds: CGRect(x: 300, y: 400, width: 120, height: 60), forType: .square, withProperties: nil)
        a.color = .red
        a.setValue("S-1", forAnnotationKey: key("PTSketchID"))
        a.userName = "Paper Time Sketch"
        a.modificationDate = fixedDate
        return a
    }

    static func ourInk() -> PDFAnnotation {
        let a = PDFAnnotation(bounds: CGRect(x: 100, y: 300, width: 80, height: 40), forType: .ink, withProperties: nil)
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 2, y: 2))
        path.line(to: CGPoint(x: 78, y: 38))
        a.add(path)
        a.color = .blue
        a.userName = "Paper Time"
        a.setValue("Paper Time", forAnnotationKey: key("PTInk"))
        a.modificationDate = fixedDate
        return a
    }

    static func isOurs(_ a: PDFAnnotation) -> Bool {
        ["PTMarkupID", "PTSketchID", "PTInk"].contains { a.value(forAnnotationKey: key($0)) != nil }
    }

    static func addMarks(_ document: PDFDocument) {
        document.page(at: 0)?.addAnnotation(ourHighlight())
        document.page(at: 0)?.addAnnotation(ourNote())
        document.page(at: 0)?.addAnnotation(ourSquare())
        document.page(at: 1)?.addAnnotation(ourInk())
    }

    /// What the sketch writer does on every save: takes its own off the page
    /// and puts the same back.
    static func replayMarks(_ document: PDFDocument) {
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            for a in page.annotations where isOurs(a) { page.removeAnnotation(a) }
        }
        addMarks(document)
    }

    static func removeNoteAndHighlight(_ document: PDFDocument) {
        guard let page = document.page(at: 0) else { return }
        for a in page.annotations {
            let id = a.value(forAnnotationKey: key("PTMarkupID")) as? String
            if id == "N-1" || id == "M-1" { page.removeAnnotation(a) }
        }
    }

    static func texts(_ d: PDFDocument) -> [String] { (0..<d.pageCount).map { d.page(at: $0)?.string ?? "" } }

    static func appended(_ outcome: IncrementalWriter.Outcome) -> (Data, IncrementalWriter.Stats)? {
        if case let .appended(data, stats) = outcome { return (data, stats) }
        return nil
    }

    static func isUnchanged(_ outcome: IncrementalWriter.Outcome) -> Bool {
        if case .unchanged = outcome { return true }
        return false
    }

    /// Every string and stream of every object in use in the current version
    /// of a file, decrypted — where a deleted comment must no longer be.
    static func currentVersionContains(_ needle: String, in data: Data, security: StandardSecurity?) throws -> Bool {
        let file = try PDFFile(data: data)
        file.security = security
        let bytes = Array(needle.utf8)
        var utf16: [UInt8] = [0xFE, 0xFF]
        for unit in needle.utf16 { utf16 += [UInt8(unit >> 8), UInt8(unit & 0xFF)] }
        func contains(_ haystack: [UInt8], _ n: [UInt8]) -> Bool {
            guard n.count <= haystack.count else { return false }
            return (0...(haystack.count - n.count)).contains { haystack[$0..<($0 + n.count)].elementsEqual(n) }
        }
        func search(_ o: PDFObj) -> Bool {
            switch o {
            case let .string(b, _): return contains(b, bytes) || contains(b, utf16)
            case let .array(a): return a.contains(where: search)
            case let .dict(d): return d.pairs.contains { search($0.value) }
            case let .stream(d, raw):
                let data = (try? Filters.decode(d, raw)) ?? raw
                return d.pairs.contains { search($0.value) } || contains(data, bytes)
            default: return false
            }
        }
        for num in file.entries.keys.sorted() where file.isInUse(num) {
            if let o = try? file.object(num), search(o) { return true }
        }
        return false
    }

    /// The objects in the current version whose strings or streams hold
    /// `needle`, with what kind of object each is.
    static func objectsContaining(_ needle: String, in data: Data, security: StandardSecurity?) throws -> [String] {
        let file = try PDFFile(data: data)
        file.security = security
        var found: [String] = []
        for num in file.entries.keys.sorted() where file.isInUse(num) {
            guard let o = try? file.object(num) else { continue }
            let one = try currentVersionContains(needle, in: o)
            if one { found.append("\(num) \(o.dict?["Subtype"]?.name ?? o.dict?["Type"]?.name ?? "?")") }
        }
        return found
    }

    static func currentVersionContains(_ needle: String, in o: PDFObj) throws -> Bool {
        let bytes = Array(needle.utf8)
        var utf16: [UInt8] = [0xFE, 0xFF]
        for unit in needle.utf16 { utf16 += [UInt8(unit >> 8), UInt8(unit & 0xFF)] }
        func contains(_ haystack: [UInt8], _ n: [UInt8]) -> Bool {
            guard n.count <= haystack.count else { return false }
            return (0...(haystack.count - n.count)).contains { haystack[$0..<($0 + n.count)].elementsEqual(n) }
        }
        func search(_ o: PDFObj) -> Bool {
            switch o {
            case let .string(b, _): return contains(b, bytes) || contains(b, utf16)
            case let .array(a): return a.contains(where: search)
            case let .dict(d): return d.pairs.contains { search($0.value) }
            case let .stream(d, raw):
                let data = (try? Filters.decode(d, raw)) ?? raw
                return d.pairs.contains { search($0.value) } || contains(data, bytes)
            default: return false
            }
        }
        return search(o)
    }

    // MARK: The protocol

    /// Four saves on one fixture — add, replay, remove, nothing — and the
    /// things that must hold after each. Returns what did not.
    static func run(_ fixture: Fixture) throws -> [String] {
        var issues: [String] = []
        let original = try fixture.data()
        guard let doc0 = PDFDocument(data: original) else { return ["PDFKit cannot open the fixture"] }
        if doc0.isLocked { doc0.unlock(withPassword: fixture.encryption?.userPassword ?? "") }
        let text0 = texts(doc0)
        guard text0.first?.contains("office") == true else { return ["the fixture has no text: \(text0)"] }
        let before = try PDFFile(data: original)
        var options = IncrementalWriter.Options()
        options.password = Array((fixture.encryption?.userPassword ?? "").utf8)
        let security = try fixture.encryption.map { try Fixture.security($0).1 }

        // 1. Every kind of mark.
        guard let (once, _) = appended(try IncrementalWriter.update(original, options: options, edit: addMarks)) else {
            return ["save 1 wrote nothing"]
        }
        if once.prefix(original.count) != original { issues.append("save 1: the original bytes changed") }
        let after = try PDFFile(data: once)
        after.security = security
        if after.repaired { issues.append("save 1: our reader repairs the result") }
        if after.sections.first?.trailer["Prev"]?.int != before.startxref { issues.append("save 1: /Prev is not the old startxref") }
        if after.sections.count != before.sections.count + 1 { issues.append("save 1: \(after.sections.count) sections") }
        if let id = before.trailer["ID"]?.array?.first?.stringBytes,
           after.trailer["ID"]?.array?.first?.stringBytes != id { issues.append("save 1: /ID[0] changed") }
        if after.sections.first?.kind != before.sections.first?.kind { issues.append("save 1: the new section is a \(after.sections.first?.kind.rawValue ?? "?")") }
        guard let doc1 = PDFDocument(data: once) else { return issues + ["save 1: PDFKit cannot open the result"] }
        if doc1.isLocked { doc1.unlock(withPassword: fixture.encryption?.userPassword ?? "") }
        if texts(doc1) != text0 { issues.append("save 1: the text changed") }
        let page0 = doc1.page(at: 0)?.annotations ?? []
        for id in ["M-1", "N-1"] where !page0.contains(where: { $0.value(forAnnotationKey: key("PTMarkupID")) as? String == id }) {
            issues.append("save 1: mark \(id) is not on page 0")
        }
        if let note = page0.first(where: { $0.value(forAnnotationKey: key("PTMarkupID")) as? String == "N-1" }), note.contents != secret {
            issues.append("save 1: the note reads \(note.contents ?? "nil")")
        }
        if !page0.contains(where: { $0.value(forAnnotationKey: key("PTSketchID")) as? String == "S-1" }) { issues.append("save 1: no square") }
        if !(doc1.page(at: 1)?.annotations ?? []).contains(where: { $0.type == "Ink" }) { issues.append("save 1: no ink on page 1") }
        let foreign0 = (doc0.page(at: 0)?.annotations ?? []).map { "\($0.type ?? "?") \($0.contents ?? "")" }
        let foreign1 = page0.filter { !isOurs($0) && $0.type != "Popup" }.map { "\($0.type ?? "?") \($0.contents ?? "")" }
        if foreign0.filter({ !$0.hasPrefix("Popup") }) != foreign1 { issues.append("save 1: another app's marks changed: \(foreign0) → \(foreign1)") }
        // Another app's annotations are the same objects, in the same order.
        if fixture.annots != .none {
            let elements = (try after.resolve(try after.pages()[0].dict["Annots"])).array?.compactMap(\.ref?.num) ?? []
            let wanted = [Fixture.highlight, Fixture.popup]
            if Array(elements.filter { wanted.contains($0) }) != wanted { issues.append("save 1: /Annots of page 0 is \(elements)") }
        }

        // 2. The same marks again, taken off and put back: nothing to write.
        if !isUnchanged(try IncrementalWriter.update(once, options: options, edit: replayMarks)) { issues.append("save 2: a replay wrote something") }
        if !isUnchanged(try IncrementalWriter.update(once, options: options) { _ in }) { issues.append("save 2: nothing wrote something") }

        // 3. The note and the highlight go.
        guard let (twice, stats) = appended(try IncrementalWriter.update(once, options: options, edit: removeNoteAndHighlight)) else {
            return issues + ["save 3 wrote nothing"]
        }
        if twice.prefix(once.count) != once { issues.append("save 3: earlier bytes changed") }
        if stats.annotationsRemoved < 2 { issues.append("save 3: removed \(stats.annotationsRemoved)") }
        guard let doc3 = PDFDocument(data: twice) else { return issues + ["save 3: PDFKit cannot open the result"] }
        if doc3.isLocked { doc3.unlock(withPassword: fixture.encryption?.userPassword ?? "") }
        if texts(doc3) != text0 { issues.append("save 3: the text changed") }
        let page3 = doc3.page(at: 0)?.annotations ?? []
        if page3.contains(where: { ($0.value(forAnnotationKey: key("PTMarkupID")) as? String).map { ["M-1", "N-1"].contains($0) } ?? false }) {
            issues.append("save 3: a removed mark is still there")
        }
        if !page3.contains(where: { $0.value(forAnnotationKey: key("PTSketchID")) as? String == "S-1" }) { issues.append("save 3: the square went too") }
        if page3.filter({ !isOurs($0) && $0.type != "Popup" }).map({ "\($0.type ?? "?") \($0.contents ?? "")" }) != foreign1 {
            issues.append("save 3: another app's marks changed")
        }
        if stats.objectsFreed == 0 { issues.append("save 3: nothing freed") }
        let holders = try objectsContaining(secret, in: twice, security: security)
        if !holders.isEmpty {
            issues.append("save 3: the deleted note's words are still in the current version, in \(holders)")
        }
        // Still in the history, which is what an incremental update is.
        if try !currentVersionContains(secret, in: once, security: security) { issues.append("save 1: the note's words are not where the check looks") }

        // 4. Nothing more.
        if !isUnchanged(try IncrementalWriter.update(twice, options: options) { _ in }) { issues.append("save 4: nothing wrote something") }
        return issues
    }

    static let shapes: [Fixture] = [
        Fixture(name: "classic table"),
        Fixture(name: "table starting at 1", xref: .tableFromOne),
        Fixture(name: "xref stream", xref: .stream),
        Fixture(name: "xref stream with PNG predictor", xref: .streamPredictor),
        Fixture(name: "pages in an object stream", xref: .stream, pagesInObjectStream: true),
        Fixture(name: "hybrid, pages in an object stream", xref: .hybrid, pagesInObjectStream: true),
        Fixture(name: "linearised chain", linearizedShape: true),
        Fixture(name: "no annotations anywhere", annots: .none),
        Fixture(name: "indirect /Annots", annots: .indirect),
        Fixture(name: "one /Annots array on two pages", annots: .shared),
        Fixture(name: "null in /Annots", annots: .withNull),
        Fixture(name: "an annotation written inline", annots: .directDict),
        Fixture(name: "a form field", annots: .widget),
        Fixture(name: "rotation inherited from /Pages", rotateInherited: true),
        Fixture(name: "junk after %%EOF", tail: String(repeating: "garbage after the end\n", count: 90)),
        Fixture(name: "no end of line after %%EOF", finalNewline: false),
        Fixture(name: "carriage returns", carriageReturns: true),
        Fixture(name: "certified, annotations allowed", docMDP: 3),
        Fixture(name: "RC4 40-bit", encryption: .init(cipher: .rc4_40)),
        Fixture(name: "RC4 128-bit", encryption: .init(cipher: .rc4_128)),
        Fixture(name: "AES-128", encryption: .init(cipher: .aes128)),
        Fixture(name: "AES-256", encryption: .init(cipher: .aes256)),
        Fixture(name: "AES-128, object streams", xref: .stream, pagesInObjectStream: true, encryption: .init(cipher: .aes128)),
        Fixture(name: "AES-256, object streams", xref: .stream, pagesInObjectStream: true, encryption: .init(cipher: .aes256)),
        Fixture(name: "RC4 128-bit, hybrid", xref: .hybrid, pagesInObjectStream: true, encryption: .init(cipher: .rc4_128)),
    ]

    @Test("Every shape of file takes marks, gives them back, and loses none of its own", arguments: shapes)
    func everyShape(_ fixture: Fixture) throws {
        let issues = try Self.run(fixture)
        #expect(issues.isEmpty, "\(fixture.name): \(issues.joined(separator: "; "))")
    }

    // MARK: Refusals

    static func refusal(_ fixture: Fixture, password: String = "") throws -> IncrementalWriter.Refusal? {
        var options = IncrementalWriter.Options()
        options.password = Array(password.utf8)
        do {
            _ = try IncrementalWriter.update(try fixture.data(), options: options, edit: addMarks)
            return nil
        } catch let r as IncrementalWriter.Refusal {
            return r
        }
    }

    @Test("A broken startxref is refused, not repaired by rewriting")
    func refusesBrokenChain() throws {
        let r = try Self.refusal(Fixture(name: "startxref 37 off", startxrefShift: 37))
        guard case .unreadableStructure? = r else { Issue.record("got \(String(describing: r))"); return }
    }

    @Test("A file with a user password is refused without it, and written with it")
    func userPassword() throws {
        let fixture = Fixture(name: "user password", encryption: .init(cipher: .aes256, userPassword: "secret"))
        #expect(try Self.refusal(fixture) == .needsPassword)
        #expect(try Self.refusal(fixture, password: "secret") == nil)
        let rc4 = Fixture(name: "user password, RC4", encryption: .init(cipher: .rc4_128, userPassword: "secret"))
        #expect(try Self.refusal(rc4) == .needsPassword)
        let issues = try Self.run(rc4)
        #expect(issues.isEmpty, "\(issues)")
    }

    @Test("Permissions that forbid annotations are respected")
    func permissions() throws {
        // Everything but bit 6, "add or modify annotations".
        let fixture = Fixture(name: "no annotations", encryption: .init(cipher: .aes128, permissions: -4 & ~(1 << 5)))
        #expect(try Self.refusal(fixture) == .permissions)
    }

    @Test("A certified document that allows no annotations is left alone")
    func certification() throws {
        #expect(try Self.refusal(Fixture(name: "P=1", docMDP: 1)) == .permissions)
        #expect(try Self.refusal(Fixture(name: "P=2", docMDP: 2)) == .permissions)
        #expect(try Self.refusal(Fixture(name: "P=3", docMDP: 3)) == nil)
    }

    @Test("A page that says /Annots twice is refused: readers disagree about which one counts")
    func duplicateAnnots() throws {
        let r = try Self.refusal(Fixture(name: "two /Annots", annots: .duplicateKey))
        guard case .annotationMapping? = r else { Issue.record("got \(String(describing: r))"); return }
    }

    @Test("An object found only by scanning is a guess, and a guess is refused")
    func refusesGuesses() throws {
        // Page 0's offset points four bytes early.
        var bytes = [UInt8](try Fixture(name: "base").data())
        let text = String(decoding: bytes, as: UTF8.self)
        let marker = "\n3 0 obj\n"
        guard let at = text.range(of: marker) else { Issue.record("no page object"); return }
        let offset = text.utf8.distance(from: text.startIndex, to: at.lowerBound) + 1
        let entry = String(format: "%010d 00000 n", offset)
        let wrong = String(format: "%010d 00000 n", offset - 4)
        guard let e = text.range(of: entry) else { Issue.record("no xref entry"); return }
        let start = text.utf8.distance(from: text.startIndex, to: e.lowerBound)
        bytes.replaceSubrange(start..<(start + wrong.utf8.count), with: Array(wrong.utf8))
        do {
            _ = try IncrementalWriter.update(Data(bytes), edit: Self.addMarks)
            Issue.record("wrote into a file it had to guess at: \(String(decoding: bytes.prefix(0), as: UTF8.self))")
        } catch let r as IncrementalWriter.Refusal {
            guard case .unreadableStructure = r else { Issue.record("got \(r)"); return }
        }
    }

    // MARK: Edits in place

    @Test("An annotation changed where it stands is written again, not dropped")
    func inPlaceEdit() throws {
        let original = try Fixture(name: "base").data()
        guard let (once, _) = Self.appended(try IncrementalWriter.update(original, edit: Self.addMarks)) else {
            Issue.record("save 1 wrote nothing"); return
        }
        let outcome = try IncrementalWriter.update(once) { document in
            document.page(at: 0)?.annotations.first { $0.value(forAnnotationKey: Self.key("PTSketchID")) != nil }?.color = .blue
        }
        guard let (twice, stats) = Self.appended(outcome) else { Issue.record("the recolour was dropped"); return }
        #expect(stats.annotationsEdited == 1)
        let square = PDFDocument(data: twice)?.page(at: 0)?.annotations.first { $0.value(forAnnotationKey: Self.key("PTSketchID")) != nil }
        let c = square?.color.usingColorSpace(.sRGB)
        #expect(c.map { $0.blueComponent > 0.9 && $0.redComponent < 0.1 } == true)
        // And another app's highlight, edited the same way.
        let foreign = try IncrementalWriter.update(once) { document in
            document.page(at: 0)?.annotations.first { $0.type == "Highlight" && !Self.isOurs($0) }?.contents = "reworded"
        }
        let reworded = Self.appended(foreign).flatMap { PDFDocument(data: $0.0) }?.page(at: 0)?.annotations
            .first { $0.type == "Highlight" && !Self.isOurs($0) }?.contents
        #expect(reworded == "reworded")
    }

    // MARK: Determinism and concurrency

    @Test("The same file and the same marks make the same bytes")
    func deterministic() throws {
        let original = try Fixture(name: "base", xref: .stream, pagesInObjectStream: true).data()
        let a = Self.appended(try IncrementalWriter.update(original, edit: Self.addMarks))?.0
        let b = Self.appended(try IncrementalWriter.update(original, edit: Self.addMarks))?.0
        #expect(a != nil && a == b)
    }

    @Test("Two papers saved at once do not step on each other")
    func parallel() async throws {
        let inputs = try [Fixture(name: "a"), Fixture(name: "b", xref: .stream, pagesInObjectStream: true),
                          Fixture(name: "c", encryption: .init(cipher: .aes256)), Fixture(name: "d", annots: .indirect)].map { try $0.data() }
        let results = await withTaskGroup(of: Bool.self) { group in
            for input in inputs {
                group.addTask {
                    guard let (out, _) = try? Self.appended(IncrementalWriter.update(input, edit: Self.addMarks)) else { return false }
                    return out.prefix(input.count) == input && PDFDocument(data: out)?.page(at: 0)?.annotations.contains(where: Self.isOurs) == true
                }
            }
            var all: [Bool] = []
            for await r in group { all.append(r) }
            return all
        }
        #expect(results.count == inputs.count && results.allSatisfy { $0 })
    }

    // MARK: The reader

    @Test("A hybrid file's stream never brings back an object a newer section freed")
    func hybridDoesNotResurrect() throws {
        let original = try Fixture(name: "hybrid", xref: .hybrid, pagesInObjectStream: true).data()
        let file = try PDFFile(data: original)
        guard case .compressed? = file.entry(Fixture.highlight) else { Issue.record("the highlight is not compressed"); return }
        // A newer section that frees the highlight, as a removal does.
        var bytes = [UInt8](original)
        let at = bytes.count
        bytes += Array("xref\n0 1\n0000000009 65535 f\r\n9 1\n0000000000 00001 f\r\ntrailer\n<< /Size \(file.size) /Root 1 0 R /Prev \(file.startxref) >>\nstartxref\n\(at)\n%%EOF\n".utf8)
        let newer = try PDFFile(data: Data(bytes))
        #expect(newer.entry(Fixture.highlight) == .free(gen: 1))
        #expect(try newer.object(Fixture.highlight).isNull)
        #expect(!newer.repaired)
    }

    @Test("An integer too big for Int is kept as it was written, not a crash")
    func hugeInteger() throws {
        let bytes = Array("<< /A 123456789012345678901234567890 /B -5 >>".utf8)
        let obj = try bytes.withUnsafeBufferPointer { buffer -> PDFObj in
            var p = Parser(buffer)
            return try p.object()
        }
        #expect(obj.dict?["A"].map { Serializer.bytes($0) } == Array("123456789012345678901234567890".utf8))
        #expect(obj.dict?["B"]?.int == -5)
    }
}
