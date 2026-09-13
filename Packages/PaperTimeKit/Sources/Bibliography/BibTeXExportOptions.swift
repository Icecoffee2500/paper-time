import Foundation

/// How a `.bib` file should be written.
///
/// Defaults are chosen for the workflow this app was built for: a file the user
/// drags into Overleaf, compiled with a normal LaTeX template.
public struct BibTeXExportOptions: Hashable, Sendable, Codable {
    /// How to represent a paper that only exists as an arXiv preprint.
    public enum PreprintStyle: String, Hashable, Sendable, Codable, CaseIterable {
        /// `@misc` with `eprint`, `archivePrefix`, `primaryClass`. Understood by
        /// biblatex and by the arXiv-aware BibTeX styles.
        case eprint
        /// `@article` with `journal = {arXiv preprint arXiv:2403.18293}`. Ugly,
        /// but every plain BibTeX style renders it without extra packages.
        case arxivPreprintArticle

        public var displayName: String {
            switch self {
            case .eprint: "eprint fields (biblatex)"
            case .arxivPreprintArticle: "arXiv preprint (plain BibTeX)"
            }
        }
    }

    public var preprintStyle: PreprintStyle
    /// Protect acronyms with braces so styles cannot lowercase them.
    public var protectCase: Bool
    /// Prefer the abbreviated journal name when the record has one.
    public var abbreviateJournals: Bool
    public var includeAbstract: Bool
    public var includeKeywords: Bool
    public var includeFileField: Bool
    public var includeURL: Bool
    /// Emit records whose metadata has not been verified.
    public var includeUnverified: Bool
    /// A header comment naming the app and the export date.
    public var includeHeader: Bool

    public init(
        preprintStyle: PreprintStyle = .eprint,
        protectCase: Bool = true,
        abbreviateJournals: Bool = false,
        includeAbstract: Bool = false,
        includeKeywords: Bool = false,
        includeFileField: Bool = false,
        includeURL: Bool = true,
        includeUnverified: Bool = false,
        includeHeader: Bool = true
    ) {
        self.preprintStyle = preprintStyle
        self.protectCase = protectCase
        self.abbreviateJournals = abbreviateJournals
        self.includeAbstract = includeAbstract
        self.includeKeywords = includeKeywords
        self.includeFileField = includeFileField
        self.includeURL = includeURL
        self.includeUnverified = includeUnverified
        self.includeHeader = includeHeader
    }

    public static let `default` = BibTeXExportOptions()
}
