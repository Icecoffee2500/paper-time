import CryptoKit
import Foundation
import PDFKit

/// Saves annotation changes as a PDF incremental update (ISO 32000-1 §7.5.6):
/// the original bytes stay exactly as they were, and the new annotation
/// objects, new versions of the pages whose /Annots changed, a cross-reference
/// section and a trailer pointing back with /Prev are appended.
///
/// Why: every way PDFKit has of writing a document — `dataRepresentation()`,
/// with options or without, `write(to:)`, even of a document nobody touched —
/// re-subsets its fonts, and on papers set in TeX that destroys the text
/// layer. One highlight on LeJEPA doubled the file and turned every "ff"
/// ligature into "!", in the file itself, for every reader. So the paper is
/// never serialised.
///
/// The annotations themselves are still made by PDFKit — the caller's `edit`
/// runs the app's usual writers on a document opened from the same bytes —
/// and still serialised by PDFKit, appearance streams and all. But PDFKit
/// only ever serialises a throwaway document of blank pages the size of the
/// ones that changed, holding just the new annotations. Their objects are
/// lifted out of that small file, renumbered after the original's, and
/// appended to the original.
///
/// When anything about the file is in doubt the writer refuses, with a
/// `Refusal` that says why, and writes nothing. It never falls back to
/// rewriting the paper.
public enum IncrementalWriter {
    public struct Options: Sendable {
        /// The user password, for a file that asks for one. Empty for the
        /// usual encrypted paper, which opens without asking.
        public var password: [UInt8] = []
        /// Whether a file with the standard security handler is written into.
        public var encryptedFiles = true
        /// Whether new appearances point at identical streams (ICC profiles,
        /// fonts) that an earlier save of ours already put in the file.
        public var reuseStreams = true
        /// Whether objects the update takes out of use are marked free, so
        /// that a deleted comment is not still in the current version of the
        /// file, only in its history.
        public var freeRemovedObjects = true
        /// Whether the result is opened with PDFKit and checked before it is
        /// handed back.
        public var verify = true

        public init() {}
    }

    public struct Stats: Sendable, CustomStringConvertible {
        public var bytesBefore = 0
        public var bytesAfter = 0
        public var appended: Int { bytesAfter - bytesBefore }
        public var xrefKind = ""
        public var pagesChanged = 0
        public var annotationsAdded = 0
        public var annotationsRemoved = 0
        /// Annotations the edit changed where they stood, written again.
        public var annotationsEdited = 0
        /// Annotations the edit removed and put back identically — the sketch
        /// writer regenerates a page wholesale — which stay as they were.
        public var keptIdentical = 0
        /// Streams (ICC profiles, fonts) pointed at rather than written again.
        public var streamsReused = 0
        public var objectsWritten = 0
        public var objectsFreed = 0
        /// Pages whose new version was spliced from the file's own text,
        /// against those serialised from their parse.
        public var pagesSpliced = 0
        public var pagesSerialised = 0
        /// Bytes PDFKit serialised: the scratch document, never the paper.
        public var scratchBytes = 0
        public var seconds = 0.0
        public var secondsPDFKitLoad = 0.0
        public var secondsScratch = 0.0
        public var secondsVerify = 0.0

        public var description: String {
            "+\(appended) B, xref=\(xrefKind), pages=\(pagesChanged), added=\(annotationsAdded), removed=\(annotationsRemoved), edited=\(annotationsEdited), kept=\(keptIdentical), reused=\(streamsReused), objects=\(objectsWritten), freed=\(objectsFreed), \(String(format: "%.3f", seconds)) s"
        }
    }

    /// Why a save was not made. The caller keeps the marks where they
    /// already are (journal, sidecars) and says so; nothing is written.
    public enum Refusal: Error, Sendable, Equatable, CustomStringConvertible {
        /// Another security handler (certificates, rights management), or a
        /// cipher the standard handler names that this writer does not know.
        case encrypted(String)
        /// The file needs a user password nobody gave.
        case needsPassword
        /// The file's permissions, or its certification, forbid annotations.
        case permissions
        /// The file's structure could not be read without guessing.
        case unreadableStructure(String)
        case pageCountMismatch(file: Int, pdfKit: Int)
        /// This reader and PDFKit disagree about a page's annotations.
        case annotationMapping(page: Int, String)
        /// An annotation changed in place that cannot be written again.
        case inPlaceEdit(page: Int)
        /// The result did not read back as it should have.
        case verificationFailed(String)

        public var description: String {
            switch self {
            case let .encrypted(why): "encrypted file: \(why)"
            case .needsPassword: "the file needs a password"
            case .permissions: "the file's permissions do not allow adding annotations"
            case let .unreadableStructure(why): "structure: \(why)"
            case let .pageCountMismatch(f, k): "page count \(f) in file vs \(k) in PDFKit"
            case let .annotationMapping(p, why): "page \(p): \(why)"
            case let .inPlaceEdit(p): "page \(p): an existing annotation was changed in a way that cannot be written"
            case let .verificationFailed(why): "the result did not check out: \(why)"
            }
        }
    }

    /// What a save came to.
    public enum Outcome: Sendable {
        /// Nothing changed; nothing needs writing.
        case unchanged(Stats)
        /// The original bytes followed by the update. `data` starts with the
        /// original, byte for byte.
        case appended(Data, Stats)

        public var stats: Stats {
            switch self {
            case let .unchanged(s), let .appended(_, s): s
            }
        }
    }

    // MARK: - Core

    /// Runs `edit` on a PDFKit document made from `original`, works out which
    /// annotations it added, removed and changed on each page, and returns
    /// `original` with those changes appended as an incremental update.
    public static func update(
        _ original: Data,
        options: Options = Options(),
        edit: (PDFDocument) throws -> Void
    ) throws -> Outcome {
        var run = try Run(original: original, options: options)
        return try run.perform(edit: edit)
    }

    // MARK: - One save

    private struct Run {
        let original: Data
        let options: Options
        let started = Date()
        var stats = Stats()
        let file: PDFFile
        var filePages: [PDFFile.PageInfo] = []

        init(original: Data, options: Options) throws {
            self.original = original
            self.options = options
            stats.bytesBefore = original.count
            do { file = try PDFFile(data: original) } catch { throw Refusal.unreadableStructure("\(error)") }
        }

        mutating func perform(edit: (PDFDocument) throws -> Void) throws -> Outcome {
            if file.repaired {
                throw Refusal.unreadableStructure("cross-reference chain needs repair: \(file.notes.joined(separator: "; "))")
            }
            try openSecurity()
            do { filePages = try file.pages() } catch { throw Refusal.unreadableStructure("page tree: \(error)") }
            try refuseGuesses()
            try checkCertification()

            let loadStart = Date()
            guard let document = PDFDocument(data: original) else { throw Refusal.unreadableStructure("PDFKit cannot open it") }
            if document.isLocked, !options.password.isEmpty {
                _ = document.unlock(withPassword: String(decoding: options.password, as: UTF8.self))
            }
            if document.isLocked { throw Refusal.needsPassword }
            // PDFKit itself refuses addAnnotation when the permissions say no;
            // the edit would silently do nothing.
            if document.isEncrypted, !document.allowsCommenting { throw Refusal.permissions }
            stats.secondsPDFKitLoad = Date().timeIntervalSince(loadStart)
            guard document.pageCount == filePages.count else {
                throw Refusal.pageCountMismatch(file: filePages.count, pdfKit: document.pageCount)
            }

            // Every annotation, and what it says, before the edit.
            var before: [[PDFAnnotation]] = []
            var described: [[Int]] = []
            before.reserveCapacity(document.pageCount)
            for i in 0..<document.pageCount {
                let annotations = document.page(at: i)?.annotations ?? []
                before.append(annotations)
                described.append(annotations.map(AnnotationFingerprint.of))
            }

            try edit(document)

            let changes = try self.changes(in: document, before: before, described: described)
            guard !changes.isEmpty else { return .unchanged(finished()) }

            // What each changed page should hold, taken before the new
            // annotations move to the scratch document.
            var expected: [Int: [Summary]] = [:]
            var texts: [Int: String] = [:]
            for change in changes {
                guard let page = document.page(at: change.index) else { continue }
                expected[change.index] = page.annotations.map(Summary.init)
                texts[change.index] = page.string ?? ""
            }

            var pageAnnots: [Int: PageAnnots] = [:]
            for change in changes {
                do {
                    pageAnnots[change.index] = try mapAnnots(of: change.index, kit: before[change.index])
                } catch {
                    // A page this reader had to guess at disagrees with PDFKit
                    // because of the guess: say that, not the disagreement.
                    try refuseGuesses()
                    throw error
                }
            }
            try refuseGuesses()

            let scratch = try serialiseScratch(changes, in: document)
            var transplant = Transplant(file: file, scratch: scratch, nextNumber: file.size)
            if options.reuseStreams, scratch.file != nil {
                let (index, guessed) = file.tolerant { reusableStreams() }
                if !guessed { transplant.reusable = index }
            }

            var pageUpdates: [(PDFRef, Appendix.Body)] = []
            var removedRefs: [PDFRef] = []
            var finalAnnots: [Int: [PDFObj]] = [:]
            var sharedArrays: [Int: Int] = [:]
            for p in filePages { if let r = p.dict["Annots"]?.ref { sharedArrays[r.num, default: 0] += 1 } }

            for change in changes {
                guard let pa = pageAnnots[change.index] else { continue }
                var removed = Set(change.removed)
                var incoming = scratch.newAnnots[change.index] ?? []
                // Also when nothing arrives: a note that goes takes its popup
                // with it, and the popup is what keeps its words reachable.
                pair(&removed, &incoming, pa: pa, mini: scratch.file)
                if removed.isEmpty, incoming.isEmpty { continue }

                let removedElements = Set(removed.map { pa.live[$0] })
                var kept: [Int] = []
                for k in pa.elements.indices where !removedElements.contains(k) { kept.append(k) }
                for k in removedElements.sorted() { if let r = pa.elements[k].ref { removedRefs.append(r) } }
                var added: [PDFRef] = []
                for ref in incoming { if let r = try transplant.bring(ref).ref { added.append(r) } }
                stats.annotationsAdded += incoming.count
                stats.annotationsRemoved += removed.count
                stats.pagesChanged += 1
                finalAnnots[change.index] = kept.map { pa.elements[$0] } + added.map { .ref($0) }

                pageUpdates.append(try newVersion(
                    of: pa, keeping: kept, adding: added,
                    ownArray: pa.indirectArray.map { sharedArrays[$0.num] == 1 } ?? false
                ))
            }
            stats.streamsReused = transplant.streamsReused

            guard !pageUpdates.isEmpty || !transplant.objects.isEmpty else { return .unchanged(finished()) }

            try refuseGuesses()

            var freed: [Appendix.Freed] = []
            if options.freeRemovedObjects, !removedRefs.isEmpty {
                let written = Set(pageUpdates.map(\.0.num))
                let arriving = transplant.objects.map { $0.1 }
                let (found, guessed) = file.tolerant {
                    freeable(removedRefs, finalAnnots: finalAnnots, written: written, arriving: arriving)
                }
                if !guessed { freed = found }
            }

            let objects = transplant.objects.map { ($0.0, Appendix.Body.object($0.1)) } + pageUpdates
            let (appendix, kind) = Appendix.bytes(for: file, objects: objects, freed: freed, firstFree: transplant.nextNumber)
            stats.xrefKind = kind.rawValue
            stats.objectsWritten = objects.count
            stats.objectsFreed = freed.count
            var out = original
            out.append(contentsOf: appendix)
            stats.bytesAfter = out.count

            if options.verify {
                let verifyStart = Date()
                try verify(out, pages: document.pageCount, expected: expected, texts: texts)
                stats.secondsVerify = Date().timeIntervalSince(verifyStart)
            }
            stats.seconds = Date().timeIntervalSince(started)
            return .appended(out, stats)
        }

        /// Anything read so far that this reader had to guess at — an object
        /// found by scanning, a stream whose length was repaired — means the
        /// save is off: PDFKit may have guessed differently.
        func refuseGuesses() throws {
            if file.guessedReads > 0 {
                throw Refusal.unreadableStructure("the reader had to guess: \(file.notes.joined(separator: "; "))")
            }
        }

        func finished() -> Stats {
            var s = stats
            s.bytesAfter = original.count
            s.seconds = Date().timeIntervalSince(started)
            return s
        }

        // MARK: Security

        /// The standard security handler with the user password (usually the
        /// empty one — a paper that opens without asking) is written into;
        /// anything else is refused.
        mutating func openSecurity() throws {
            guard file.isEncrypted else { return }
            guard options.encryptedFiles else { throw Refusal.encrypted("encrypted files are switched off") }
            guard let encrypt = (try? file.resolve(file.trailer["Encrypt"]))?.dict else {
                throw Refusal.encrypted("no /Encrypt dictionary")
            }
            let id0 = file.trailer["ID"]?.array?.first?.stringBytes ?? []
            let security: StandardSecurity
            do {
                security = try StandardSecurity(encrypt: encrypt, id0: id0, password: options.password)
            } catch StandardSecurity.Failure.wrongPassword {
                throw Refusal.needsPassword
            } catch {
                throw Refusal.encrypted("\(error)")
            }
            guard security.allowsAnnotations else { throw Refusal.permissions }
            file.security = security
        }

        /// A certified document (ISO 32000-1 §12.8.2.2) says how much may
        /// change after it was signed; below 3, annotations may not.
        func checkCertification() throws {
            guard let root = (try? file.resolve(file.trailer["Root"]))?.dict,
                  let perms = (try? file.resolve(root["Perms"]))?.dict,
                  let mdp = (try? file.resolve(perms["DocMDP"]))?.dict
            else { return }
            var p = 2 // absent /P means 2
            for r in (try? file.resolve(mdp["Reference"]))?.array ?? [] {
                if let tp = (try? file.resolve((try? file.resolve(r))?.dict?["TransformParams"]))?.dict, let v = tp["P"]?.int { p = v }
            }
            if p < 3 { throw Refusal.permissions }
        }

        // MARK: What changed

        struct PageChange {
            var index: Int
            /// Indices into PDFKit's annotations before the edit — which are
            /// also indices into the page's live /Annots elements.
            var removed: [Int]
            /// In PDFKit's order after the edit.
            var added: [PDFAnnotation]
        }

        mutating func changes(in document: PDFDocument, before: [[PDFAnnotation]], described: [[Int]]) throws -> [PageChange] {
            var changes: [PageChange] = []
            for i in 0..<document.pageCount {
                guard let page = document.page(at: i) else { continue }
                let after = page.annotations
                let afterIDs = Set(after.map(ObjectIdentifier.init))
                let beforeIDs = Set(before[i].map(ObjectIdentifier.init))
                var removed = before[i].indices.filter { !afterIDs.contains(ObjectIdentifier(before[i][$0])) }
                // Changed where it stood: written again, as a removal and an
                // addition — never left out.
                var edited = Set<ObjectIdentifier>()
                for k in before[i].indices where afterIDs.contains(ObjectIdentifier(before[i][k])) {
                    guard AnnotationFingerprint.of(before[i][k]) != described[i][k] else { continue }
                    let annotation = before[i][k]
                    // A form field belongs to the form as well as the page;
                    // taking it off one and putting a copy on the other would
                    // break the form.
                    if annotation.type == "Widget" { throw Refusal.inPlaceEdit(page: i) }
                    edited.insert(ObjectIdentifier(annotation))
                    removed.append(k)
                }
                removed.sort()
                stats.annotationsEdited += edited.count
                let added = after.filter { !beforeIDs.contains(ObjectIdentifier($0)) || edited.contains(ObjectIdentifier($0)) }
                if !removed.isEmpty || !added.isEmpty {
                    changes.append(PageChange(index: i, removed: removed, added: added))
                }
            }
            return changes
        }

        // MARK: A page's /Annots

        /// The live elements of a changed page's /Annots, matched one to one
        /// with PDFKit's annotations for that page.
        struct PageAnnots {
            var index: Int
            var info: PDFFile.PageInfo
            /// The /Annots array as written.
            var elements: [PDFObj]
            /// Each element's text as the file wrote it, when it can be had.
            var elementTexts: [[UInt8]]?
            /// Indices of the elements that are annotation dictionaries — in
            /// PDFKit's order.
            var live: [Int]
            /// When /Annots is an indirect array.
            var indirectArray: PDFRef?
        }

        func mapAnnots(of index: Int, kit: [PDFAnnotation]) throws -> PageAnnots {
            let info = filePages[index]
            if info.dict.count(of: "Annots") > 1 {
                throw Refusal.annotationMapping(page: index, "the page dictionary has more than one /Annots")
            }
            var elements: [PDFObj] = []
            var indirect: PDFRef?
            if let a = info.dict["Annots"] {
                if let r = a.ref { indirect = PDFRef(r.num, file.generation(of: r.num)) }
                elements = (try file.resolve(a)).array ?? []
            }
            var live: [Int] = []
            for (k, e) in elements.enumerated() {
                if let d = (try? file.resolve(e))?.dict, d["Subtype"] != nil || d["Rect"] != nil { live.append(k) }
            }
            guard live.count == kit.count else {
                throw Refusal.annotationMapping(page: index, "\(live.count) annotations in the file, \(kit.count) in PDFKit")
            }
            // Every one of them, not only the ones the edit touched: a page
            // this reader reads differently from PDFKit is not written.
            for (k, li) in live.enumerated() {
                guard let d = (try? file.resolve(elements[li]))?.dict else { continue }
                let st = d["Subtype"]?.name ?? ""
                let kt = kit[k].type ?? ""
                if !st.isEmpty, st != kt {
                    throw Refusal.annotationMapping(page: index, "annotation \(k) is /\(st) in the file but \(kt) in PDFKit")
                }
                if kt != "Popup", kt != "Text", let r = d["Rect"]?.array?.compactMap(\.number), r.count == 4 {
                    let b = kit[k].bounds
                    let fr = CGRect(x: min(r[0], r[2]), y: min(r[1], r[3]), width: abs(r[2] - r[0]), height: abs(r[3] - r[1]))
                    if abs(fr.minX - b.minX) > 0.6 || abs(fr.minY - b.minY) > 0.6 || abs(fr.width - b.width) > 0.6 || abs(fr.height - b.height) > 0.6 {
                        throw Refusal.annotationMapping(page: index, "annotation \(k): /Rect \(fr) in the file, \(b) in PDFKit")
                    }
                }
            }
            return PageAnnots(
                index: index, info: info, elements: elements,
                elementTexts: annotsElementTexts(of: info, indirect: indirect, count: elements.count),
                live: live, indirectArray: indirect
            )
        }

        /// The text of each /Annots element, as the file wrote it.
        func annotsElementTexts(of info: PDFFile.PageInfo, indirect: PDFRef?, count: Int) -> [[UInt8]]? {
            guard info.dict["Annots"] != nil else { return count == 0 ? [] : nil }
            let arrayText: [UInt8]
            if let indirect {
                guard let raw = file.rawText(of: indirect.num), !(file.isEncrypted && raw.inObjectStream) else { return nil }
                arrayText = raw.text
            } else {
                guard let raw = file.rawText(of: info.ref.num), !(file.isEncrypted && raw.inObjectStream),
                      let spans = try? raw.text.withUnsafeBufferPointer({ try Spans.of($0, at: 0) }),
                      let entry = spans.entries.first(where: { $0.key == "Annots" })
                else { return nil }
                arrayText = Array(raw.text[entry.valueStart..<entry.valueEnd])
            }
            guard let spans = try? arrayText.withUnsafeBufferPointer({ try Spans.of($0, at: 0) }),
                  spans.entries.count == count
            else { return nil }
            return spans.entries.map { Array(arrayText[$0.valueStart..<$0.valueEnd]) }
        }

        /// The page's (or its /Annots array's) new version: the file's own
        /// text with the one value spliced in where it can be, and the parse
        /// serialised again where it cannot.
        mutating func newVersion(of pa: PageAnnots, keeping kept: [Int], adding added: [PDFRef], ownArray: Bool) throws -> (PDFRef, Appendix.Body) {
            var listText: [UInt8]?
            // In an encrypted file an element's strings are encrypted for the
            // object they sit in: text from a shared array cannot move into
            // the page.
            let crossesObjects = pa.indirectArray != nil && !ownArray
            if let texts = pa.elementTexts, !(file.isEncrypted && crossesObjects) {
                var t: [UInt8] = Array("[".utf8)
                for (n, k) in kept.enumerated() {
                    if n > 0 { t.append(0x20) }
                    t += texts[k]
                }
                for (n, r) in added.enumerated() {
                    if n > 0 || !kept.isEmpty { t.append(0x20) }
                    t += Array("\(r.num) \(r.gen) R".utf8)
                }
                t += Array("]".utf8)
                listText = t
            }
            let list: [PDFObj] = kept.map { pa.elements[$0] } + added.map { .ref($0) }

            if let arrayRef = pa.indirectArray, ownArray {
                if let listText {
                    stats.pagesSpliced += 1
                    return (arrayRef, .raw(listText))
                }
                if file.irregular.contains(arrayRef.num) {
                    throw Refusal.unreadableStructure("the /Annots array of page \(pa.index) cannot be written back")
                }
                stats.pagesSerialised += 1
                return (arrayRef, .object(.array(list)))
            }

            // The page itself, with its /Annots spliced in its own text.
            let pageRef = pa.info.ref
            if let listText, let raw = file.rawText(of: pageRef.num), !(file.isEncrypted && raw.inObjectStream),
               let spans = try? raw.text.withUnsafeBufferPointer({ try Spans.of($0, at: 0) }) {
                var text = raw.text
                let annots = spans.entries.filter { $0.key == "Annots" }
                if let entry = annots.first {
                    if list.isEmpty {
                        text.replaceSubrange(entry.keyStart..<entry.valueEnd, with: [])
                    } else {
                        text.replaceSubrange(entry.valueStart..<entry.valueEnd, with: listText)
                    }
                } else if !list.isEmpty {
                    text.replaceSubrange(spans.close..<spans.close, with: Array(" /Annots ".utf8) + listText + [0x20])
                }
                stats.pagesSpliced += 1
                return (pageRef, .raw(text))
            }
            if file.irregular.contains(pageRef.num) {
                throw Refusal.unreadableStructure("page \(pa.index) cannot be written back")
            }
            var dict = pa.info.dict
            dict["Annots"] = list.isEmpty ? nil : .array(list)
            stats.pagesSerialised += 1
            return (pageRef, .object(.dict(dict)))
        }

        // MARK: The scratch document

        /// PDFKit serialises only the new annotations, on blank pages the size
        /// and rotation of the pages they belong to.
        mutating func serialiseScratch(_ changes: [PageChange], in document: PDFDocument) throws -> Scratch {
            let start = Date()
            defer { stats.secondsScratch = Date().timeIntervalSince(start) }
            var scratch = Scratch()
            let mini = PDFDocument()
            var order: [Int] = []
            for change in changes where !change.added.isEmpty {
                guard let page = document.page(at: change.index) else { continue }
                let blank = PDFPage()
                blank.setBounds(page.bounds(for: .mediaBox), for: .mediaBox)
                blank.setBounds(page.bounds(for: .cropBox), for: .cropBox)
                blank.rotation = page.rotation
                mini.insert(blank, at: mini.pageCount)
                for annotation in change.added {
                    page.removeAnnotation(annotation)
                    blank.addAnnotation(annotation)
                }
                order.append(change.index)
            }
            guard mini.pageCount > 0 else { return scratch }
            // The one serialisation this writer asks of PDFKit: a document
            // of blank pages and new annotations, never the paper.
            guard let data = mini.dataRepresentation() else { // not a paper: blank pages and new annotations
                throw Refusal.unreadableStructure("PDFKit could not serialise the annotations")
            }
            stats.scratchBytes = data.count
            let f: PDFFile
            let pages: [PDFFile.PageInfo]
            do {
                f = try PDFFile(data: data)
                pages = try f.pages()
            } catch {
                throw Refusal.unreadableStructure("scratch document: \(error)")
            }
            guard pages.count == order.count, !f.repaired else { throw Refusal.unreadableStructure("scratch document lost pages") }
            for (k, pageIndex) in order.enumerated() {
                scratch.pageRefs[pages[k].ref.num] = filePages[pageIndex].ref
                let list = (try? f.resolve(pages[k].dict["Annots"]))?.array ?? []
                scratch.newAnnots[pageIndex] = list.compactMap(\.ref)
            }
            scratch.file = f
            return scratch
        }

        // MARK: Pairing unchanged annotations

        /// Pairs removed originals with identical newcomers: the sketch
        /// writer regenerates a page wholesale, and a paired original keeps
        /// its object. Popups travel with their parent: PDFKit makes a fresh
        /// one for every note it writes, and points its /Parent at a copy of
        /// the note, not the note itself.
        mutating func pair(_ removed: inout Set<Int>, _ incoming: inout [PDFRef], pa: PageAnnots, mini: PDFFile?) {
            guard !incoming.isEmpty || !removed.isEmpty else { return }
            func subtype(_ o: PDFObj, _ f: PDFFile) -> String? { (try? f.resolve(o))?.dict?["Subtype"]?.name }
            // In page order, so which of two identical originals stays is the
            // same every time.
            var oldKeys: [(index: Int, key: [UInt8])] = removed.sorted().map { ($0, Canonical.form(pa.elements[pa.live[$0]], in: file)) }
            var keptIncoming: [PDFRef] = []
            if let mini {
                let incomingMain = incoming.filter { subtype(.ref($0), mini) != "Popup" }
                let incomingPopups = incoming.filter { subtype(.ref($0), mini) == "Popup" }
                for ref in incomingMain {
                    let key = Canonical.form(.ref(ref), in: mini)
                    if let match = oldKeys.firstIndex(where: { $0.key == key }) {
                        removed.remove(oldKeys[match].index)
                        oldKeys.remove(at: match)
                        stats.keptIdentical += 1
                    } else {
                        keptIncoming.append(ref)
                    }
                }
                // A new popup stays only if the annotation it belongs to is
                // really being added.
                let addedKeys = Set(keptIncoming.map { Canonical.form(.ref($0), in: mini) })
                for popup in incomingPopups {
                    let parent = (try? mini.resolve(.ref(popup)))?.dict?["Parent"]
                    if let parent, addedKeys.contains(Canonical.form(parent, in: mini)) {
                        keptIncoming.append(popup)
                    } else {
                        stats.keptIdentical += 1
                    }
                }
            }
            // An original popup goes with the annotation that goes.
            let goneKeys = Set(oldKeys.map(\.key))
            let goneRefs = Set(removed.compactMap { pa.elements[pa.live[$0]].ref?.num })
            var removedPopups = Set<Int>()
            for (k, li) in pa.live.enumerated() where !removed.contains(k) {
                guard subtype(pa.elements[li], file) == "Popup",
                      let parent = (try? file.resolve(pa.elements[li]))?.dict?["Parent"] else { continue }
                if let r = parent.ref, goneRefs.contains(r.num) { removedPopups.insert(k); continue }
                if goneKeys.contains(Canonical.form(parent, in: file)) { removedPopups.insert(k) }
            }
            removed.formUnion(removedPopups)
            incoming = keptIncoming
        }

        // MARK: Streams already in the file

        /// Leaf streams — ICC profiles, font programs — under the appearances
        /// of every annotation of ours anywhere in the file, which a new
        /// appearance can point at instead of carrying its own copy.
        func reusableStreams() -> [[UInt8]: PDFRef] {
            var map: [[UInt8]: PDFRef] = [:]
            for info in filePages {
                guard let annots = (try? file.resolve(info.dict["Annots"]))?.array else { continue }
                for element in annots {
                    guard let d = (try? file.resolve(element))?.dict, Ownership.isOurs(d), let ap = d["AP"] else { continue }
                    Transplant.collectLeafStreams(ap, in: file, into: &map, depth: 0)
                }
            }
            return map
        }

        // MARK: Freeing what is no longer used

        /// The objects the removed annotations leave behind that nothing in
        /// the current version refers to any more.
        ///
        /// Ours go with everything under them — the appearance that draws a
        /// card's words is as readable as the words. Another app's go alone:
        /// their appearances may share what the page uses, and freeing a font
        /// the page draws with would take its text off the page.
        func freeable(_ removed: [PDFRef], finalAnnots: [Int: [PDFObj]], written: Set<Int>, arriving: [PDFObj]) -> [Appendix.Freed] {
            var candidates = Set<Int>()
            for ref in removed {
                guard let d = (try? file.object(ref.num))?.dict else { continue }
                // The structure tree points at it.
                if d["StructParent"] != nil { continue }
                candidates.insert(ref.num)
                let ours = Ownership.isOurs(d) || (d["Subtype"]?.name == "Popup"
                    && ((try? file.resolve(d["Parent"]))?.dict.map(Ownership.isOurs) ?? false))
                if ours { Reach.collect(.dict(d), in: file, into: &candidates) }
            }
            guard !candidates.isEmpty else { return [] }

            // Everything still in use: every annotation on every page, what
            // this update brings in (a new appearance may point at a profile
            // an old one used), and whatever the form and the structure tree
            // hold.
            var live = Set<Int>()
            for object in arriving { Reach.collect(object, in: file, into: &live) }
            for (i, info) in filePages.enumerated() {
                live.insert(info.ref.num)
                if let r = info.dict["Annots"]?.ref { live.insert(r.num) }
                let elements = finalAnnots[i] ?? (try? file.resolve(info.dict["Annots"]))?.array ?? []
                for element in elements { Reach.collect(element, in: file, into: &live) }
            }
            if let root = (try? file.resolve(file.trailer["Root"]))?.dict {
                if let rootRef = file.trailer["Root"]?.ref { live.insert(rootRef.num) }
                for key in ["AcroForm", "StructTreeRoot"] {
                    if let value = root[key] { Reach.collect(value, in: file, into: &live) }
                }
            }
            return candidates.subtracting(live).subtracting(written)
                .filter { file.isInUse($0) }
                .sorted()
                .map { num -> Appendix.Freed in
                    let gen = file.generation(of: num)
                    return Appendix.Freed(num: num, gen: min(gen + 1, 65535))
                }
        }

        // MARK: Checking the result

        /// Opens the result with PDFKit as any reader would, and checks it
        /// says what the edit meant: the same pages, the right annotations on
        /// the changed ones, and not a letter of their text different.
        func verify(_ out: Data, pages: Int, expected: [Int: [Summary]], texts: [Int: String]) throws {
            guard let ours = try? PDFFile(data: out), !ours.repaired else {
                throw Refusal.verificationFailed("the cross-reference chain does not read back")
            }
            // The same key opens it: the /Encrypt dictionary and the first
            // half of /ID are the ones it had.
            ours.security = file.security
            guard (try? ours.pages().count) == pages else {
                throw Refusal.verificationFailed("the page tree does not read back")
            }
            guard let reread = PDFDocument(data: out) else { throw Refusal.verificationFailed("PDFKit cannot open the result") }
            if reread.isLocked { reread.unlock(withPassword: String(decoding: options.password, as: UTF8.self)) }
            guard reread.pageCount == pages else {
                throw Refusal.verificationFailed("\(reread.pageCount) pages instead of \(pages)")
            }
            for (index, want) in expected {
                guard let page = reread.page(at: index) else { throw Refusal.verificationFailed("page \(index) is missing") }
                let got = page.annotations.map(Summary.init)
                if let why = Summary.difference(want, got) {
                    throw Refusal.verificationFailed("page \(index): \(why)")
                }
                if (page.string ?? "") != texts[index] {
                    throw Refusal.verificationFailed("page \(index): the text layer changed")
                }
            }
        }
    }

    /// The scratch document PDFKit serialised, read back.
    struct Scratch {
        var file: PDFFile?
        /// Scratch page object number → the real page's reference.
        var pageRefs: [Int: PDFRef] = [:]
        /// The new annotations, as references into the scratch file, per
        /// real page index.
        var newAnnots: [Int: [PDFRef]] = [:]
    }

    // MARK: - What a page should hold

    /// One annotation, as far as checking the result goes: its kind, what
    /// identifies it as ours, and where it is.
    struct Summary {
        var type: String
        var identity: String
        var bounds: CGRect

        init(_ annotation: PDFAnnotation) {
            type = annotation.type ?? "?"
            var id = ""
            for key in ["/PTMarkupID", "/PTSketchID", "/PTSketchPart", "/PTInkStroke", "/PTComment"] {
                if let v = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: key)) as? String { id += "\(key)=\(v);" }
            }
            identity = id
            bounds = annotation.bounds
        }

        /// Where two lists disagree, or nil. Popups are left out — PDFKit
        /// makes them as it sees fit — and a note is placed by its top left
        /// corner, because PDFKit reads a note back as an icon of its own
        /// size.
        static func difference(_ want: [Summary], _ got: [Summary]) -> String? {
            let w = want.filter { $0.type != "Popup" }.sorted(by: order)
            let g = got.filter { $0.type != "Popup" }.sorted(by: order)
            guard w.count == g.count else { return "\(g.count) annotations instead of \(w.count)" }
            for (a, b) in zip(w, g) {
                guard a.type == b.type, a.identity == b.identity else { return "a \(b.type) where a \(a.type) should be" }
                let near: Bool
                if a.type == "Text" {
                    near = abs(a.bounds.minX - b.bounds.minX) < 0.6 && abs(a.bounds.maxY - b.bounds.maxY) < 0.6
                } else {
                    near = abs(a.bounds.minX - b.bounds.minX) < 0.6 && abs(a.bounds.minY - b.bounds.minY) < 0.6
                        && abs(a.bounds.width - b.bounds.width) < 0.6 && abs(a.bounds.height - b.bounds.height) < 0.6
                }
                if !near { return "a \(a.type) at \(b.bounds) instead of \(a.bounds)" }
            }
            return nil
        }

        static func order(_ a: Summary, _ b: Summary) -> Bool {
            if a.type != b.type { return a.type < b.type }
            if a.identity != b.identity { return a.identity < b.identity }
            if abs(a.bounds.minY - b.bounds.minY) >= 0.3 { return a.bounds.minY < b.bounds.minY }
            return a.bounds.minX < b.bounds.minX
        }
    }
}

// MARK: - Whose annotation

enum Ownership {
    /// An annotation this app wrote: it carries one of our keys, or the
    /// title our writers give it.
    static func isOurs(_ d: PDFDict) -> Bool {
        if d["PTMarkupID"] != nil || d["PTSketchID"] != nil || d["PTInk"] != nil { return true }
        let title = d["T"]?.text
        return title == "Paper Time" || title == "Paper Time Sketch"
    }
}

// MARK: - What an object reaches

enum Reach {
    /// Every object number reachable from `o`, not through a page's /P and
    /// not into the page tree or the catalog.
    static func collect(_ o: PDFObj, in f: PDFFile, into set: inout Set<Int>, depth: Int = 0) {
        guard depth < 48 else { return }
        switch o {
        case let .ref(r):
            guard !set.contains(r.num), let resolved = try? f.object(r.num) else { return }
            if let t = resolved.dict?["Type"]?.name, t == "Page" || t == "Pages" || t == "Catalog" { return }
            set.insert(r.num)
            collect(resolved, in: f, into: &set, depth: depth + 1)
        case let .array(items):
            for item in items { collect(item, in: f, into: &set, depth: depth + 1) }
        case let .dict(d), let .stream(d, _):
            for (k, v) in d.pairs where k != "P" { collect(v, in: f, into: &set, depth: depth + 1) }
        default:
            break
        }
    }
}

// MARK: - Moving objects across

/// Takes objects out of the scratch file, renumbered after the original's.
struct Transplant {
    let file: PDFFile
    let scratch: IncrementalWriter.Scratch
    var nextNumber: Int
    var reusable: [[UInt8]: PDFRef] = [:]
    var renumber: [Int: PDFRef] = [:]
    var objects: [(PDFRef, PDFObj)] = []
    var streamsReused = 0

    init(file: PDFFile, scratch: IncrementalWriter.Scratch, nextNumber: Int) {
        self.file = file
        self.scratch = scratch
        self.nextNumber = nextNumber
    }

    /// The object `ref` of the scratch file, brought across: its new
    /// reference in the original. A reference to a scratch page becomes the
    /// real page's (which fills /P); references to the scratch page tree and
    /// catalog are dropped.
    mutating func bring(_ ref: PDFRef) throws -> PDFObj {
        guard let mini = scratch.file else { return .null }
        if let target = scratch.pageRefs[ref.num] { return .ref(target) }
        if let done = renumber[ref.num] { return .ref(done) }
        let obj = try mini.object(ref.num)
        if let t = obj.dict?["Type"]?.name, t == "Pages" || t == "Catalog" { return .null }
        if !reusable.isEmpty, let key = Transplant.leafStreamKey(obj), let existing = reusable[key] {
            renumber[ref.num] = existing
            streamsReused += 1
            return .ref(existing)
        }
        let assigned = PDFRef(nextNumber, 0)
        nextNumber += 1
        renumber[ref.num] = assigned
        let rewritten = try rewrite(obj)
        objects.append((assigned, rewritten))
        return .ref(assigned)
    }

    private mutating func rewrite(_ o: PDFObj) throws -> PDFObj {
        switch o {
        case let .ref(r): return try bring(r)
        case let .array(items):
            var out: [PDFObj] = []
            for item in items { out.append(try rewrite(item)) }
            return .array(out)
        case let .dict(d): return .dict(try rewriteDict(d))
        case let .stream(d, data): return .stream(try rewriteDict(d), data)
        default: return o
        }
    }

    private mutating func rewriteDict(_ d: PDFDict) throws -> PDFDict {
        var out = PDFDict()
        for (k, v) in d.pairs {
            let nv = try rewrite(v)
            if nv.isNull, !v.isNull { continue } // a reference into the scratch page tree
            out.pairs.append((k, nv))
        }
        return out
    }

    /// A stream that references nothing (an ICC profile, a font program):
    /// its dictionary, sorted, and a digest of its bytes. Nil for anything
    /// else.
    static func leafStreamKey(_ o: PDFObj) -> [UInt8]? {
        guard case let .stream(d, data) = o else { return nil }
        var out: [UInt8] = []
        for (k, v) in d.pairs.sorted(by: { $0.key < $1.key }) where k != "Length" {
            if refers(v) { return nil }
            out += Array("/\(k) ".utf8)
            Serializer.write(v, into: &out)
        }
        out += Array(SHA256.hash(data: data))
        return out
    }

    private static func refers(_ x: PDFObj) -> Bool {
        switch x {
        case .ref: true
        case let .array(a): a.contains(where: refers)
        case let .dict(d): d.pairs.contains { refers($0.value) }
        default: false
        }
    }

    static func collectLeafStreams(_ o: PDFObj, in f: PDFFile, into map: inout [[UInt8]: PDFRef], depth: Int) {
        guard depth < 24 else { return }
        switch o {
        case let .ref(r):
            guard let resolved = try? f.object(r.num) else { return }
            if let key = leafStreamKey(resolved) {
                if map[key] == nil { map[key] = PDFRef(r.num, f.generation(of: r.num)) }
                return
            }
            if let t = resolved.dict?["Type"]?.name, t == "Page" || t == "Pages" || t == "Annot" { return }
            collectLeafStreams(resolved, in: f, into: &map, depth: depth + 1)
        case let .array(a):
            for x in a { collectLeafStreams(x, in: f, into: &map, depth: depth + 1) }
        case let .dict(d), let .stream(d, _):
            for (k, v) in d.pairs where k != "Parent" && k != "P" { collectLeafStreams(v, in: f, into: &map, depth: depth + 1) }
        default:
            break
        }
    }
}

// MARK: - When two annotations are the same

enum Canonical {
    /// An annotation, references inlined, without the keys that say where it
    /// lives or when it was written, or its appearance — what makes two
    /// copies "the same". The appearance is left out because PDFKit names
    /// its resources (Cs1, Cs2…) by what else was in the same scratch file.
    static func form(_ o: PDFObj, in f: PDFFile) -> [UInt8] {
        var out: [UInt8] = []
        var visiting = Set<Int>()
        func emit(_ o: PDFObj, depth: Int) {
            guard depth < 32 else { out += Array("…".utf8); return }
            switch o {
            case let .ref(r):
                guard !visiting.contains(r.num) else { out += Array("^".utf8); return }
                guard let resolved = try? f.object(r.num) else { out += Array("?".utf8); return }
                if let t = resolved.dict?["Type"]?.name, t == "Page" || t == "Pages" { out += Array("PAGE".utf8); return }
                visiting.insert(r.num)
                emit(resolved, depth: depth + 1)
                visiting.remove(r.num)
            case let .array(items):
                out.append(0x5B)
                for i in items { emit(i, depth: depth + 1); out.append(0x20) }
                out.append(0x5D)
            case let .dict(d), let .stream(d, _):
                out += Array("<<".utf8)
                for (k, v) in d.pairs.sorted(by: { $0.key < $1.key }) {
                    if k == "P" || k == "M" || k == "AP" || k == "Popup" || k == "Length" { continue }
                    out += Array("/\(k) ".utf8)
                    emit(v, depth: depth + 1)
                    out.append(0x20)
                }
                out += Array(">>".utf8)
                if case let .stream(_, data) = o {
                    out += Array("stream".utf8)
                    out += Array(SHA256.hash(data: data))
                }
            case let .string(bytes, _):
                // Literal or hex is spelling, not meaning — and a decrypted
                // string comes back in whichever form it was stored.
                Serializer.writeString(bytes, hex: true, into: &out)
            default:
                Serializer.write(o, into: &out)
            }
        }
        emit(o, depth: 0)
        return out
    }
}
