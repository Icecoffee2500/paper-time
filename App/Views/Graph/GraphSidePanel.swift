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
                Text("Graph")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await graph.build(from: model) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(graph.isBuilding)
                .help("Look for connections again")
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Text("Papers are joined when one cites the other, when your notes link them, when they share an author, or when you filed them together.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            Toggle("Focus on selection", isOn: Bindable(graph).focusesOnSelection)
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .disabled(graph.selection == nil)

            Divider()

            List {
                Section("Most connected") {
                    ForEach(graph.mostConnected()) { node in
                        Button {
                            graph.selection = node.id
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
                        Button("Open This Paper") {
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
