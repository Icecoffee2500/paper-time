import Foundation
import PDFKit

/// Whether two files show the same annotations — the check that stands
/// between a rebuilt file and the one it replaces.
///
/// Two views of "the same", because they answer different questions. The
/// canonical view (`Canonical.form`, what the writer uses to pair a replayed
/// annotation with its original) reads the files themselves: every key and
/// every referenced object, without the appearance streams, the dates and the
/// links back to the page. That is the strict one, for compaction — where the
/// file being replaced was written by this same writer and any difference at
/// all means something in it is not ours. The summary view reads the files as
/// PDFKit does: kind, our identifying keys, and where on the page. That is
/// for a restore, where the file being replaced was written by another
/// program and only the marks' meaning can be expected to match.
public enum AnnotationComparison {
    /// The canonical form of every annotation but the popups, page by page,
    /// sorted within each page. Popups are left out because PDFKit makes
    /// them as it sees fit — a note written three times has three.
    public static func canonicalPages(of data: Data, password: [UInt8] = []) throws -> [[[UInt8]]] {
        let file = try PDFFile(data: data)
        try openSecurity(of: file, password: password)
        var pages: [[[UInt8]]] = []
        for info in try file.pages() {
            var forms: [[UInt8]] = []
            for element in (try file.resolve(info.dict["Annots"])).array ?? [] {
                guard let d = (try? file.resolve(element))?.dict, d["Subtype"] != nil || d["Rect"] != nil else { continue }
                if d["Subtype"]?.name == "Popup" { continue }
                forms.append(Canonical.form(element, in: file))
            }
            pages.append(forms.sorted { $0.lexicographicallyPrecedes($1) })
        }
        return pages
    }

    /// Where `candidate` shows different annotations from `current`, or nil
    /// when every page shows the same.
    public static func canonicalDifference(current: Data, candidate: Data, password: [UInt8] = []) throws -> String? {
        let a = try canonicalPages(of: current, password: password)
        let b = try canonicalPages(of: candidate, password: password)
        guard a.count == b.count else { return "\(b.count) pages instead of \(a.count)" }
        for (index, (x, y)) in zip(a, b).enumerated() where x != y {
            let onlyCurrent = Set(x).subtracting(y).count
            let onlyCandidate = Set(y).subtracting(x).count
            return "page \(index): \(onlyCurrent) annotation(s) only in the current file, \(onlyCandidate) only in the candidate"
        }
        return nil
    }

    /// Where PDFKit reads different annotations off the pages of two
    /// documents, or nil: the same kinds, the same identifying keys of ours,
    /// the same places. Popups are left out.
    public static func summaryDifference(current: PDFDocument, candidate: PDFDocument) -> String? {
        guard current.pageCount == candidate.pageCount else {
            return "\(candidate.pageCount) pages instead of \(current.pageCount)"
        }
        for index in 0..<current.pageCount {
            let want = (current.page(at: index)?.annotations ?? []).map(IncrementalWriter.Summary.init)
            let got = (candidate.page(at: index)?.annotations ?? []).map(IncrementalWriter.Summary.init)
            if let why = IncrementalWriter.Summary.difference(want, got) { return "page \(index): \(why)" }
        }
        return nil
    }

    static func openSecurity(of file: PDFFile, password: [UInt8]) throws {
        guard file.isEncrypted else { return }
        guard let encrypt = (try? file.resolve(file.trailer["Encrypt"]))?.dict else {
            throw IncrementalWriter.Refusal.encrypted("no /Encrypt dictionary")
        }
        let id0 = file.trailer["ID"]?.array?.first?.stringBytes ?? []
        do {
            file.security = try StandardSecurity(encrypt: encrypt, id0: id0, password: password)
        } catch StandardSecurity.Failure.wrongPassword {
            throw IncrementalWriter.Refusal.needsPassword
        } catch {
            throw IncrementalWriter.Refusal.encrypted("\(error)")
        }
    }
}

/// What the revisions after a known base changed.
///
/// A compaction folds every revision after the base into one, rebuilt from
/// the app's own state. That is only honest when those revisions held nothing
/// but annotations: a catalog, a form, a signature or a page's content
/// changed there by another program would be silently undone. So before
/// anything is rebuilt, every object the current version uses that lies past
/// the base is accounted for — it is a page whose only difference from its
/// base version is /Annots, an /Annots array, a cross-reference stream, or
/// something an annotation reaches. Anything else is a reason not to.
public enum RevisionAudit {
    /// Nil when everything past `baseLength` belongs to annotations;
    /// otherwise the first thing that does not.
    public static func foreignChanges(in data: Data, after baseLength: Int, password: [UInt8] = []) throws -> String? {
        guard baseLength > 0, baseLength <= data.count else { return "the base does not fit the file" }
        let file = try PDFFile(data: data)
        try AnnotationComparison.openSecurity(of: file, password: password)
        let base = try PDFFile(data: data.prefix(baseLength))
        try AnnotationComparison.openSecurity(of: base, password: password)
        if file.repaired || base.repaired { return "the cross-reference chain needed repair" }
        if file.trailer["Root"]?.ref != base.trailer["Root"]?.ref { return "the catalog changed" }
        if file.trailer["Info"]?.ref != base.trailer["Info"]?.ref { return "the document information changed" }

        // Which objects the folded revisions define.
        var newer = Set<Int>()
        for (num, entry) in file.entries {
            switch entry {
            case let .offset(off, _) where off >= baseLength: newer.insert(num)
            case let .compressed(stream, _):
                if case let .offset(off, _)? = file.entries[stream], off >= baseLength { newer.insert(num) }
            default: break
            }
        }
        if newer.isEmpty { return nil }

        let pages = try file.pages()
        let basePages = try base.pages()
        guard pages.count == basePages.count else { return "\(pages.count) pages instead of \(basePages.count)" }
        var allowed = Set<Int>()
        for (page, basePage) in zip(pages, basePages) {
            guard page.ref == basePage.ref else { return "the page tree changed" }
            allowed.insert(page.ref.num)
            var now = page.dict, then = basePage.dict
            now["Annots"] = nil
            then["Annots"] = nil
            if Serializer.bytes(.dict(now)) != Serializer.bytes(.dict(then)) {
                return "page \(page.ref.num) changed in more than its annotations"
            }
            if let array = page.dict["Annots"]?.ref { allowed.insert(array.num) }
            for element in (try file.resolve(page.dict["Annots"])).array ?? [] {
                Reach.collect(element, in: file, into: &allowed)
            }
        }
        for num in newer.sorted() where !allowed.contains(num) {
            let object = try? file.object(num)
            if object?.dict?["Type"]?.name == "XRef" { continue }
            // An object stream is a container; what it holds is judged by
            // its own number.
            if object?.dict?["Type"]?.name == "ObjStm" { continue }
            let what = object?.dict?["Type"]?.name ?? object?.dict?["Subtype"]?.name ?? "object"
            return "\(what) \(num) was changed by something other than an annotation"
        }
        return nil
    }
}
