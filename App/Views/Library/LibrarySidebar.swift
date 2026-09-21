import PaperCore
import SwiftUI

/// The source list: built-in scopes, collections, and tags.
///
/// Not a `List(selection:)`. The system paints a selected sidebar row in the
/// accent while the list has keyboard focus and in grey the moment focus
/// moves to the papers — which, on a panel, read as "inactive" and, on the
/// window's glass, read as a smudge. Which shelf you are on is not a fact
/// about where the keyboard is pointing, so each row marks itself: the
/// accent for its words on a pale tint of the accent behind them, the shape
/// the folder's name takes in the header and a passage takes in a note.
struct LibrarySidebar: View {
    @Environment(AppModel.self) private var app
    @State private var showsAllAuthors = false
    @State private var authorsAreShown = true
    @Bindable var model: LibraryModel

    /// Where the shelf you are on sits, in the list's own space — one shape
    /// for the whole list, so it can travel between rows.
    @State private var litShelf: CGRect?
    /// Whether the pointer is over the search row, which is the only row
    /// that carries a control of its own.
    @State private var hoveringSearch = false
    /// And whether it is over the button itself, which answers on its own.
    @State private var hoveringDismiss = false

    @State private var isPresentingNewCollection = false
    @State private var newCollectionName = ""

    var body: some View {
        list
            // The rows clip their own backgrounds, so a shape that travels
            // between them cannot live in one. It is drawn once, behind the
            // whole list, at whichever row is lit.
            .scrollContentBackground(.hidden)
            .background(alignment: .topLeading) { litGlass }
            .onPreferenceChange(LitShelf.self) { litShelf = $0 }
    }

    /// The shelf you are on, lit: one piece of glass carrying the row's own
    /// colour. It slides from row to row rather than being repainted in each,
    /// which is the move the buttons along the foot of Music make — and it
    /// says the thing a wash cannot: you came from there, you are here now.
    private var litGlass: some View {
        // Rows and list both measured against the window, so the difference
        // is where the glass goes; a named space put it half a panel away.
        GeometryReader { proxy in
            if let litShelf {
                let origin = proxy.frame(in: .global).origin
                let shape = RoundedRectangle(cornerRadius: Corner.row, style: .continuous)
                shape
                    .fill(ScopeRow.ground(for: model.scope))
                    .liquidGlass(.control, in: shape)
                    // The list's width, not the row's: every row is the same
                    // width, and a width taken from whichever row answered
                    // first was animated as it travelled, so the glass swelled
                    // out over the page on its way down.
                    .frame(width: max(proxy.size.width - 12, 0), height: litShelf.height)
                    .offset(x: 6, y: litShelf.minY - origin.y)
            }
        }
        .clipped()
    }

    /// The way out of a search: a small round button in the row's corner, on
    /// the Mac while the pointer is over the row and on a touch screen
    /// always — there is no hovering with a finger, and a control that only
    /// appears under a pointer does not exist on an iPad.
    ///
    /// A button, not a character. An × drawn as text is something you have to
    /// guess is pressable; this is the thing a token or a tab is closed with
    /// everywhere else — a filled disc that darkens under the pointer, with a
    /// target bigger than the mark inside it.
    /// Whether the cross is on the row at all: under the pointer on the Mac,
    /// always on a touch screen.
    private var dismissShown: Bool {
        #if os(macOS)
        hoveringSearch
        #else
        true
        #endif
    }

    @ViewBuilder
    private var dismissSearch: some View {
        Button {
            model.clearSearchResults()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(hoveringDismiss ? Color.primary : .secondary)
                .frame(width: 17, height: 17)
                .background {
                    Circle().fill(hoveringDismiss ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary))
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hoveringDismiss = $0 }
        // In the corner, not over it. Hanging the button outside the row put
        // half of it past the edge a list row clips at, so the disc came out
        // with its top and its right side sliced off. Flush with the row's
        // own bounds is as far into the corner as it can go and still be
        // drawn whole.
        .padding(.top, 1)
        .padding(.trailing, 1)
        .opacity(dismissShown ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: dismissShown)
        .animation(.easeOut(duration: 0.1), value: hoveringDismiss)
        .accessibilityLabel(L("찾기 끝내기", "Clear Search"))
        .help(L("찾기 끝내기", "Clear Search"))
    }

    private var list: some View {
        List {
            if !model.searchQuery.isEmpty {
                // A search is somewhere you can be, not a filter left switched
                // on somewhere off-screen — so it gets a row of its own, at the
                // top, and it can be dismissed from there.
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L("찾은 것", "Search Results"))
                            Text(model.searchQuery)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } icon: {
                        Image(systemName: "magnifyingglass")
                    }
                    // The count steps aside for the button rather than
                    // sharing the corner with it: a number with a cross on
                    // top of it is two things in one place, and the one you
                    // can press has to win.
                    .count(dismissShown ? nil : model.searchResultCount,
                           current: model.scope == .searchResults)
                    .scopeRow(.searchResults, in: model)
                    // A search you have finished with should be as easy to
                    // put away as it was to open. It stayed until it was
                    // replaced, or until somebody thought to look in a
                    // context menu for it.
                    .overlay(alignment: .topTrailing) { dismissSearch }
                    .onHover { hoveringSearch = $0 }
                    .contextMenu {
                        Button(L("찾기 끝내기", "Clear Search")) { model.clearSearchResults() }
                    }
                }
            }

            Section {
                Label(L("모두", "All"), systemImage: "tray.full")
                    .count(model.counts.all, current: model.scope == .all)
                    .scopeRow(.all, in: model)
                // The two kinds appear only once the library holds both. A
                // shelf that has never seen anything but papers looks exactly
                // as it did, which is most libraries here.
                if model.counts.documents > 0, model.counts.papers > 0 {
                    Label(L("논문", "Papers"), systemImage: "text.document")
                        .count(model.counts.papers, current: model.scope == .papers)
                        .scopeRow(.papers, in: model)
                    Label(L("문서", "Documents"), systemImage: "doc")
                        .count(model.counts.documents, current: model.scope == .documents)
                        .scopeRow(.documents, in: model)
                }
                // What is open right now — a row of tabs, as a shelf. From
                // here a paper is closed, or put beside another.
                Label(L("열린 논문", "Open Papers"), systemImage: "rectangle.on.rectangle")
                    .count(model.openPaperIDs.count, current: model.scope == .open)
                    .scopeRow(.open, in: model)
                Label(L("안 읽음", "Unread"), systemImage: "circle")
                    .count(model.counts.unread, current: model.scope == .unread)
                    .scopeRow(.unread, in: model)
                    .dropTarget(in: model) { await model.setReadingStatus(.unread, for: $0) }
                Label(L("읽는 중", "Reading"), systemImage: "circle.lefthalf.filled")
                    .count(model.counts.reading, current: model.scope == .reading)
                    .scopeRow(.reading, in: model)
                    .dropTarget(in: model) { await model.setReadingStatus(.reading, for: $0) }
                Label(L("읽음", "Read"), systemImage: "checkmark.circle")
                    .count(model.counts.read, current: model.scope == .read)
                    .scopeRow(.read, in: model)
                    .dropTarget(in: model) { await model.setReadingStatus(.read, for: $0) }
                Label(L("즐겨찾기", "Favorites"), systemImage: "star")
                    .count(model.counts.favorites, current: model.scope == .favorites)
                    .scopeRow(.favorites, in: model)
                    .dropTarget(in: model) { await model.setFavorite(true, for: $0) }
                Label(L("살펴볼 것", "Needs Review"), systemImage: "exclamationmark.triangle")
                    .count(model.counts.needsReview, current: model.scope == .needsReview)
                    .scopeRow(.needsReview, in: model)
            } header: {
                // The folder's name, small, where a headline used to sit
                // over the whole list saying the same thing louder.
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(L("라이브러리", "Library"))
                    // The folder as a chip — the same shape a passage from a
                    // paper takes in a note, and for the same reason: it
                    // names where something came from. Plain accent type
                    // beside a grey header shouted; on its own pale tint it
                    // is a label.
                    // Pressed, the chip is the way to another folder.
                    Button {
                        app.chooseLibraryFolder()
                    } label: {
                        Text(model.displayName)
                            .foregroundStyle(.tint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                RoundedRectangle(cornerRadius: Corner.control - 2.5, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.12))
                            )
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(L("라이브러리 폴더 바꾸기", "Change the library folder"))
                }
                // Lines the first row up with the first paper across the way:
                // the list column's header is taller than this one, and the
                // two rows underneath should sit level.
                .padding(.bottom, 13)
            }

            Section(L("슬립박스", "Slip-Box")) {
                Label(L("노트", "Notes"), systemImage: "tray.full")
                    .count(model.notes.notes.count, current: model.scope == .notes)
                    .scopeRow(.notes, in: model)
            }

            // Every folder the library is reading. A library used to be one
            // folder; now it is as many as you point it at, each keeping its
            // own records beside its own PDFs, so disconnecting one leaves it
            // exactly as it was.
            Section(L("폴더", "Folders")) {
                ForEach(model.sources, id: \.url) { source in
                    Label(source.url.lastPathComponent, systemImage: source.provider.symbolName)
                        .count(model.counts.folders[source.url] ?? 0, current: model.scope == .folder(source.url))
                        .scopeRow(.folder(source.url), in: model)
                        .contextMenu {
                            Button {
                                #if os(macOS)
                                NSWorkspace.shared.activateFileViewerSelecting([source.url])
                                #endif
                            } label: {
                                Label(L("Finder에서 보기", "Show in Finder"), systemImage: "folder")
                            }
                            if source.url != model.location.url {
                                Divider()
                                Button(role: .destructive) {
                                    Task { await app.disconnectFolder(at: source.url) }
                                } label: {
                                    Label(L("연결 해제", "Disconnect"), systemImage: "eject")
                                }
                            }
                        }
                        .help(source.url.path(percentEncoded: false))
                }
                Button {
                    app.addLibraryFolder()
                } label: {
                    Label(L("폴더 더하기…", "Add Folder…"), systemImage: "plus.circle")
                        .foregroundStyle(.secondary)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }

            Section(L("컬렉션", "Collections")) {
                ForEach(model.collections.collections) { collection in
                    Label(collection.name, systemImage: symbolName(for: collection))
                        .count(model.counts.collections[collection.id] ?? 0, current: model.scope == .collection(collection.id))
                        .scopeRow(.collection(collection.id), in: model)
                        .dropTarget(in: model, isEnabled: !collection.isSmart) { paperID in
                            await model.addToCollection(collection.id, paperID: paperID)
                        }
                }
                Button {
                    newCollectionName = ""
                    isPresentingNewCollection = true
                } label: {
                    Label(L("새 컬렉션…", "New Collection…"), systemImage: "plus.circle")
                        .foregroundStyle(.secondary)
                        .contentShape(.rect)
                }
                // Plain, or SwiftUI gives it a bezel and it sits in the source
                // list looking like the one thing that is not a row.
                .buttonStyle(.plain)
            }

            Section(L("태그", "Tags")) {
                ForEach(model.manifest.tags) { tag in
                    Label {
                        Text(tag.name)
                    } icon: {
                        Circle()
                            .fill(tag.color.swiftUIColor)
                            .frame(width: 10, height: 10)
                            .accessibilityHidden(true)
                    }
                    .count(model.counts.tags[tag.id] ?? 0, current: model.scope == .tag(tag.id))
                    .scopeRow(.tag(tag.id), in: model)
                    .dropTarget(in: model) { await model.addTag(tag.id, to: $0) }
                }
            }

            authorsSection

            Section {
                Label {
                    Text(L("그래프", "Graph"))
                } icon: {
                    GraphSymbol(colored: model.scope == .graph)
                }
                .scopeRow(.graph, in: model)
            }
        }
        .hiddenScrollers()
        // The source list used to get this from being a split view's sidebar.
        // Laying the columns out ourselves means asking for it: without it the
        // rows come back with separator lines under them.
        #if os(macOS)
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        #endif
        .navigationTitle(model.displayName)
        .sheet(isPresented: $isPresentingNewCollection) {
            NewCollectionSheet(
                name: $newCollectionName,
                onCreate: { name in
                    Task { await model.addCollection(named: name) }
                }
            )
        }
    }

    /// Who is on the most papers here.
    ///
    /// A shelf has a shape, and this is it: the names that keep coming back.
    /// Ten of them fit without turning the source list into a directory; the
    /// rest are one click away.
    @ViewBuilder
    private var authorsSection: some View {
        let ranking = model.authorRanking
        if !ranking.isEmpty {
            Section(L("저자", "Authors"), isExpanded: $authorsAreShown) {
                ForEach(showsAllAuthors ? ranking : Array(ranking.prefix(10))) { author in
                    Label(author.name, systemImage: "person")
                        .count(author.count, current: model.scope == .author(author.key))
                        .scopeRow(.author(author.key), in: model)
                }
                if ranking.count > 10 {
                    Button(showsAllAuthors ? L("줄이기", "Show Fewer") : L("\(ranking.count)명 모두 보기", "Show All \(ranking.count)")) {
                        withAnimation(.snappy(duration: 0.2)) { showsAllAuthors.toggle() }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                }
            }
        }
    }

    private func symbolName(for collection: Collection) -> String {
        collection.isSmart ? "folder.badge.gearshape" : collection.symbolName
    }
}

/// Small name-only sheet for creating a manual collection.
private struct NewCollectionSheet: View {
    @Binding var name: String
    let onCreate: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField(L("컬렉션 이름", "Collection Name"), text: $name)
            }
            .formStyle(.grouped)
            .navigationTitle(L("새 컬렉션", "New Collection"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("취소", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("만들기", "Create")) {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        onCreate(trimmed)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 320, minHeight: 140)
        #endif
    }
}

extension Tag.Color {
    /// Maps the library's persisted tag palette onto system colors, so tag
    /// swatches always match the platform's semantic palette.
    var swiftUIColor: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .gray: .gray
        }
    }
}

/// Makes a sidebar row accept a dragged paper.
///
/// Filing a paper by dragging it onto the thing you want it filed under is the
/// gesture people already know from Finder and Mail, and it is faster than
/// finding the same action in a menu.
private struct PaperDropTarget: ViewModifier {
    let model: LibraryModel
    let isEnabled: Bool
    let handle: (UUID) async -> Void

    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            // A ring, not the row's background — the background belongs to
            // whichever row is chosen, and a drop can land on any of them.
            .overlay(
                RoundedRectangle(cornerRadius: Corner.row, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(isTargeted ? 0.6 : 0), lineWidth: 1.5)
                    .padding(.horizontal, -8)
                    .padding(.vertical, -3)
            )
            .dropDestination(for: PaperTransfer.self) { items, _ in
                guard isEnabled, !items.isEmpty else { return false }
                // A drag that started on one of several selected rows brings
                // all of them.
                Task {
                    var seen: Set<UUID> = []
                    for item in items {
                        for id in model.draggedPapers(startingAt: item.id)
                        where seen.insert(id).inserted {
                            await handle(id)
                        }
                    }
                }
                return true
            } isTargeted: { targeted in
                isTargeted = isEnabled && targeted
            }
    }
}

extension View {
    func dropTarget(
        in model: LibraryModel,
        isEnabled: Bool = true,
        handle: @escaping (UUID) async -> Void
    ) -> some View {
        modifier(PaperDropTarget(model: model, isEnabled: isEnabled, handle: handle))
    }
}


/// A row of the source list that stands for a scope: pressed, it becomes the
/// scope; when it is the scope, it says so in the accent.
private struct ScopeRow: ViewModifier {
    @Environment(AppModel.self) private var app
    let scope: LibraryModel.Scope
    let model: LibraryModel

    private var isCurrent: Bool { model.scope == scope }

    /// The colour the chosen row's symbol takes. The source list's own icon
    /// colouring ignores the row's foreground style, so the label is drawn
    /// here, symbol first. States get the system's colours for states —
    /// reading is under way, read is done, review is wanted — and places
    /// take the accent, so the strip reads as one thing with a few meanings.
    private var symbolColor: Color { Self.symbolColor(for: scope) }

    static func symbolColor(for scope: LibraryModel.Scope) -> Color {
        switch scope {
        case .reading: .orange
        case .read: .green
        case .favorites: .yellow
        case .needsReview: .red
        default: .accentColor
        }
    }

    /// The three colours the graph draws its connections in, for its row.
    static let graphColors: [Color] = [.blue, .purple, .pink]
    @Environment(\.colorScheme) private var colorScheme

    /// The row's colour made fit for words: a yellow star reads, yellow
    /// type on a pale wash over a blue desktop does not. Deepened toward
    /// black in the light, lifted toward white in the dark.
    private var textColor: Color {
        symbolColor.mixed(with: colorScheme == .dark ? .white : .black, by: colorScheme == .dark ? 0.25 : 0.4)
    }

    /// A pale wash of a shelf's colour; for the graph, the three colours of
    /// its connections running into one another. Asked for by the one lit
    /// shape the list draws, which is not inside any row.
    static func ground(for scope: LibraryModel.Scope) -> AnyShapeStyle {
        if scope == .graph {
            return AnyShapeStyle(LinearGradient(
                colors: graphColors.map { $0.opacity(0.24) },
                startPoint: .leading, endPoint: .trailing
            ))
        }
        return AnyShapeStyle(symbolColor(for: scope).opacity(0.2))
    }

    func body(content: Content) -> some View {
        content
            // Yellow is the one colour that cannot carry a line drawing on a
            // pale ground; the star takes the deepened gold the words use.
            .labelStyle(SidebarLabelStyle(symbolColor: isCurrent ? (scope == .favorites ? textColor : symbolColor) : nil))
            // The row's colour is the symbol's: name, count and ground
            // agree, rather than an orange symbol on a blue wash.
            .tint(textColor)
            .foregroundStyle(isCurrent ? AnyShapeStyle(textColor) : AnyShapeStyle(.primary))
            .fontWeight(isCurrent ? .medium : .regular)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .onTapGesture {
                // Animated, so the lit shape travels from the row you were on
                // to this one rather than blinking out and in somewhere else.
                withAnimation(.smooth(duration: 0.32)) { model.scope = scope }
                // On the iPad the list is the split view's first column and
                // the shelves came from a panel, which has done its job —
                // but not before the glass has been seen arriving. A panel
                // that vanishes on the touch takes the answer with it.
                app.compactColumn = .sidebar
                dismissPanel()
            }
            // The row says where it is when it is the one lit; the list
            // draws the glass there. Nothing of its own: a row's background
            // is clipped to the row, and a shape clipped to where it starts
            // cannot be seen going anywhere.
            .listRowBackground(place)
    }

    /// Puts the shelves panel away once the glass has arrived.
    private func dismissPanel() {
        guard app.showsScopePanel else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            withAnimation(AppModel.paneMotion) { app.showsScopePanel = false }
        }
    }

    @ViewBuilder
    private var place: some View {
        if isCurrent {
            GeometryReader { proxy in
                Color.clear.preference(key: LitShelf.self, value: proxy.frame(in: .global))
            }
        } else {
            Color.clear
        }
    }
}

/// Where the lit shelf is. Only the row that is lit answers; the first
/// answer wins, and none at all means it has been scrolled out of sight.
struct LitShelf: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = value ?? nextValue()
    }
}

/// The graph's symbol: three nodes joined by dotted edges, each node in one
/// of the colours the graph draws its connections in when the row is the
/// one chosen, and plain otherwise.
private struct GraphSymbol: View {
    let colored: Bool

    var body: some View {
        Canvas { context, size in
            let radius: CGFloat = 3
            let points = [
                CGPoint(x: size.width * 0.5, y: radius + 0.5),
                CGPoint(x: radius + 0.5, y: size.height - radius - 0.5),
                CGPoint(x: size.width - radius - 0.5, y: size.height - radius - 0.5),
            ]
            // Edges run from rim to rim, not through the nodes, so the three
            // circles stay circles.
            var edges = Path()
            for index in 0..<3 {
                let from = points[index], to = points[(index + 1) % 3]
                let length = hypot(to.x - from.x, to.y - from.y)
                let unit = CGPoint(x: (to.x - from.x) / length, y: (to.y - from.y) / length)
                edges.move(to: CGPoint(x: from.x + unit.x * (radius + 1), y: from.y + unit.y * (radius + 1)))
                edges.addLine(to: CGPoint(x: to.x - unit.x * (radius + 1), y: to.y - unit.y * (radius + 1)))
            }
            context.stroke(edges, with: .color(colored ? .secondary : .primary.opacity(0.55)),
                           style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
            // Filled in colour when chosen; outlined, like the other rows'
            // symbols, when not.
            for (index, point) in points.enumerated() {
                let dot = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
                if colored {
                    context.fill(Path(ellipseIn: dot), with: .color(ScopeRow.graphColors[index]))
                } else {
                    context.stroke(Path(ellipseIn: dot), with: .color(.primary), lineWidth: 1.2)
                }
            }
        }
        .frame(width: 17, height: 16)
        .accessibilityHidden(true)
    }
}

/// A source-list label whose symbol can be given a colour of its own.
private struct SidebarLabelStyle: LabelStyle {
    let symbolColor: Color?

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon
                .foregroundStyle(symbolColor.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
                .frame(width: 20, alignment: .center)
            configuration.title
        }
    }
}

private extension View {
    func scopeRow(_ scope: LibraryModel.Scope, in model: LibraryModel) -> some View {
        modifier(ScopeRow(scope: scope, model: model))
    }

    /// A count beside a source-list row, shown even when it is zero.
    ///
    /// `.badge(0)` draws nothing at all, so a row would lose its number exactly
    /// when the number is worth knowing — an empty collection reads as broken
    /// rather than empty.
    /// Nil takes the badge off the row, for a row that has something else to
    /// show in that corner.
    func count(_ value: Int?, current: Bool = false) -> some View {
        // On the row you are on, the same accent as the words: a pale number
        // beside a blue name looked like it belonged to a different row.
        badge(
            value.map {
                Text($0, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(current ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
        )
    }
}

extension Color {
    /// This colour moved part of the way toward another.
    ///
    /// `mix(with:by:)` arrived with macOS 15; before it, AppKit's blend does
    /// the same sum in the same space, near enough for a wash behind words.
    func mixed(with other: Color, by fraction: Double) -> Color {
        if #available(macOS 15, iOS 18, *) {
            return mix(with: other, by: fraction)
        }
        #if os(macOS)
        let base = NSColor(self)
        return Color(nsColor: base.blended(withFraction: fraction, of: NSColor(other)) ?? base)
        #else
        return self
        #endif
    }
}
