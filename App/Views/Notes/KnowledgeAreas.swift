import PaperCore
import SwiftUI
import UniformTypeIdentifiers

/// The slip-box's three places (1.1, 2026-11-18): 문헌 노트 — the notes
/// written against a paper, a book or a document; 지식 — the notes of no
/// paper, filed in areas that are folders under the notes folder; and
/// 프로젝트. The names follow the Zettelkasten's own: a literature note is
/// about a source, and the knowledge is what was written in one's own words.
enum KnowledgeArea {
    /// What a knowledge shelf is called: «지식» for all of it, «분류 안 함»
    /// for the notes filed in no area, an area by its own (last) name.
    static func title(_ area: String?) -> String {
        guard let area else { return L("지식", "Knowledge") }
        if area.isEmpty { return L("분류 안 함", "Unfiled") }
        return name(area)
    }

    /// The last folder of an area's path.
    static func name(_ area: String) -> String {
        area.split(separator: "/").last.map(String.init) ?? area
    }

    /// How deep an area sits: one for an area at the top.
    static func depth(_ area: String) -> Int {
        area.split(separator: "/").count
    }

    /// The area an area is in, or "" for the top.
    static func parent(_ area: String) -> String {
        area.split(separator: "/").dropLast().joined(separator: "/")
    }
}

/// The order a list of notes is in.
enum NoteOrder: String, CaseIterable, Identifiable {
    case edited, created, title

    var id: String { rawValue }

    var label: String {
        switch self {
        case .edited: L("최근에 고친 순", "Recently Edited")
        case .created: L("최근에 쓴 순", "Recently Written")
        case .title: L("이름 순", "Name")
        }
    }

    func sorted(_ notes: [Zettel]) -> [Zettel] {
        switch self {
        case .edited: notes.sorted { $0.modified == $1.modified ? $0.id > $1.id : $0.modified > $1.modified }
        case .created: notes.sorted { $0.created == $1.created ? $0.id > $1.id : $0.created > $1.created }
        case .title: notes.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
        }
    }
}

/// A note, dragged: onto an area in the sidebar to file it there.
struct NoteTransfer: Codable, Transferable, Hashable {
    var id: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .paperTimeNote)
    }
}

extension UTType {
    static let paperTimeNote = UTType(exportedAs: "com.imtaeheon.PaperTime.note")
}

/// What the name sheet is asked for.
enum AreaPrompt: Identifiable, Equatable {
    case create(inside: String)
    case rename(String)

    var id: String {
        switch self {
        case let .create(parent): "create:" + parent
        case let .rename(area): "rename:" + area
        }
    }

    var title: String {
        switch self {
        case let .create(parent): parent.isEmpty ? L("새 영역", "New Area") : L("‘\(KnowledgeArea.name(parent))’ 안에 새 영역", "New Area in “\(KnowledgeArea.name(parent))”")
        case .rename: L("영역 이름 바꾸기", "Rename Area")
        }
    }

    var action: String {
        switch self {
        case .create: L("만들기", "Create")
        case .rename: L("바꾸기", "Rename")
        }
    }
}

/// One name, asked for — an area's, made or renamed.
struct AreaNameSheet: View {
    let prompt: AreaPrompt
    let onDone: (String) -> Void
    @State private var name: String
    @Environment(\.dismiss) private var dismiss

    init(prompt: AreaPrompt, onDone: @escaping (String) -> Void) {
        self.prompt = prompt
        self.onDone = onDone
        if case let .rename(area) = prompt {
            _name = State(initialValue: KnowledgeArea.name(area))
        } else {
            _name = State(initialValue: "")
        }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                TextField(L("영역 이름", "Area Name"), text: $name)
                    .onSubmit(done)
                if !trimmed.isEmpty, trimmed.contains("/") || trimmed.hasPrefix(".") {
                    Text(L("이름에 /를 넣거나 .으로 시작할 수 없어요.", "A name can't contain / or start with a dot."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(prompt.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("취소", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(prompt.action, action: done)
                        .disabled(!valid)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 340, minHeight: 150)
        #endif
    }

    private var valid: Bool {
        !trimmed.isEmpty && !trimmed.contains("/") && !trimmed.hasPrefix(".") && !trimmed.contains(":")
    }

    private func done() {
        guard valid else { return }
        onDone(trimmed)
        dismiss()
    }
}

/// The colour a source's kind wears on a literature note's row.
extension ShelfKind {
    /// The kind on a row's chip — short, one source.
    var chip: String {
        switch self {
        case .paper: L("논문", "Paper")
        case .book: L("책", "Book")
        case .document: L("문서", "Document")
        }
    }

    var tint: Color {
        switch self {
        case .paper: .accentColor
        case .book: .purple
        case .document: .orange
        }
    }
}
