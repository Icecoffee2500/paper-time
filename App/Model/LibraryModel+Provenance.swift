import Foundation
import LibraryStore
import PDFReader
import PaperCore
import SwiftUI

#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

/// Where each paper's file stands against its import, and the way back for
/// one that another program rewrote.
///
/// The answer costs a read and a hash of the whole file, so it is worked out
/// off the main thread the first time somebody asks — the inspector, a menu —
/// and kept by the file's size and date. Nothing is hashed for a paper nobody
/// has looked at.
extension LibraryModel {
    /// What is known about a paper's file, or nil while it is being worked
    /// out (asking starts the work).
    public func provenance(of paper: LoadedPaper) -> FileProvenance? {
        let stamp = FileStamp(url: paper.documentURL)
        if let known = provenances[paper.id], provenanceStamps[paper.id] == stamp { return known }
        if !provenanceInProgress.contains(paper.id) {
            provenanceInProgress.insert(paper.id)
            Task { await refreshProvenance(for: paper.id) }
        }
        return nil
    }

    public func refreshProvenance(for paperID: UUID) async {
        defer { provenanceInProgress.remove(paperID) }
        guard let paper = papers.first(where: { $0.id == paperID }) else { return }
        let url = paper.documentURL
        let meta = paper.meta
        let stamp = FileStamp(url: url)
        let found = await Task.detached(priority: .utility) {
            (try? FileProvenance.classify(fileAt: url, meta: meta)) ?? FileProvenance.unknown
        }.value
        provenances[paperID] = found
        provenanceStamps[paperID] = stamp
    }

    // MARK: - Restoring the original text

    /// A restore waiting for a yes: what was read, and what it would do.
    public struct RestoreFlow {
        public var paperID: UUID
        public var title: String
        public var plan: PaperRestore.Plan
    }

    /// Asks for the original file, then says what restoring from it would
    /// change. The panel is the system's; what it hands back is checked
    /// against the record's digest before anything else is said.
    public func chooseOriginal(for paperID: UUID) {
        #if os(macOS)
        guard let paper = papers.first(where: { $0.id == paperID }) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.pdf]
        panel.prompt = L("이 파일 쓰기", "Use This File")
        panel.message = L(
            "«\(paper.meta.displayTitle)»의 원본 PDF를 골라주세요. 들여올 때의 파일과 바이트까지 같아야 해요.",
            "Choose the original PDF of “\(paper.meta.displayTitle)”. It must be the very file you imported."
        )
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await self?.previewRestore(of: paperID, from: url) }
        }
        #endif
    }

    /// Reads the chosen file and the current one and works out what a
    /// restore would do. Sets `restore` to ask, or `restoreNotice` to say
    /// why not.
    @discardableResult
    public func previewRestore(of paperID: UUID, from url: URL) async -> Bool {
        guard let paper = papers.first(where: { $0.id == paperID }) else { return false }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let plan = try await PaperRestore.plan(original: url, for: paper, store: store(for: paper))
            restore = RestoreFlow(paperID: paperID, title: paper.meta.displayTitle, plan: plan)
            return true
        } catch {
            restoreNotice = Self.restoreMessage(for: error)
            return false
        }
    }

    /// What the restore would do, said for the alert.
    public static func restoreSummary(_ preview: PaperRestore.Preview) -> String {
        var ko = "\(preview.pageCount)쪽 그대로예요. 글자가 다른 쪽은 \(preview.textDiffersOn)개예요. 표시 \(preview.marks)개를 원본에 다시 써요."
        var en = "Same \(preview.pageCount) pages. Text differs on \(preview.textDiffersOn). Paper Time writes \(preview.marks) marks onto the original."
        if preview.foreign > 0 {
            ko += " 다른 앱의 주석 \(preview.foreign)개도 함께 옮겨요."
            en += " \(preview.foreign) annotations from other apps come along."
        }
        ko += " 지금 파일은 휴지통으로 가요."
        en += " The current file goes to the Trash."
        return L(ko, en)
    }

    /// Writes the marks onto the original in the damaged file's place, tells
    /// whoever has it open, and says what happened.
    public func confirmRestore() async {
        guard let flow = restore else { return }
        restore = nil
        guard let paper = papers.first(where: { $0.id == flow.paperID }) else { return }
        for session in DocumentSession.open(forPaper: paper.id) { await session.flush() }
        let root = rootURL(of: paper)
        let plan = flow.plan
        let result = await Task.detached(priority: .userInitiated) {
            Result { try PaperRestore.perform(plan, for: paper, libraryRoot: root) }
        }.value
        switch result {
        case let .success(report):
            lastRestore = report
            for session in DocumentSession.open(forPaper: paper.id) { await session.fileWasReplaced() }
            await refreshProvenance(for: paper.id)
            restoreNotice = L(
                "원본 글자를 되살렸어요. 표시 \(report.preview.marks)개를 옮겼고, 전 파일은 휴지통에 있어요.",
                "The original text is back. \(report.preview.marks) marks came across; the old file is in the Trash."
            )
        case let .failure(error):
            restoreNotice = Self.restoreMessage(for: error)
        }
    }

    public func cancelRestore() {
        restore = nil
    }

    /// Why a restore did not happen, in the reader's language.
    static func restoreMessage(for error: any Error) -> String {
        switch error as? PaperRestore.Refusal {
        case .notTheOriginal:
            L("고른 파일이 들여온 원본과 달라요. 아무것도 바꾸지 않았어요.", "That file is not the one you imported. Nothing changed.")
        case .noDigest:
            L("이 기록에는 원본의 지문이 없어서 맞춰 볼 수 없어요.", "This record has no digest of the original to check against.")
        case .cannotOpen:
            L("파일을 열지 못했어요.", "Paper Time could not open the file.")
        case let .pageCount(original, current):
            L("쪽 수가 달라요. 원본은 \(original)쪽, 지금 파일은 \(current)쪽이에요.", "The page counts differ: \(original) in the original, \(current) now.")
        case .marksDiffer:
            L("표시를 원본에 똑같이 옮기지 못해서 그만뒀어요. 아무것도 바꾸지 않았어요.", "The marks did not come across the same, so nothing changed.")
        case .writer:
            L("원본에 표시를 쓰지 못했어요. 아무것도 바꾸지 않았어요.", "Paper Time could not write the marks into the original. Nothing changed.")
        case nil:
            error.localizedDescription
        }
    }
}
