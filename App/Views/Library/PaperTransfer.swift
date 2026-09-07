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

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .paperTimePaper)
        ProxyRepresentation(exporting: \.title)
    }
}

extension UTType {
    static let paperTimePaper = UTType(exportedAs: "com.imtaeheon.PaperTime.paper")
}
