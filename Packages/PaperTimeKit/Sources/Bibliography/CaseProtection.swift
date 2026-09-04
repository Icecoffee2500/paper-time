import Foundation

/// Wraps words that must keep their capitalisation in braces.
///
/// Most BibTeX styles lowercase titles. Without protection, "A BERT Study of
/// GANs" is typeset as "A bert study of gans", which is the single most common
/// complaint about exported bibliographies.
public enum CaseProtection {
    /// Protects acronyms and internally capitalised words in a title.
    ///
    /// Applied to the already-escaped LaTeX string, so it must not disturb
    /// commands: a token containing a backslash is left alone.
    public static func protectTitle(_ escaped: String) -> String {
        escaped
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { protectToken(String($0)) }
            .joined(separator: " ")
    }

    private static func protectToken(_ token: String) -> String {
        guard !token.isEmpty else { return token }
        // Leave anything that already contains markup or protection untouched.
        guard !token.contains("\\"), !token.contains("{"), !token.contains("$") else {
            return token
        }

        // Trailing and leading punctuation stays outside the braces so that a
        // protected word at the end of a sentence still renders its period.
        let leading = token.prefix { !$0.isLetter && !$0.isNumber }
        let trailing = token.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed()
        let coreStart = token.index(token.startIndex, offsetBy: leading.count)
        let coreEnd = token.index(token.endIndex, offsetBy: -trailing.count)
        guard coreStart < coreEnd else { return token }
        let core = String(token[coreStart..<coreEnd])

        guard needsProtection(core) else { return token }
        return "\(leading){\(core)}\(String(trailing))"
    }

    /// True when the word carries capitalisation a style would destroy.
    ///
    /// The test is per hyphen-separated part, because "Open-Vocabulary" is
    /// ordinary title case rather than an acronym and does not need braces.
    static func needsProtection(_ word: String) -> Bool {
        for part in word.split(separator: "-") {
            let characters = Array(part)
            guard !characters.isEmpty else { continue }
            // Uppercase anywhere but the first position means BiSeNet, GANs,
            // ResNet50, or an all-caps acronym.
            if characters.dropFirst().contains(where: \.isUppercase) { return true }
            // A leading digit next to a capital: "3D", "2D".
            if characters.count > 1, characters[0].isNumber,
               characters.dropFirst().contains(where: \.isUppercase) {
                return true
            }
        }
        return false
    }
}
