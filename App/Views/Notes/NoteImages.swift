#if os(macOS)
import AppKit
import LibraryStore

/// The pictures in notes.
///
/// A picture is a file beside the notes, in a folder of its own, and the
/// note says where: `![](.assets/<name>.png)` — Markdown's own way of
/// saying it, on a line of its own. The folder is hidden so it is not taken
/// for an area of knowledge (those are the folders one can see), and every
/// box of notes has one: a library folder's under `.papertime/notes`, the
/// loose notes' under their own folder — so a picture travels with the
/// folder its note is in.
enum NoteImages {
    static let folderName = ".assets"

    /// Every box's folder of pictures, set as the boxes are (`NotesModel`).
    /// A note names its picture by file, and the file is looked for in each:
    /// a note carried from one box to another still finds its picture while
    /// both are open.
    nonisolated(unsafe) static var directories: [URL] = []
    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]

    /// The folder of pictures of a box of notes.
    static func directory(ofBox box: any SlipBox) -> URL {
        if let loose = box as? LooseNotes {
            return loose.directory.appending(path: folderName, directoryHint: .isDirectory)
        }
        return LibraryLayout.supportDirectoryURL(inLibrary: box.boxID)
            .appending(path: LibraryLayout.notesDirectoryName, directoryHint: .isDirectory)
            .appending(path: folderName, directoryHint: .isDirectory)
    }

    /// The file a note's `![](…)` names: one of ours by its name, in
    /// whichever box holds it — or a file anywhere, by its whole path.
    static func url(for path: String) -> URL? {
        let manager = FileManager.default
        let decoded = path.removingPercentEncoding ?? path
        if decoded.hasPrefix(folderName + "/") {
            let name = String(decoded.dropFirst(folderName.count + 1))
            guard !name.contains("/"), !name.hasPrefix(".") else { return nil }
            return directories.map { $0.appending(path: name) }
                .first { manager.fileExists(atPath: $0.path(percentEncoded: false)) }
        }
        if decoded.hasPrefix("file://"), let url = URL(string: path), manager.fileExists(atPath: url.path(percentEncoded: false)) {
            return url
        }
        if decoded.hasPrefix("/"), manager.fileExists(atPath: decoded) { return URL(fileURLWithPath: decoded) }
        return nil
    }

    static func image(_ path: String) -> NSImage? {
        if let known = cache[path] { return known }
        guard let url = url(for: path), let image = NSImage(contentsOf: url), image.size.width > 0 else { return nil }
        if cache.count > 200 { cache.removeAll() }
        cache[path] = image
        return image
    }

    /// Keeps a picture in a box's folder and gives back what the note
    /// writes for it. The name is new every time: two pictures are never
    /// one file, and nothing is written over.
    static func keep(_ data: Data, as fileExtension: String, in directory: URL) throws -> String {
        try FileOperations.ensureDirectory(at: directory)
        let name = UUID().uuidString.lowercased() + "." + fileExtension
        try data.write(to: directory.appending(path: name), options: .atomic)
        return folderName + "/" + name
    }

    /// The picture on a pasteboard — a file somebody copied or dragged, or
    /// a picture itself — as the bytes to keep and the kind they are.
    static func picture(on pasteboard: NSPasteboard) -> (data: Data, fileExtension: String)? {
        let kinds = ["png", "jpg", "jpeg", "gif", "heic", "tiff", "tif", "webp"]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let file = urls.first(where: { kinds.contains($0.pathExtension.lowercased()) }),
           let data = try? Data(contentsOf: file) {
            return (data, file.pathExtension.lowercased())
        }
        // Files of some other kind: theirs is not a picture to keep.
        if pasteboard.availableType(from: [.fileURL]) != nil { return nil }
        if let png = pasteboard.data(forType: .png) { return (png, "png") }
        if let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return (png, "png")
        }
        return nil
    }
}
#endif
