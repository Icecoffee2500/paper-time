import Foundation

/// A CSL-JSON date object.
///
/// Only `date-parts` is authoritative; `raw` and `literal` are preserved so a
/// record imported from BibTeX keeps whatever the source actually said.
public struct CSLDate: Codable, Hashable, Sendable {
    /// `[[year, month, day]]` — month and day optional. CSL also allows a
    /// second element for ranges, which Paper Time preserves but never writes.
    public var dateParts: [[Int]]?
    public var raw: String?
    public var literal: String?

    public init(dateParts: [[Int]]? = nil, raw: String? = nil, literal: String? = nil) {
        self.dateParts = dateParts
        self.raw = raw
        self.literal = literal
    }

    public init(year: Int, month: Int? = nil, day: Int? = nil) {
        var parts = [year]
        if let month { parts.append(month) }
        if let month, let day { _ = month; parts.append(day) }
        self.dateParts = [parts]
    }

    private enum CodingKeys: String, CodingKey {
        case dateParts = "date-parts"
        case raw, literal
    }

    public var year: Int? {
        if let value = dateParts?.first?.first { return value }
        // Fall back to the first 4-digit run in the free text forms.
        for candidate in [raw, literal].compactMap({ $0 }) {
            if let year = Self.firstYear(in: candidate) { return year }
        }
        return nil
    }

    public var month: Int? {
        guard let parts = dateParts?.first, parts.count > 1 else { return nil }
        return parts[1]
    }

    public static func firstYear(in text: String) -> Int? {
        var digits = ""
        for character in text {
            if character.isNumber {
                digits.append(character)
                if digits.count == 4 {
                    if let value = Int(digits), (1500...2200).contains(value) { return value }
                    digits.removeFirst()
                }
            } else {
                digits = ""
            }
        }
        return nil
    }
}
