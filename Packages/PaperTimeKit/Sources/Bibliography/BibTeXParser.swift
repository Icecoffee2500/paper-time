import Foundation

/// A hand-written character scanner for `.bib` files.
///
/// BibTeX's grammar is small but irregular - bare tokens, brace-balanced
/// values, quoted values that themselves contain balanced braces, `@string`
/// macros, `#` concatenation - so a scanner reads more clearly here than a
/// regular expression would, and it is the only way to keep nested-brace
/// values (`title = {A {BERT} Study}`) intact.
public enum BibTeXParser {
    public struct ParseResult: Sendable {
        public var entries: [BibTeXEntry]
        public var warnings: [String]

        public init(entries: [BibTeXEntry] = [], warnings: [String] = []) {
            self.entries = entries
            self.warnings = warnings
        }
    }

    public static func parse(_ source: String) -> ParseResult {
        let chars = Array(source)
        let n = chars.count
        var i = 0
        var entries: [BibTeXEntry] = []
        var warnings: [String] = []
        // `@string` macro names are case-insensitive in BibTeX, so the table
        // key is always lowercased.
        var stringTable: [String: String] = [:]

        // Bare BibTeX tokens (entry types, keys, macro names, unquoted
        // numbers) run until whitespace or one of the grammar's own
        // punctuation characters - never braces, since those always start a
        // balanced group instead of being part of the token itself.
        func isIdentChar(_ c: Character) -> Bool {
            !c.isWhitespace && !"{}(),=#\"@".contains(c)
        }

        func skipWhitespace() {
            while i < n, chars[i].isWhitespace { i += 1 }
        }

        func readWhile(_ predicate: (Character) -> Bool) -> String {
            var s = ""
            while i < n, predicate(chars[i]) {
                s.append(chars[i])
                i += 1
            }
            return s
        }

        // Reads a brace-balanced `{...}` value with `i` positioned at the
        // opening brace. The outer pair is consumed; inner braces are kept
        // in the returned text so `{A {BERT} Study}` round-trips intact.
        // Returns nil - and leaves `i` at end of input - if the braces never
        // close, so the caller can turn that into a warning instead of
        // scanning forever.
        func readBracedRaw() -> String? {
            guard i < n, chars[i] == "{" else { return nil }
            i += 1
            var depth = 1
            var s = ""
            while i < n {
                let c = chars[i]
                if c == "{" {
                    depth += 1
                    s.append(c)
                } else if c == "}" {
                    depth -= 1
                    i += 1
                    if depth == 0 { return s }
                    s.append(c)
                    continue
                } else {
                    s.append(c)
                }
                i += 1
            }
            return nil
        }

        // Reads a `"..."` value with `i` at the opening quote. Braces inside
        // are tracked only so a quote nested inside a brace group (rare, but
        // legal - `"a \"depth-protected\" {"} title"`-style content some
        // tools emit) doesn't end the value early; they don't need to
        // balance against anything outside the quotes.
        func readQuotedRaw() -> String? {
            guard i < n, chars[i] == "\"" else { return nil }
            i += 1
            var depth = 0
            var s = ""
            while i < n {
                let c = chars[i]
                if c == "{" {
                    depth += 1
                    s.append(c)
                } else if c == "}" {
                    depth -= 1
                    s.append(c)
                } else if c == "\"", depth == 0 {
                    i += 1
                    return s
                } else {
                    s.append(c)
                }
                i += 1
            }
            return nil
        }

        // BibTeX line-wraps long field values; a run of whitespace
        // (including newlines) inside a value is not meaningful and becomes
        // a single space.
        func collapseWhitespace(_ s: String) -> String {
            var result = ""
            result.reserveCapacity(s.count)
            var lastWasSpace = false
            for c in s {
                if c.isWhitespace {
                    if !lastWasSpace { result.append(" ") }
                    lastWasSpace = true
                } else {
                    result.append(c)
                    lastWasSpace = false
                }
            }
            return result.trimmingCharacters(in: .whitespaces)
        }

        func expandMacro(_ token: String) -> String {
            stringTable[token.lowercased()] ?? token
        }

        // Reads one `#`-concatenated field value - `{...}` / `"..."` /
        // bareword pieces joined with no separator, each bareword expanded
        // against `stringTable` first (so `"Proc. " # acl` becomes one
        // string). Returns nil on truncated input.
        func readValue() -> String? {
            var pieces: [String] = []
            while true {
                skipWhitespace()
                guard i < n else { return nil }
                if chars[i] == "{" {
                    guard let raw = readBracedRaw() else { return nil }
                    pieces.append(raw)
                } else if chars[i] == "\"" {
                    guard let raw = readQuotedRaw() else { return nil }
                    pieces.append(raw)
                } else {
                    let token = readWhile(isIdentChar)
                    guard !token.isEmpty else { return nil } // malformed; avoid spinning in place
                    pieces.append(expandMacro(token))
                }
                skipWhitespace()
                if i < n, chars[i] == "#" {
                    i += 1
                    continue
                }
                break
            }
            return collapseWhitespace(pieces.joined())
        }

        // Consumes through the closing brace of the current `@...{ ... }`
        // block, called with `i` already one level inside (right after the
        // block's own opening brace was consumed). Every value reader above
        // leaves braces balanced or bails out entirely, so at any point
        // between fields the true nesting depth relative to that opening
        // brace is exactly 1 - which is what lets this same helper double as
        // both the normal close-out for `@comment`/`@preamble`/`@string` and
        // the error-recovery path for a malformed entry.
        func skipBalancedBody(context: String) {
            var depth = 1
            while i < n {
                let c = chars[i]
                if c == "{" {
                    depth += 1
                } else if c == "}" {
                    depth -= 1
                    if depth == 0 {
                        i += 1
                        return
                    }
                }
                i += 1
            }
            warnings.append("Unterminated \(context): input ended before its closing brace")
        }

        // `BibTeXEntry.EntryType` is a closed enum with no "unknown" case, so
        // every raw `@type` word - including common aliases real exporters
        // use - has to land somewhere. Anything genuinely unrecognized is
        // reported and treated as `.misc`, which keeps parsing best-effort
        // rather than dropping the entry.
        func mapType(_ raw: String, key: String) -> BibTeXEntry.EntryType {
            if let known = BibTeXEntry.EntryType(rawValue: raw) { return known }
            switch raw {
            case "conference": return .inproceedings
            case "electronic", "www": return .online
            case "collection": return .book
            case "proceedings", "manual", "booklet", "periodical": return .misc
            default:
                warnings.append("Unknown entry type '@\(raw)' for key '\(key)'; treated as misc")
                return .misc
            }
        }

        func parseStringDef() {
            skipWhitespace()
            let name = readWhile(isIdentChar)
            skipWhitespace()
            guard i < n, chars[i] == "=" else {
                warnings.append("Malformed @string definition (missing '=')")
                skipBalancedBody(context: "@string")
                return
            }
            i += 1
            guard let value = readValue() else {
                let label = name.isEmpty ? "" : " for '\(name)'"
                warnings.append("Truncated @string definition\(label); input ended before it closed")
                return
            }
            if !name.isEmpty { stringTable[name.lowercased()] = value }
            // Consumes any trailing comma/whitespace up to the block's own
            // closing brace, well-formed or not.
            skipBalancedBody(context: "@string")
        }

        func parseEntry(rawType: String) {
            skipWhitespace()
            let key = readWhile(isIdentChar)
            let type = mapType(rawType, key: key.isEmpty ? "<no key>" : key)

            skipWhitespace()
            if i < n, chars[i] == "," {
                i += 1
            } else if i < n, chars[i] == "}" {
                i += 1
                entries.append(BibTeXEntry(type: type, key: key, fields: []))
                return
            }
            // Otherwise malformed (no comma and no immediate close) - fall
            // through and let the field loop's own truncation/recovery
            // handling take it from here.

            var fields: [BibTeXEntry.Field] = []
            var seenNames: Set<String> = []

            // A field loop reaching true end-of-input (no closing brace ever
            // found) means this entry never finished, so - unlike the
            // mid-file malformations below, which can always find the
            // entry's closing brace and recover - there's nothing sound to
            // append. Only a warning is recorded and the partial entry is
            // discarded; entries already appended before this one are kept.
            fieldLoop: while true {
                skipWhitespace()
                guard i < n else {
                    warnings.append("Entry '\(key)' truncated at end of file; discarding incomplete entry")
                    return
                }
                if chars[i] == "}" {
                    i += 1
                    break fieldLoop
                }
                if chars[i] == "," {
                    // A trailing comma before the closing brace, or a stray
                    // extra one - either way there's no field here.
                    i += 1
                    continue fieldLoop
                }

                let fname = readWhile(isIdentChar)
                guard !fname.isEmpty else {
                    warnings.append("Malformed field in entry '\(key)'; skipping to next entry")
                    entries.append(BibTeXEntry(type: type, key: key, fields: fields))
                    skipBalancedBody(context: "entry '\(key)'")
                    return
                }

                skipWhitespace()
                guard i < n, chars[i] == "=" else {
                    warnings.append("Field '\(fname)' in entry '\(key)' is missing '='; skipping to next entry")
                    entries.append(BibTeXEntry(type: type, key: key, fields: fields))
                    skipBalancedBody(context: "entry '\(key)'")
                    return
                }
                i += 1

                guard let rawValue = readValue() else {
                    warnings.append("Entry '\(key)' truncated while reading field '\(fname)'; discarding incomplete entry")
                    return
                }

                let lname = fname.lowercased()
                if seenNames.contains(lname) {
                    warnings.append("Duplicate field '\(lname)' in entry '\(key)'; keeping first occurrence")
                } else {
                    seenNames.insert(lname)
                    fields.append(BibTeXEntry.Field(name: lname, value: rawValue))
                }

                skipWhitespace()
                if i < n, chars[i] == "," {
                    i += 1
                    continue fieldLoop
                } else if i < n, chars[i] == "}" {
                    i += 1
                    break fieldLoop
                } else if i >= n {
                    warnings.append("Entry '\(key)' truncated at end of file; discarding incomplete entry")
                    return
                } else {
                    warnings.append("Unexpected character in entry '\(key)' after field '\(fname)'; entry closed early")
                    skipBalancedBody(context: "entry '\(key)'")
                    entries.append(BibTeXEntry(type: type, key: key, fields: fields))
                    return
                }
            }

            entries.append(BibTeXEntry(type: type, key: key, fields: fields))
        }

        while true {
            // Free text between entries (export headers, comments the source
            // tool didn't wrap in `@comment{}`) is simply skipped.
            while i < n, chars[i] != "@" { i += 1 }
            guard i < n else { break }
            i += 1 // consume '@'

            let typeWord = readWhile { $0.isLetter }
            guard !typeWord.isEmpty else {
                // A bare '@' with nothing recognizable after it; move on
                // without looping in place - the outer scan above already
                // advances past it next time around.
                continue
            }
            let type = typeWord.lowercased()

            skipWhitespace()
            guard i < n, chars[i] == "{" else {
                warnings.append("Entry '@\(typeWord)' is missing its opening '{'; skipped")
                continue
            }
            i += 1 // consume '{'

            switch type {
            case "comment", "preamble":
                skipBalancedBody(context: "@\(type)")
            case "string":
                parseStringDef()
            default:
                parseEntry(rawType: type)
            }
        }

        return ParseResult(entries: entries, warnings: warnings)
    }
}
