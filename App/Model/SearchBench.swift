import Foundation
import LibraryStore
import PaperCore

/// Search Everything, timed and written down, without a hand on the machine.
///
///     Scripts/probe.sh -s 120 -- --papertime-library=<probe library> \
///         --papertime-search-bench=1 --papertime-trace=1
///
/// Typing into the palette from a script means posting keys to whatever is in
/// front, so the palette's own two halves are driven from here instead: the
/// ranking the palette does on every keystroke, and the walk through the text
/// of the papers it does a moment after. Each is timed, and each answer is
/// written out in full — the point of a faster search is that it says exactly
/// what the slower one said, and a list printed by both is how that is seen.
///
/// `--papertime-search-bench=<q1|q2|…>` names the queries; `1` is the set the
/// evaluation was measured with. The run quits when it is done, so the trace
/// can say what the time went on.
@MainActor
enum SearchBench {
    static let evaluationQueries = [
        "unlearning", "catastrophic forgetting", "학습", "unlernaing",
        "Wasserstein", "forgetting catastrophic", "Almudévar", "le",
    ]

    static func run(in model: LibraryModel, spec: String) async {
        let queries = spec.isEmpty || spec == "1"
            ? evaluationQueries
            : spec.split(separator: "|").map(String.init)
        // `--papertime-search-bench-phases=text,steady,rank` runs only some of
        // it, and `--papertime-search-bench-samples=<n>` times each thing n
        // times instead of five — the old ranking of six hundred papers and a
        // thousand notes took two seconds a keystroke, and five of each is
        // most of an hour.
        let phases = Set((Boot.setting("PAPERTIME_SEARCH_BENCH_PHASES") ?? "text,steady,rank")
            .split(separator: ",").map(String.init))
        let samples = max(1, Int(Boot.setting("PAPERTIME_SEARCH_BENCH_SAMPLES") ?? "") ?? 5)
        // The window is still laying out its first list when the library is
        // ready, and the answers arrive on the main thread: timed from here,
        // the first search would be timing the window.
        try? await Task.sleep(for: .seconds(3))
        say("bench: \(model.papers.count) papers · \(model.notes.notes.count) notes · \(Trace.memory())")

        // The words inside the papers first, while nothing of them has been
        // read: the first query of a session is the one that pays for the
        // library, and it is only first once.
        let sources = textSources(in: model)
        // A first search that has to read six hundred papers takes minutes,
        // and what the memory does while it reads is half of what it costs:
        // said every fifteen seconds until the reading is done.
        let ticker = Task { @MainActor in
            let clock = ContinuousClock()
            let started = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                say(String(format: "bench: reading for %.0f s · %@",
                           milliseconds(clock.now - started) / 1000, Trace.memory()))
            }
        }
        for (index, query) in queries.enumerated() where phases.contains("text") {
            let run = await walk(query, in: sources, stopAfter: nil)
            let label = index == 0 ? "first of the session" : "cold for this word"
            say(String(format: "text: “%@” (%@) — first hit %.1f ms · all %.1f ms · papers %d · matches %d · order kept %@",
                       query, label, run.first ?? -1, run.total, run.hits.count,
                       run.hits.reduce(0) { $0 + $1.count }, run.orderKept ? "yes" : "NO"))
            for hit in run.hits.sorted(by: Self.stable) {
                say("text:   \(hit.title.prefix(60)) · p\(hit.passage.pageIndex + 1)"
                    + " @\(hit.passage.location)+\(hit.passage.length) ×\(hit.count) | \(hit.snippet)")
            }
        }
        ticker.cancel()
        say("bench: text read · \(Trace.memory())")

        // The same queries again, now that everything is read: what a search
        // costs on every keystroke after the first.
        for query in queries where phases.contains("steady") {
            var totals: [Double] = []
            var firsts: [Double] = []
            var palette: [Double] = []
            for _ in 0..<samples {
                let full = await walk(query, in: sources, stopAfter: nil)
                totals.append(full.total)
                firsts.append(full.first ?? full.total)
                // The palette stops at four; the list does not.
                palette.append(await walk(query, in: sources, stopAfter: 4).total)
            }
            say(String(format: "steady: “%@” — list (all papers) median %.2f ms · first hit %.2f ms · palette (4) median %.2f ms",
                       query, median(totals), median(firsts), median(palette)))
        }
        say("bench: steady done · \(Trace.memory())")

        // The ranking, one keystroke at a time, the way it is asked for while
        // somebody types — and what it costs to get ready for it, once, when
        // the palette opens.
        let clock = ContinuousClock()
        var opening: [Double] = []
        if phases.contains("rank") {
            // The palette folds the notes off the main thread as it opens,
            // and the library once they are done; the openings timed below
            // are the ones after that.
            let started = clock.now
            await model.notes.prepareSearch()
            say(String(format: "rank: the notes folded off the main thread in %.1f ms",
                       milliseconds(clock.now - started)))
        }
        for query in queries where phases.contains("rank") {
            let before = clock.now
            let ranker = Ranker(model: model)
            opening.append(milliseconds(clock.now - before))
            var perKey: [Double] = []
            var last: [SearchResult] = []
            let letters = Array(query)
            for count in 1...letters.count {
                let prefix = String(letters.prefix(count))
                var timings: [Double] = []
                for _ in 0..<samples {
                    let started = clock.now
                    // Each keystroke is a turn of the run loop of its own,
                    // which drains what it made; a loop of ninety of them
                    // here drains nothing without this, and the old ranking
                    // left nine gigabytes of regular-expression leftovers.
                    last = autoreleasepool { ranker.results(for: prefix) }
                    timings.append(milliseconds(clock.now - started))
                }
                perKey.append(median(timings))
            }
            say(String(format: "rank: “%@” — %d keystrokes · median %.2f ms · worst %.2f ms · %d results",
                       query, letters.count, median(perKey), perKey.max() ?? 0, last.count))
            for result in last {
                say(String(format: "rank:   %.4f %@ %@ — %@", result.score, kindName(result.kind),
                           result.title, result.subtitle))
            }
        }
        if let first = opening.first {
            say(String(format: "rank: getting ready when the palette opens — first %.2f ms, then median %.2f ms",
                       first, median(Array(opening.dropFirst()))))
        }
        say("bench: done · \(Trace.memory())")
    }

    // MARK: - The two halves

    /// What the palette ranks with, made when it opens: the library folded
    /// afresh each time — not the copy the palette keeps between openings —
    /// so the time it takes is the time an opening after a change takes.
    @MainActor
    private struct Ranker {
        let prepared: SearchIndex.Prepared

        init(model: LibraryModel) {
            prepared = SearchIndex.Prepared(model: model)
        }

        func results(for query: String) -> [SearchResult] {
            SearchIndex.results(for: query, in: prepared)
        }
    }

    /// The papers in the order the list reads them: the one opened most
    /// recently first, and then — every probe paper being unopened — by
    /// identifier, so two runs read them in the same order.
    private static func textSources(in model: LibraryModel) -> [PaperTextIndex.Source] {
        model.papers
            .filter { $0.meta.parentID == nil }
            .sorted {
                let lhs = $0.state.lastOpenedAt ?? .distantPast
                let rhs = $1.state.lastOpenedAt ?? .distantPast
                return lhs != rhs ? lhs > rhs : $0.id.uuidString < $1.id.uuidString
            }
            .map { PaperTextIndex.Source(id: $0.id, url: $0.documentURL, title: $0.meta.displayTitle) }
    }

    private struct Walk {
        var hits: [PaperTextIndex.Hit] = []
        var first: Double?
        var total: Double = 0
        var orderKept = true
    }

    private static func walk(_ query: String, in sources: [PaperTextIndex.Source],
                             stopAfter limit: Int?) async -> Walk {
        let clock = ContinuousClock()
        let started = clock.now
        var run = Walk()
        let position = Dictionary(uniqueKeysWithValues: sources.enumerated().map { ($1.id, $0) })
        var last = -1
        for await hit in PaperTextIndex.shared.hits(for: query, in: sources) {
            if run.first == nil { run.first = milliseconds(clock.now - started) }
            let at = position[hit.passage.paperID] ?? -1
            if at <= last { run.orderKept = false }
            last = at
            run.hits.append(hit)
            if let limit, run.hits.count >= limit { break }
        }
        run.total = milliseconds(clock.now - started)
        return run
    }

    // MARK: - Writing it down

    private static func stable(_ lhs: PaperTextIndex.Hit, _ rhs: PaperTextIndex.Hit) -> Bool {
        lhs.title != rhs.title ? lhs.title < rhs.title : lhs.passage.paperID.uuidString < rhs.passage.paperID.uuidString
    }

    private static func kindName(_ kind: SearchResult.Kind) -> String {
        switch kind {
        case .showAll: "all"
        case .paper: "paper"
        case .passage: "passage"
        case .note: "note"
        case .collection: "collection"
        case .tag: "tag"
        case .action: "action"
        }
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private static func say(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
