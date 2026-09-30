import Foundation

/// The numbers in an update's progress lines: «17.4 MB / 53.7 MB · 32%».
///
/// The Finder's units — decimal, whole kilobytes, a tenth of a megabyte, a
/// hundredth of a gigabyte, a trailing zero dropped, and a size that rounds
/// up to the next unit said in it — but no words: `ByteCountFormatter` says
/// «Zero KB» and «999 bytes», in English inside a Korean line, and a download
/// that has just begun read «Zero KB / 53.7 MB». From a kilobyte up the two
/// agree exactly (checked against the formatter across the whole range); below
/// it this rounds to kilobytes. The Portable build's `sizeText`
/// (shared/updates.ts) keeps the same rules and its tests the same cases.
enum UpdateMeasure {
    static func size(_ bytes: Int64) -> String {
        let bytes = max(0, bytes)
        // Rounded half up in whole numbers: 17,450,000 is 17.5 MB, where the
        // same sum in floating point comes to 17.449999… and so 17.4.
        let kilobytes = (bytes + 500) / 1_000
        if kilobytes < 1_000 { return "\(kilobytes) KB" }
        let tenths = (bytes + 50_000) / 100_000
        if tenths < 10_000 {
            return tenths % 10 == 0 ? "\(tenths / 10) MB" : "\(tenths / 10).\(tenths % 10) MB"
        }
        let hundredths = (bytes + 5_000_000) / 10_000_000
        let whole = hundredths / 100, part = hundredths % 100
        if part == 0 { return "\(whole) GB" }
        return part % 10 == 0 ? "\(whole).\(part / 10) GB" : "\(whole).\(part < 10 ? "0" : "")\(part) GB"
    }

    /// Rounded down, so 100% is only ever said of something finished.
    static func percent(_ fraction: Double) -> String {
        "\(min(100, max(0, Int((fraction * 100).rounded(.down)))))%"
    }

    /// What has come so far, and of how much once the server has said.
    static func bytes(_ received: Int64, of total: Int64?) -> String {
        guard let total, total > 0 else { return size(received) }
        return "\(size(received)) / \(size(total)) · \(percent(Double(received) / Double(total)))"
    }
}
