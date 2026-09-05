import PDFKit
import PDFReader
import SwiftUI

/// A handle the detail column holds on whatever paper is open.
///
/// The reader owns its document session, but the toolbar lives one level up so
/// that every control in the window can be declared in one place and appear in
/// a deliberate order. This carries the two things those controls need — the
/// open session and the current text selection — without moving the reader's
/// own state out of it.
@MainActor
@Observable
final class ReaderLink {
    var session: DocumentSession?
    var selection: PDFSelection?

    var hasSelection: Bool { selection?.string?.isEmpty == false }

    init() {}
}
