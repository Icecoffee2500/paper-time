import Foundation
import PDFKit

/// Checks the search-by-meaning tokenizer against Hugging Face's on more
/// text than a fixture can hold, and measures what the chunker makes of real
/// papers — without building the package or opening the app.
///
///     swiftc -O Packages/PaperTimeKit/Sources/Semantic/WordPieceTokenizer.swift \
///       Packages/PaperTimeKit/Sources/Semantic/SemanticChunker.swift \
///       Scripts/wordpiece-probe.swift -o /tmp/wordpiece
///
///     /tmp/wordpiece dump <out.json> <pdf or folder>…     passages cut from real pages
///     <venv>/bin/python Scripts/wordpiece-sweep.py texts <out.json> <ids.json>
///     /tmp/wordpiece compare <ids.json>                   id for id, and how often 256 cuts
///
/// `wordpiece-sweep.py codepoints` makes an `ids.json` of every code point
/// instead, which is how the tokenizer's Unicode rules were pinned.
@main
struct WordPieceProbe {
    static let vocabulary = URL(fileURLWithPath: "Packages/PaperTimeKit/Sources/Semantic/Resources/vocab.txt")

    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let mode = arguments.first else { usage() }
        switch mode {
        case "dump" where arguments.count >= 3:
            try dump(to: URL(fileURLWithPath: arguments[1]), from: arguments.dropFirst(2).map(URL.init(fileURLWithPath:)))
        case "compare" where arguments.count == 2:
            try compare(URL(fileURLWithPath: arguments[1]))
        default:
            usage()
        }
    }

    static func usage() -> Never {
        print("usage: wordpiece-probe dump <out.json> <pdf|folder>… | compare <ids.json>")
        exit(2)
    }

    static func pdfs(in urls: [URL]) -> [URL] {
        urls.flatMap { url -> [URL] in
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return [] }
            guard isFolder.boolValue else { return url.pathExtension.lowercased() == "pdf" ? [url] : [] }
            let found = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "pdf" } ?? []
            return found.sorted { $0.path < $1.path }
        }
    }

    static func dump(to out: URL, from inputs: [URL]) throws {
        var texts: [String] = []
        var pages = 0
        let files = pdfs(in: inputs)
        for file in files {
            guard let document = PDFDocument(url: file) else { continue }
            let paper = UUID()
            for index in 0..<document.pageCount {
                guard let text = document.page(at: index)?.string else { continue }
                pages += 1
                texts += SemanticChunker.chunks(ofPage: text, paperID: paper, pageIndex: index).map(\.text)
            }
        }
        try JSONEncoder().encode(texts).write(to: out)
        print("\(files.count) PDFs, \(pages) pages, \(texts.count) passages -> \(out.path)")
    }

    struct Cases: Decodable { var cases: [Case] }
    struct Case: Decodable {
        var text: String
        var ids: [Int32]
        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            text = try container.decode(String.self)
            ids = try container.decode([Int32].self)
        }
    }

    static func compare(_ url: URL) throws {
        let tokenizer = try WordPieceTokenizer(contentsOf: vocabulary)
        let cases = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: url)).cases
        var wrong = 0
        var cut = 0
        var lengths: [Int] = []
        let start = Date()
        for item in cases {
            let ids = tokenizer.encode(item.text)
            lengths.append(tokenizer.pieces(of: item.text).count + 2)
            if lengths.last! > WordPieceTokenizer.maxLength { cut += 1 }
            guard ids != item.ids else { continue }
            wrong += 1
            if ProcessInfo.processInfo.environment["WORDPIECE_ALL"] != nil {
                let scalar = item.text.unicodeScalars.dropFirst(item.text.unicodeScalars.count == 3 ? 1 : 0).first!
                print(String(format: "U+%04X", scalar.value), scalar.properties.generalCategory,
                      scalar.properties.age.map { "\($0.major).\($0.minor)" } ?? "-", item.text.debugDescription,
                      "swift", ids, "hf", item.ids)
            } else if wrong <= 25 {
                let points = item.text.unicodeScalars.prefix(12).map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
                print("differs: \(item.text.prefix(60).debugDescription) [\(points)]\n  swift \(ids.prefix(16))\n  hf    \(item.ids.prefix(16))")
            }
        }
        let seconds = Date().timeIntervalSince(start)
        lengths.sort()
        print("\(cases.count) texts, \(wrong) differ (\(String(format: "%.4f", Double(wrong) / Double(max(cases.count, 1)) * 100))%) · "
              + "\(cut) longer than 256 ids (\(String(format: "%.1f", Double(cut) / Double(max(cases.count, 1)) * 100))%) · "
              + "median \(lengths[lengths.count / 2]) ids, 95th \(lengths[lengths.count * 95 / 100]) · "
              + String(format: "%.1f s", seconds))
    }
}
