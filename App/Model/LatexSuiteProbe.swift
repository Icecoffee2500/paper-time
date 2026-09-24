import Foundation
import PaperCore

/// Proves the Latex Suite engine works inside the app — that its snippet file
/// made it into PaperCore's resource bundle in this build, not only in
/// `swift test` — and quits: `--papertime-latex-suite=1`.
///
/// The engine is not in any editor yet, so this is the one place the app
/// target touches it. It types a few keystrokes into a note held in memory
/// and prints what came out; nothing is opened or written.
enum LatexSuiteProbe {
    static func run() {
        print("latex suite \(LatexSuite.version): \(LatexSuite.snippetCount) snippets")
        let engine = LatexSuite.Engine()
        for (marked, keys) in [("$|$", "@a"), ("$x|$", "/"), ("$|$", "//"), ("$x|$", "sr"), ("text |", "dm")] {
            var text = marked.replacingOccurrences(of: "|", with: "")
            var selection = [NSRange(location: (marked as NSString).range(of: "|").location, length: 0)]
            var tabstops = LatexSuite.Tabstops.none
            for key in keys.map(String.init) {
                if let edit = engine.handle(.text(key), text: text, selection: selection, tabstops: tabstops) {
                    let storage = NSMutableString(string: text)
                    for change in edit.changes.reversed() { storage.replaceCharacters(in: change.range, with: change.text) }
                    text = storage as String
                    selection = edit.selection
                    tabstops = edit.tabstops
                } else {
                    let change = LatexSuite.Change(range: selection[0], text: key)
                    text = (text as NSString).replacingCharacters(in: change.range, with: key)
                    selection = [NSRange(location: selection[0].location + (key as NSString).length, length: 0)]
                    tabstops = tabstops.afterEdit([change], selection: selection)
                }
            }
            let shown = (text as NSString).replacingCharacters(in: NSRange(location: selection[0].location, length: 0), with: "|")
            print("  \(marked.debugDescription) + \(keys.debugDescription) → \(shown.debugDescription)"
                + (tabstops.isActive ? " (\(tabstops.groups.count) tabstops)" : ""))
        }
        exit(0)
    }
}
