import Foundation

/// What the app spends its time on, when you ask it.
///
/// Reading a paper has to feel immediate, and "it feels slower than it used
/// to" is not something you can fix by reading code — the last time this was
/// measured the answer was a surprise (a palette working out the same two
/// answers sixty times). So this is the ruler. It costs nothing when it is
/// off: one atomic read of a flag set at launch.
///
///     PAPERTIME_TRACE=1 "Paper Time"        # anything over 4 ms
///     PAPERTIME_TRACE=12 "Paper Time"       # anything over 12 ms
///     PAPERTIME_TRACE=all "Paper Time"      # everything, however small
///
/// Lines are one to a step, with how long it took and how many times that
/// step has run in this session — a step that costs 3 ms and runs two hundred
/// times is the one worth finding, and a total is the only way to see it.
enum Trace {
    nonisolated(unsafe) private(set) static var isOn = false
    nonisolated(unsafe) private static var floor: Double = 0.004
    nonisolated(unsafe) private static var totals: [String: (count: Int, seconds: Double)] = [:]
    nonisolated(unsafe) private static var started = Date.now
    private static let lock = NSLock()

    static func begin() {
        guard let setting = Boot.setting("PAPERTIME_TRACE") else { return }
        isOn = true
        floor = setting == "all" ? 0 : (Double(setting).map { $0 / 1000 } ?? 0.004)
        started = .now
        fputs("— trace on, anything over \(Int(floor * 1000)) ms\n", stderr)
    }

    /// Times one step. The label is not built unless the trace is on.
    @discardableResult
    static func time<T>(_ label: @autoclosure () -> String, _ work: () throws -> T) rethrows -> T {
        guard isOn else { return try work() }
        let start = DispatchTime.now().uptimeNanoseconds
        let result = try work()
        report(label(), Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        return result
    }

    /// The same, for something that waits. Isolated to whoever calls it, so
    /// the closure does not have to cross an actor to be timed.
    static func time<T>(
        isolation: isolated (any Actor)? = #isolation,
        _ label: @autoclosure () -> String,
        _ work: () async throws -> T
    ) async rethrows -> T {
        guard isOn else { return try await work() }
        let start = DispatchTime.now().uptimeNanoseconds
        let result = try await work()
        report(label(), Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        return result
    }

    /// A moment worth marking, with how long since the app started.
    static func mark(_ label: @autoclosure () -> String) {
        guard isOn else { return }
        fputs(String(format: "%7.2fs  %@\n", Date.now.timeIntervalSince(started), label()), stderr)
    }

    private static func report(_ label: String, _ seconds: Double) {
        lock.lock()
        var total = totals[label] ?? (0, 0)
        total.count += 1
        total.seconds += seconds
        totals[label] = total
        lock.unlock()
        guard seconds >= floor else { return }
        fputs(String(format: "%7.1fms  %-34@ (%d× · %.0fms total)\n",
                     seconds * 1000, label as NSString,
                     total.count, total.seconds * 1000), stderr)
    }

    /// Everything measured, heaviest first. Printed when the app goes away,
    /// and whenever anybody asks.
    static func summary() {
        guard isOn else { return }
        lock.lock()
        let all = totals.sorted { $0.value.seconds > $1.value.seconds }
        lock.unlock()
        fputs("\n— what the time went on\n", stderr)
        for (label, total) in all.prefix(24) {
            fputs(String(format: "%8.0fms  %5d×  %6.1fms each  %@\n",
                         total.seconds * 1000, total.count,
                         total.seconds * 1000 / Double(total.count), label as NSString), stderr)
        }
    }
}

/// Watches the main thread for the pauses a person actually notices.
///
/// A step that takes 200 ms is a step that dropped twelve frames, and the
/// hand feels it as the window sticking. This says when that happened even
/// where nothing has been instrumented, which is how the unmeasured places
/// give themselves away.
@MainActor
enum Hitches {
    private static var timer: Timer?
    private static var last = DispatchTime.now().uptimeNanoseconds

    static func watch() {
        guard Trace.isOn, timer == nil else { return }
        last = DispatchTime.now().uptimeNanoseconds
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = DispatchTime.now().uptimeNanoseconds
                let gap = Double(now - last) / 1e9
                last = now
                // Three frames. Below that nobody can tell.
                if gap > 0.05 {
                    fputs(String(format: "%7.0fms  ⟨main thread stalled⟩\n", gap * 1000), stderr)
                }
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
}
