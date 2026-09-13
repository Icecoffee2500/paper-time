import Observation
import PDFKit

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
public final class DocumentFinder {
    public var query: String = ""
    public private(set) var matches: [PDFSelection] = []
    public private(set) var currentIndex: Int = 0
    public private(set) var isSearching = false

    private var pendingSearch: Task<Void, Never>?
    /// The query the current `matches` were produced for.
    ///
    /// SwiftUI re-commits a text field's value when it is submitted, so
    /// pressing Return set the same string again, which started another
    /// search, which reset the index a quarter of a second later — the match
    /// counter jumped back to 1 while the user sat still.
    private var searchedQuery: String?

    public init() {}

    public var matchCount: Int { matches.count }

    /// "3 of 47", or "No results", or "" when the query is empty.
    public var summary: String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard !matches.isEmpty else { return isSearching ? "" : "No results" }
        return "\(currentIndex + 1) of \(matches.count)"
    }

    public func search(_ query: String, in document: PDFDocument) async {
        let trimmedNew = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Re-running the same search would restart the walk through the
        // matches from the beginning, undoing whatever navigation the user
        // has done since.
        if trimmedNew == searchedQuery, !matches.isEmpty {
            self.query = query
            return
        }

        self.query = query
        pendingSearch?.cancel()

        let trimmed = trimmedNew
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
        searchedQuery = trimmed
    }

    public func next() {
        guard !matches.isEmpty else { return }
        currentIndex = (currentIndex + 1) % matches.count
    }

    public func previous() {
        guard !matches.isEmpty else { return }
        currentIndex = (currentIndex - 1 + matches.count) % matches.count
    }

    public func clear() {
        clear(keepingQuery: false)
    }

    private func clear(keepingQuery: Bool) {
        pendingSearch?.cancel()
        pendingSearch = nil
        if !keepingQuery { query = "" }
        searchedQuery = nil
        matches = []
        currentIndex = 0
        isSearching = false
    }

    /// The selection to show right now, already highlighted for display.
    public var currentSelection: PDFSelection? {
        guard matches.indices.contains(currentIndex) else { return nil }
        let selection = matches[currentIndex]
        // Distinct from the app's own markup colors so a search hit never
        // reads as a saved highlight. `.systemYellow` exists on both
        // UIColor and NSColor, so no platform branch is needed here.
        selection.color = .systemYellow
        return selection
    }
}
