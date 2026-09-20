import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

/// The interface in two languages, written side by side in the source.
///
/// Kept inline rather than in a string catalogue for the reason
/// `ReleaseNotes.Text2` gives: the two versions have to be edited together to
/// stay true, and a catalogue puts them in two files where one quietly rots.
/// The cost is that the language is chosen at read time rather than by the
/// system's own bundle lookup — which is what lets a reader override it.
///
/// Korean is written first, always, the way the rest of this project is.
public enum Language {
    public enum Choice: String, CaseIterable, Identifiable, Sendable {
        /// What the system asks for: Korean if the first preferred language is
        /// Korean, English for everything else.
        case system
        case korean
        case english

        public var id: String { rawValue }
    }

    private static let defaultsKey = "language.choice"

    /// What the system asks for, read once. `preferredLanguages` is the
    /// user's ordered list, already narrowed to what the app ships.
    public static let systemPrefersKorean: Bool =
        Locale.preferredLanguages.first?.hasPrefix("ko") ?? false

    /// Read from anywhere — a release note is built outside any actor — and
    /// written only from Settings, on the main thread.
    nonisolated(unsafe) public private(set) static var prefersKorean: Bool =
        resolve(stored)

    nonisolated(unsafe) private static var current: Choice = stored

    /// Main-actor because setting it nudges the view tree. Reading the
    /// resolved answer — `prefersKorean` — is free from anywhere.
    @MainActor
    public static var choice: Choice {
        get { current }
        set {
            guard newValue != current else { return }
            current = newValue
            prefersKorean = resolve(newValue)
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            Switch.shared.generation &+= 1
        }
    }

    private static var stored: Choice {
        UserDefaults.standard.string(forKey: defaultsKey)
            .flatMap(Choice.init(rawValue:)) ?? .system
    }

    private static func resolve(_ choice: Choice) -> Bool {
        switch choice {
        case .system: systemPrefersKorean
        case .korean: true
        case .english: false
        }
    }

    /// Changing the language has to redraw everything, and a plain `static`
    /// cannot tell SwiftUI that. The root view carries `.id(generation)`, so a
    /// bump rebuilds the tree once — which is the honest thing to do when
    /// every string in it has changed.
    @MainActor
    @Observable
    public final class Switch {
        public static let shared = Switch()
        public internal(set) var generation = 0
        private init() {}
    }
}

/// One string, both languages. Korean first.
///
/// ```swift
/// Button(L("완료", "Done")) { … }
/// ```
public func L(_ ko: String, _ en: String) -> String {
    Language.prefersKorean ? ko : en
}

/// The same, for the places that build a whole sentence out of pieces and
/// would otherwise choose the language twice and disagree with themselves.
public func L(_ ko: @autoclosure () -> String, else en: @autoclosure () -> String) -> String {
    Language.prefersKorean ? ko() : en()
}

extension Language.Choice {
    /// Each name in its own language, never translated: a reader looking for
    /// English should not have to read Korean to find it.
    public var title: String {
        switch self {
        case .system: L("시스템에 따라", "Follow System")
        case .korean: "한국어"
        case .english: "English"
        }
    }
}
