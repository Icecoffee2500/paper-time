import Foundation

// The reading plan: which papers, in what order, on which day, with what
// beside them. Four small files, all of them plain JSON in the library folder:
//
//   .papertime/plans/<plan>.json          ReadingPlan — name, sections, order
//   .papertime/papers/<paper>/plan.json   PaperSchedule — the day to read it
//   .papertime/papers/<paper>/links.json  PaperMaterials — slides, code, videos
//
// The day belongs to the paper, not to a plan, so «this week» can gather
// every plan at once and a paper needs no plan to be given a day. Every rule
// here — the calendar arithmetic, what «금요일» means, how a plan is spread
// over the weekdays, what kind of thing an address is — has a twin in the
// Portable build's `shared/readingPlan.ts`, held to the answers this file
// gives (`Scripts/reading-plan-fixture.swift`).

// MARK: - A day

/// A day on the reader's own calendar — «read this on Friday», not a moment.
///
/// Written `YYYY-MM-DD` and counted from 1970-01-01 with the proleptic
/// Gregorian calendar's own arithmetic, so the two builds agree to the day
/// without either asking a time zone anything. A week starts on Monday,
/// everywhere: a study week is Monday to Sunday whatever the system calendar
/// prints along its top.
public struct PlanDay: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        guard (1...9999).contains(year), (1...12).contains(month),
              day >= 1, day <= PlanDay.length(ofMonth: month, in: year) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// `YYYY-MM-DD`, exactly — what the files hold.
    public init?(_ text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        self.init(year: year, month: month, day: day)
    }

    /// The day `ordinal` days after 1970-01-01.
    public init(ordinal: Int) {
        let z = ordinal + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        self.year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        self.month = month
        self.day = day
    }

    /// Days since 1970-01-01.
    public var ordinal: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    public var text: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public var description: String { text }

    public func adding(days: Int) -> PlanDay { PlanDay(ordinal: ordinal + days) }

    /// 0 is Monday and 6 is Sunday.
    public var weekday: Int { ((ordinal + 3) % 7 + 7) % 7 }

    /// The Monday that starts this day's week.
    public var monday: PlanDay { adding(days: -weekday) }

    public func days(since other: PlanDay) -> Int { ordinal - other.ordinal }

    /// Today where the reader is.
    public static func today(now: Date = .now, calendar: Calendar = .current) -> PlanDay {
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return PlanDay(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
            ?? PlanDay(ordinal: 0)
    }

    /// Noon of this day where the reader is — for formatting a day with the
    /// system's own names for months and weekdays.
    public func date(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? .now
    }

    public static func length(ofMonth month: Int, in year: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    public static func < (lhs: PlanDay, rhs: PlanDay) -> Bool { lhs.ordinal < rhs.ordinal }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let day = PlanDay(raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a day: \(raw)")
        }
        self = day
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

// MARK: - Reading a day someone typed

/// What a person types into a date field: «금요일», «다음 주 수», «12/3»,
/// «+1주», «tomorrow», «next fri», «Dec 3».
///
/// Read against today and never against the clock, so the same words give
/// the same day on both builds. Anything it cannot read is nil — the field
/// says it could not, rather than guessing.
public enum PlanDayParser {
    public static func read(_ raw: String, today: PlanDay) -> PlanDay? {
        let text = normalized(raw)
        guard !text.isEmpty else { return nil }

        switch text {
        case "오늘", "today": return today
        case "내일", "tomorrow": return today.adding(days: 1)
        case "모레": return today.adding(days: 2)
        case "다음 주", "다음주", "담주", "next week": return today.monday.adding(days: 7)
        case "주말", "이번 주말", "이번주말", "weekend", "this weekend":
            return today.adding(days: (5 - today.weekday + 7) % 7)
        default: break
        }

        // +3, +3일, +2주, +2w, 3일 뒤, 2주 후, in 3 days
        if let m = match("^\\+ ?([0-9]{1,3}) ?(일|d|day|days|주|w|wk|wks|week|weeks)?$", text)
            ?? match("^([0-9]{1,3}) ?(일|주) ?(?:뒤|후)$", text)
            ?? match("^in ([0-9]{1,3}) ?(d|day|days|w|wk|wks|week|weeks)$", text),
           let count = Int(m[0] ?? "") {
            let weeks = ["주", "w", "wk", "wks", "week", "weeks"].contains(m[1] ?? "")
            return today.adding(days: count * (weeks ? 7 : 1))
        }

        // 2027-01-05, 2027.1.5, 2027년 1월 5일
        if let m = match("^([0-9]{4}) ?[-./] ?([0-9]{1,2}) ?[-./] ?([0-9]{1,2})\\.?$", text)
            ?? match("^([0-9]{4})년 ?([0-9]{1,2})월 ?([0-9]{1,2})일?$", text) {
            return PlanDay(year: Int(m[0] ?? "") ?? 0, month: Int(m[1] ?? "") ?? 0, day: Int(m[2] ?? "") ?? 0)
        }

        // 12/3, 12.3, 12-3, 12월 3일
        if let m = match("^([0-9]{1,2}) ?[-./] ?([0-9]{1,2})\\.?$", text)
            ?? match("^([0-9]{1,2})월 ?([0-9]{1,2})일?$", text) {
            return upcoming(month: Int(m[0] ?? "") ?? 0, day: Int(m[1] ?? "") ?? 0, today: today)
        }

        // Dec 3, December 3rd, 3 Dec
        if let m = match("^([a-z]{3,9})\\.? ([0-9]{1,2})(?:st|nd|rd|th)?$", text),
           let month = monthNumber(m[0] ?? "") {
            return upcoming(month: month, day: Int(m[1] ?? "") ?? 0, today: today)
        }
        if let m = match("^([0-9]{1,2})(?:st|nd|rd|th)? ([a-z]{3,9})\\.?$", text),
           let month = monthNumber(m[1] ?? "") {
            return upcoming(month: month, day: Int(m[0] ?? "") ?? 0, today: today)
        }

        // 20일 — this month's twentieth, or next month's once it has passed.
        if let m = match("^([0-9]{1,2})일$", text), let day = Int(m[0] ?? "") {
            if day >= today.day, let this = PlanDay(year: today.year, month: today.month, day: day) { return this }
            let next = today.month == 12 ? (today.year + 1, 1) : (today.year, today.month + 1)
            return PlanDay(year: next.0, month: next.1, day: day)
        }

        // 금, 금요일, 이번 주 금, 다음 주 수요일
        if let m = match("^(이번 ?주 ?|다음 ?주 ?|담주 ?)?([월화수목금토일])(?:요일)?$", text),
           let name = m[1], let weekday = "월화수목금토일".firstIndex(of: Character(name)) {
            let index = "월화수목금토일".distance(from: "월화수목금토일".startIndex, to: weekday)
            let which: Which = switch (m[0] ?? "").replacingOccurrences(of: " ", with: "") {
            case "": .upcoming
            case "이번주": .thisWeek
            default: .nextWeek
            }
            return day(index, which, today: today)
        }

        // fri, friday, this fri, next friday
        if let m = match("^(this |next )?([a-z]{3,9})$", text), let index = weekdayNumber(m[1] ?? "") {
            let which: Which = switch m[0] ?? "" {
            case "this ": .thisWeek
            case "next ": .nextWeek
            default: .upcoming
            }
            return day(index, which, today: today)
        }
        return nil
    }

    private enum Which { case upcoming, thisWeek, nextWeek }

    private static func day(_ weekday: Int, _ which: Which, today: PlanDay) -> PlanDay {
        switch which {
        case .upcoming: today.adding(days: (weekday - today.weekday + 7) % 7)
        case .thisWeek: today.monday.adding(days: weekday)
        case .nextWeek: today.monday.adding(days: 7 + weekday)
        }
    }

    /// This year's day, unless that is more than two months behind — then
    /// next year's. «1/5» typed in November means January coming.
    private static func upcoming(month: Int, day: Int, today: PlanDay) -> PlanDay? {
        guard let this = PlanDay(year: today.year, month: month, day: day) else {
            return PlanDay(year: today.year + 1, month: month, day: day)
        }
        if this < today.adding(days: -60) { return PlanDay(year: today.year + 1, month: month, day: day) }
        return this
    }

    private static let months = ["january", "february", "march", "april", "may", "june",
                                 "july", "august", "september", "october", "november", "december"]
    private static let weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

    private static func monthNumber(_ word: String) -> Int? {
        guard word.count >= 3 else { return nil }
        return months.firstIndex(where: { $0.hasPrefix(word) }).map { $0 + 1 }
    }

    private static func weekdayNumber(_ word: String) -> Int? {
        guard word.count >= 3 else { return nil }
        return weekdays.firstIndex(where: { $0.hasPrefix(word) })
    }

    /// Spaces of every kind made one space, the ends trimmed, lowercased.
    static func normalized(_ raw: String) -> String {
        normalizedKeepingCase(raw).lowercased()
    }

    /// The capture groups of a whole-string match, or nil.
    private static func match(_ pattern: String, _ text: String) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let found = regex.firstMatch(in: text, range: range) else { return nil }
        return (1..<found.numberOfRanges).map { index in
            let r = found.range(at: index)
            guard r.location != NSNotFound, let swiftRange = Range(r, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }
}

// MARK: - Spreading a plan over the weeks

public enum PlanSpread {
    /// The days `count` papers are read on: walking forward from `start`, a
    /// day on each of the chosen weekdays (0 is Monday), `perDay` papers a day.
    public static func days(count: Int, weekdays: Set<Int>, perDay: Int, from start: PlanDay) -> [PlanDay] {
        let chosen = weekdays.filter { (0...6).contains($0) }
        guard count > 0, perDay > 0, !chosen.isEmpty else { return [] }
        var out: [PlanDay] = []
        var day = start
        while out.count < count {
            if chosen.contains(day.weekday) {
                for _ in 0..<perDay where out.count < count { out.append(day) }
            }
            day = day.adding(days: 1)
        }
        return out
    }
}

// MARK: - The plan

/// `plans/<id>.json`: a run of papers to read, in order, cut into sections.
///
/// The order is the order of `entries`; a section is a name the entries point
/// at. A paper's day is not here — it is the paper's (`PaperSchedule`).
public struct ReadingPlan: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var sections: [Section]
    public var entries: [Entry]
    public var createdAt: Date

    public struct Section: Codable, Hashable, Sendable, Identifiable {
        public var id: UUID
        public var name: String

        public init(id: UUID = UUID(), name: String) {
            self.id = id
            self.name = name
        }
    }

    public struct Entry: Codable, Hashable, Sendable {
        public var paper: UUID
        public var section: UUID?

        public init(paper: UUID, section: UUID? = nil) {
            self.paper = paper
            self.section = section
        }
    }

    /// A section and its papers, in reading order.
    public struct Group: Hashable, Sendable {
        public var section: Section?
        public var papers: [UUID]
    }

    public init(id: UUID = UUID(), name: String, sections: [Section] = [], entries: [Entry] = [], createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.sections = sections
        self.entries = entries
        self.createdAt = createdAt
    }

    public func contains(_ paper: UUID) -> Bool { entries.contains { $0.paper == paper } }

    /// The section a paper sits in; nil for one in none, or in one that is gone.
    public func section(of paper: UUID) -> Section? {
        guard let id = entries.first(where: { $0.paper == paper })?.section else { return nil }
        return sections.first { $0.id == id }
    }

    /// Papers in no section come first — and are the only group when the
    /// plan has no sections at all — then every section, empty ones too, so
    /// there is a place to drop into.
    public var groups: [Group] {
        let known = Set(sections.map(\.id))
        let loose = entries.filter { entry in entry.section.map { !known.contains($0) } ?? true }.map(\.paper)
        var out: [Group] = []
        if !loose.isEmpty || sections.isEmpty { out.append(Group(section: nil, papers: loose)) }
        for section in sections {
            out.append(Group(section: section, papers: entries.filter { $0.section == section.id }.map(\.paper)))
        }
        return out
    }

    /// Every paper, the way the groups read top to bottom.
    public var readingOrder: [UUID] { groups.flatMap(\.papers) }

    /// Appends the papers the plan does not have yet, into `section`.
    public mutating func add(_ papers: [UUID], to section: UUID? = nil) {
        let target = section.flatMap { id in sections.contains { $0.id == id } ? id : nil }
        var have = Set(entries.map(\.paper))
        for paper in papers where !have.contains(paper) {
            entries.append(Entry(paper: paper, section: target))
            have.insert(paper)
        }
    }

    public mutating func remove(_ papers: Set<UUID>) {
        entries.removeAll { papers.contains($0.paper) }
    }

    /// Moves the papers, in the order given, to just before `target`, into
    /// `target`'s section. Nothing moves when the target is one of them.
    public mutating func move(_ papers: [UUID], before target: UUID) {
        guard !papers.contains(target) else { return }
        guard let anchor = entries.first(where: { $0.paper == target }) else {
            move(papers, toEndOf: nil)
            return
        }
        let present = Set(entries.map(\.paper))
        let taken = ordered(papers).filter { present.contains($0) }
        let moving = Set(taken)
        entries.removeAll { moving.contains($0.paper) }
        let index = entries.firstIndex { $0.paper == target } ?? entries.count
        entries.insert(contentsOf: taken.map { Entry(paper: $0, section: anchor.section) }, at: index)
    }

    /// Moves the papers, in the order given, to the end of `section` (nil:
    /// out of every section).
    public mutating func move(_ papers: [UUID], toEndOf section: UUID?) {
        let target = section.flatMap { id in sections.contains { $0.id == id } ? id : nil }
        let present = Set(entries.map(\.paper))
        let taken = ordered(papers).filter { present.contains($0) }
        let moving = Set(taken)
        entries.removeAll { moving.contains($0.paper) }
        entries.append(contentsOf: taken.map { Entry(paper: $0, section: target) })
    }

    @discardableResult
    public mutating func addSection(named name: String, id: UUID = UUID()) -> UUID {
        sections.append(Section(id: id, name: name))
        return id
    }

    public mutating func renameSection(_ id: UUID, to name: String) {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
        sections[index].name = name
    }

    /// The section goes; its papers stay, in their order, in no section.
    public mutating func removeSection(_ id: UUID) {
        sections.removeAll { $0.id == id }
        for index in entries.indices where entries[index].section == id {
            entries[index].section = nil
        }
    }

    public mutating func moveSection(_ id: UUID, by offset: Int) {
        guard let from = sections.firstIndex(where: { $0.id == id }) else { return }
        let to = max(0, min(sections.count - 1, from + offset))
        guard to != from else { return }
        let section = sections.remove(at: from)
        sections.insert(section, at: to)
    }

    /// The papers, once each, in the order given.
    private func ordered(_ papers: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return papers.filter { seen.insert($0).inserted }
    }
}

/// `papers/<id>/plan.json`: the day a paper is to be read.
///
/// No file is no day. A file of its own beside `meta.json` rather than a key
/// in it, for the reason `source.json` is: the record's bytes are shared with
/// the other build, and a key one build does not know is a conflict on every
/// record the other writes.
public struct PaperSchedule: Codable, Hashable, Sendable {
    public var date: PlanDay

    public init(date: PlanDay) {
        self.date = date
    }
}

// MARK: - Materials

/// What a thing beside a paper is: slides, code, a video, a notebook.
public enum MaterialKind: String, Codable, Hashable, Sendable, CaseIterable {
    case paper, slides, code, notebook, video, data, post, file

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MaterialKind(rawValue: raw) ?? .file
    }
}

/// `papers/<id>/links.json`: what the reader keeps beside a paper.
public struct PaperMaterials: Codable, Hashable, Sendable {
    public var links: [PaperMaterial]

    public init(links: [PaperMaterial] = []) {
        self.links = links
    }
}

/// One thing kept beside a paper: an address, or a file in the library folder.
public struct PaperMaterial: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: MaterialKind
    /// The address, as `MaterialLink.address` wrote it.
    public var url: String?
    /// A file copied into the library folder, relative to the folder's root,
    /// with `/` between the parts.
    public var file: String?
    /// A name the reader gave it; nil shows the one worked out from the address.
    public var title: String?
    public var addedAt: Date

    public init(id: UUID = UUID(), kind: MaterialKind, url: String? = nil, file: String? = nil,
                title: String? = nil, addedAt: Date = .now) {
        self.id = id
        self.kind = kind
        self.url = url
        self.file = file
        self.title = title
        self.addedAt = addedAt
    }

    /// The name to show.
    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let url { return MaterialLink.title(ofAddress: url) }
        if let file { return (file as NSString).lastPathComponent }
        return ""
    }
}

/// Reading an address someone pasted beside a paper.
public enum MaterialLink {
    /// The address to keep, with `https://` put in front when it was left
    /// off; nil for anything that is not a web address.
    public static func address(_ raw: String) -> String? {
        var text = PlanDayParser.normalizedKeepingCase(raw)
        if text.hasPrefix("<"), text.hasSuffix(">") { text = String(text.dropFirst().dropLast()) }
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        let lower = text.lowercased()
        let rest: String
        if lower.hasPrefix("https://") {
            rest = String(text.dropFirst(8))
        } else if lower.hasPrefix("http://") {
            rest = String(text.dropFirst(7))
        } else if lower.contains("://") {
            return nil
        } else {
            rest = text
            text = "https://" + text
        }
        var host = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }.lowercased()
        if let colon = host.firstIndex(of: ":") {
            let port = host[host.index(after: colon)...]
            guard !port.isEmpty, port.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            host = String(host[..<colon])
        }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard host.contains("."), host.allSatisfy({ allowed.contains($0) }),
              !host.hasPrefix("."), !host.hasSuffix("."), !host.hasPrefix("-"), !host.contains("..") else { return nil }
        return text
    }

    /// The host, without `www.` and without a port.
    public static func host(of address: String) -> String {
        var rest = address
        if let range = rest.range(of: "://") { rest = String(rest[range.upperBound...]) }
        var host = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }.lowercased()
        if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return host
    }

    /// The path's parts, percent-decoded, without the empty ones.
    static func pathParts(of address: String) -> [String] {
        var rest = address
        if let range = rest.range(of: "://") { rest = String(rest[range.upperBound...]) }
        guard let slash = rest.firstIndex(of: "/") else { return [] }
        let path = rest[slash...].prefix { $0 != "?" && $0 != "#" }
        return path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
    }

    static func hasQuery(_ address: String) -> Bool {
        var rest = address
        if let range = rest.range(of: "://") { rest = String(rest[range.upperBound...]) }
        return rest.contains("?")
    }

    public static func kind(ofAddress address: String) -> MaterialKind {
        let host = host(of: address)
        let parts = pathParts(of: address)
        let first = parts.first?.lowercased() ?? ""
        let last = parts.last?.lowercased() ?? ""
        func ends(_ extensions: [String]) -> Bool { extensions.contains { last.hasSuffix("." + $0) } }

        if ends(["ipynb"]) { return .notebook }
        if host == "colab.research.google.com" || host == "nbviewer.org" || (host == "kaggle.com" && first == "code") {
            return .notebook
        }
        if ["github.com", "gitlab.com", "bitbucket.org", "codeberg.org"].contains(host) { return .code }
        if host == "huggingface.co" { return first == "datasets" ? .data : .code }
        if host == "kaggle.com" && first == "datasets" { return .data }
        if ["youtube.com", "m.youtube.com", "youtu.be", "vimeo.com", "bilibili.com"].contains(host) { return .video }
        if host == "docs.google.com" && first == "presentation" { return .slides }
        if ["slideshare.net", "speakerdeck.com", "slides.com"].contains(host) { return .slides }
        if ends(["ppt", "pptx", "key", "odp"]) { return .slides }
        if ["arxiv.org", "openreview.net", "doi.org", "dx.doi.org", "aclanthology.org", "proceedings.neurips.cc",
            "proceedings.mlr.press", "semanticscholar.org", "dl.acm.org", "ieeexplore.ieee.org",
            "link.springer.com"].contains(host) || ends(["pdf"]) {
            return .paper
        }
        if ends(["mp4", "mov", "m4v", "webm", "mkv"]) { return .video }
        if ends(["csv", "tsv", "json", "jsonl", "parquet"]) { return .data }
        return .post
    }

    public static func kind(ofFileName name: String) -> MaterialKind {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "ppt", "pptx", "key", "odp": return .slides
        case "ipynb": return .notebook
        case "mp4", "mov", "m4v", "webm", "mkv", "avi": return .video
        case "csv", "tsv", "json", "jsonl", "parquet", "h5", "hdf5", "npz", "npy", "xlsx", "xls": return .data
        case "py", "r", "jl", "m", "c", "cc", "cpp", "h", "hpp", "js", "ts", "rs", "go", "java", "sh", "swift": return .code
        case "md", "txt", "html", "htm": return .post
        default: return .file
        }
    }

    /// A short name for an address: `owner/repo`, `arXiv:2106.06860`, the
    /// file's name, or the host.
    public static func title(ofAddress address: String) -> String {
        let host = host(of: address)
        let parts = pathParts(of: address)
        if ["github.com", "gitlab.com", "bitbucket.org", "codeberg.org"].contains(host), parts.count >= 2 {
            var repo = parts[1]
            if repo.lowercased().hasSuffix(".git") { repo = String(repo.dropLast(4)) }
            return parts[0] + "/" + repo
        }
        if host == "huggingface.co" {
            let rest = ["datasets", "spaces", "models"].contains(parts.first ?? "") ? Array(parts.dropFirst()) : parts
            if rest.count >= 2 { return rest[0] + "/" + rest[1] }
        }
        if host == "arxiv.org", parts.count >= 2, ["abs", "pdf", "html"].contains(parts[0]) {
            var id = parts.dropFirst().joined(separator: "/")
            if id.lowercased().hasSuffix(".pdf") { id = String(id.dropLast(4)) }
            return "arXiv:" + id
        }
        if host == "doi.org" || host == "dx.doi.org", !parts.isEmpty {
            return parts.joined(separator: "/")
        }
        if let last = parts.last, hasFileExtension(last) { return last }
        return parts.isEmpty && !hasQuery(address) ? host : host + "/…"
    }

    /// The paper's own address, from its identifiers.
    public static func paperAddress(arxiv: String?, doi: String?) -> String? {
        if let arxiv, !arxiv.isEmpty { return "https://arxiv.org/abs/" + arxiv }
        if let doi, !doi.isEmpty { return "https://doi.org/" + doi }
        return nil
    }

    static func hasFileExtension(_ part: String) -> Bool {
        guard let dot = part.lastIndex(of: "."), dot != part.startIndex else { return false }
        let ext = part[part.index(after: dot)...]
        return (1...5).contains(ext.count) && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}

extension PlanDayParser {
    /// Spaces of every kind made one space and the ends trimmed, case kept.
    static func normalizedKeepingCase(_ raw: String) -> String {
        let spaces: Set<Character> = [" ", "\t", "\n", "\r", "\r\n", "\u{3000}", "\u{00A0}"]
        var out = ""
        var pendingSpace = false
        for character in raw {
            if spaces.contains(character) {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace { out.append(" "); pendingSpace = false }
            out.append(character)
        }
        return out
    }
}
