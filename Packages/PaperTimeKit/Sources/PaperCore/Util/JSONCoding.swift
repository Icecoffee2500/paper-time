import Foundation

/// Encoders and decoders shared by every file Paper Time writes.
///
/// Keys are sorted and output is pretty-printed on purpose: these files live in
/// a synced folder, so a small edit should produce a small, readable diff rather
/// than one reordered line, and a person who opens `meta.json` in a text editor
/// should be able to read it.
///
/// Fresh coder instances are handed out per call because `JSONEncoder` is not
/// `Sendable`; the cost is irrelevant next to the file I/O that follows.
public enum JSONCoding {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            // Registrars and our own writes disagree about fractional seconds.
            if let date = try? Date(raw, strategy: .iso8601WithFraction) { return date }
            if let date = try? Date(raw, strategy: .iso8601) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognised date: \(raw)"
            )
        }
        return decoder
    }

    public static func encode(_ value: some Encodable) throws -> Data {
        try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}

private extension ParseStrategy where Self == Date.ISO8601FormatStyle {
    static var iso8601WithFraction: Date.ISO8601FormatStyle {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    }
}
