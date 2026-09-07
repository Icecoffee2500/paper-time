import PDFKit
import SwiftUI

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Drives an in-document text search over an open `PDFDocument`, the engine
/// behind `FindBar`.
///
/// `PDFDocument` is a reference type PDFKit does not mark `Sendable`, and
/// `DocumentSession` can swap the instance out from under a long-running
/// search when it reloads the file to merge external changes (see
/// `DocumentSession.reloadAndReapply`). Hopping the actual `findString` call
/// to a background task would mean holding that reference across an actor
/// boundary with no guarantee it stays valid — a data race Swift 6 strict
/// concurrency is right to refuse. So the call stays on the main actor.
/// What keeps typing responsive instead is the 250 ms debounce below, plus
/// `isSearching` so the bar can show a spinner while a longer document is
/// scanned.
@MainActor
@Observable
final class DocumentFinder {
    var query: String = ""
    private(set) var matches: [PDFSelection] = []
    private(set) var currentIndex: Int = 0
    private(set) var isSearching = false

    private var pendingSearch: Task<Void, Never>?

    var matchCount: Int { matches.count }

    /// "3 of 47", or "No results", or "" when the query is empty.
    var summary: String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard !matches.isEmpty else { return isSearching ? "" : "No results" }
        return "\(currentIndex + 1) of \(matches.count)"
    }

    func search(_ query: String, in document: PDFDocument) async {
        self.query = query
        pendingSearch?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clear(keepingQuery: true)
            return
        }

        let task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.performSearch(for: trimmed, in: document)
        }
        pendingSearch = task
        await task.value
    }

    private func performSearch(for trimmed: String, in document: PDFDocument) async {
        guard !Task.isCancelled else { return }
        isSearching = true
        defer { isSearching = false }
        let found = document.findString(trimmed, withOptions: [.caseInsensitive, .diacriticInsensitive])
        // The debounce delay already gave a newer keystroke a chance to
        // cancel us; check again after the (synchronous, possibly slow on a
        // long PDF) scan so a stale result never clobbers a fresher one.
        guard !Task.isCancelled else { return }
        matches = found
        currentIndex = 0
    }

    func next() {
        guard !matches.isEmpty else { return }
        currentIndex = (currentIndex + 1) % matches.count
    }

    func previous() {
        guard !matches.isEmpty else { return }
        currentIndex = (currentIndex - 1 + matches.count) % matches.count
    }

    func clear() {
        clear(keepingQuery: false)
    }

    private func clear(keepingQuery: Bool) {
        pendingSearch?.cancel()
        pendingSearch = nil
        if !keepingQuery { query = "" }
        matches = []
        currentIndex = 0
        isSearching = false
    }

    /// The selection to show right now, already highlighted for display.
    var currentSelection: PDFSelection? {
        guard matches.indices.contains(currentIndex) else { return nil }
        let selection = matches[currentIndex]
        // Distinct from the app's own markup colors so a search hit never
        // reads as a saved highlight. `.systemYellow` exists on both
        // UIColor and NSColor, so no platform branch is needed here.
        selection.color = .systemYellow
        return selection
    }
}
