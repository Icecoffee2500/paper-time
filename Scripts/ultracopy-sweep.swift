import Foundation
import PDFKit

/// Reads every formula on every page of every paper it is given, the way
/// Ultracopy reads them, and points at the ones that look wrong.
///
///     swiftc -O App/Model/MathReader.swift App/Model/MathTranscriber.swift \
///       App/Model/PDFContentScanner.swift App/Model/TeXGlyphNames.swift \
///       Scripts/probe-localized.swift Scripts/ultracopy-sweep.swift -o /tmp/sweep
///     /tmp/sweep ~/Documents/Bookends/Attachments            # flags only
///     /tmp/sweep paper.pdf --page 4 --all                    # every formula on a page
///     /tmp/sweep ~/Documents/Bookends/Attachments --fonts    # which fonts each paper draws with
///
/// Nobody can check ten thousand formulas by eye, so the sweep asks each one
/// the questions a wrong reading fails: small glyphs with no script written
/// for them, an empty group, braces that do not close, glyphs that came back
/// as nothing.
@main
struct UltracopySweep {
    struct Reading {
        var page: Int
        var glyphs: [PDFContentScanner.Glyph]
        var context: MathTranscriber.Context?
        var latex: String
    }

    @MainActor
    static func main() {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let all = arguments.contains("--all")
        let fonts = arguments.contains("--fonts")
        var onlyPage: Int?
        if let at = arguments.firstIndex(of: "--page"), at + 1 < arguments.count {
            onlyPage = Int(arguments[at + 1])
            arguments.removeSubrange(at...(at + 1))
        }
        arguments.removeAll { $0.hasPrefix("--") }
        var files: [URL] = []
        for argument in arguments {
            var isDirectory: ObjCBool = false
            let url = URL(fileURLWithPath: argument)
            if FileManager.default.fileExists(atPath: argument, isDirectory: &isDirectory), isDirectory.boolValue {
                let inside = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                files += inside.filter { $0.pathExtension.lowercased() == "pdf" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            } else {
                files.append(url)
            }
        }
        guard !files.isEmpty else {
            print("usage: ultracopy-sweep <pdf or folder>… [--page N] [--all] [--fonts]")
            exit(2)
        }

        var totals: [String: Int] = [:]
        var read = 0
        for file in files {
            guard let document = PDFDocument(url: file) else { print("!! cannot open \(file.lastPathComponent)"); continue }
            let name = file.lastPathComponent
            if fonts {
                var families: [String: Int] = [:]
                for index in 0..<document.pageCount {
                    guard let page = document.page(at: index), let reference = page.pageRef else { continue }
                    for glyph in PDFContentScanner.scan(page: reference).glyphs {
                        let family = glyph.fontName.split(separator: "+").last.map(String.init) ?? glyph.fontName
                        families[family, default: 0] += 1
                    }
                }
                let listed = families.sorted { $0.value > $1.value }.map { "\($0.key):\($0.value)" }
                print("\(name): \(listed.joined(separator: " "))")
                continue
            }
            let pages = onlyPage.map { [$0 - 1] } ?? Array(0..<document.pageCount)
            for index in pages {
                guard let page = document.page(at: index) else { continue }
                let box = page.bounds(for: .cropBox)
                guard let selection = page.selection(for: box) else { continue }
                var readings: [Reading] = []
                MathTranscriber.observer = { glyphs, context, latex in
                    readings.append(Reading(page: index + 1, glyphs: glyphs, context: context, latex: latex))
                }
                _ = MathReader.pieces(from: selection)
                MathTranscriber.observer = nil
                for reading in readings {
                    read += 1
                    let flags = flags(of: reading)
                    for flag in flags { totals[flag, default: 0] += 1 }
                    if all || !flags.isEmpty {
                        let tag = flags.isEmpty ? "ok" : flags.joined(separator: ",")
                        print("\(name) p\(reading.page) [\(tag)] \(reading.latex)")
                        if !flags.isEmpty || all { print("    " + describe(reading)) }
                    }
                }
            }
        }
        if !fonts {
            let summary = totals.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            print("— \(read) formulas read; flagged: \(summary.isEmpty ? "none" : summary)")
        }
    }

    /// What is suspicious about a reading. Empty when nothing is.
    static func flags(of reading: Reading) -> [String] {
        var flags: [String] = []
        let latex = reading.latex
        let glyphs = reading.glyphs
        let body = reading.context?.bodySize ?? MathTranscriber.size(of: glyphs)
        let baseline = reading.context?.baseline ?? median(glyphs.filter { $0.size >= body * 0.92 }.map(\.origin.y)) ?? 0
        // Small glyphs that spell something, off the line or not: a script
        // was drawn, so a script must have been written.
        let small = glyphs.filter { glyph in
            guard !glyph.isExtension, glyph.size < body * 0.85 else { return false }
            let spelled = MathTranscriber.spelling(of: glyph)
            return spelled.count == 1 && (spelled.first!.isLetter || spelled.first!.isNumber)
        }
        let hasScript = latex.contains("_") || latex.contains("^") || latex.contains("\\frac")
        if !small.isEmpty, !hasScript { flags.append("noscript") }
        // A script that is bigger than it should be: written as a script but
        // sitting on the line at full size is a different mistake (rare), so
        // only the other way round is asked.
        if latex.contains("{}") || latex.hasSuffix("_") || latex.hasSuffix("^") || latex.contains("_}") || latex.contains("^}") { flags.append("empty") }
        var depth = 0
        var unbalanced = false
        var previous: Character = " "
        for character in latex {
            if character == "{", previous != "\\" { depth += 1 }
            if character == "}", previous != "\\" { depth -= 1; if depth < 0 { unbalanced = true } }
            previous = character
        }
        if depth != 0 || unbalanced { flags.append("braces") }
        let unread = glyphs.filter { MathTranscriber.spelling(of: $0).isEmpty && !MathTranscriber.isSpace($0) }.count
        if unread * 5 > glyphs.count, glyphs.count >= 2 { flags.append("unread") }
        if latex.contains("\u{FFFD}") { flags.append("fffd") }
        // A full-size glyph well off the baseline that was not written as a
        // script or a limit: something raised the reader did not see.
        let lifted = glyphs.filter { glyph in
            !glyph.isExtension && glyph.size >= body * 0.92 && abs(glyph.origin.y - baseline) > body * 0.45
        }
        if lifted.count > 0, lifted.count * 3 < glyphs.count, !latex.contains("\\frac"), !latex.contains("^"), !latex.contains("_") {
            flags.append("lifted")
        }
        return flags
    }

    static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// The glyphs, one per column: spelling, size, and height above the baseline.
    static func describe(_ reading: Reading) -> String {
        let glyphs = reading.glyphs
        let body = reading.context?.bodySize ?? MathTranscriber.size(of: glyphs)
        let baseline = reading.context?.baseline ?? median(glyphs.filter { $0.size >= body * 0.92 }.map(\.origin.y)) ?? 0
        let fonts = Set(glyphs.map { $0.fontName.split(separator: "+").last.map(String.init) ?? $0.fontName })
        let columns = glyphs.prefix(40).map { glyph -> String in
            let spelled = MathTranscriber.spelling(of: glyph)
            let shown = spelled.isEmpty ? "·\(glyph.glyphName ?? "?")" : spelled
            return String(format: "%@%.1f@%+.1f", shown, glyph.size, glyph.origin.y - baseline)
        }
        return String(format: "body %.1f fonts %@ | %@%@", body, fonts.sorted().joined(separator: ","),
                      columns.joined(separator: " "), glyphs.count > 40 ? " …" : "")
    }
}
