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

    /// How many times something happened, for the questions that are about
    /// counts rather than milliseconds — "how many rows did that scroll
    /// build?" is the difference between a list that draws what you can see
    /// and one that draws the whole library every time.
    private nonisolated(unsafe) static var counts: [String: Int] = [:]

    static func tick(_ label: String) {
        guard isOn else { return }
        lock.lock()
        counts[label, default: 0] += 1
        lock.unlock()
    }

    /// Every counter whose name carries this, as one line. For a probe that
    /// wants to know which of several things happened without knowing their
    /// names in advance.
    static func tickSummary(matching fragment: String) -> String {
        guard isOn else { return "(tracing is off)" }
        lock.lock()
        defer { lock.unlock() }
        let found = counts.filter { $0.key.contains(fragment) }
            .sorted { $0.value > $1.value }
            .map { "\($0.key)=\($0.value)" }
        return found.isEmpty ? "(none)" : found.joined(separator: " · ")
    }

    static func ticks(_ label: String) -> Int {
        guard isOn else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        return counts[label] ?? 0
    }

    /// How much memory the app holds, as one line: what is resident now and
    /// at most, and the footprint the system charges it for (what Activity
    /// Monitor calls Memory) now and at its peak. A search that keeps the
    /// text of six hundred papers is a search that has to say what that
    /// costs.
    static func memory() -> String {
        var basic = mach_task_basic_info()
        var basicCount = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let basicResult = withUnsafeMutablePointer(to: &basic) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &basicCount)
            }
        }
        var vm = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let vmResult = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }
        // And how many pages had to be fetched back from the disk: a file
        // read by mapping it is free until the system wants the memory back,
        // and then every look at it is a read again.
        var events = task_events_info()
        var eventsCount = mach_msg_type_number_t(
            MemoryLayout<task_events_info>.size / MemoryLayout<natural_t>.size
        )
        let eventsResult = withUnsafeMutablePointer(to: &events) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(eventsCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_EVENTS_INFO), $0, &eventsCount)
            }
        }
        let megabyte = 1_048_576.0
        guard basicResult == KERN_SUCCESS, vmResult == KERN_SUCCESS else { return "memory: ?" }
        return String(format: "rss %.0f MB (max %.0f) · footprint %.0f MB (peak %.0f) · page-ins %d",
                      Double(basic.resident_size) / megabyte,
                      Double(basic.resident_size_max) / megabyte,
                      Double(vm.phys_footprint) / megabyte,
                      Double(vm.ledger_phys_footprint_peak) / megabyte,
                      eventsResult == KERN_SUCCESS ? Int(events.pageins) : -1)
    }

    /// Everything measured, heaviest first. Printed when the app goes away,
    /// and whenever anybody asks.
    static func summary() {
        guard isOn else { return }
        lock.lock()
        let all = totals.sorted { $0.value.seconds > $1.value.seconds }
        lock.unlock()
        fputs("\n— what the time went on\n", stderr)
        let busy = MainActor.assumeIsolated { Hitches.summary }
        if !busy.isEmpty { fputs("          \(busy)\n", stderr) }
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
    private static var observers: [CFRunLoopObserver] = []
    private static var awoke: UInt64?
    /// How long the main thread has spent working, and how often it has been
    /// asked to, since the app started.
    private static var busySpells = 0
    private static var busyTotal = 0.0

    /// Watches how long the main thread works between going back to sleep.
    ///
    /// Not the gap between timer fires, which is what this used to measure and
    /// which is not a stall at all: the system coalesces the timers of an app
    /// that is doing nothing, so a 1/60 timer nobody keeps busy fires every
    /// hundred milliseconds. Measured on an idle window with an empty list —
    /// 130 "stalls" in twenty seconds, while `sample` showed the main thread
    /// asleep in `mach_msg` for 98% of them. A ruler that reads a hundred
    /// milliseconds on an app that is doing nothing sends whoever reads it
    /// hunting a bottleneck that is not there.
    ///
    /// What a stall is: the run loop woke up, did some work, and took a long
    /// time to get back to waiting. So the work is what is timed, from waking
    /// to sleeping again — which is idle-proof, because an idle app does no
    /// work between the two.
    static func watch() {
        guard Trace.isOn, observers.isEmpty else { return }
        // Two observers rather than one: the first has to run before anything
        // else on wake and the second after everything on the way to sleep,
        // or the work in between is the work this misses.
        let wake = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min
        ) { _, _ in awoke = DispatchTime.now().uptimeNanoseconds }
        let sleep = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max
        ) { _, _ in
            guard let started = awoke else { return }
            awoke = nil
            let busy = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
            busySpells += 1
            busyTotal += busy
            // Three frames. Below that nobody can tell.
            if busy > 0.05 {
                fputs(String(format: "%7.0fms  ⟨main thread busy⟩\n", busy * 1000), stderr)
            }
        }
        for observer in [wake, sleep].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer)
        }
    }

    /// What the main thread did with its time, for the summary at the end.
    static var summary: String {
        guard busySpells > 0 else { return "" }
        return String(format: "main thread busy %.2fs over %d turns", busyTotal, busySpells)
    }
}
