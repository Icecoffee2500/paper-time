import Foundation
@testable import PaperCore
import Testing

/// Which paper a supplement is attached to without asking — the cases
/// Portable's `confidentParent` reads too (`Fixtures/supplement-parents.json`).
@Suite("Supplements attached without asking")
struct SupplementParentTests {
    struct Fixture: Decodable {
        struct Paper: Decodable { var title: String; var fileName: String }
        struct Case: Decodable { var name: String; var fileName: String; var title: String?; var parent: Int? }
        var library: [Paper]
        var cases: [Case]
    }

    @Test("Each case finds the parent it should, or none")
    func cases() throws {
        let url = try #require(Bundle.module.url(forResource: "supplement-parents", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let ids = fixture.library.map { _ in UUID() }
        let candidates = zip(ids, fixture.library).map { (id: $0, title: $1.title, fileName: $1.fileName) }
        for item in fixture.cases {
            let found = SupplementDetector.confidentParent(forFileName: item.fileName, title: item.title, among: candidates)
            #expect(found == item.parent.map { ids[$0] }, "\(item.name)")
        }
    }
}
