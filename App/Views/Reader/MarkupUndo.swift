import Foundation
import InkEngine
import PDFReader

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Undo for marks, both ways round.
///
/// Making a mark and removing one are the same act seen from opposite ends, so
/// they need opposite undos: undoing a mark that was made takes it off the
/// page, and undoing a mark that was removed puts it back. Only the first was
/// ever registered, which is why a deleted highlight stayed deleted however
/// many times ⌘Z was pressed.
///
/// Each registration puts back the opposite one, so a mark can be taken off and
/// restored as many times as the reader likes.
@MainActor
enum MarkupUndo {
    /// The marks were just made. Undoing removes them.
    static func registerCreation(
        _ descriptors: [MarkupDescriptor],
        name: String,
        in session: DocumentSession,
        with undoManager: UndoManager?
    ) {
        register(descriptors, name: name, in: session, with: undoManager, restoring: false)
    }

    /// The marks were just removed. Undoing puts them back.
    static func registerRemoval(
        _ descriptors: [MarkupDescriptor],
        name: String,
        in session: DocumentSession,
        with undoManager: UndoManager?
    ) {
        register(descriptors, name: name, in: session, with: undoManager, restoring: true)
    }

    private static func register(
        _ descriptors: [MarkupDescriptor],
        name: String,
        in session: DocumentSession,
        with undoManager: UndoManager?,
        restoring: Bool
    ) {
        guard !descriptors.isEmpty, let undoManager else { return }
        undoManager.setActionName(name)
        undoManager.registerUndo(withTarget: session) { session in
            MainActor.assumeIsolated {
                if restoring {
                    session.restore(descriptors)
                } else {
                    session.removeMarkups(ids: descriptors.map(\.id))
                }
                register(
                    descriptors, name: name, in: session,
                    with: undoManager, restoring: !restoring
                )
            }
        }
    }
}
