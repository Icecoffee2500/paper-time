// The reading plan's rules, answered by the Mac's `ReadingPlan.swift`, for
// `Tests/PaperCoreTests/Fixtures/reading-plans.json` — which the Portable
// build's `shared/readingPlan.ts` is held to.
//
//   swiftc -O Packages/PaperTimeKit/Sources/PaperCore/Model/ReadingPlan.swift \
//     Packages/PaperTimeKit/Sources/PaperCore/Util/JSONCoding.swift \
//     Scripts/reading-plan-fixture.swift -o /tmp/reading-plan-fixture && /tmp/reading-plan-fixture
import Foundation

struct DayCase: Encodable { var ordinal: Int; var text: String; var weekday: Int; var monday: String }
struct ParseCase: Encodable { var today: String; var text: String; var day: String? }
struct SpreadCase: Encodable { var count: Int; var weekdays: [Int]; var perDay: Int; var from: String; var days: [String] }
struct GroupOut: Encodable { var section: String?; var papers: [String] }
struct PlanStep: Encodable { var op: String; var args: [String]; var json: String; var groups: [GroupOut]; var order: [String] }
struct AddressCase: Encodable { var text: String; var address: String?; var kind: String?; var title: String?; var host: String? }
struct FileCase: Encodable { var name: String; var kind: String }
struct Encoded: Encodable { var schedule: String; var links: String }
struct Fixture: Encodable {
    var days: [DayCase]
    var parse: [ParseCase]
    var spread: [SpreadCase]
    var plan: [PlanStep]
    var addresses: [AddressCase]
    var files: [FileCase]
    var encoded: Encoded
}

func uuid(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }

@main
struct Main {
    static func main() throws {
        var days: [DayCase] = []
        for ordinal in [-719_468, -1, 0, 1, 2, 3, 4, 5, 6, 7, 58, 59, 60, 365, 789, 10957, 11016, 11017,
                        18262, 19782, 20408, 20409, 20438, 20453, 20454, 20503, 20513, 21000, 2_932_896] {
            let day = PlanDay(ordinal: ordinal)
            days.append(DayCase(ordinal: ordinal, text: day.text, weekday: day.weekday, monday: day.monday.text))
        }

        let inputs = [
            "", "  ", "오늘", "Today", "내일", "tomorrow", "모레", "다음 주", "다음주", "담주", "next week",
            "주말", "이번 주말", "weekend", "this weekend",
            "+1", "+3", "+ 3", "+3일", "+3d", "+3 days", "+2주", "+2w", "+2 weeks", "+1wk", "+999", "+1000",
            "3일 뒤", "3일후", "2주 뒤", "2 주 후", "in 3 days", "in 2 weeks", "in 1 wk",
            "12/3", "12.3", "12.3.", "12-3", "12 / 3", "1/5", "9/1", "9/20", "2/29", "2/30", "13/1", "0/3", "12/0", "12/32",
            "12월 3일", "12월3일", "1월 5일", "12월 3", "3월",
            "2027-01-05", "2027.1.5", "2027/01/05", "2027년 1월 5일", "2027-02-29", "2028-02-29", "2026-11-16.",
            "dec 3", "Dec 3", "December 3", "dec. 3", "dec 3rd", "3 dec", "3rd December", "ma 3", "may 31", "jun 31",
            "20일", "1일", "31일", "30일", "15일",
            "월", "월요일", "화", "수요일", "목", "금", "금요일", "토", "일", "일요일",
            "이번 주 금", "이번주 금요일", "이번 주 월", "다음 주 수", "다음주 수요일", "담주 화", "다음 주 일요일",
            "mon", "monday", "tue", "tues", "wed", "thu", "thurs", "fri", "friday", "sat", "sun", "sunday",
            "this fri", "this monday", "next fri", "next wednesday", "next sun", "mo", "frid", "fridays",
            "march", "week", "next", "금요일요일", "다음 주 금요일 오후", "12/3/2026", "  금요일  ", "금\u{3000}요일",
        ]
        var parse: [ParseCase] = []
        for today in ["2026-11-16", "2026-11-20", "2026-11-22", "2026-12-30", "2028-01-31", "2028-02-27"] {
            let day = PlanDay(today)!
            for text in inputs {
                parse.append(ParseCase(today: today, text: text, day: PlanDayParser.read(text, today: day)?.text))
            }
        }

        var spread: [SpreadCase] = []
        let patterns: [[Int]] = [[0, 2, 4], [0], [6], [0, 1, 2, 3, 4], [5, 6], [], [7, -1], [3, 9]]
        for weekdays in patterns {
            for perDay in [1, 2, 3] {
                for from in ["2026-11-16", "2026-11-19", "2026-11-23", "2026-12-28"] {
                    for count in [0, 1, 7, 12] {
                        let made = PlanSpread.days(count: count, weekdays: Set(weekdays), perDay: perDay, from: PlanDay(from)!)
                        spread.append(SpreadCase(count: count, weekdays: weekdays, perDay: perDay, from: from, days: made.map(\.text)))
                    }
                }
            }
        }

        var plan = ReadingPlan(id: uuid(1), name: "Offline RL 정주행", createdAt: Date(timeIntervalSince1970: 1_794_787_200))
        var steps: [PlanStep] = []
        func record(_ op: String, _ args: [String]) throws {
            let json = String(decoding: try JSONCoding.encode(plan), as: UTF8.self)
            steps.append(PlanStep(
                op: op, args: args, json: json,
                groups: plan.groups.map { GroupOut(section: $0.section?.id.uuidString, papers: $0.papers.map(\.uuidString)) },
                order: plan.readingOrder.map(\.uuidString)
            ))
        }
        func p(_ n: Int) -> UUID { uuid(100 + n) }
        func s(_ n: Int) -> UUID { uuid(200 + n) }
        try record("start", [])
        plan.add([p(1), p(2), p(3)]); try record("add", [p(1), p(2), p(3)].map(\.uuidString) + ["-"])
        plan.add([p(2), p(4)]); try record("add", [p(2), p(4)].map(\.uuidString) + ["-"])
        plan.addSection(named: "바탕", id: s(1)); try record("addSection", ["바탕", s(1).uuidString])
        plan.addSection(named: "값을 낮춰 잡기", id: s(2)); try record("addSection", ["값을 낮춰 잡기", s(2).uuidString])
        plan.move([p(1), p(2)], toEndOf: s(1)); try record("moveToEnd", [p(1), p(2)].map(\.uuidString) + [s(1).uuidString])
        plan.add([p(5), p(6)], to: s(2)); try record("add", [p(5), p(6)].map(\.uuidString) + [s(2).uuidString])
        plan.add([p(7)], to: s(9)); try record("add", [p(7).uuidString, s(9).uuidString])
        plan.move([p(6), p(3)], before: p(1)); try record("moveBefore", [p(6), p(3)].map(\.uuidString) + [p(1).uuidString])
        plan.move([p(1)], before: p(1)); try record("moveBefore", [p(1).uuidString, p(1).uuidString])
        plan.move([p(4)], before: p(99)); try record("moveBefore", [p(4).uuidString, p(99).uuidString])
        plan.move([p(5), p(99), p(5)], toEndOf: nil); try record("moveToEnd", [p(5), p(99), p(5)].map(\.uuidString) + ["-"])
        plan.renameSection(s(2), to: "단순하게"); try record("renameSection", [s(2).uuidString, "단순하게"])
        plan.moveSection(s(2), by: -1); try record("moveSection", [s(2).uuidString, "-1"])
        plan.moveSection(s(2), by: -5); try record("moveSection", [s(2).uuidString, "-5"])
        plan.addSection(named: "모델로 풀기", id: s(3)); try record("addSection", ["모델로 풀기", s(3).uuidString])
        plan.moveSection(s(2), by: 9); try record("moveSection", [s(2).uuidString, "9"])
        plan.removeSection(s(1)); try record("removeSection", [s(1).uuidString])
        plan.remove([p(3), p(7)]); try record("remove", [p(3), p(7)].map(\.uuidString))
        plan.move([p(2), p(6)], toEndOf: s(3)); try record("moveToEnd", [p(2), p(6)].map(\.uuidString) + [s(3).uuidString])
        plan.name = "새 이름 \"quoted\"\n"; try record("rename", ["새 이름 \"quoted\"\n"])

        let addressInputs = [
            "github.com/sfujim/TD3_BC", "https://github.com/sfujim/TD3_BC", "https://github.com/sfujim/TD3_BC.git",
            "https://github.com/sfujim", "https://www.github.com/sfujim/BCQ/tree/main/continuous_BCQ",
            "https://github.com/a/b/blob/main/practice04_cql.ipynb", "gitlab.com/group/project", "https://codeberg.org/x/y",
            "https://colab.research.google.com/drive/1abcDEF", "https://www.kaggle.com/code/someone/notebook",
            "https://www.kaggle.com/datasets/someone/data", "https://nbviewer.org/github/a/b/x.ipynb",
            "youtube.com/watch?v=cql-talk", "https://www.youtube.com/watch?v=abc", "https://youtu.be/abc", "https://m.youtube.com/watch?v=1",
            "https://vimeo.com/123", "https://docs.google.com/presentation/d/1abc/edit", "https://docs.google.com/document/d/1abc",
            "https://speakerdeck.com/a/b", "https://example.org/talks/CQL%20slides.pptx", "https://example.org/deck.key",
            "https://arxiv.org/abs/2106.06860", "arxiv.org/pdf/2106.06860v2.pdf", "https://arxiv.org/abs/cs/0101001",
            "https://openreview.net/forum?id=abc", "https://doi.org/10.1038/nature14236", "https://dx.doi.org/10.1145/3292500.3330701",
            "https://example.org/paper.pdf", "https://huggingface.co/datasets/imone/D4RL", "https://huggingface.co/spaces/a/b",
            "https://huggingface.co/meta-llama/Llama-3", "https://huggingface.co", "https://example.org/data/train.csv",
            "https://example.org/video.mp4", "https://lilianweng.github.io/posts/2018-04-08-policy-gradient/",
            "https://bair.berkeley.edu/blog/2020/12/07/offline/", "https://example.org", "https://example.org/", "example.org?x=1",
            "http://example.org:8080/a", "HTTPS://Example.ORG/Path", "<https://github.com/a/b>", "  https://github.com/a/b  ",
            "ftp://example.org/x", "not a link", "localhost:8000/x", "https://-bad.org", "https://bad..org", ".org", "https://",
            "example", "mailto:a@b.org", "https://example.org:port/x", "https://例시.kr/a", "https://example.org/%E1%84%80.pdf",
            "https://example.org/a%ZZ.pdf", "https://example.org/v1.2", "https://example.org/archive.tar.gz",
        ]
        var addresses: [AddressCase] = []
        for text in addressInputs {
            let address = MaterialLink.address(text)
            addresses.append(AddressCase(
                text: text, address: address,
                kind: address.map { MaterialLink.kind(ofAddress: $0).rawValue },
                title: address.map { MaterialLink.title(ofAddress: $0) },
                host: address.map { MaterialLink.host(of: $0) }
            ))
        }
        let names = ["CQL 발표자료.pptx", "PPO.PPT", "talk.key", "practice04_cql.ipynb", "demo.mp4", "clip.MOV", "train.csv",
                     "weights.npz", "agent.py", "main.cpp", "notes.md", "page.html", "slides.pdf", "bundle.zip", "README",
                     ".hidden", "archive.tar.gz", "sheet.xlsx", "x.swift", "noext."]
        let files = names.map { FileCase(name: $0, kind: MaterialKind.kind(ofFile: $0)) }

        let schedule = String(decoding: try JSONCoding.encode(PaperSchedule(date: PlanDay("2026-11-20")!)), as: UTF8.self)
        let links = String(decoding: try JSONCoding.encode(PaperMaterials(links: [
            PaperMaterial(id: uuid(301), kind: .code, url: "https://github.com/sfujim/TD3_BC", addedAt: Date(timeIntervalSince1970: 1_794_787_200)),
            PaperMaterial(id: uuid(302), kind: .slides, file: "Offline RL/CQL 발표자료.pptx", addedAt: Date(timeIntervalSince1970: 1_794_790_800)),
            PaperMaterial(id: uuid(303), kind: .video, url: "https://youtu.be/abc", title: "저자 발표 영상", addedAt: Date(timeIntervalSince1970: 1_794_794_400)),
        ])), as: UTF8.self)

        let fixture = Fixture(days: days, parse: parse, spread: spread, plan: steps, addresses: addresses, files: files,
                              encoded: Encoded(schedule: schedule, links: links))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let out = URL(fileURLWithPath: "Packages/PaperTimeKit/Tests/PaperCoreTests/Fixtures/reading-plans.json")
        try encoder.encode(fixture).write(to: out)
        print("wrote \(out.path): \(days.count) days, \(parse.count) readings, \(spread.count) spreads, \(steps.count) plan steps, \(addresses.count) addresses")
    }
}

extension MaterialKind {
    static func kind(ofFile name: String) -> String { MaterialLink.kind(ofFileName: name).rawValue }
}
