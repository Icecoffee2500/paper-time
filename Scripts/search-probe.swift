import Foundation

/// Searches a folder of PDFs the way the palette does, and prints what it
/// found — the index without the app around it.
///
///     swiftc -O App/Model/PaperTextIndex.swift Scripts/search-probe.swift -o /tmp/probe
///     /tmp/probe unlearning ~/Documents/Bookends/Attachments
///
/// The note editor and the palette are both several panes deep and neither
/// answers a synthetic click, so this is how "does it find the word, and does
/// it find the right characters?" gets answered without a window.
@main
struct SearchProbe {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else {
            print("usage: probe <query> <folder>")
            exit(2)
        }
        let query = arguments[1]
        let folder = URL(fileURLWithPath: (arguments[2] as NSString).expandingTildeInPath)

        let files = (try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        ))
        .filter { $0.pathExtension.lowercased() == "pdf" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let sources = files.map {
            PaperTextIndex.Source(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000000") ?? UUID(),
                url: $0, title: $0.deletingPathExtension().lastPathComponent
            )
        }
        .enumerated()
        .map { index, source -> PaperTextIndex.Source in
            var source = source
            source.id = UUID(uuidString: String(format: "%08x-0000-0000-0000-000000000000", index))
                ?? UUID()
            return source
        }

        print("— \(sources.count) papers, looking for “\(query)”")
        let started = Date.now
        let index = PaperTextIndex.shared
        var found = 0
        for await hit in index.hits(for: query, in: sources) {
            found += 1
            print("""
                  \(hit.title.prefix(56))
                      p.\(hit.passage.pageIndex + 1) · \(hit.count) × · chars \(hit.passage.location)…\(hit.passage.location + hit.passage.length)
                      \(hit.snippet)
                  """)
            if let rect = await index.rect(for: hit.passage, at: sources.first { $0.id == hit.passage.paperID }!.url) {
                print("      rect \(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height))")
            } else {
                print("      rect — NOT FOUND")
            }
        }
        print("— \(found) papers in \(String(format: "%.1f", Date.now.timeIntervalSince(started)))s")
    }
}
