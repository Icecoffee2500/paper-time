@testable import Bibliography
import Foundation
@testable import MetadataPipeline
import PDFKit
@testable import PaperCore

// Writes what the Mac's metadata pipeline makes of real inputs, for Portable's
// port (`Portable/src/shared/metadata/`), which is held to the same answers:
//
//   swift run papertime-metadata-fixtures signals <out.json> <pdf>…
//   swift run papertime-metadata-fixtures pure <cases.json>          (stdout)
//   swift run papertime-metadata-fixtures resolve <inputs.json> <responses.json> [--record]
//
// `signals` reads each PDF the way the app does (`DocumentSignalsExtractor`)
// and also keeps the first page's font runs, so the typography half can be
// run on the same runs elsewhere. `pure` evaluates a list of calls
// (`{"fn", "args"}`) and prints each result. `resolve` runs the real
// `MetadataResolver` on signals with the network answered from a file of
// recorded responses — `--record` asks the registrars once and writes them.
// Scripts/metadata-fixtures.sh drives all three.

setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

func json(_ value: some Encodable) -> Any {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try! encoder.encode(value)
    return try! JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
}

func write(_ value: Any, to path: String?) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted, .fragmentsAllowed])
    if let path { try! data.write(to: URL(fileURLWithPath: path)) } else {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    }
}

func read(_ path: String) -> Any {
    let data = try! Data(contentsOf: URL(fileURLWithPath: path))
    return try! JSONSerialization.jsonObject(with: data)
}

// MARK: - Signals

func encode(_ signals: DocumentSignals) -> [String: Any] {
    var out: [String: Any] = [
        "pageCount": signals.pageCount,
        "embeddedAuthors": signals.embeddedAuthors,
        "embeddedKeywords": signals.embeddedKeywords,
        "firstPageLines": signals.firstPageLines,
        "openingText": signals.openingText,
        "hasTextLayer": signals.hasTextLayer,
        "hasAbstract": signals.hasAbstract,
        "hasReferences": signals.hasReferences,
        "isLandscape": signals.isLandscape,
    ]
    if let value = signals.embeddedTitle { out["embeddedTitle"] = value }
    if let value = signals.embeddedSubject { out["embeddedSubject"] = value }
    if let value = signals.largestFontText { out["largestFontText"] = value }
    return out
}

func decodeSignals(_ raw: [String: Any]) -> DocumentSignals {
    DocumentSignals(
        pageCount: raw["pageCount"] as? Int ?? 0,
        embeddedTitle: raw["embeddedTitle"] as? String,
        embeddedAuthors: raw["embeddedAuthors"] as? [String] ?? [],
        embeddedSubject: raw["embeddedSubject"] as? String,
        embeddedKeywords: raw["embeddedKeywords"] as? [String] ?? [],
        firstPageLines: raw["firstPageLines"] as? [String] ?? [],
        openingText: raw["openingText"] as? String ?? "",
        largestFontText: raw["largestFontText"] as? String,
        hasTextLayer: raw["hasTextLayer"] as? Bool ?? false,
        hasAbstract: raw["hasAbstract"] as? Bool ?? false,
        hasReferences: raw["hasReferences"] as? Bool ?? false,
        isLandscape: raw["isLandscape"] as? Bool ?? false
    )
}

func fontRuns(on page: PDFPage) -> (runs: [[Int]], sizes: [Double], text: String) {
    guard let attributed = page.attributedString else { return ([], [], "") }
    var runs: [[Int]] = []
    var sizes: [Double] = []
    attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
        guard let font = value as? NSFont else { return }
        let text = attributed.attributedSubstring(from: range).string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        runs.append([range.location, range.length])
        sizes.append(Double(font.pointSize))
    }
    return (runs, sizes, attributed.string)
}

func signalsMode(_ arguments: [String]) {
    guard let out = arguments.first else { fail("signals <out.json> <pdf>…") }
    var rows: [[String: Any]] = []
    for path in arguments.dropFirst() {
        let url = URL(fileURLWithPath: path)
        guard let document = PDFDocument(url: url) else { continue }
        let signals = DocumentSignalsExtractor.extract(from: document)
        var row: [String: Any] = ["file": url.lastPathComponent, "signals": encode(signals)]
        let guess = signals.guess
        row["guess"] = ["kind": guess.kind.rawValue, "reason": "\(guess.reason)"]
        row["headers"] = HeaderExtractor.candidates(from: signals).map(encodeHeader)
        if let page = document.page(at: 0) {
            let runs = fontRuns(on: page)
            row["firstPage"] = ["runs": runs.runs, "sizes": runs.sizes, "text": runs.text]
        }
        // The pages a reference list is looked for on, and their text — what
        // another reader is held to for `hasReferences`.
        row["referencePages"] = DocumentSignalsExtractor.referencePageIndices(count: document.pageCount)
        rows.append(row)
        FileHandle.standardError.write("signals: \(url.lastPathComponent)\n".data(using: .utf8)!)
    }
    write(rows, to: out)
}

func encodeHeader(_ header: ExtractedHeader) -> [String: Any] {
    var out: [String: Any] = [
        "title": header.title,
        "authors": json(header.authors),
        "strength": header.strength,
        "source": header.source.rawValue,
    ]
    if let value = header.venueHint { out["venueHint"] = value }
    if let value = header.year { out["year"] = value }
    return out
}

func decodeHeader(_ raw: [String: Any]) -> ExtractedHeader {
    let authors = (try? JSONDecoder().decode([CSLName].self, from: JSONSerialization.data(withJSONObject: raw["authors"] ?? []))) ?? []
    return ExtractedHeader(
        title: raw["title"] as? String ?? "",
        authors: authors,
        venueHint: raw["venueHint"] as? String,
        year: raw["year"] as? Int,
        strength: raw["strength"] as? Double ?? 0,
        source: Provenance.Source(rawValue: raw["source"] as? String ?? "") ?? .heuristic
    )
}

func decodeCSL(_ raw: Any) -> CSLItem {
    let data = try! JSONSerialization.data(withJSONObject: raw)
    return try! JSONDecoder().decode(CSLItem.self, from: data)
}

func encodeAssessment(_ assessment: MatchAssessment) -> [String: Any] {
    var out: [String: Any] = [
        "titleSimilarity": assessment.titleSimilarity,
        "identifierCameFromDocument": assessment.identifierCameFromDocument,
        "verdict": assessment.verdict.rawValue,
        "explanation": assessment.explanation,
        "score": assessment.score,
    ]
    if let value = assessment.firstAuthorMatches { out["firstAuthorMatches"] = value }
    if let value = assessment.yearDifference { out["yearDifference"] = value }
    return out
}

func optional(_ value: Any?) -> Any { value ?? NSNull() }

// MARK: - Pure calls

func call(_ fn: String, _ args: [Any]) -> Any {
    func s(_ index: Int) -> String { args[index] as? String ?? "" }
    switch fn {
    case "normalizeDOI": return optional(Identifiers.normalizeDOI(s(0)))
    case "normalizeArxiv": return optional(Identifiers.normalizeArxiv(s(0)))
    case "arxivBaseID": return optional(Identifiers(arxiv: s(0)).arxivBaseID)
    case "scan": return json(IdentifierScanner.scan(s(0)))
    case "dois": return IdentifierScanner.dois(in: s(0))
    case "arxivIDs": return IdentifierScanner.arxivIDs(in: s(0))
    case "pubmedID": return optional(IdentifierScanner.pubmedID(in: s(0)))
    case "arxivIDFromFileName": return optional(IdentifierScanner.arxivID(fromFileName: s(0)))
    case "foldedTitle": return TextNormalization.foldedTitle(s(0))
    case "collapsingWhitespace": return TextNormalization.collapsingWhitespace(s(0))
    case "repairingHyphenation": return TextNormalization.repairingHyphenation(s(0))
    case "titleSimilarity": return StringSimilarity.titleSimilarity(s(0), s(1))
    case "jaroWinkler": return StringSimilarity.jaroWinkler(s(0), s(1))
    case "firstYear": return optional(CSLDate.firstYear(in: s(0)))
    case "parseName": return json(CSLName.parse(s(0)))
    case "cleanEmbeddedTitle": return optional(DocumentSignalsExtractor.cleanEmbeddedTitle(s(0)))
    case "splitAuthorField": return DocumentSignalsExtractor.splitAuthorField(s(0))
    case "keywordList": return DocumentSignalsExtractor.keywordList(s(0))
    case "isStamp": return DocumentSignalsExtractor.isStamp(s(0))
    case "isLikelyAuthorOrAffiliationLine": return DocumentSignalsExtractor.isLikelyAuthorOrAffiliationLine(s(0))
    case "looksLikeAbstract": return DocumentSignalsExtractor.looksLikeAbstract(s(0))
    case "looksLikeBoilerplate": return HeaderExtractor.looksLikeBoilerplate(s(0))
    case "endsMidPhrase": return HeaderExtractor.endsMidPhrase(s(0))
    case "firstMeaningfulLine": return optional(HeaderExtractor.firstMeaningfulLine(args[0] as? [String] ?? []))
    case "authorsFollowingTitle": return json(HeaderExtractor.authorsFollowingTitle(s(0), in: args[1] as? [String] ?? []))
    case "splitAuthorLine": return json(HeaderExtractor.splitAuthorLine(s(0)))
    case "namesACourse": return DocumentGuess.namesACourse(s(0))
    case "referencePageIndices": return DocumentSignalsExtractor.referencePageIndices(count: args[0] as? Int ?? 0)
    case "largestFontText":
        let page = args[0] as? [String: Any] ?? [:]
        let ranges = (page["runs"] as? [[Int]] ?? []).map { NSRange(location: $0[0], length: $0[1]) }
        let sizes = page["sizes"] as? [Double] ?? []
        let runs = zip(sizes, ranges).map { (size: CGFloat($0), range: $1) }
        return optional(DocumentSignalsExtractor.largestFontText(runs: runs, fullText: page["text"] as? String ?? ""))
    case "candidates":
        return HeaderExtractor.candidates(from: decodeSignals(args[0] as? [String: Any] ?? [:])).map(encodeHeader)
    case "guess":
        let guess = decodeSignals(args[0] as? [String: Any] ?? [:]).guess
        return ["kind": guess.kind.rawValue, "reason": "\(guess.reason)"]
    case "assess":
        let header = (args[1] as? [String: Any]).map(decodeHeader)
        return encodeAssessment(MetadataVerifier.assess(
            candidate: decodeCSL(args[0]), against: header, identifierCameFromDocument: args[2] as? Bool ?? false))
    case "unescape": return LaTeXEscaping.unescape(s(0))
    case "clean": return RecordSanitizer.clean(s(0))
    case "sanitized": return json(RecordSanitizer.sanitized(decodeCSL(args[0])))
    case "decodeCSL":
        guard let data = s(0).data(using: .utf8), let item = try? JSONDecoder().decode(CSLItem.self, from: data) else { return "throws" }
        return json(item)
    case "crossrefList":
        guard let data = s(0).data(using: .utf8),
              let response = try? JSONDecoder().decode(CrossrefWorkListResponse.self, from: data) else { return "throws" }
        return (response.message.items ?? []).map { json($0.asCSLItem()) }
    case "crossrefWork":
        guard let data = s(0).data(using: .utf8),
              let response = try? JSONDecoder().decode(CrossrefWorkResponse.self, from: data) else { return "throws" }
        return json(response.message.asCSLItem())
    case "openAlexList":
        guard let data = s(0).data(using: .utf8),
              let response = try? JSONDecoder().decode(OpenAlexWorkList.self, from: data) else { return "throws" }
        return (response.results ?? []).map { json($0.asCSLItem()) }
    case "arxivFeed":
        guard let data = s(0).data(using: .utf8), let entries = try? ArxivFeedParser.parse(data) else { return "throws" }
        return entries.map { entry -> [String: Any] in
            var out: [String: Any] = [
                "id": entry.id, "arxivID": entry.arxivID, "title": entry.title, "summary": entry.summary,
                "authors": entry.authors, "categories": entry.categories, "csl": json(entry.asCSLItem()),
            ]
            if let value = entry.doi { out["doi"] = value }
            if let value = entry.journalRef { out["journalRef"] = value }
            if let value = entry.primaryCategory { out["primaryCategory"] = value }
            if let value = entry.comment { out["comment"] = value }
            if let value = entry.pdfURL { out["pdfURL"] = value }
            return out
        }
    default: fail("unknown fn \(fn)")
    }
}

func pureMode(_ arguments: [String]) {
    guard let path = arguments.first, let cases = read(path) as? [[String: Any]] else { fail("pure <cases.json>") }
    let out = cases.map { one -> [String: Any] in
        let fn = one["fn"] as? String ?? ""
        let args = one["args"] as? [Any] ?? []
        return ["fn": fn, "args": args, "result": call(fn, args)]
    }
    write(out, to: nil)
}

// MARK: - Resolution with recorded responses

/// Answers every request from a file of responses, or — recording — asks
/// the network once and keeps what came back.
final class Replay: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [String: [String: Any]] = [:]
    nonisolated(unsafe) static var recording = false
    nonisolated(unsafe) static var asked: [String] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = request.url!.absoluteString
        Self.lock.withLock { Self.asked.append(key) }
        if Self.recording, Self.lock.withLock({ Self.responses[key] }) == nil {
            var copy = request
            copy.timeoutInterval = 30
            let real = copy
            let (data, response) = (try? awaitResult { try await URLSession.shared.data(for: real) }) ?? (Data(), nil)
            let http = response as? HTTPURLResponse
            var entry: [String: Any] = [
                "status": http?.statusCode ?? 0,
                "body": String(data: data, encoding: .utf8) ?? "",
            ]
            if let accept = request.value(forHTTPHeaderField: "Accept") { entry["accept"] = accept }
            if let retry = http?.value(forHTTPHeaderField: "Retry-After") { entry["retryAfter"] = retry }
            Self.lock.withLock { Self.responses[key] = entry }
        }
        guard let entry = Self.lock.withLock({ Self.responses[key] }), let status = entry["status"] as? Int, status > 0 else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        var headers: [String: String] = [:]
        if let retry = entry["retryAfter"] as? String { headers["Retry-After"] = retry }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (entry["body"] as? String ?? "").data(using: .utf8)!)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

func awaitResult<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<T, Error>!
    Task.detached {
        do { result = .success(try await work()) } catch { result = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    return try result.get()
}

func encodeResult(_ result: ResolutionResult) -> [String: Any] {
    func provenance(_ value: Provenance) -> [String: Any] {
        var out: [String: Any] = ["source": value.source.rawValue]
        if let detail = value.detail { out["detail"] = detail }
        return out
    }
    var out: [String: Any] = [
        "csl": json(result.csl),
        "identifiers": json(result.identifiers),
        "confidence": result.confidence.rawValue,
        "provenance": provenance(result.provenance),
        "candidates": result.candidates.map { candidate -> [String: Any] in
            [
                "csl": json(candidate.csl), "identifiers": json(candidate.identifiers),
                "provenance": provenance(candidate.provenance), "score": candidate.score,
                "matchExplanation": candidate.matchExplanation,
            ]
        },
        "transient": result.transientFailure != nil,
    ]
    if let assessment = result.assessment { out["assessment"] = encodeAssessment(assessment) }
    return out
}

func resolveMode(_ arguments: [String]) {
    guard arguments.count >= 2, let inputs = read(arguments[0]) as? [[String: Any]] else {
        fail("resolve <inputs.json> <responses.json> [--record]")
    }
    let responsesPath = arguments[1]
    Replay.recording = arguments.contains("--record")
    Replay.responses = (FileManager.default.fileExists(atPath: responsesPath) ? read(responsesPath) as? [String: [String: Any]] : nil) ?? [:]
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [Replay.self]
    let session = URLSession(configuration: configuration)
    var rows: [[String: Any]] = []
    for input in inputs {
        let signals = decodeSignals(input["signals"] as? [String: Any] ?? [:])
        let fileName = input["file"] as? String ?? ""
        // A fresh service for each paper: the pacing between papers is the
        // app's business, not the answer's.
        let network = NetworkService(session: session, contactEmail: input["email"] as? String)
        let resolver = MetadataResolver(network: network, contactEmail: input["email"] as? String)
        Replay.lock.withLock { Replay.asked = [] }
        let result = try! awaitResult { await resolver.resolve(signals: signals, originalFileName: fileName) }
        var row = encodeResult(result)
        row["file"] = fileName
        row["asked"] = Replay.lock.withLock { Replay.asked }
        rows.append(row)
        FileHandle.standardError.write("resolve: \(fileName) → \(result.confidence.rawValue)\n".data(using: .utf8)!)
    }
    if Replay.recording { write(Replay.responses, to: responsesPath) }
    write(rows, to: nil)
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "signals": signalsMode(Array(arguments.dropFirst()))
case "pure": pureMode(Array(arguments.dropFirst()))
case "resolve": resolveMode(Array(arguments.dropFirst()))
default: fail("usage: papertime-metadata-fixtures signals|pure|resolve …")
}
