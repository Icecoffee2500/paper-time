import Foundation
import Testing
@testable import PaperCore

/// `Fixtures/reading-plans.json` is what `ReadingPlan.swift` answers
/// (`Scripts/reading-plan-fixture.swift`); the Portable build's tests read
/// the same file. A change to a rule that is not written back fails here.
@Suite struct ReadingPlanFixtureTests {
    struct DayCase: Decodable { var ordinal: Int; var text: String; var weekday: Int; var monday: String }
    struct ParseCase: Decodable { var today: String; var text: String; var day: String? }
    struct SpreadCase: Decodable { var count: Int; var weekdays: [Int]; var perDay: Int; var from: String; var days: [String] }
    struct Step: Decodable { var op: String; var args: [String]; var json: String }
    struct AddressCase: Decodable { var text: String; var address: String?; var kind: String?; var title: String?; var host: String? }
    struct FileCase: Decodable { var name: String; var kind: String }
    struct Encoded: Decodable { var schedule: String; var links: String }
    struct File: Decodable {
        var days: [DayCase]; var parse: [ParseCase]; var spread: [SpreadCase]; var plan: [Step]
        var addresses: [AddressCase]; var files: [FileCase]; var encoded: Encoded
    }

    func fixture() throws -> File {
        let url = try #require(Bundle.module.url(forResource: "reading-plans", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
    }

    @Test func daysCountAsTheFileSays() throws {
        for day in try fixture().days {
            let made = PlanDay(ordinal: day.ordinal)
            #expect(made.text == day.text)
            #expect(made.weekday == day.weekday)
            #expect(made.monday.text == day.monday)
            if let parsed = PlanDay(day.text) { #expect(parsed.ordinal == day.ordinal) }
        }
    }

    @Test func typedDaysReadAsTheFileSays() throws {
        for c in try fixture().parse {
            #expect(PlanDayParser.read(c.text, today: PlanDay(c.today)!)?.text == c.day, Comment(rawValue: "\(c.text) on \(c.today)"))
        }
    }

    @Test func spreadsLandAsTheFileSays() throws {
        for c in try fixture().spread {
            let days = PlanSpread.days(count: c.count, weekdays: Set(c.weekdays), perDay: c.perDay, from: PlanDay(c.from)!)
            #expect(days.map(\.text) == c.days)
        }
    }

    @Test func editsWriteTheFileTheFileSays() throws {
        let steps = try fixture().plan
        var plan = try JSONCoding.decode(ReadingPlan.self, from: Data(steps[0].json.utf8))
        func id(_ s: String) -> UUID? { s == "-" ? nil : UUID(uuidString: s) }
        for step in steps.dropFirst() {
            let a = step.args
            switch step.op {
            case "add": plan.add(a.dropLast().compactMap(id), to: id(a.last!))
            case "addSection": plan.addSection(named: a[0], id: id(a[1])!)
            case "moveToEnd": plan.move(a.dropLast().compactMap(id), toEndOf: id(a.last!))
            case "moveBefore": plan.move(a.dropLast().compactMap(id), before: id(a.last!)!)
            case "renameSection": plan.renameSection(id(a[0])!, to: a[1])
            case "moveSection": plan.moveSection(id(a[0])!, by: Int(a[1])!)
            case "removeSection": plan.removeSection(id(a[0])!)
            case "remove": plan.remove(Set(a.compactMap(id)))
            case "rename": plan.name = a[0]
            default: Issue.record("unknown step \(step.op)")
            }
            #expect(String(decoding: try JSONCoding.encode(plan), as: UTF8.self) == step.json, Comment(rawValue: step.op))
        }
    }

    @Test func addressesReadAsTheFileSays() throws {
        let file = try fixture()
        for c in file.addresses {
            let address = MaterialLink.address(c.text)
            #expect(address == c.address, Comment(rawValue: c.text))
            guard let address else { continue }
            #expect(MaterialLink.kind(ofAddress: address).rawValue == c.kind)
            #expect(MaterialLink.title(ofAddress: address) == c.title)
            #expect(MaterialLink.host(of: address) == c.host)
        }
        for c in file.files { #expect(MaterialLink.kind(ofFileName: c.name).rawValue == c.kind, Comment(rawValue: c.name)) }
    }

    @Test func filesComeBackByteForByte() throws {
        let encoded = try fixture().encoded
        let schedule = try JSONCoding.decode(PaperSchedule.self, from: Data(encoded.schedule.utf8))
        #expect(String(decoding: try JSONCoding.encode(schedule), as: UTF8.self) == encoded.schedule)
        let links = try JSONCoding.decode(PaperMaterials.self, from: Data(encoded.links.utf8))
        #expect(String(decoding: try JSONCoding.encode(links), as: UTF8.self) == encoded.links)
        #expect(links.links[2].displayTitle == "저자 발표 영상")
        #expect(links.links[0].displayTitle == "sfujim/TD3_BC")
    }
}
