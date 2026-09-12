import Foundation

/// Prints what a library folder looks like from this device — for chasing
/// a library that is there on one device and empty on another.
public enum LibraryDiagnostics {
    public static func log(_ message: String) {
        print("[PaperTime] \(message)")
    }

    public static func dump(_ label: String, root: URL) {
        let manager = FileManager.default
        log("\(label) root=\(root.path(percentEncoded: false))")
        describe(root, indent: "  ")
        let support = LibraryLayout.supportDirectoryURL(inLibrary: root)
        describe(support, indent: "  ")
        for item in (try? manager.contentsOfDirectory(at: support, includingPropertiesForKeys: nil, options: [])) ?? [] {
            describe(item, indent: "    ")
        }
        let records = LibraryLayout.recordsDirectoryURL(inLibrary: root)
        let folders = (try? manager.contentsOfDirectory(at: records, includingPropertiesForKeys: nil, options: [])) ?? []
        log("  records: \(folders.count) entries")
        for folder in folders.prefix(2) {
            describe(folder, indent: "    ")
            for item in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [])) ?? [] {
                describe(item, indent: "      ")
            }
        }
        let all = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [])) ?? []
        log("  root entries: \(all.count); hidden: \(all.filter { $0.lastPathComponent.hasPrefix(".") }.map(\.lastPathComponent))")
    }

    static func describe(_ url: URL, indent: String) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .fileSizeKey, .isHiddenKey, .isReadableKey]
        let exists = FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        guard let v = try? url.resourceValues(forKeys: keys) else {
            log("\(indent)\(url.lastPathComponent): exists=\(exists) (no resource values)")
            return
        }
        let status = v.ubiquitousItemDownloadingStatus?.rawValue ?? "-"
        log("\(indent)\(url.lastPathComponent): exists=\(exists) dir=\(v.isDirectory ?? false) ubiq=\(v.isUbiquitousItem ?? false) status=\(status) size=\(v.fileSize ?? -1) readable=\(v.isReadable ?? false)")
    }
}
