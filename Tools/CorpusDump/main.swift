import Foundation
import PDFKit
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Config

let inputDirs: [String] = [
    "/Users/imtaeheon/Documents/Bookends/Attachments",
    "/Users/imtaeheon/Documents/Bookends/vla",
]

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("Usage: corpusdump <output.json>\n".data(using: .utf8)!)
    exit(1)
}
let outputPath = CommandLine.arguments[1]

// MARK: - Helpers

func collapseWhitespace(_ s: String) -> String {
    let scalars = s.unicodeScalars
    var result = ""
    result.reserveCapacity(s.count)
    var lastWasSpace = false
    for scalar in scalars {
        if CharacterSet.whitespacesAndNewlines.contains(scalar) {
            if !lastWasSpace {
                result.append(" ")
                lastWasSpace = true
            }
        } else {
            result.unicodeScalars.append(scalar)
            lastWasSpace = false
        }
    }
    return result.trimmingCharacters(in: .whitespaces)
}

func truncate(_ s: String, _ maxLen: Int) -> String {
    if s.count <= maxLen { return s }
    let idx = s.index(s.startIndex, offsetBy: maxLen)
    return String(s[s.startIndex..<idx])
}

func firstNonEmptyLines(_ fullText: String, limit: Int) -> [String] {
    var lines: [String] = []
    for rawLine in fullText.components(separatedBy: .newlines) {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            lines.append(trimmed)
            if lines.count >= limit { break }
        }
    }
    return lines
}

func trimTrailingPunctuation(_ s: String) -> String {
    var result = s
    let punctSet = CharacterSet(charactersIn: ".,;)")
    while let last = result.unicodeScalars.last, punctSet.contains(last) {
        result.removeLast()
    }
    return result
}

func dedupPreservingOrder(_ items: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for item in items {
        if !seen.contains(item) {
            seen.insert(item)
            result.append(item)
        }
    }
    return result
}

func detectDOIs(in text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: #"10\.\d{4,9}/[-._;()/:A-Za-z0-9]+"#) else {
        return []
    }
    let nsText = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
    var results: [String] = []
    for m in matches {
        let raw = nsText.substring(with: m.range)
        let trimmed = trimTrailingPunctuation(raw)
        if !trimmed.isEmpty {
            results.append(trimmed)
        }
    }
    return dedupPreservingOrder(results)
}

func detectArxivIDs(in text: String) -> [String] {
    var results: [String] = []

    // Pattern 1: arXiv:1234.56789v1
    if let regex1 = try? NSRegularExpression(pattern: #"arXiv:\s*(\d{4}\.\d{4,5}(v\d+)?)"#, options: [.caseInsensitive]) {
        let nsText = text as NSString
        let matches = regex1.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        for m in matches {
            if m.numberOfRanges > 1 {
                let r = m.range(at: 1)
                if r.location != NSNotFound {
                    results.append(nsText.substring(with: r))
                }
            }
        }
    }

    // Pattern 2: bare 1234.56789v1 appearing "next to" the word arXiv.
    // Interpretation: find occurrences of the word "arXiv" (case-insensitive) and look for a
    // bare id pattern within a small window of characters around each occurrence (that isn't
    // already captured by the "arXiv:" prefix form above).
    if let idRegex = try? NSRegularExpression(pattern: #"\d{4}\.\d{4,5}(v\d+)?"#),
       let arxivWordRegex = try? NSRegularExpression(pattern: #"arXiv"#, options: [.caseInsensitive]) {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let arxivWordMatches = arxivWordRegex.matches(in: text, range: fullRange)
        let idMatches = idRegex.matches(in: text, range: fullRange)
        let windowRadius = 40 // characters
        for wordMatch in arxivWordMatches {
            let wordLoc = wordMatch.range.location
            for idMatch in idMatches {
                let idLoc = idMatch.range.location
                let distance = abs(idLoc - wordLoc)
                if distance <= windowRadius {
                    results.append(nsText.substring(with: idMatch.range))
                }
            }
        }
    }

    return dedupPreservingOrder(results)
}

func isoDateString(from date: Date?) -> String? {
    guard let date = date else { return nil }
    let formatter = ISO8601DateFormatter()
    return formatter.string(from: date)
}

// MARK: - Data model

struct PDFRecord: Codable {
    var fileName: String
    var relativePath: String
    var byteSize: Int
    var pageCount: Int?
    var docInfo: [String: String]?
    var firstPageText: String?
    var firstPageLines: [String]?
    var detectedDOIs: [String]?
    var detectedArxivIDs: [String]?
    var hasTextLayer: Bool?
    var largestFontSize: Double?
    var largestFontText: String?
    var error: String?
}

// MARK: - Directory scanning

struct FoundFile {
    let url: URL
    let baseDir: String
}

func findPDFs(in dirs: [String]) -> [FoundFile] {
    let fm = FileManager.default
    var found: [FoundFile] = []
    for dir in dirs {
        let dirURL = URL(fileURLWithPath: dir)
        guard let enumerator = fm.enumerator(
            at: dirURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { continue }
        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension.lowercased() == "pdf" {
                found.append(FoundFile(url: fileURL, baseDir: dir))
            }
        }
    }
    return found
}

// MARK: - Per-file processing

enum ProcessError: Error {
    case cannotOpen
}

func relativePath(of fileURL: URL, base: String) -> String {
    let baseComponents = URL(fileURLWithPath: base).standardizedFileURL.pathComponents
    let fileComponents = fileURL.standardizedFileURL.pathComponents
    if fileComponents.count > baseComponents.count && Array(fileComponents.prefix(baseComponents.count)) == baseComponents {
        let baseName = URL(fileURLWithPath: base).lastPathComponent
        let remainder = fileComponents.suffix(from: baseComponents.count)
        return ([baseName] + remainder).joined(separator: "/")
    }
    return fileURL.lastPathComponent
}

func extractLargestFont(from page: PDFPage) -> (Double, String)? {
    guard let attrString = page.attributedString else { return nil }
    let nsString = attrString.string as NSString
    let fullRange = NSRange(location: 0, length: attrString.length)
    guard fullRange.length > 0 else { return nil }

    var largestSize: Double = -1
    var rangesAtLargestSize: [NSRange] = []

    attrString.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
        var size: Double? = nil
        #if canImport(AppKit)
        if let font = value as? NSFont {
            size = Double(font.pointSize)
        }
        #endif
        guard let fontSize = size else { return }
        if fontSize > largestSize {
            largestSize = fontSize
            rangesAtLargestSize = [range]
        } else if fontSize == largestSize {
            rangesAtLargestSize.append(range)
        }
    }

    guard largestSize >= 0, !rangesAtLargestSize.isEmpty else { return nil }

    var combinedText = ""
    for range in rangesAtLargestSize {
        if range.location != NSNotFound, range.location + range.length <= nsString.length {
            combinedText += nsString.substring(with: range)
            if combinedText.count >= 200 { break }
        }
    }
    let collapsed = collapseWhitespace(combinedText)
    if collapsed.isEmpty { return nil }
    return (largestSize, truncate(collapsed, 200))
}

func processFile(_ file: FoundFile) -> PDFRecord {
    let fileURL = file.url
    let fileName = fileURL.lastPathComponent
    let relPath = relativePath(of: fileURL, base: file.baseDir)

    let byteSize: Int
    do {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        byteSize = (attrs[.size] as? Int) ?? 0
    } catch {
        return PDFRecord(
            fileName: fileName, relativePath: relPath, byteSize: 0, pageCount: nil,
            docInfo: nil, firstPageText: nil, firstPageLines: nil,
            detectedDOIs: nil, detectedArxivIDs: nil, hasTextLayer: nil,
            largestFontSize: nil, largestFontText: nil,
            error: "Could not stat file: \(error.localizedDescription)"
        )
    }

    guard let document = PDFDocument(url: fileURL) else {
        return PDFRecord(
            fileName: fileName, relativePath: relPath, byteSize: byteSize, pageCount: nil,
            docInfo: nil, firstPageText: nil, firstPageLines: nil,
            detectedDOIs: nil, detectedArxivIDs: nil, hasTextLayer: nil,
            largestFontSize: nil, largestFontText: nil,
            error: "PDFDocument failed to open file (malformed or unreadable PDF)"
        )
    }

    let pageCount = document.pageCount

    // docInfo
    var docInfo: [String: String] = [:]
    if let attrs = document.documentAttributes {
        if let title = attrs[PDFDocumentAttribute.titleAttribute] as? String { docInfo["Title"] = title }
        if let author = attrs[PDFDocumentAttribute.authorAttribute] as? String { docInfo["Author"] = author }
        if let subject = attrs[PDFDocumentAttribute.subjectAttribute] as? String { docInfo["Subject"] = subject }
        if let keywords = attrs[PDFDocumentAttribute.keywordsAttribute] as? String {
            docInfo["Keywords"] = keywords
        } else if let keywordsArr = attrs[PDFDocumentAttribute.keywordsAttribute] as? [String] {
            docInfo["Keywords"] = keywordsArr.joined(separator: ", ")
        }
        if let creator = attrs[PDFDocumentAttribute.creatorAttribute] as? String { docInfo["Creator"] = creator }
        if let producer = attrs[PDFDocumentAttribute.producerAttribute] as? String { docInfo["Producer"] = producer }
        if let creationDate = attrs[PDFDocumentAttribute.creationDateAttribute] as? Date {
            if let iso = isoDateString(from: creationDate) { docInfo["CreationDate"] = iso }
        }
    }

    // First page text + related signals
    var firstPageTextFull = ""
    var firstPageLines: [String] = []
    var largestFontSize: Double? = nil
    var largestFontText: String? = nil
    var hasTextLayer = false

    if pageCount > 0, let page1 = document.page(at: 0) {
        firstPageTextFull = page1.string ?? ""
        firstPageLines = firstNonEmptyLines(firstPageTextFull, limit: 40)
        hasTextLayer = firstPageTextFull.count >= 200
        if let (size, text) = extractLargestFont(from: page1) {
            largestFontSize = size
            largestFontText = text
        }
    } else {
        hasTextLayer = false
    }

    let firstPageTextCollapsed = truncate(collapseWhitespace(firstPageTextFull), 3000)

    // DOI / arXiv detection across first 2 pages
    var scanText = firstPageTextFull
    if pageCount > 1, let page2 = document.page(at: 1) {
        scanText += "\n" + (page2.string ?? "")
    }
    let dois = detectDOIs(in: scanText)
    let arxivIDs = detectArxivIDs(in: scanText)

    return PDFRecord(
        fileName: fileName,
        relativePath: relPath,
        byteSize: byteSize,
        pageCount: pageCount,
        docInfo: docInfo.isEmpty ? [:] : docInfo,
        firstPageText: firstPageTextCollapsed,
        firstPageLines: firstPageLines,
        detectedDOIs: dois,
        detectedArxivIDs: arxivIDs,
        hasTextLayer: hasTextLayer,
        largestFontSize: largestFontSize,
        largestFontText: largestFontText,
        error: nil
    )
}

// MARK: - Main

let files = findPDFs(in: inputDirs).sorted { a, b in
    if a.baseDir != b.baseDir {
        return a.baseDir < b.baseDir
    }
    return a.url.path < b.url.path
}

var records: [PDFRecord] = []
for file in files {
    // processFile() is defensive internally (optional-binding around PDFKit APIs,
    // no force-unwraps) and returns an `error`-populated record instead of throwing
    // or crashing on a malformed PDF.
    records.append(processFile(file))
}

// Stable sort by relativePath for diffability
records.sort { $0.relativePath < $1.relativePath }

// Write JSON
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
do {
    let data = try encoder.encode(records)
    let outputURL = URL(fileURLWithPath: outputPath)
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: outputURL)
} catch {
    FileHandle.standardError.write("Failed to write output JSON: \(error)\n".data(using: .utf8)!)
    exit(1)
}

// Summary
let total = records.count
let withDOI = records.filter { ($0.detectedDOIs?.isEmpty == false) }.count
let withArxiv = records.filter { ($0.detectedArxivIDs?.isEmpty == false) }.count
let withNeither = records.filter { ($0.detectedDOIs?.isEmpty != false) && ($0.detectedArxivIDs?.isEmpty != false) }.count
let noTextLayer = records.filter { $0.hasTextLayer == false }.count

print("Total PDFs: \(total) | With DOI: \(withDOI) | With arXiv ID: \(withArxiv) | With neither: \(withNeither) | No text layer: \(noTextLayer)")
