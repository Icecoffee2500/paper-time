import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A paper being dragged.
///
/// Carrying the identifier rather than the file URL means a drop onto a
/// collection or a reading state can act on the record, while a drop onto the
/// Finder or another app still gets something meaningful from the title.
struct PaperTransfer: Codable, Transferable, Hashable {
    var id: UUID
    var title: String
    /// The pane the drag began on, when it began on a pane's title: dropped
    /// into another zone, that pane moves rather than a second one of the
    /// paper opening. Absent in every other drag (and in older payloads).
    var pane: UUID? = nil

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .paperTimePaper)
        ProxyRepresentation(exporting: \.title)
    }
}

extension UTType {
    static let paperTimePaper = UTType(exportedAs: "com.imtaeheon.PaperTime.paper")
}
