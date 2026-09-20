import PaperCore
import SwiftUI

/// What the graph column shows beside the graph: how to read it, and where to
/// start.
struct GraphSidePanel: View {
    let model: LibraryModel
    let graph: GraphModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("그래프", "Graph"))
                    .font(.headline)
                Spacer()
                Button {
                    Task { await graph.build(from: model) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(graph.isBuilding)
                .help(L("연결 다시 찾기", "Look for connections again"))
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Text(L("논문은 한쪽이 다른 쪽을 인용할 때, 내 노트가 둘을 이을 때, 공저자가 있을 때, 같은 컬렉션에 넣었을 때 이어진다.", "Papers are joined when one cites the other, when your notes link them, when they share an author, or when you filed them together."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            // Disabled until there is something to focus *on*, and saying so.
            // It was greyed out with no reason given, which reads as broken
            // rather than as not-yet — and the panel below it was meanwhile
            // telling the reader to turn it on.
            VStack(alignment: .leading, spacing: 2) {
                Toggle(L("고른 것에 집중", "Focus on selection"), isOn: Bindable(graph).focusesOnSelection)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(graph.selection == nil)
                if graph.selection == nil {
                    Text(L("먼저 그래프에서 논문을 하나 누른다.", "Click a paper in the graph first."))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            // Shown only until something is picked. What the graph is made of
            // was already written down; what it is *for* was not, and a
            // picture of sixty dots does not explain itself. Once you are
            // working it goes away, because by then you know.
            if graph.selection == nil { howToUse }

            List {
                Section(L("가장 많이 이어진", "Most connected")) {
                    ForEach(graph.mostConnected()) { node in
                        Button {
                            graph.selection = node.id
                            graph.reheat(0.3)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(node.title)
                                    .font(.callout)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 6)
                                Text(node.degree, format: .number)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let id = graph.selection, let node = graph.node(id) {
                    Section(node.title) {
                        ForEach(connections(of: id)) { entry in
                            Button {
                                graph.selection = entry.node.id
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.node.title)
                                        .font(.callout)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Text(entry.why)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                        Button(L("이 논문 열기", "Open This Paper")) {
                            model.scope = .all
                            model.selectedPaperID = id
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .listStyle(.inset)
                // An inset list paints its own opaque white, which is why the
                // lists were the one white rectangle in a window of glass. The
                // panel behind them is the background now.
                .scrollContentBackground(.hidden)
            .hiddenScrollers()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// What to do with it.
    ///
    /// Four things, in the order you would do them, each naming the gesture
    /// rather than describing the idea: a graph is only useful if you know
    /// which part of it answers a question you have.
    private var howToUse: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L("쓰는 법", "HOW TO USE IT"))
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)

            step("hand.tap", L("점을 누른다", "Click a dot"),
                 L("이웃이 밝아지고, 이 패널이 그 하나하나를 이어진 이유와 함께 늘어놓는다.", "Its neighbours light up, and this panel lists every one with the reason they are joined."))
            step("scope", L("'고른 것에 집중'을 켠다", "Turn on Focus on selection"),
                 L("관계없는 것은 다 물러나고, 논문 하나의 이웃만 남는다.", "Everything unrelated drops away, so one paper's neighbourhood is all that is left."))
            step("line.3.horizontal.decrease", L("범례에서 선 하나를 끈다", "Switch a line off in the legend"),
                 L("인용을 숨기면 내 노트가 이은 것만 남는다 — 문헌의 관계가 아니라 내 읽기다.", "Hide citations to see only what your own notes have joined — that is your reading, not the literature's."))
            step("arrow.up.left.and.arrow.down.right", L("핀치로 확대, 드래그로 이동", "Pinch to zoom, drag to pan"),
                 L("들어갈수록 제목이 나타난다. 점을 두 번 누르면 논문이 열린다.", "Titles appear as you go in. Double-click a dot to open the paper."))

            Text(L("아래에서 시작한다: 가장 많이 이어진 논문에 나머지 라이브러리가 매달려 있다.", "Start below: the most connected papers are the ones the rest of your library hangs off."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func step(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A row in the connections list. It carries its own identity because the
    /// same paper can also stand in the list above, and two rows with one
    /// identity make a list that draws neither of them properly.
    private struct Connection: Identifiable {
        let node: GraphModel.Node
        let why: String
        var id: String { "connection-\(node.id.uuidString)" }
    }

    private func connections(of id: UUID) -> [Connection] {
        graph.visibleEdges
            .filter { $0.a == id || $0.b == id }
            .compactMap { edge in
                let other = edge.a == id ? edge.b : edge.a
                guard let node = graph.node(other) else { return nil }
                let kinds = edge.kinds.sorted { $0.label < $1.label }.map(\.label)
                let why = edge.reason.isEmpty
                    ? kinds.joined(separator: " · ")
                    : "\(kinds.joined(separator: " · ")) — \(edge.reason)"
                return Connection(node: node, why: why)
            }
            .sorted { $0.node.degree > $1.node.degree }
    }
}
