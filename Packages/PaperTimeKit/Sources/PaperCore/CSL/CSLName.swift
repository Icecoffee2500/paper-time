import Foundation

/// A CSL-JSON name object (author, editor, translator).
///
/// Either the structured `family`/`given` pair is present, or `literal` is used
/// for institutional authors ("The MITRE Corporation").
public struct CSLName: Codable, Hashable, Sendable {
    public var family: String?
    public var given: String?
    public var literal: String?
    public var suffix: String?
    public var droppingParticle: String?
    public var nonDroppingParticle: String?

    public init(
        family: String? = nil,
        given: String? = nil,
        literal: String? = nil,
        suffix: String? = nil,
        droppingParticle: String? = nil,
        nonDroppingParticle: String? = nil
    ) {
        self.family = family
        self.given = given
        self.literal = literal
        self.suffix = suffix
        self.droppingParticle = droppingParticle
        self.nonDroppingParticle = nonDroppingParticle
    }

    private enum CodingKeys: String, CodingKey {
        case family, given, literal, suffix
        case droppingParticle = "dropping-particle"
        case nonDroppingParticle = "non-dropping-particle"
    }

    /// True when the name carries no usable content.
    public var isEmpty: Bool {
        (family?.isEmpty ?? true) && (given?.isEmpty ?? true) && (literal?.isEmpty ?? true)
    }

    /// The surname used for citation keys and for verifying an API match.
    /// Institutional names fall back to their first word.
    public var sortingSurname: String? {
        if let family, !family.isEmpty {
            if let particle = nonDroppingParticle, !particle.isEmpty {
                return "\(particle) \(family)"
            }
            return family
        }
        if let literal, !literal.isEmpty {
            return literal
        }
        return nil
    }

    /// "Given Family" for display.
    public var displayName: String {
        if let literal, !literal.isEmpty { return literal }
        let particle = [nonDroppingParticle, family].compactMap { $0 }.filter { !$0.isEmpty }
        let tail = particle.joined(separator: " ")
        let head = given?.isEmpty == false ? given! : nil
        let core = [head, tail.isEmpty ? nil : tail].compactMap { $0 }.joined(separator: " ")
        if let suffix, !suffix.isEmpty { return "\(core), \(suffix)" }
        return core
    }

    /// Parses "Family, Given" or "Given Family" into a structured name.
    ///
    /// Used when importing BibTeX/RIS and when reading names out of a PDF's
    /// first page, where only free text is available.
    public static func parse(_ raw: String) -> CSLName {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return CSLName() }

        if let comma = trimmed.firstIndex(of: ",") {
            let family = String(trimmed[trimmed.startIndex..<comma])
                .trimmingCharacters(in: .whitespaces)
            let rest = String(trimmed[trimmed.index(after: comma)...])
                .trimmingCharacters(in: .whitespaces)
            // "Family, Given, Jr." -> suffix in the third component.
            let parts = rest.split(separator: ",", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            return CSLName(
                family: family,
                given: parts.first.flatMap { $0.isEmpty ? nil : $0 },
                suffix: parts.count > 1 ? parts[1] : nil
            )
        }

        let words = trimmed.split(separator: " ").map(String.init)
        guard words.count > 1 else { return CSLName(family: trimmed) }
        return CSLName(
            family: words.last,
            given: words.dropLast().joined(separator: " ")
        )
    }
}
