#if os(macOS)
import CryptoKit
import Foundation
import JavaScriptCore

/// MathJax, running in JavaScriptCore: the engine the Portable build sets its
/// formulas with, so a note set on a Mac and on a PC is the same note.
///
/// The bundle is `App/Resources/MathJax.js` (`Scripts/mathjax-bundle.sh`),
/// which is the Portable build's own setter (`Portable/src/shared/mathJax.ts`)
/// with MathJax inside it. A context is not safe on two threads at once, so
/// everything goes through one queue; the calls are quick — a formula is a
/// millisecond or two — and a note needs its formulas before it can be laid
/// out, so they are made synchronously.
final class MathJaxEngine: @unchecked Sendable {
    static let shared = MathJaxEngine()

    /// A formula as MathJax set it.
    struct Formula: Sendable {
        var svg: String
        /// The count after this formula: what the next one starts from.
        var next: Int
        /// The labels it wrote, and the numbers they stand for.
        var labels: [String: String]
    }

    /// What a formula of a note is set with, once the note is counted.
    struct Numbered: Sendable, Equatable {
        var start: Int
        var known: [String: String]
    }

    private let queue = DispatchQueue(label: "com.imtaeheon.PaperTime.mathjax", qos: .userInitiated)
    private var context: JSContext?
    private var render: JSValue?
    private var number: JSValue?
    /// Set once loading failed, so a missing bundle is looked for once.
    private var unavailable = false

    /// Loads MathJax off the main thread, so the first note with a formula in
    /// it does not wait the tenth of a second that takes.
    func prewarm() {
        queue.async { _ = self.loaded() }
    }

    /// Whether MathJax is there to set with. When it is not — a build without
    /// the bundle — the Mac's own typesetter sets what it can.
    var isAvailable: Bool {
        queue.sync { loaded() }
    }

    /// A formula, set. Nil when MathJax cannot set it. `width` is the room
    /// it has, in MathJax's pixels; only a `multline` or a `flalign` reads it.
    func set(_ latex: String, display: Bool, start: Int = 0, known: [String: String] = [:],
             width: CGFloat? = nil) -> Formula? {
        queue.sync {
            guard loaded(), let render else { return nil }
            let labels = Self.json(known) ?? "{}"
            let room = width.map { Double($0) } ?? 0
            guard let answer = render.call(withArguments: [latex, display, start, labels, room])?.toString(),
                  !answer.isEmpty, let data = answer.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let svg = object["svg"] as? String
            else { return nil }
            let next = (object["next"] as? NSNumber)?.intValue ?? start
            let written = (object["labels"] as? [String: Any] ?? [:]).mapValues { "\($0)" }
            return Formula(svg: svg, next: next, labels: written)
        }
    }

    /// A note's formulas counted from the top: for each, in order, the count
    /// it starts from and the labels it refers to.
    func number(_ formulas: [(latex: String, display: Bool)]) -> [Numbered]? {
        queue.sync {
            guard loaded(), let number else { return nil }
            let list = formulas.map { ["latex": $0.latex, "display": $0.display] as [String: Any] }
            guard let request = Self.json(list),
                  let answer = number.call(withArguments: [request])?.toString(),
                  !answer.isEmpty, let data = answer.data(using: .utf8),
                  let steps = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  steps.count == formulas.count
            else { return nil }
            return steps.map { step in
                Numbered(start: (step["start"] as? NSNumber)?.intValue ?? 0,
                         known: (step["known"] as? [String: Any] ?? [:]).mapValues { "\($0)" })
            }
        }
    }

    /// On the queue.
    private func loaded() -> Bool {
        if render != nil { return true }
        if unavailable { return false }
        guard let url = Bundle.main.url(forResource: "MathJax", withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8),
              let made = JSContext()
        else {
            unavailable = true
            return false
        }
        var failure: String?
        made.exceptionHandler = { _, exception in failure = exception?.toString() }
        // Where what was set is kept between runs — see `Shelf`.
        if let shelf = Shelf.make(for: script) {
            let get: @convention(block) (String) -> String? = { shelf.read($0) }
            let put: @convention(block) (String, String) -> Void = { shelf.write($0, $1) }
            if let store = JSValue(newObjectIn: made) {
                store.setObject(get, forKeyedSubscript: "get" as NSString)
                store.setObject(put, forKeyedSubscript: "set" as NSString)
                made.setObject(store, forKeyedSubscript: "PaperTimeStore" as NSString)
            }
        }
        Trace.time("math: load MathJax") {
            made.evaluateScript(script, withSourceURL: url)
        }
        let math = made.objectForKeyedSubscript("PaperTimeMath")
        guard failure == nil, let math, !math.isUndefined,
              let render = math.objectForKeyedSubscript("render"), !render.isUndefined,
              let number = math.objectForKeyedSubscript("number"), !number.isUndefined
        else {
            FileHandle.standardError.write(Data("math: MathJax did not load: \(failure ?? "no PaperTimeMath")\n".utf8))
            unavailable = true
            return false
        }
        // A throw after loading is MathJax's own and already answered as "";
        // nothing is printed for each half-typed formula.
        made.exceptionHandler = { _, _ in }
        context = made
        self.render = render
        self.number = number
        return true
    }

    /// What MathJax set, kept on disk, so a note opened again — the next day,
    /// after a restart — is not set again: setting is two milliseconds a
    /// formula, and reading one back is a twentieth of that.
    ///
    /// A file a formula, named for the setter's own key, in the app's caches
    /// under the bundle's fingerprint: a new MathJax sets everything afresh,
    /// and the old bundle's folder is cleared away. A probe keeps nothing
    /// unless it is given a folder (`--papertime-math-cache=`) — it shares
    /// the caches with the copy somebody uses.
    private final class Shelf: @unchecked Sendable {
        let folder: URL

        init(folder: URL) { self.folder = folder }

        static func make(for script: String) -> Shelf? {
            let fingerprint = SHA256.hash(data: Data(script.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
            let root: URL
            if let chosen = Boot.setting("PAPERTIME_MATH_CACHE") {
                root = URL(fileURLWithPath: chosen, isDirectory: true)
            } else if Boot.setting("PAPERTIME_LIBRARY") != nil {
                return nil
            } else {
                guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                else { return nil }
                root = caches.appendingPathComponent("MathJax", isDirectory: true)
            }
            let folder = root.appendingPathComponent(fingerprint, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Another bundle's formulas are never read again.
            for old in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            where old.lastPathComponent != fingerprint {
                try? FileManager.default.removeItem(at: old)
            }
            return Shelf(folder: folder)
        }

        private func file(for key: String) -> URL {
            let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
            return folder.appendingPathComponent(String(name.prefix(2)), isDirectory: true)
                .appendingPathComponent(name + ".json")
        }

        func read(_ key: String) -> String? {
            try? String(contentsOf: file(for: key), encoding: .utf8)
        }

        func write(_ key: String, _ value: String) {
            let url = file(for: key)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(value.utf8).write(to: url, options: .atomic)
        }
    }

    private static func json(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
#endif
